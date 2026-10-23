import Foundation

public struct UsageSessionSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var agent: String
    public var startedAt: Date
    public var endedAt: Date
    public var durationSeconds: Double
}

public struct UsageWorkspaceDaySummary: Codable, Sendable, Equatable {
    public var workspaceID: UUID
    public var workspaceName: String
    public var dispatchedPrompts: Int
    public var loopIterations: Int
    public var runningSeconds: Double
    public var idleSeconds: Double
    public var waitingForInputSeconds: Double
    public var sessions: [UsageSessionSummary]

    public init(workspaceID: UUID, workspaceName: String) {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.dispatchedPrompts = 0
        self.loopIterations = 0
        self.runningSeconds = 0
        self.idleSeconds = 0
        self.waitingForInputSeconds = 0
        self.sessions = []
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID, workspaceName, dispatchedPrompts, loopIterations, sessions
        case runningSeconds, idleSeconds, waitingForInputSeconds
        case workingSeconds, restingSeconds, needsYouSeconds // legacy keys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        workspaceName = try container.decode(String.self, forKey: .workspaceName)
        dispatchedPrompts = try container.decodeIfPresent(Int.self, forKey: .dispatchedPrompts) ?? 0
        loopIterations = try container.decodeIfPresent(Int.self, forKey: .loopIterations) ?? 0
        sessions = try container.decodeIfPresent([UsageSessionSummary].self, forKey: .sessions) ?? []
        runningSeconds = try container.decodeIfPresent(Double.self, forKey: .runningSeconds)
            ?? container.decodeIfPresent(Double.self, forKey: .workingSeconds) ?? 0 // legacy key
        idleSeconds = try container.decodeIfPresent(Double.self, forKey: .idleSeconds)
            ?? container.decodeIfPresent(Double.self, forKey: .restingSeconds) ?? 0 // legacy key
        waitingForInputSeconds = try container.decodeIfPresent(Double.self, forKey: .waitingForInputSeconds)
            ?? container.decodeIfPresent(Double.self, forKey: .needsYouSeconds) ?? 0 // legacy key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(workspaceName, forKey: .workspaceName)
        try container.encode(dispatchedPrompts, forKey: .dispatchedPrompts)
        try container.encode(loopIterations, forKey: .loopIterations)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(runningSeconds, forKey: .runningSeconds)
        try container.encode(idleSeconds, forKey: .idleSeconds)
        try container.encode(waitingForInputSeconds, forKey: .waitingForInputSeconds)
    }
}

public struct UsageDaySummary: Codable, Sendable, Equatable {
    public var day: String
    public var workspaces: [UsageWorkspaceDaySummary]

    public init(day: String, workspaces: [UsageWorkspaceDaySummary]) {
        self.day = day
        self.workspaces = workspaces
    }
}

public struct UsageStatsDocument: Codable, Sendable, Equatable {
    public var version: Int
    public var days: [UsageDaySummary]

    public init(version: Int = UsageStatsStore.currentSchemaVersion, days: [UsageDaySummary] = []) {
        self.version = version
        self.days = days
    }
}

public enum UsageStatsStoreError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case fileTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version): "Usage stats schema version \(version) is unsupported."
        case let .fileTooLarge(bytes): "Usage stats file is too large (\(bytes) bytes)."
        }
    }
}

public struct UsageStatsStore {
    public static let currentSchemaVersion = 1
    public static let maxFileBytes = 1_048_576
    public static let maxDays = 45
    public static let maxSessionsPerWorkspaceDay = 250

    private let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.rootURL = rootURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lanebay", isDirectory: true)
        self.fileManager = fileManager
    }

    public func load() throws -> UsageStatsDocument {
        let file = fileURL
        guard fileManager.fileExists(atPath: file.path) else { return UsageStatsDocument() }
        let attributes = try fileManager.attributesOfItem(atPath: file.path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard bytes <= Self.maxFileBytes else { throw UsageStatsStoreError.fileTooLarge(bytes) }
        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(UsageStatsDocument.self, from: data)
        guard document.version == Self.currentSchemaVersion else {
            throw UsageStatsStoreError.unsupportedVersion(document.version)
        }
        return document
    }

    public func save(_ document: UsageStatsDocument) throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var bounded = document
        bounded.version = Self.currentSchemaVersion
        bounded.days = Array(bounded.days.sorted { $0.day > $1.day }.prefix(Self.maxDays))
        bounded.days = bounded.days.map { day in
            var normalized = day
            normalized.workspaces = normalized.workspaces.map { workspace in
                var copy = workspace
                if copy.sessions.count > Self.maxSessionsPerWorkspaceDay {
                    copy.sessions = Array(copy.sessions.suffix(Self.maxSessionsPerWorkspaceDay))
                }
                return copy
            }
            return normalized
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(bounded)
        guard data.count <= Self.maxFileBytes else {
            throw UsageStatsStoreError.fileTooLarge(data.count)
        }
        try AtomicPrivateFileWriter.write(data, to: fileURL, temporaryPrefix: "usage-stats", fileManager: fileManager)
    }

    private var fileURL: URL { rootURL.appendingPathComponent("usage-stats.json") }
}

