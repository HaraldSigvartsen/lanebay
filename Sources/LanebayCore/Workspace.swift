import Foundation

public struct Workspace: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var version: Int
    public var repos: [URL]
    public var nodes: [Node]
    public var groups: [Group]
    public var loops: [Loop]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, version: Int = 1, repos: [URL] = [], nodes: [Node] = [], groups: [Group] = [], loops: [Loop] = [], createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.version = version
        self.repos = repos
        self.nodes = nodes
        self.groups = groups
        self.loops = loops
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum NodeKind: String, Codable, Sendable { case console, note, panel }

public struct NodeFrame: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public struct Node: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var kind: NodeKind
    public var agentID: String?
    public var cwd: URL
    public var frame: NodeFrame
    public var profileID: String?
    public var title: String
    public var notStarted: Bool

    public init(id: UUID = UUID(), kind: NodeKind, agentID: String? = nil, cwd: URL, frame: NodeFrame, profileID: String? = nil, title: String, notStarted: Bool = false) {
        self.id = id; self.kind = kind; self.agentID = agentID; self.cwd = cwd; self.frame = frame
        self.profileID = profileID; self.title = title; self.notStarted = notStarted
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, agentID, cwd, frame, profileID, title, notStarted
        case dormant // legacy key
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(NodeKind.self, forKey: .kind)
        agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
        cwd = try container.decode(URL.self, forKey: .cwd)
        frame = try container.decode(NodeFrame.self, forKey: .frame)
        profileID = try container.decodeIfPresent(String.self, forKey: .profileID)
        title = try container.decode(String.self, forKey: .title)
        notStarted = try container.decodeIfPresent(Bool.self, forKey: .notStarted)
            ?? container.decodeIfPresent(Bool.self, forKey: .dormant) ?? false // legacy key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(agentID, forKey: .agentID)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(frame, forKey: .frame)
        try container.encodeIfPresent(profileID, forKey: .profileID)
        try container.encode(title, forKey: .title)
        try container.encode(notStarted, forKey: .notStarted)
    }
}

public struct Group: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var nodeIDs: [UUID]
    public var color: String
    public var leadNodeID: UUID?
    public init(id: UUID = UUID(), name: String, nodeIDs: [UUID] = [], color: String, leadNodeID: UUID? = nil) {
        self.id = id; self.name = name; self.nodeIDs = nodeIDs; self.color = color; self.leadNodeID = leadNodeID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, nodeIDs, color, leadNodeID
        case commanderNodeID // legacy key
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        nodeIDs = try container.decode([UUID].self, forKey: .nodeIDs)
        color = try container.decode(String.self, forKey: .color)
        leadNodeID = try container.decodeIfPresent(UUID.self, forKey: .leadNodeID)
            ?? container.decodeIfPresent(UUID.self, forKey: .commanderNodeID) // legacy key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(nodeIDs, forKey: .nodeIDs)
        try container.encode(color, forKey: .color)
        try container.encodeIfPresent(leadNodeID, forKey: .leadNodeID)
    }
}


public enum WorkspaceStoreError: Error, LocalizedError {
    case invalidWorkspaceID
    case unsupportedVersion(Int)
    case migrationFailed(String)
    case corruptFile(URL, String)

    public var errorDescription: String? {
        switch self {
        case .invalidWorkspaceID: "Workspace ID must be a UUID."
        case let .unsupportedVersion(version): "Workspace schema version \(version) is unsupported."
        case let .migrationFailed(message): "Workspace migration failed: \(message)"
        case let .corruptFile(url, reason): "Corrupt workspace moved to \(url.path): \(reason)"
        }
    }
}

/// JSON persistence for workspaces. The migration hook receives the decoded JSON object and its schema version.
public struct WorkspaceStore {
    public typealias Migration = @Sendable (_ object: [String: Any], _ fromVersion: Int, _ toVersion: Int) throws -> [String: Any]
    public static let currentSchemaVersion = 1

    private let rootURL: URL
    private let fileManager: FileManager
    private let migration: Migration?

    public init(rootURL: URL? = nil, fileManager: FileManager = .default, migration: Migration? = nil) {
        self.rootURL = rootURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lanebay/workspaces", isDirectory: true)
        self.fileManager = fileManager
        self.migration = migration
    }

    public func list() throws -> [Workspace] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { try load(id: $0.deletingPathExtension().lastPathComponent) }
    }

    public func load(id: UUID) throws -> Workspace { try load(id: id.uuidString) }

    public func load(id: String) throws -> Workspace {
        guard UUID(uuidString: id) != nil else { throw WorkspaceStoreError.invalidWorkspaceID }
        let url = fileURL(id: id)
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var workspace: Workspace
            do { workspace = try decoder.decode(Workspace.self, from: data) }
            catch {
                workspace = try decodeMigrated(data, originalError: error)
            }
            workspace.nodes = workspace.nodes.map { node in
                var node = node
                if node.kind == .console { node.notStarted = true }
                return node
            }
            return workspace
        } catch let error as WorkspaceStoreError {
            if case .unsupportedVersion = error { throw error }
            let quarantine = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(Self.timestamp())")
            do { try fileManager.moveItem(at: url, to: quarantine) } catch { }
            if case let .corruptFile(_, reason) = error { throw WorkspaceStoreError.corruptFile(quarantine, reason) }
            throw WorkspaceStoreError.corruptFile(quarantine, error.localizedDescription)
        }
        catch {
            let quarantine = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(Self.timestamp())")
            do { try fileManager.moveItem(at: url, to: quarantine) }
            catch { /* Preserve original decode/read failure if quarantine itself is unavailable. */ }
            throw WorkspaceStoreError.corruptFile(quarantine, String(describing: error))
        }
    }

    public func save(_ workspace: Workspace) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var stored = workspace
        stored.version = Self.currentSchemaVersion
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        let destination = fileURL(id: stored.id.uuidString)
        let temporary = rootURL.appendingPathComponent(".\(stored.id.uuidString).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            if fileManager.fileExists(atPath: destination.path) {
                let backup = rootURL.appendingPathComponent(".\(stored.id.uuidString).\(UUID().uuidString).bak")
                try fileManager.moveItem(at: destination, to: backup)
                do {
                    try fileManager.moveItem(at: temporary, to: destination)
                    try? fileManager.removeItem(at: backup)
                } catch {
                    try? fileManager.moveItem(at: backup, to: destination)
                    throw error
                }
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    public func delete(id: UUID) throws { try delete(id: id.uuidString) }

    public func delete(id: String) throws {
        guard UUID(uuidString: id) != nil else { throw WorkspaceStoreError.invalidWorkspaceID }
        let url = fileURL(id: id)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func decodeMigrated(_ data: Data, originalError: Error) throws -> Workspace {
        guard let migration,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int else { throw originalError }
        guard version <= Self.currentSchemaVersion else { throw WorkspaceStoreError.unsupportedVersion(version) }
        guard version < Self.currentSchemaVersion else { throw originalError }
        do {
            let migrated = try migration(object, version, Self.currentSchemaVersion)
            let migratedData = try JSONSerialization.data(withJSONObject: migrated)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Workspace.self, from: migratedData)
        } catch let error as WorkspaceStoreError { throw error }
        catch { throw WorkspaceStoreError.migrationFailed(String(describing: error)) }
    }

    private func fileURL(id: String) -> URL { rootURL.appendingPathComponent("\(id).json") }
    private static func timestamp() -> String { String(Int(Date().timeIntervalSince1970 * 1_000)) }
}
