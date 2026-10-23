import Foundation

/// Preferences shared by the app's panels and persisted as a single versioned JSON document.
public struct AppPreferences: Codable, Sendable, Equatable {
    public var version: Int
    public var defaultWorkingDirectory: URL?
    public var restoreLastWorkspace: Bool
    public var showNotifications: Bool
    public var speakWaitingForInputStatus: Bool
    public var lastWorkspaceID: UUID?
    public var customExecutables: [CustomAgentExecutable]
    public var accountProfiles: [AgentAccountProfile]
    public var lastUsedAgentID: String?
    public var recentWorkingDirectories: [URL]
    /// When true, a send to another console shows the target and the text first.
    public var askBeforeSendingToTerminal: Bool

    public init(
        version: Int = AppPreferencesStore.currentSchemaVersion,
        defaultWorkingDirectory: URL? = nil,
        restoreLastWorkspace: Bool = true,
        showNotifications: Bool = true,
        speakWaitingForInputStatus: Bool = false,
        lastWorkspaceID: UUID? = nil,
        customExecutables: [CustomAgentExecutable] = [],
        accountProfiles: [AgentAccountProfile] = [],
        lastUsedAgentID: String? = nil,
        recentWorkingDirectories: [URL] = [],
        askBeforeSendingToTerminal: Bool = true
    ) {
        self.version = version
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.restoreLastWorkspace = restoreLastWorkspace
        self.showNotifications = showNotifications
        self.speakWaitingForInputStatus = speakWaitingForInputStatus
        self.lastWorkspaceID = lastWorkspaceID
        self.customExecutables = customExecutables
        self.accountProfiles = accountProfiles
        self.lastUsedAgentID = lastUsedAgentID
        self.recentWorkingDirectories = recentWorkingDirectories
        self.askBeforeSendingToTerminal = askBeforeSendingToTerminal
    }

    private enum CodingKeys: String, CodingKey {
        case version, defaultWorkingDirectory, restoreLastWorkspace, showNotifications, speakWaitingForInputStatus, lastWorkspaceID
        case customExecutables, accountProfiles, lastUsedAgentID, recentWorkingDirectories, askBeforeSendingToTerminal
        case speakNeedsYouStatus // legacy key
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let speak = try values.decodeIfPresent(Bool.self, forKey: .speakWaitingForInputStatus)
            ?? values.decodeIfPresent(Bool.self, forKey: .speakNeedsYouStatus) // legacy key
        self.init(
            version: try values.decodeIfPresent(Int.self, forKey: .version) ?? 1,
            defaultWorkingDirectory: try values.decodeIfPresent(URL.self, forKey: .defaultWorkingDirectory),
            restoreLastWorkspace: try values.decodeIfPresent(Bool.self, forKey: .restoreLastWorkspace) ?? true,
            showNotifications: try values.decodeIfPresent(Bool.self, forKey: .showNotifications) ?? true,
            speakWaitingForInputStatus: speak ?? false,
            lastWorkspaceID: try values.decodeIfPresent(UUID.self, forKey: .lastWorkspaceID),
            customExecutables: try values.decodeIfPresent([CustomAgentExecutable].self, forKey: .customExecutables) ?? [],
            accountProfiles: try values.decodeIfPresent([AgentAccountProfile].self, forKey: .accountProfiles) ?? [],
            lastUsedAgentID: Self.sanitizedAgentID(try values.decodeIfPresent(String.self, forKey: .lastUsedAgentID)),
            recentWorkingDirectories: Self.sanitizedDirectories(
                try values.decodeIfPresent([URL].self, forKey: .recentWorkingDirectories) ?? []),
            askBeforeSendingToTerminal: try values.decodeIfPresent(Bool.self, forKey: .askBeforeSendingToTerminal) ?? true
        )
    }

    private static func sanitizedAgentID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NewTerminalDraft.isAcceptableAgentID(trimmed) else { return nil }
        return trimmed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(defaultWorkingDirectory, forKey: .defaultWorkingDirectory)
        try container.encode(restoreLastWorkspace, forKey: .restoreLastWorkspace)
        try container.encode(showNotifications, forKey: .showNotifications)
        try container.encode(speakWaitingForInputStatus, forKey: .speakWaitingForInputStatus)
        try container.encodeIfPresent(lastWorkspaceID, forKey: .lastWorkspaceID)
        try container.encode(customExecutables, forKey: .customExecutables)
        try container.encode(accountProfiles, forKey: .accountProfiles)
        try container.encodeIfPresent(lastUsedAgentID, forKey: .lastUsedAgentID)
        try container.encode(recentWorkingDirectories, forKey: .recentWorkingDirectories)
        try container.encode(askBeforeSendingToTerminal, forKey: .askBeforeSendingToTerminal)
    }

    private static func sanitizedDirectories(_ urls: [URL]) -> [URL] {
        var kept: [URL] = []
        for url in urls {
            guard url.isFileURL, url.path.hasPrefix("/"), url.path.count <= 1_024, !url.path.contains("\0") else { continue }
            let cleaned = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
            if kept.contains(where: { $0.path == cleaned.path }) { continue }
            kept.append(cleaned)
            if kept.count == NewTerminalDraft.recentDirectoryLimit { break }
        }
        return kept
    }

}

public struct AppPreferencesStore {
    public static let currentSchemaVersion = 3
    private let rootURL: URL
    private let fileManager: FileManager

    /// `rootURL` is the preferences directory itself; inject a temporary directory in tests.
    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.rootURL = rootURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lanebay", isDirectory: true)
        self.fileManager = fileManager
    }

    public func load() throws -> AppPreferences {
        let url = rootURL.appendingPathComponent("preferences.json")
        guard fileManager.fileExists(atPath: url.path) else { return AppPreferences() }
        var preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: url))
        guard preferences.version <= Self.currentSchemaVersion else {
            throw AppPreferencesStoreError.unsupportedVersion(preferences.version)
        }
        preferences.version = Self.currentSchemaVersion
        return preferences
    }

    public func save(_ preferences: AppPreferences) throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var stored = preferences
        stored.version = Self.currentSchemaVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        let destination = rootURL.appendingPathComponent("preferences.json")
        try AtomicPrivateFileWriter.write(data, to: destination, temporaryPrefix: "preferences", fileManager: fileManager)
    }
}

public enum AppPreferencesStoreError: Error, LocalizedError {
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version): "Preferences schema version \(version) is unsupported."
        }
    }
}