public struct UsageStatusDuration: Sendable, Equatable {
    public var running: Double
    public var idle: Double
    public var waitingForInput: Double
}

public struct UsageLogSnapshot: Sendable, Equatable {
    public var statusDuration: UsageStatusDuration
    public var dispatchedPrompts: Int
    public var loopIterations: Int
}

public struct LocalUsageLogSnapshotReader {
    public static let maxLogFiles = 20
    public static let maxLogFileBytes = 524_288

    private let homeRoot: URL
    private let fileManager: FileManager

    public init(homeRoot: URL, fileManager: FileManager = .default) {
        self.homeRoot = homeRoot
        self.fileManager = fileManager
    }

    public func snapshot() -> UsageLogSnapshot? {
        let roots = [".codex", ".claude", ".cursor"].map { homeRoot.appendingPathComponent($0, isDirectory: true) }
        let candidates = roots.filter { fileManager.fileExists(atPath: $0.path) }
        guard !candidates.isEmpty else { return nil }
        var files: [URL] = []
        for root in candidates {
            if let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let file as URL in enumerator {
                    if files.count >= Self.maxLogFiles { break }
                    let name = file.lastPathComponent.lowercased()
                    if !(name.contains("usage") || name.contains("session")) { continue }
                    if !name.hasSuffix(".jsonl") && !name.hasSuffix(".log") && !name.hasSuffix(".json") { continue }
                    let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    if values?.isSymbolicLink == true {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard values?.isRegularFile == true else { continue }
                    guard (values?.fileSize ?? 0) <= Self.maxLogFileBytes else { continue }
                    files.append(file)
                }
            }
        }
        guard !files.isEmpty else { return nil }
        var snapshot = UsageLogSnapshot(
            statusDuration: UsageStatusDuration(running: 0, idle: 0, waitingForInput: 0),
            dispatchedPrompts: 0,
            loopIterations: 0
        )
        for file in files {
            guard let text = try? String(decoding: Data(contentsOf: file), as: UTF8.self) else { continue }
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { continue }
                if let prompts = object["dispatchedPrompts"] as? Int { snapshot.dispatchedPrompts += max(0, prompts) }
                if let loops = object["loopIterations"] as? Int { snapshot.loopIterations += max(0, loops) }
                if let status = (object["status"] as? String)?.lowercased(),
                   let seconds = object["durationSeconds"] as? Double {
                    switch status {
                    case "running", "working": snapshot.statusDuration.running += max(0, seconds) // legacy key: working
                    case "idle", "resting": snapshot.statusDuration.idle += max(0, seconds) // legacy key: resting
                    case "waitingforinput", "needsyou", "needs-you", "needs_you": snapshot.statusDuration.waitingForInput += max(0, seconds) // legacy keys
                    default: break
                    }
                }
            }
        }
        return snapshot
    }
}

@MainActor
public final class UsageStatsTracker {
    private struct SessionState {
        var workspaceID: UUID
        var workspaceName: String
        var agent: String
        var startedAt: Date
        var lastStatus: String
        var lastStatusAt: Date
    }

    private let store: UsageStatsStore
    private var document: UsageStatsDocument
    private var sessions: [UUID: SessionState] = [:]
    private let calendar = Calendar(identifier: .gregorian)
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    public init(store: UsageStatsStore = UsageStatsStore()) {
        self.store = store
        self.document = (try? store.load()) ?? UsageStatsDocument()
    }

    public func workspaceDidChange(id: UUID, name: String, at: Date = .now) {
        _ = workspaceDay(day: dayFormatter.string(from: at), workspaceID: id, workspaceName: name)
        persist()
    }

    public func sessionStarted(id: UUID, workspaceID: UUID, workspaceName: String, agent: String, status: String, at: Date = .now) {
        sessions[id] = SessionState(
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            agent: agent,
            startedAt: at,
            lastStatus: normalized(status),
            lastStatusAt: at
        )
        _ = workspaceDay(day: dayFormatter.string(from: at), workspaceID: workspaceID, workspaceName: workspaceName)
        persist()
    }

    public func sessionStatusChanged(id: UUID, status: String, at: Date = .now) {
        guard var state = sessions[id] else { return }
        accumulateStatusDuration(state: state, until: at)
        state.lastStatus = normalized(status)
        state.lastStatusAt = at
        sessions[id] = state
        persist()
    }

