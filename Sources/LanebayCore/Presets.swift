import Foundation

public struct PromptPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var text: String
    public var targetAgentKind: String?

    public init(id: UUID = UUID(), name: String, text: String, targetAgentKind: String? = nil) {
        self.id = id
        self.name = name
        self.text = text
        self.targetAgentKind = targetAgentKind
    }
}

public struct PresetsStore {
    public static let maximumFileBytes = 262_144
    public static let maximumPresets = 200
    public static let maximumNameBytes = 256
    public static let maximumTextBytes = 8_192
    public static let maximumAgentKindBytes = 64
    private let rootURL: URL
    private let fileManager: FileManager
    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.rootURL = rootURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lanebay", isDirectory: true)
        self.fileManager = fileManager
    }

    public func load() throws -> [PromptPreset] {
        let url = rootURL.appendingPathComponent("presets.json")
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumFileBytes else { throw PresetsStoreError.fileTooLarge(Self.maximumFileBytes) }
        let presets = try JSONDecoder().decode([PromptPreset].self, from: data)
        return try validate(presets)
    }

    public func save(_ presets: [PromptPreset]) throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let validated = try validate(presets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(validated)
        guard data.count <= Self.maximumFileBytes else { throw PresetsStoreError.fileTooLarge(Self.maximumFileBytes) }
        let destination = rootURL.appendingPathComponent("presets.json")
        try AtomicPrivateFileWriter.write(data, to: destination, temporaryPrefix: "presets", fileManager: fileManager)
    }

    private func validate(_ presets: [PromptPreset]) throws -> [PromptPreset] {
        guard presets.count <= Self.maximumPresets else { throw PresetsStoreError.tooManyPresets(Self.maximumPresets) }
        return try presets.map { preset in
            guard preset.name.utf8.count <= Self.maximumNameBytes else { throw PresetsStoreError.nameTooLarge(Self.maximumNameBytes) }
            guard preset.text.utf8.count <= Self.maximumTextBytes else { throw PresetsStoreError.textTooLarge(Self.maximumTextBytes) }
            if let kind = preset.targetAgentKind, kind.utf8.count > Self.maximumAgentKindBytes {
                throw PresetsStoreError.targetTooLarge(Self.maximumAgentKindBytes)
            }
            return preset
        }
    }
}

public enum PresetsStoreError: LocalizedError {
    case fileTooLarge(Int)
    case tooManyPresets(Int)
    case nameTooLarge(Int)
    case textTooLarge(Int)
    case targetTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let max): return "Presets are too large to load or save (limit \(max) bytes)."
        case .tooManyPresets(let max): return "Too many presets (limit \(max))."
        case .nameTooLarge(let max): return "Preset name is too long (limit \(max) bytes)."
        case .textTooLarge(let max): return "Preset text is too long (limit \(max) bytes)."
        case .targetTooLarge(let max): return "Preset target is too long (limit \(max) bytes)."
        }
    }
}
