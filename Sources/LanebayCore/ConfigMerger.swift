import Foundation

public enum HookConfigError: Error, LocalizedError {
    case malformed(URL, String)
    case unsupportedRoot(URL)
    public var errorDescription: String? {
        switch self { case let .malformed(url, reason): "Refusing to modify malformed hook config at \(url.path): \(reason)"; case let .unsupportedRoot(url): "Hook config at \(url.path) must contain a JSON object." }
    }
}

/// Installs tagged hook entries in isolated injectable config roots. Original files are backed up once.
public struct ConfigMerger {
    public static let marker = "lanebay-managed-hook"
    private let claudeRoot: URL
    private let codexRoot: URL
    private let hooksRoot: URL
    private let fileManager: FileManager

    public init(claudeRoot: URL, codexRoot: URL, hooksRoot: URL, fileManager: FileManager = .default) {
        self.claudeRoot = claudeRoot; self.codexRoot = codexRoot; self.hooksRoot = hooksRoot; self.fileManager = fileManager
    }

    public init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) {
        self.init(claudeRoot: homeURL.appendingPathComponent(".claude", isDirectory: true),
                  codexRoot: homeURL.appendingPathComponent(".codex", isDirectory: true),
                  hooksRoot: homeURL.appendingPathComponent(".lanebay/hooks", isDirectory: true), fileManager: fileManager)
    }

    public func install() throws {
        try validateIfPresent(claudeRoot.appendingPathComponent("settings.json"))
        try validateIfPresent(codexRoot.appendingPathComponent("hooks.json"))
        try HookScriptInstaller().install(to: hooksRoot)
        let script = hooksRoot.appendingPathComponent("lanebay-hook.sh").path
        try mergeClaude(script: script)
        try mergeCodex(script: script)
    }

    public func uninstall() throws {
        try validateIfPresent(claudeRoot.appendingPathComponent("settings.json"))
        try validateIfPresent(codexRoot.appendingPathComponent("hooks.json"))
        try mutate(claudeRoot.appendingPathComponent("settings.json")) { root in
            guard var hooks = root["hooks"] as? [String: Any] else { return }
            for key in Array(hooks.keys) {
                guard let groups = hooks[key] as? [Any] else { continue }
                var removed = false
                let remainingGroups = groups.compactMap { item -> Any? in
                    guard var group = item as? [String: Any], let entries = group["hooks"] as? [Any] else { return item }
                    let remaining = entries.filter { !Self.isManaged($0) }
                    let hadManaged = entries.contains(where: Self.isManaged)
                    removed = removed || hadManaged
                    if hadManaged && remaining.isEmpty { return nil }
                    if hadManaged { group["hooks"] = remaining }
                    return group
                }
                if removed && remainingGroups.isEmpty { hooks.removeValue(forKey: key) } else if removed { hooks[key] = remainingGroups }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        try mutate(codexRoot.appendingPathComponent("hooks.json")) { root in
            guard var hooks = root["hooks"] as? [String: Any] else { return }
            for key in Array(hooks.keys) {
                guard let groups = hooks[key] as? [Any] else { continue }
                var removed = false
                let remainingGroups = groups.compactMap { item -> Any? in
                    guard var group = item as? [String: Any], let entries = group["hooks"] as? [Any] else { return item }
                    let remaining = entries.filter { !Self.isManaged($0) }
                    let hadManaged = entries.contains(where: Self.isManaged)
                    removed = removed || hadManaged
                    if hadManaged && remaining.isEmpty { return nil }
                    if hadManaged { group["hooks"] = remaining }
                    return group
                }
                guard removed else { continue }
                if remainingGroups.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = remainingGroups }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        try removeOriginallyAbsentEmptyConfig(claudeRoot.appendingPathComponent("settings.json"))
        try removeOriginallyAbsentEmptyConfig(codexRoot.appendingPathComponent("hooks.json"))
        try? fileManager.removeItem(at: hooksRoot.appendingPathComponent("lanebay-hook.sh"))
        try? fileManager.removeItem(at: hooksRoot.appendingPathComponent("runtime.json"))
    }

    private func mergeClaude(script: String) throws {
        try mutate(claudeRoot.appendingPathComponent("settings.json")) { root in
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for (event, hookEvent) in Self.claudeEvents {
                var groups = (hooks[event] as? [Any] ?? []).compactMap { item -> Any? in
                    guard var group = item as? [String: Any], let entries = group["hooks"] as? [Any] else { return item }
                    let remaining = entries.filter { !Self.isManaged($0) }
                    let hadManaged = entries.contains(where: Self.isManaged)
                    if hadManaged && remaining.isEmpty { return nil }
                    if hadManaged { group["hooks"] = remaining }
                    return group
                }
                groups.append(["matcher": "", "hooks": [["type": "command", "command": "\(Self.shellQuote(script)) claude \(hookEvent.rawValue) # \(Self.marker)", "timeout": 1]]])
                hooks[event] = groups
            }
            root["hooks"] = hooks
        }
    }

    private func mergeCodex(script: String) throws {
        try mutate(codexRoot.appendingPathComponent("hooks.json")) { root in
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            // Codex currently supports these hook event names; Claude-only lifecycle/UI events are omitted.
            for event in ["SessionStart", "SessionEnd", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop"] {
                var groups = hooks[event] as? [Any] ?? []
                groups = groups.compactMap { item -> Any? in
                    guard var group = item as? [String: Any], let entries = group["hooks"] as? [Any] else { return item }
                    let remaining = entries.filter { !Self.isManaged($0) }
                    let hadManaged = entries.contains(where: Self.isManaged)
                    if hadManaged && remaining.isEmpty { return nil }
                    if hadManaged { group["hooks"] = remaining }
                    return group
                }
                groups.append(["matcher": "*", "hooks": [["type": "command", "command": "\(Self.shellQuote(script)) codex \(Self.codexEventName(event)) # \(Self.marker)"]]])
                hooks[event] = groups
            }
            root["hooks"] = hooks
        }
    }

    private func mutate(_ url: URL, update: (inout [String: Any]) -> Void) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        let existed = fileManager.fileExists(atPath: url.path)
        if existed {
            let data = try Data(contentsOf: url)
            do {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HookConfigError.unsupportedRoot(url) }
                root = object
            } catch let error as HookConfigError { throw error }
            catch { throw HookConfigError.malformed(url, String(describing: error)) }
        }
        update(&root)
        guard JSONSerialization.isValidJSONObject(root) else { throw HookConfigError.unsupportedRoot(url) }
        if existed {
            let backup = url.appendingPathExtension("lanebay.bak")
            let absent = url.appendingPathExtension("lanebay.absent")
            if !fileManager.fileExists(atPath: backup.path), !fileManager.fileExists(atPath: absent.path) { try fileManager.copyItem(at: url, to: backup) }
        } else {
            try Data().write(to: url.appendingPathExtension("lanebay.absent"), options: .atomic)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        try data.write(to: url, options: .atomic)
    }

    private func validateIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            guard try JSONSerialization.jsonObject(with: Data(contentsOf: url)) is [String: Any] else { throw HookConfigError.unsupportedRoot(url) }
        } catch let error as HookConfigError { throw error }
        catch { throw HookConfigError.malformed(url, String(describing: error)) }
    }

    private func removeOriginallyAbsentEmptyConfig(_ url: URL) throws {
        let absent = url.appendingPathExtension("lanebay.absent")
        guard fileManager.fileExists(atPath: absent.path) else { return }
        if fileManager.fileExists(atPath: url.path),
           let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], root.isEmpty {
            try fileManager.removeItem(at: url)
        }
        try fileManager.removeItem(at: absent)
    }

    private static let claudeEvents: [(String, AgentHookEvent)] = [
        ("SessionStart", .sessionStart), ("SessionEnd", .sessionEnd), ("PreToolUse", .preToolUse), ("PostToolUse", .postToolUse),
        ("PostToolUseFailure", .postToolUseFailure), ("PermissionRequest", .permissionRequest), ("Notification", .notification), ("Stop", .stop), ("SubagentStop", .subagentStop),
    ]
    private static func isManaged(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if object[marker] as? Bool == true { return true }
            guard object["type"] as? String == "command", let command = object["command"] as? String else { return false }
            let suffix = " # \(marker)"
            guard command.hasSuffix(suffix) else { return false }
            let invocation = String(command.dropLast(suffix.count))
            return invocation.contains(" lanebay ") || invocation.hasSuffix(" lanebay") || invocation.contains(" claude ") || invocation.hasSuffix(" claude") || invocation.contains(" codex ") || invocation.hasSuffix(" codex")
        }
        return false
    }
    private static func hasEntries(_ value: Any) -> Bool { if let array = value as? [Any] { return !array.isEmpty }; if let object = value as? [String: Any] { return !object.isEmpty }; return true }
    private static func codexEventName(_ event: String) -> String { ["SessionStart":"sessionStart", "SessionEnd":"sessionEnd", "PreToolUse":"preToolUse", "PostToolUse":"postToolUse", "PostToolUseFailure":"postToolUseFailure", "Stop":"stop"][event] ?? event }
    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