    public func sessionEnded(id: UUID, at: Date = .now) {
        guard let state = sessions.removeValue(forKey: id) else { return }
        accumulateStatusDuration(state: state, until: at)
        let day = dayFormatter.string(from: state.startedAt)
        var workspace = workspaceDay(day: day, workspaceID: state.workspaceID, workspaceName: state.workspaceName)
        let duration = max(0, at.timeIntervalSince(state.startedAt))
        let session = UsageSessionSummary(
            id: id,
            agent: state.agent,
            startedAt: state.startedAt,
            endedAt: at,
            durationSeconds: duration
        )
        workspace.sessions.append(session)
        setWorkspaceDay(workspace, day: day)
        persist()
    }

    public func recordPromptDispatch(workspaceID: UUID, workspaceName: String, count: Int, at: Date = .now) {
        guard count > 0 else { return }
        let day = dayFormatter.string(from: at)
        var workspace = workspaceDay(day: day, workspaceID: workspaceID, workspaceName: workspaceName)
        workspace.dispatchedPrompts += count
        setWorkspaceDay(workspace, day: day)
        persist()
    }

    public func recordLoopIteration(workspaceID: UUID, workspaceName: String, at: Date = .now) {
        let day = dayFormatter.string(from: at)
        var workspace = workspaceDay(day: day, workspaceID: workspaceID, workspaceName: workspaceName)
        workspace.loopIterations += 1
        setWorkspaceDay(workspace, day: day)
        persist()
    }

    public func loadDocument() -> UsageStatsDocument {
        document = (try? store.load()) ?? document
        return document
    }

    private func accumulateStatusDuration(state: SessionState, until end: Date) {
        guard end > state.lastStatusAt else { return }
        var cursor = state.lastStatusAt
        while cursor < end {
            let nextDay = calendar.startOfDay(for: cursor).addingTimeInterval(86_400)
            let segmentEnd = min(end, nextDay)
            let seconds = segmentEnd.timeIntervalSince(cursor)
            let day = dayFormatter.string(from: cursor)
            var workspace = workspaceDay(day: day, workspaceID: state.workspaceID, workspaceName: state.workspaceName)
            switch normalized(state.lastStatus) {
            case "running": workspace.runningSeconds += seconds
            case "idle": workspace.idleSeconds += seconds
            case "waitingForInput": workspace.waitingForInputSeconds += seconds
            default: break
            }
            setWorkspaceDay(workspace, day: day)
            cursor = segmentEnd
        }
    }

    private func normalized(_ status: String) -> String {
        let lowered = status.lowercased()
        if lowered == "waitingforinput" || lowered == "needsyou" || lowered == "needs-you" || lowered == "needs_you" { return "waitingForInput" } // legacy keys
        if lowered == "idle" || lowered == "resting" { return "idle" } // legacy key: resting
        if lowered == "running" || lowered == "working" { return "running" }
        if lowered == "stopped" || lowered == "paused" { return "stopped" }
        if lowered == "finished" || lowered == "done" { return "finished" }
        return "running"
    }

    private func workspaceDay(day: String, workspaceID: UUID, workspaceName: String) -> UsageWorkspaceDaySummary {
        if let dayIndex = document.days.firstIndex(where: { $0.day == day }),
           let workspaceIndex = document.days[dayIndex].workspaces.firstIndex(where: { $0.workspaceID == workspaceID }) {
            if document.days[dayIndex].workspaces[workspaceIndex].workspaceName != workspaceName {
                document.days[dayIndex].workspaces[workspaceIndex].workspaceName = workspaceName
            }
            return document.days[dayIndex].workspaces[workspaceIndex]
        }
        var daySummary = document.days.first(where: { $0.day == day }) ?? UsageDaySummary(day: day, workspaces: [])
        let workspace = UsageWorkspaceDaySummary(workspaceID: workspaceID, workspaceName: workspaceName)
        daySummary.workspaces.append(workspace)
        if let existing = document.days.firstIndex(where: { $0.day == day }) {
            document.days[existing] = daySummary
        } else {
            document.days.append(daySummary)
        }
        return workspace
    }

    private func setWorkspaceDay(_ workspace: UsageWorkspaceDaySummary, day: String) {
        guard let dayIndex = document.days.firstIndex(where: { $0.day == day }) else { return }
        if let workspaceIndex = document.days[dayIndex].workspaces.firstIndex(where: { $0.workspaceID == workspace.workspaceID }) {
            document.days[dayIndex].workspaces[workspaceIndex] = workspace
        } else {
            document.days[dayIndex].workspaces.append(workspace)
        }
    }

    private func persist() {
        try? store.save(document)
    }
}
