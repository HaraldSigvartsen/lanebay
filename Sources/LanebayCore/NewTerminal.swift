import Darwin
import Foundation

public struct NewTerminalAgent: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var isCustom: Bool

    public init(id: String, title: String, isCustom: Bool) {
        self.id = id
        self.title = title
        self.isCustom = isCustom
    }
}

public struct NewTerminalDirectory: Equatable, Sendable, Identifiable {
    public var path: String
    public var id: String { path }

    public init(path: String) {
        self.path = path
    }
}

/// One-step terminal setup: a short agent list, a remembered folder, and Return to create.
public struct NewTerminalDraft: Equatable, Sendable {
    public static let featuredAgentIDs = ["shell", "orchestrator", "codex", "claude", "cursor-agent"]
    public static let recentDirectoryLimit = 8

    public var agents: [NewTerminalAgent]
    public var selectedAgentID: String
    public var directories: [NewTerminalDirectory]
    public var selectedDirectoryPath: String

    public var featuredAgents: [NewTerminalAgent] { agents.filter { !$0.isCustom } }
    public var customAgents: [NewTerminalAgent] { agents.filter(\.isCustom) }

    public var selectedDirectory: URL? {
        guard selectedDirectoryPath.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: selectedDirectoryPath, isDirectory: true)
    }

    public init(
        agents: [NewTerminalAgent],
        selectedAgentID: String,
        directories: [NewTerminalDirectory],
        selectedDirectoryPath: String
    ) {
        self.agents = agents
        self.selectedAgentID = selectedAgentID
        self.directories = directories
        self.selectedDirectoryPath = selectedDirectoryPath
    }

    public static func agents(
        knownAgents: [KnownAgentCLI],
        customExecutables: [CustomAgentExecutable]
    ) -> [NewTerminalAgent] {
        var result: [NewTerminalAgent] = []
        for id in featuredAgentIDs {
            if id == OrchestratorKind.agentID {
                result.append(NewTerminalAgent(id: id, title: OrchestratorKind.title, isCustom: false))
                continue
            }
            guard let known = knownAgents.first(where: { $0.id == id }) else { continue }
            result.append(NewTerminalAgent(id: known.id, title: known.displayName, isCustom: false))
        }
        for custom in customExecutables {
            let id = custom.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = custom.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isAcceptableAgentID(id), !title.isEmpty, !result.contains(where: { $0.id == id }) else { continue }
            result.append(NewTerminalAgent(id: id, title: title, isCustom: true))
        }
        return result
    }

    public static func make(
        knownAgents: [KnownAgentCLI],
        customExecutables: [CustomAgentExecutable],
        lastUsedAgentID: String?,
        recentDirectories: [URL],
        defaultDirectory: URL?,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> NewTerminalDraft {
        let agents = agents(knownAgents: knownAgents, customExecutables: customExecutables)
        let selectedAgentID: String
        if let lastUsedAgentID, agents.contains(where: { $0.id == lastUsedAgentID }) {
            selectedAgentID = lastUsedAgentID
        } else if agents.contains(where: { $0.id == "shell" }) {
            selectedAgentID = "shell"
        } else {
            selectedAgentID = agents.first?.id ?? "shell"
        }
        var directories: [URL] = []
        func add(_ url: URL?) {
            guard directories.count < recentDirectoryLimit,
                let url,
                let valid = validatedDirectory(url, fileManager: fileManager),
                !directories.contains(where: { $0.path == valid.path })
            else { return }
            directories.append(valid)
        }
        for url in recentDirectories { add(url) }
        add(defaultDirectory)
        if directories.isEmpty { add(homeDirectory) }
        return NewTerminalDraft(
            agents: agents,
            selectedAgentID: selectedAgentID,
            directories: directories.map { NewTerminalDirectory(path: $0.path) },
            selectedDirectoryPath: directories.first?.path ?? ""
        )
    }

    public func selectingAgent(_ id: String) -> NewTerminalDraft {
        guard agents.contains(where: { $0.id == id }) else { return self }
        var copy = self
        copy.selectedAgentID = id
        return copy
    }

    public func selectingDirectory(_ path: String) -> NewTerminalDraft {
        guard directories.contains(where: { $0.path == path }) else { return self }
        var copy = self
        copy.selectedDirectoryPath = path
        return copy
    }

    public func insertingDirectory(_ url: URL, fileManager: FileManager = .default) -> NewTerminalDraft {
        guard let valid = Self.validatedDirectory(url, fileManager: fileManager) else { return self }
        var copy = self
        copy.directories.removeAll { $0.path == valid.path }
        copy.directories.insert(NewTerminalDirectory(path: valid.path), at: 0)
        if copy.directories.count > Self.recentDirectoryLimit {
            copy.directories = Array(copy.directories.prefix(Self.recentDirectoryLimit))
        }
        copy.selectedDirectoryPath = valid.path
        return copy
    }

    /// Keeps the chosen folder first. Drops missing folders and anything past the cap.
    public static func rememberedDirectories(
        existing: [URL],
        chosen: URL,
        fileManager: FileManager = .default
    ) -> [URL]? {
        guard let chosen = validatedDirectory(chosen, fileManager: fileManager) else { return nil }
        var kept = [chosen]
        for url in existing {
            guard kept.count < recentDirectoryLimit,
                let valid = validatedDirectory(url, fileManager: fileManager),
                !kept.contains(where: { $0.path == valid.path })
            else { continue }
            kept.append(valid)
        }
        return kept
    }

    /// An existing directory the process may enter. Symlinks resolve to that directory.
    public static func validatedDirectory(_ url: URL, fileManager: FileManager = .default) -> URL? {
        guard url.isFileURL else { return nil }
        let raw = url.path
        guard raw.hasPrefix("/"), raw.count <= 1_024, !raw.contains("\0") else { return nil }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix("/"), path.count <= 1_024, !path.contains("\0") else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        guard access(path, X_OK) == 0 else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func isAcceptableAgentID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128, !id.contains("/"), !id.contains("\0") else { return false }
        return id.unicodeScalars.allSatisfy { $0.value >= 32 }
    }
}
