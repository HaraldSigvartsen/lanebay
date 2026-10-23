import Darwin
import Foundation

public enum AgentHookSupport: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case none
}

public struct KnownAgentCLI: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let executableName: String
    public let defaultArguments: [String]
    public let hookSupport: AgentHookSupport

    public init(id: String, displayName: String, executableName: String, defaultArguments: [String] = [], hookSupport: AgentHookSupport) {
        self.id = id
        self.displayName = displayName
        self.executableName = executableName
        self.defaultArguments = defaultArguments
        self.hookSupport = hookSupport
    }
}

public struct CustomAgentExecutable: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var executablePath: String
    public var arguments: [String]
    public var hookSupport: AgentHookSupport

    public init(
        id: String = "custom-\(UUID().uuidString.lowercased())",
        displayName: String,
        executablePath: String,
        arguments: [String] = [],
        hookSupport: AgentHookSupport = .none
    ) {
        self.id = id
        self.displayName = displayName
        self.executablePath = executablePath
        self.arguments = arguments
        self.hookSupport = hookSupport
    }
}

public struct AgentAccountProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var agentID: String
    public var environment: [String: String]

    public init(id: String = UUID().uuidString, name: String, agentID: String, environment: [String: String]) {
        self.id = id
        self.name = name
        self.agentID = agentID
        self.environment = environment
    }
}

public enum AgentCatalogValidationError: Error, LocalizedError, Equatable {
    case invalidDisplayName
    case executablePathMustBeAbsolute
    case executableDoesNotExist
    case executableIsNotRegularFile
    case executableIsNotExecutable
    case interpolatedArgument(String)
    case invalidProfileName
    case invalidEnvironmentKey(String)
    case secretLikeValue(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDisplayName:
            "Display name is required."
        case .executablePathMustBeAbsolute:
            "Executable path must be an absolute path."
        case .executableDoesNotExist:
            "Executable does not exist."
        case .executableIsNotRegularFile:
            "Executable path must point to a regular file."
        case .executableIsNotExecutable:
            "Executable file is not executable."
        case let .interpolatedArgument(argument):
            "Argument '\(argument)' looks like shell interpolation. Use literal argument array values only."
        case .invalidProfileName:
            "Profile name is required."
        case let .invalidEnvironmentKey(key):
            "Environment key '\(key)' is invalid."
        case let .secretLikeValue(key):
            "Environment value for '\(key)' looks like a secret and is not allowed (best-effort heuristic only, not a security boundary)."
        }
    }
}

public enum AgentCatalog {
    public static let knownCLIs: [KnownAgentCLI] = [
        .init(id: "shell", displayName: "Shell", executableName: "zsh", defaultArguments: ["-l"], hookSupport: .none),
        .init(id: "codex", displayName: "Codex", executableName: "codex", hookSupport: .codex),
        .init(id: "claude", displayName: "Claude Code", executableName: "claude", hookSupport: .claude),
        .init(id: "opencode", displayName: "OpenCode", executableName: "opencode", hookSupport: .none),
        .init(id: "aider", displayName: "Aider", executableName: "aider", hookSupport: .none),
        .init(id: "gemini-cli", displayName: "Gemini CLI", executableName: "gemini", hookSupport: .none),
        .init(id: "cursor-agent", displayName: "Cursor Agent", executableName: "cursor-agent", hookSupport: .none),
        .init(id: "amp", displayName: "Amp", executableName: "amp", hookSupport: .none),
        .init(id: "goose", displayName: "Goose", executableName: "goose", hookSupport: .none),
        .init(id: "qwen-code", displayName: "Qwen Code", executableName: "qwen-code", hookSupport: .none),
        .init(id: "crush", displayName: "Crush", executableName: "crush", hookSupport: .none),
        .init(id: "the-bins", displayName: "The Bins", executableName: "the-bins", hookSupport: .none),
        .init(id: "void", displayName: "Void", executableName: "void", hookSupport: .none),
        .init(id: "kilocode", displayName: "Kilo Code", executableName: "kilocode", hookSupport: .none),
        .init(id: "cline", displayName: "Cline", executableName: "cline", hookSupport: .none),
        .init(id: "roo-code", displayName: "Roo Code", executableName: "roo-code", hookSupport: .none),
        .init(id: "warp-agent", displayName: "Warp Agent", executableName: "warp-agent", hookSupport: .none),
        .init(id: "amazon-q", displayName: "Amazon Q", executableName: "q", hookSupport: .none),
        .init(id: "github-copilot-cli", displayName: "GitHub Copilot CLI", executableName: "github-copilot", hookSupport: .none),
        .init(id: "llm", displayName: "LLM", executableName: "llm", hookSupport: .none),
        .init(id: "mods", displayName: "Mods", executableName: "mods", hookSupport: .none),
        .init(id: "sgpt", displayName: "Shell GPT", executableName: "sgpt", hookSupport: .none),
        .init(id: "fabric", displayName: "Fabric", executableName: "fabric", hookSupport: .none),
        .init(id: "simonw-ai", displayName: "Simonw AI", executableName: "ai", hookSupport: .none),
        .init(id: "chatblade", displayName: "Chatblade", executableName: "chatblade", hookSupport: .none),
        .init(id: "tgpt", displayName: "tgpt", executableName: "tgpt", hookSupport: .none),
        .init(id: "plandex", displayName: "Plandex", executableName: "plandex", hookSupport: .none),
        .init(id: "codebuff", displayName: "Codebuff", executableName: "codebuff", hookSupport: .none),
        .init(id: "gptme", displayName: "GPTme", executableName: "gptme", hookSupport: .none),
        .init(id: "rivet", displayName: "Rivet", executableName: "rivet", hookSupport: .none),
        .init(id: "autogenstudio", displayName: "AutoGen Studio", executableName: "autogenstudio", hookSupport: .none),
        .init(id: "openhands", displayName: "OpenHands", executableName: "openhands", hookSupport: .none),
        .init(id: "devon", displayName: "Devon", executableName: "devon", hookSupport: .none),
        .init(id: "semgrep-agent", displayName: "Semgrep Agent", executableName: "semgrep-agent", hookSupport: .none),
    ]

    public static let defaultExecutableSearchDirectories: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin", isDirectory: true),
    ]

    public static func validate(custom executable: CustomAgentExecutable, fileManager: FileManager = .default) throws {
        guard !executable.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentCatalogValidationError.invalidDisplayName
        }
        guard executable.executablePath.hasPrefix("/") else {
            throw AgentCatalogValidationError.executablePathMustBeAbsolute
        }
        let path = URL(fileURLWithPath: executable.executablePath).standardizedFileURL.path
        guard fileManager.fileExists(atPath: path) else { throw AgentCatalogValidationError.executableDoesNotExist }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw AgentCatalogValidationError.executableIsNotRegularFile
        }
        guard access(path, X_OK) == 0 else { throw AgentCatalogValidationError.executableIsNotExecutable }
        for argument in executable.arguments where looksLikeShellInterpolation(argument) {
            throw AgentCatalogValidationError.interpolatedArgument(argument)
        }
    }

    public static func validate(profile: AgentAccountProfile) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentCatalogValidationError.invalidProfileName
        }
        for (key, value) in profile.environment {
            guard isValidEnvironmentKey(key) else {
                throw AgentCatalogValidationError.invalidEnvironmentKey(key)
            }
            if looksLikeSecret(value) {
                throw AgentCatalogValidationError.secretLikeValue(key)
            }
        }
    }

    public static func detectInstalledKnownAgents(
        searchDirectories: [URL] = AgentCatalog.defaultExecutableSearchDirectories,
        fileManager: FileManager = .default
    ) -> Set<String> {
        Set(knownCLIs.compactMap { cli in
            resolve(executableName: cli.executableName, searchDirectories: searchDirectories, fileManager: fileManager) == nil ? nil : cli.id
        })
    }

    public static func resolve(executableName: String, searchDirectories: [URL], fileManager: FileManager = .default) -> URL? {
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(executableName)
            if isExecutableFile(candidate, fileManager: fileManager) { return candidate }
        }
        return nil
    }

    public static func isExecutableFile(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return false }
        return access(url.path, X_OK) == 0
    }

    private static func looksLikeShellInterpolation(_ argument: String) -> Bool {
        let markers = ["$(", "${", "`", "&&", "||", "|", ";", ">", "<"]
        return markers.contains { argument.contains($0) }
    }

    private static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        guard let first = key.first, (first == "_" || first.isUppercase) else { return false }
        return key.allSatisfy { $0 == "_" || $0.isNumber || $0.isUppercase }
    }

    private static func looksLikeSecret(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 24 && (trimmed.hasPrefix("sk-") || trimmed.hasPrefix("ghp_") || trimmed.hasPrefix("gho_")) {
            return true
        }
        let lower = trimmed.lowercased()
        if lower.contains("api_key") || lower.contains("apikey") || lower.contains("token") || lower.contains("secret") {
            return true
        }
        let charset = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        if trimmed.count >= 32 && trimmed.unicodeScalars.allSatisfy({ charset.contains($0) }) {
            return true
        }
        return false
    }
}
