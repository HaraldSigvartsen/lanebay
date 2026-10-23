import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LanebayCore

private enum SessionTestError: Error {
    case timedOut
    case failed(String)
}

private struct SessionResult: Sendable {
    let id: SessionID
    var output = Data()
    var events: [ProcessEvent] = []
    var scrollback = Data()
    var text: String { String(decoding: output, as: UTF8.self) }
}

/// The deadline cancels the stream reader and kills the process even on assertion/setup failure.
private func runSession(
    _ spec: ProcessSpec,
    supervisor: ProcessSupervisor = ProcessSupervisor(),
    ready: String? = nil,
    allowFailure: Bool = false,
    consumeTimeout: Duration = .seconds(3),
    beforeConsuming: @escaping @Sendable (ProcessSupervisor, SessionID) async throws -> Void = { _, _ in },
    action: @escaping @Sendable (ProcessSupervisor, SessionID) async throws -> Void = { _, _ in }
) async throws -> SessionResult {
    var spec = spec
    let startupDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: startupDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: startupDirectory) }
    if spec.environment["ZDOTDIR"] == nil { spec.environment["ZDOTDIR"] = startupDirectory.path }
    let session = try await supervisor.start(spec: spec)
    do {
        try await beforeConsuming(supervisor, session.id)
        return try await withThrowingTaskGroup(of: SessionResult.self) { group in
            group.addTask {
                var result = SessionResult(id: session.id)
                var acted = false
                for await event in session.events {
                    result.events.append(event)
                    switch event {
                    case let .output(data): result.output.append(data)
                    case let .failed(message):
                        if !allowFailure { throw SessionTestError.failed(message) }
                    case .exited: break
                    }
                    if !acted, let ready, result.text.contains(ready) {
                        acted = true
                        try await action(supervisor, session.id)
                    }
                }
                try Task.checkCancellation()
                result.scrollback = try await supervisor.scrollback(for: session.id)
                return result
            }
            group.addTask {
                try await Task.sleep(for: consumeTimeout)
                await supervisor.terminate(session.id, gracePeriod: .zero)
                throw SessionTestError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    } catch {
        await supervisor.terminate(session.id, gracePeriod: .zero)
        throw error
    }
}

@MainActor
final class LanebayCoreTests: XCTestCase {
    func testWorkspaceDocumentsListsAndReadsOnlyMarkdownAndTextFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Notes".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("plain".utf8).write(to: root.appendingPathComponent("todo.txt"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("private.json"))
        let nested = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("guide".utf8).write(to: nested.appendingPathComponent("guide.markdown"))

        let service = WorkspaceDocuments()
        let docs = try service.list(in: root)
        XCTAssertEqual(docs.map(\.relativePath), ["docs/guide.markdown", "README.md", "todo.txt"])
        XCTAssertEqual(try service.read(docs[1], in: root), "# Notes")
    }

    func testWorkspaceDocumentsRejectsSymlinksAndTraversal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsideDoc = outside.appendingPathComponent("secret.md")
        try Data("secret".utf8).write(to: outsideDoc)
        let link = root.appendingPathComponent("escape.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDoc)

        let service = WorkspaceDocuments()
        XCTAssertTrue(try service.list(in: root).isEmpty)
        let forged = WorkspaceDocument(url: outsideDoc, relativePath: "../secret.md")
        XCTAssertThrowsError(try service.read(forged, in: root))
    }

    func testWorkspaceDocumentsRejectsFilesOverSizeLimit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.txt")
        try Data(repeating: 0x61, count: WorkspaceDocuments.maximumFileSize + 1).write(to: file)
        let service = WorkspaceDocuments()
        XCTAssertTrue(try service.list(in: root).isEmpty, "Oversized files are excluded from listings")
        let document = WorkspaceDocument(url: file, relativePath: "large.txt")
        XCTAssertThrowsError(try service.read(document, in: root)) { error in
            XCTAssertEqual(error as? WorkspaceDocumentsError, .tooLarge)
        }
    }

    func testWorkspaceDocumentsListsAndReadsSafeSourceFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("let answer = 42\nprint(answer)".utf8).write(to: root.appendingPathComponent("main.swift"))
        try Data("export const value = 1".utf8).write(to: root.appendingPathComponent("app.ts"))
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("image.png"))
        let nestedRoots = [".git", "node_modules", ".build"].map { root.appendingPathComponent($0, isDirectory: true) }
        for (index, nested) in nestedRoots.enumerated() {
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("ignored".utf8).write(to: nested.appendingPathComponent("ignored\(index).swift"))
        }
        let oversized = root.appendingPathComponent("large.rs")
        try Data(repeating: 0x61, count: WorkspaceDocuments.maximumFileSize + 1).write(to: oversized)

        let service = WorkspaceDocuments()
        let files = try service.listSourceFiles(in: root)
        XCTAssertEqual(files.map(\.relativePath), ["app.ts", "main.swift"])
        XCTAssertEqual(try service.readSourceFile(try XCTUnwrap(files.last), in: root), "let answer = 42\nprint(answer)")
    }

    func testWorkspaceDocumentsRejectsSourceSymlinkEscapeAndBinary() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("secret.swift")
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.swift"), withDestinationURL: secret)
        try Data([0x61, 0, 0x62]).write(to: root.appendingPathComponent("binary.c"))

        let service = WorkspaceDocuments()
        XCTAssertTrue(try service.listSourceFiles(in: root).isEmpty)
        XCTAssertThrowsError(try service.readSourceFile(WorkspaceSourceFile(url: secret, relativePath: "secret.swift"), in: root)) { error in
            XCTAssertEqual(error as? WorkspaceDocumentsError, .outsideRoot)
        }
    }

    func testWorkspaceDocumentsRejectsBinaryBytesForDocumentsAndSource() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["binary.md", "binary.txt", "binary.swift"] {
            try Data([0x61, 0x00, 0x62]).write(to: root.appendingPathComponent(name))
        }
        let reader = WorkspaceDocuments()
        XCTAssertTrue(try reader.list(in: root).isEmpty)
        XCTAssertTrue(try reader.listSourceFiles(in: root).isEmpty)
        for name in ["binary.md", "binary.txt"] {
            let file = WorkspaceDocument(url: root.appendingPathComponent(name), relativePath: name)
            XCTAssertThrowsError(try reader.read(file, in: root)) { XCTAssertEqual($0 as? WorkspaceDocumentsError, .unsupportedFile) }
        }
    }

    func testWorkspaceDocumentsRejectsAncestorSymlinkIntroducedAfterListing() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: nested.appendingPathComponent("secret.md"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.md"))
        let source = nested.appendingPathComponent("secret.swift")
        try Data("inside".utf8).write(to: source)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.swift"))
        let reader = WorkspaceDocuments()
        let listedDoc = try XCTUnwrap(reader.list(in: root).first)
        let listedSource = try XCTUnwrap(reader.listSourceFiles(in: root).first)
        try FileManager.default.removeItem(at: nested)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)
        XCTAssertThrowsError(try reader.read(listedDoc, in: root))
        XCTAssertThrowsError(try reader.readSourceFile(listedSource, in: root))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testStatusHeuristicsClassifyPromptsAndPermissionRequests() {
        let clock = ContinuousClock()
        let start = clock.now
        var heuristic = StatusHeuristics(rules: .init(quietPeriod: .seconds(2)))
        heuristic.receivedOutput(at: start)
        XCTAssertEqual(heuristic.infer(from: "$ ", now: start.advanced(by: .seconds(1))), .running)
        XCTAssertEqual(heuristic.infer(from: "$ ", now: start.advanced(by: .seconds(2))), .idle)
        XCTAssertEqual(heuristic.infer(from: "Allow this command?", now: start), .waitingForInput)
        XCTAssertEqual(heuristic.infer(from: "compiling", now: start.advanced(by: .seconds(10))), .running)
    }

    func testStatusHeuristicsIgnoreStaleHistoryAndNormalizeANSIAcrossChunks() {
        let start = ContinuousClock.now
        var heuristic = StatusHeuristics(rules: .init(quietPeriod: .seconds(2)))
        heuristic.receivedOutput(at: start)
        XCTAssertEqual(heuristic.infer(from: "$ \ncompiling", now: start.advanced(by: .seconds(10))), .running)
        XCTAssertEqual(heuristic.infer(from: "Allow this command?\nApproved\nworking", now: start.advanced(by: .seconds(10))), .running)
        XCTAssertEqual(heuristic.infer(from: "\u{001B}[31m❯\u{001B}[0m", now: start.advanced(by: .seconds(2))), .idle)
        XCTAssertEqual(heuristic.infer(from: "yes (allow)", now: start), .waitingForInput)
        XCTAssertEqual(heuristic.infer(from: "no (deny)", now: start), .waitingForInput)

        heuristic.receivedOutput(at: start.advanced(by: .seconds(5)))
        XCTAssertEqual(heuristic.infer(from: "$ ", now: start.advanced(by: .seconds(6))), .running)
        XCTAssertEqual(heuristic.infer(from: "$ ", now: start.advanced(by: .seconds(7))), .idle)
    }

    func testStatusHeuristicsRecognizeLongShellPromptsAndInputRequests() {
        let start = ContinuousClock.now
        var heuristic = StatusHeuristics(rules: .init(quietPeriod: .seconds(2)))
        heuristic.receivedOutput(at: start)
        let longPath = String(repeating: "p", count: 180)
        XCTAssertEqual(heuristic.infer(from: "\(longPath) ❯ ", now: start.advanced(by: .seconds(2))), .idle)
        XCTAssertEqual(heuristic.infer(from: "user@host \(longPath) % ", now: start.advanced(by: .seconds(2))), .idle)
        XCTAssertEqual(heuristic.infer(from: "root@host \(longPath) # ", now: start.advanced(by: .seconds(2))), .idle)
        XCTAssertEqual(
            heuristic.infer(from: "\u{001B}[35m❯ \(longPath)\u{001B}[0m", now: start.advanced(by: .seconds(2))),
            .idle)
        XCTAssertEqual(heuristic.infer(from: "Downloading 100%", now: start.advanced(by: .seconds(3))), .running)
        XCTAssertEqual(
            heuristic.infer(from: "❯ sleep 4", now: start.advanced(by: .seconds(3)), blockingCommand: "sleep 4"),
            .running)
        XCTAssertEqual(
            heuristic.infer(from: "❯ \(longPath) main", now: start.advanced(by: .seconds(3)), blockingCommand: "sleep 4"),
            .idle)
        XCTAssertEqual(heuristic.infer(from: "Enter value: ", now: start), .waitingForInput)
        XCTAssertEqual(heuristic.infer(from: "Password: ", now: start), .waitingForInput)
        XCTAssertEqual(heuristic.infer(from: "old prompt\r❯ \(longPath)", now: start.advanced(by: .seconds(2))), .idle)
        XCTAssertEqual(
            heuristic.infer(
                from: "\u{001B}[35m❯ \(longPath)\u{001B}[0m\u{001B}[K\u{001B}[?2004h",
                now: start.advanced(by: .seconds(2))),
            .idle)
    }

    func testAppName() {
        XCTAssertEqual(LanebayCore.appName, "Lanebay")
    }

    func testAppPreferencesStoreDefaultsAndRoundTripsInInjectedRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppPreferencesStore(rootURL: root)

        XCTAssertEqual(try store.load(), AppPreferences())
        let preferences = AppPreferences(
            defaultWorkingDirectory: URL(fileURLWithPath: "/tmp/project"),
            restoreLastWorkspace: false,
            showNotifications: false
        )
        try store.save(preferences)
        XCTAssertEqual(try store.load(), preferences)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("preferences.json").path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testAppPreferencesStoreRejectsUnsupportedVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data("{\"version\":99,\"restoreLastWorkspace\":true,\"showNotifications\":true}".utf8)
        try data.write(to: root.appendingPathComponent("preferences.json"))

        XCTAssertThrowsError(try AppPreferencesStore(rootURL: root).load()) { error in
            guard case AppPreferencesStoreError.unsupportedVersion(99) = error else {
                return XCTFail("Expected unsupported version error, got \(error)")
            }
        }
    }

    func testPreferenceSaveFilesArePrivateAndReplacementUpgradesLegacyMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppPreferencesStore(rootURL: root)
        try store.save(AppPreferences())
        let file = root.appendingPathComponent("preferences.json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try store.save(AppPreferences(showNotifications: false))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".preferences.json.bak").path))
        XCTAssertEqual(try store.load().showNotifications, false)
    }

    func testLegacyRegexLoopIsDisabledAndMarkedForReviewButLiteralRemainsValid() throws {
        let id = UUID(), target = UUID()
        let legacy = Loop(id: id, targetNodeID: target, prompt: "go", trigger: .outputMatch(pattern: "READY.*"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object["isEnabled"] = true
        let decoded = try JSONDecoder().decode(Loop.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.isEnabled)
        XCTAssertTrue(decoded.needsReview)
        XCTAssertTrue(LoopValidator.matches("READY.*", output: "prefix READY.* suffix"))
        XCTAssertFalse(LoopValidator.matches("READY.*", output: "READY and more"))
    }

    func testSparkleConfigurationValidation() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertFalse(SparkleConfiguration.isConfigured(info: [:]))
        XCTAssertFalse(SparkleConfiguration.isConfigured(info: ["SUFeedURL": "https://example.invalid/feed.xml", "SUPublicEDKey": key]))
        XCTAssertFalse(SparkleConfiguration.isConfigured(info: ["SUFeedURL": "not a url", "SUPublicEDKey": key]))
        XCTAssertFalse(SparkleConfiguration.isConfigured(info: ["SUFeedURL": "https://updates.example.org/feed.xml", "SUPublicEDKey": "short"] ))
        XCTAssertTrue(SparkleConfiguration.isConfigured(info: ["SUFeedURL": "https://updates.lanebay.app/feed.xml", "SUPublicEDKey": key]))
    }

    func testWorkspaceStoreRoundTripAndNotStartedConsoles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let id = UUID()
        let workspace = Workspace(
            id: id, name: "Test", repos: [URL(fileURLWithPath: "/tmp/repo")],
            nodes: [
                Node(kind: .console, cwd: URL(fileURLWithPath: "/tmp"), frame: NodeFrame(x: 1, y: 2, w: 300, h: 200), title: "Shell"),
                Node(kind: .note, cwd: URL(fileURLWithPath: "/tmp"), frame: NodeFrame(x: 4, y: 5, w: 100, h: 80), title: "Note"),
            ], groups: [Group(name: "Team", color: "blue")]
        )
        try store.save(workspace)
        let loaded = try store.load(id: id)
        XCTAssertEqual(loaded.id, workspace.id)
        XCTAssertEqual(loaded.name, workspace.name)
        XCTAssertEqual(loaded.repos, workspace.repos)
        XCTAssertEqual(loaded.nodes.count, 2)
        XCTAssertTrue(loaded.nodes[0].notStarted)
        XCTAssertFalse(loaded.nodes[1].notStarted)
        XCTAssertEqual(try store.list().map(\.id), [id])
        try store.delete(id: id)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testLegacyGroupDecodesWithoutLeadAndLeadRoundTrips() throws {
        let decoder = JSONDecoder()
        let legacy = Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"Legacy\",\"nodeIDs\":[],\"color\":\"blue\"}".utf8)
        XCTAssertNil(try decoder.decode(Group.self, from: legacy).leadNodeID)
        let lead = UUID()
        let group = Group(name: "Team", color: "blue", leadNodeID: lead)
        XCTAssertEqual(try decoder.decode(Group.self, from: JSONEncoder().encode(group)).leadNodeID, lead)
    }

    func testLegacyGroupLeadKeyDecodesFromStoredCommanderField() throws {
        let lead = UUID()
        let json = Data("""
        {"id":"\(UUID().uuidString)","name":"Legacy","nodeIDs":[],"color":"blue","commanderNodeID":"\(lead.uuidString)"}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Group.self, from: json).leadNodeID, lead)
        let encoded = try JSONEncoder().encode(Group(name: "Team", color: "blue", leadNodeID: lead))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["leadNodeID"] as? String, lead.uuidString)
        XCTAssertNil(object["commanderNodeID"])
    }

    func testLegacyNodeNotStartedDecodesFromStoredDormantField() throws {
        let id = UUID()
        let json = Data("""
        {"id":"\(id.uuidString)","kind":"console","cwd":"file:///tmp/","frame":{"x":0,"y":0,"w":1,"h":1},"title":"Shell","dormant":true}
        """.utf8)
        XCTAssertTrue(try JSONDecoder().decode(Node.self, from: json).notStarted)
        let encoded = try JSONEncoder().encode(Node(
            id: id, kind: .console, cwd: URL(fileURLWithPath: "/tmp"),
            frame: NodeFrame(x: 0, y: 0, w: 1, h: 1), title: "Shell", notStarted: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["notStarted"] as? Bool, true)
        XCTAssertNil(object["dormant"])
    }

    func testLegacyUsageWorkspaceDaySummaryDecodesOldStatusDurations() throws {
        let workspaceID = UUID()
        let json = Data("""
        {"workspaceID":"\(workspaceID.uuidString)","workspaceName":"W","dispatchedPrompts":0,"loopIterations":0,"workingSeconds":3,"restingSeconds":2,"needsYouSeconds":1,"sessions":[]}
        """.utf8)
        let decoded = try JSONDecoder().decode(UsageWorkspaceDaySummary.self, from: json)
        XCTAssertEqual(decoded.runningSeconds, 3)
        XCTAssertEqual(decoded.idleSeconds, 2)
        XCTAssertEqual(decoded.waitingForInputSeconds, 1)
        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["runningSeconds"] as? Double, 3)
        XCTAssertNil(object["workingSeconds"])
    }

    func testLegacyAppPreferencesSpeakWaitingForInputDecodesFromStoredNeedsYouField() throws {
        let json = Data("{\"version\":3,\"speakNeedsYouStatus\":true}".utf8)
        XCTAssertTrue(try JSONDecoder().decode(AppPreferences.self, from: json).speakWaitingForInputStatus)
        let encoded = try JSONEncoder().encode(AppPreferences(speakWaitingForInputStatus: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["speakWaitingForInputStatus"] as? Bool, true)
        XCTAssertNil(object["speakNeedsYouStatus"])
    }

    func testWorkspaceStoreReplacesExistingFileCompletely() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let id = UUID()
        try store.save(Workspace(id: id, name: "Old", nodes: [Node(kind: .note, cwd: URL(fileURLWithPath: "/tmp"), frame: NodeFrame(x: 0, y: 0, w: 1, h: 1), title: "Old note")]))
        try store.save(Workspace(id: id, name: "New", nodes: [Node(kind: .note, cwd: URL(fileURLWithPath: "/tmp"), frame: NodeFrame(x: 2, y: 3, w: 4, h: 5), title: "New note")]))
        let loaded = try store.load(id: id)
        XCTAssertEqual(loaded.name, "New")
        XCTAssertEqual(loaded.nodes.map(\.title), ["New note"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }, [])
    }

    func testCorruptWorkspaceIsQuarantinedAndReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let file = root.appendingPathComponent("\(id.uuidString).json")
        try Data("not json".utf8).write(to: file)
        let store = WorkspaceStore(rootURL: root)
        XCTAssertThrowsError(try store.load(id: id)) { error in
            guard case let WorkspaceStoreError.corruptFile(quarantine, _) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
            XCTAssertTrue(quarantine.lastPathComponent.hasPrefix("\(id.uuidString).json.corrupt-"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testWorkspaceStoreMigratesVersionZero() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let old = """
        {"id":"\(id.uuidString)","name":"Legacy","version":0,"repos":[],"nodes":[],"groups":[],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        """
        try Data(old.utf8).write(to: root.appendingPathComponent("\(id.uuidString).json"))
        let store = WorkspaceStore(rootURL: root, migration: { object, from, to in
            XCTAssertEqual(from, 0)
            XCTAssertEqual(to, 1)
            var migrated = object
            migrated["loops"] = []
            migrated["version"] = 1
            return migrated
        })
        let loaded = try store.load(id: id)
        XCTAssertEqual(loaded.name, "Legacy")
        XCTAssertEqual(loaded.version, 1)
    }

    func testEchoOutputAndExit() async throws {
        let result = try await runSession(ProcessSpec(executable: "/bin/echo", arguments: ["hello lanebay"]))
        XCTAssertEqual(result.text, "hello lanebay\r\n")
        XCTAssertEqual(result.events.last, .exited(code: 0, signal: nil))
        XCTAssertEqual(result.events.filter { if case .exited = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(result.scrollback, result.output)
    }

    func testDrainsMultipleChunksBeforeNonzeroExit() async throws {
        let result = try await runSession(ProcessSpec(
            executable: "/bin/sh", arguments: ["-c", "head -c 100000 /dev/zero; printf END; exit 37"]
        ))
        XCTAssertEqual(result.output, Data(repeating: 0, count: 100_000) + Data("END".utf8))
        XCTAssertEqual(result.scrollback, result.output)
        XCTAssertEqual(result.events.last, .exited(code: 37, signal: nil))
    }

    func testShellDoesNotInheritHostColumns() async throws {
        let result = try await runSession(ProcessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'C=%s\\n' \"$COLUMNS\"; /bin/stty size"],
            environment: ["COLUMNS": "999", "LINES": "40"],
            columns: 91, rows: 31
        ))
        XCTAssertFalse(result.text.contains("C=999"), result.text)
        XCTAssertTrue(result.text.contains("31 91"), result.text)
    }

    func testWriteResizeAndInitialSize() async throws {
        let result = try await runSession(ProcessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "stty size; printf READY; IFS= read -r line; stty size; printf 'INPUT:%s' \"$line\""],
            columns: 91, rows: 31
        ), ready: "READY", action: { supervisor, id in
            try await supervisor.resize(120, 42, for: id)
            try await supervisor.write(Data("hello 'world'\n".utf8), to: id)
        })
        XCTAssertTrue(result.text.hasPrefix("31 91\r\n"), result.text)
        XCTAssertTrue(result.text.contains("42 120\r\n"), result.text)
        XCTAssertTrue(result.text.hasSuffix("INPUT:hello 'world'"), result.text)
        XCTAssertEqual(result.events.last, .exited(code: 0, signal: nil))
    }

    func testLargeWriteDoesNotBlockOutputDelivery() async throws {
        let result = try await runSession(ProcessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "stty raw -echo; printf READY; head -c 100000 | wc -c"]
        ), ready: "READY", action: { supervisor, id in
            try await supervisor.write(Data(repeating: 65, count: 100_000), to: id)
        })
        XCTAssertTrue(result.text.contains("100000"), result.text)
        XCTAssertEqual(result.events.last, .exited(code: 0, signal: nil))
    }

    func testTerminateHandlesSignalBeforeEscalation() async throws {
        let result = try await runSession(ProcessSpec(
            executable: "/bin/sh", arguments: ["-c", "trap 'exit 23' TERM; printf READY; while :; do :; done"]
        ), ready: "READY", action: { supervisor, id in
            await supervisor.terminate(id, gracePeriod: .milliseconds(200))
        })
        XCTAssertEqual(result.events.last, .exited(code: 23, signal: nil))
    }

    func testTerminateEscalatesAndKillsWholeProcessGroup() async throws {
        // Both shell and descendant ignore TERM, requiring group escalation.
        let result = try await runSession(ProcessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; /bin/sh -c 'trap \"\" TERM; printf CHILD_READY; while :; do read line; done' & wait"]
        ), ready: "CHILD_READY", action: { supervisor, id in
            await supervisor.terminate(id, gracePeriod: .milliseconds(50))
            await supervisor.terminate(id, gracePeriod: .seconds(2))
        })
        XCTAssertEqual(result.events.last, .exited(code: 128 + SIGKILL, signal: SIGKILL))
    }

    func testEscalationContinuesAfterLeaderExits() async throws {
        let result = try await runSession(ProcessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "trap 'exit 23' TERM; /bin/sh -c 'trap \"\" TERM HUP; printf \"CHILD_READY:%s:READY_END\\n\" \"$$\"; while :; do :; done' & wait"]
        ), ready: ":READY_END\r\n", action: { supervisor, id in
            await supervisor.terminate(id, gracePeriod: .milliseconds(50))
        })
        XCTAssertEqual(result.events.last, .exited(code: 23, signal: nil), result.text)
        let marker = try XCTUnwrap(result.text.range(of: "CHILD_READY:"), result.text)
        let pidText = result.text[marker.upperBound...].split(separator: ":").first
        let descendant = try XCTUnwrap(pidText.flatMap { Int32($0) }, result.text)
        defer { _ = kill(descendant, SIGKILL) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while kill(descendant, 0) == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let probe = kill(descendant, 0)
        let probeError = errno
        XCTAssertEqual(probe, -1, "Descendant survived process-group termination")
        XCTAssertEqual(probeError, ESRCH)
    }

    func testOutputEOFStillWaitsForExitStatus() async throws {
        let result = try await runSession(ProcessSpec(
            executable: "/bin/sh", arguments: ["-c", "exec </dev/null >/dev/null 2>&1; exit 37"]
        ))
        XCTAssertEqual(result.events, [.exited(code: 37, signal: nil)])
    }

    func testRingScrollbackRetainsOnlySuffix() async throws {
        let result = try await runSession(ProcessSpec(
            executable: "/bin/sh", arguments: ["-c", "head -c 100000 /dev/zero; printf 0123456789"], scrollbackBytes: 7
        ))
        XCTAssertEqual(result.output.count, 100_010)
        XCTAssertEqual(result.scrollback, Data("3456789".utf8))
        XCTAssertEqual(result.events.last, .exited(code: 0, signal: nil))
        let disabled = try await runSession(ProcessSpec(executable: "/bin/echo", arguments: ["discard"], scrollbackBytes: 0))
        XCTAssertEqual(disabled.scrollback, Data())
    }

    func testLoginShellResolvesPathAndPreservesArgumentsEnvironmentAndDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // This executable is discoverable only after the login profile runs.
        try Data("export PATH=\"$ZDOTDIR:$PATH\"\n".utf8).write(to: directory.appendingPathComponent(".zprofile"))
        let executable = directory.appendingPathComponent("lanebay-test-command")
        try Data("#!/bin/sh\nprintf '%s|%s|%s' \"$1\" \"$LANEBAY_TEST\" \"$PWD\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let argument = "spaces ' quotes ; $(false)"
        let result = try await runSession(ProcessSpec(
            executable: "lanebay-test-command", arguments: [argument],
            environment: ["ZDOTDIR": directory.path, "LANEBAY_TEST": "override"], workingDirectory: directory
        ))
        XCTAssertTrue(result.text.hasPrefix("\(argument)|override|"), result.text)
        let actualDirectory = URL(fileURLWithPath: String(result.text.split(separator: "|").last!))
        XCTAssertEqual(actualDirectory.resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
        XCTAssertEqual(result.events.last, .exited(code: 0, signal: nil))
    }

    func testLaunchFailuresReportExitStatus() async throws {
        let missing = try await runSession(ProcessSpec(executable: "/no/such/lanebay-command"))
        XCTAssertEqual(missing.events.last, .exited(code: 127, signal: nil))
        let badDirectory = try await runSession(ProcessSpec(
            executable: "/bin/echo", workingDirectory: URL(fileURLWithPath: "/no/such/lanebay-directory")
        ))
        XCTAssertEqual(badDirectory.events.last, .exited(code: 126, signal: nil))
    }

    func testConcurrentSessionsKeepOutputAndExitStatusesSeparate() async throws {
        let supervisor = ProcessSupervisor()
        let results = try await withThrowingTaskGroup(of: (Int, SessionResult).self) { group in
            for index in 0..<8 {
                group.addTask {
                    let result = try await runSession(ProcessSpec(
                        executable: "/bin/sh", arguments: ["-c", "printf session-\(index); exit \(index)"]
                    ), supervisor: supervisor)
                    return (index, result)
                }
            }
            var results: [(Int, SessionResult)] = []
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.count, 8)
        for (index, result) in results {
            XCTAssertEqual(result.text, "session-\(index)")
            XCTAssertEqual(result.scrollback, result.output)
            XCTAssertEqual(result.events.last, .exited(code: Int32(index), signal: nil))
        }
    }

    func testStalledConsumerPausesReadAndResumesWithoutTermination() async throws {
        let result = try await runSession(ProcessSpec(
            executable: "/bin/sh", arguments: ["-c", "head -c 1200000 /dev/zero"]
        ), consumeTimeout: .seconds(5), beforeConsuming: { supervisor, id in
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if try await supervisor.outputReadPaused(for: id) { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("Backpressure never paused PTY reads while the consumer was stalled")
        })
        XCTAssertFalse(result.events.contains { if case .failed = $0 { true } else { false } })
        guard case .exited(code: 0, signal: nil) = result.events.last else { return XCTFail("Missing clean final exit event") }
        XCTAssertLessThanOrEqual(result.scrollback.count, 1_048_576)
    }

    func testUnreadExitLeavesTheSupervisorResponsive() async throws {
        let supervisor = ProcessSupervisor()
        let session = try await supervisor.start(spec: ProcessSpec(executable: "/bin/echo", arguments: ["bye-lanebay"]))
        let outcome = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while ContinuousClock.now < deadline {
                    if let data = try? await supervisor.scrollback(for: session.id),
                       String(decoding: data, as: UTF8.self).contains("bye-lanebay") {
                        return "ready"
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                return "missing"
            }
            group.addTask {
                try await Task.sleep(for: .seconds(4))
                return "timed-out"
            }
            let first = try await group.next() ?? "missing"
            group.cancelAll()
            return first
        }
        XCTAssertEqual(outcome, "ready")
        await supervisor.terminate(session.id, gracePeriod: .zero)
    }

    func testHeavyPipelineCompletionIsDeliveredInCoalescedChunks() async throws {
        let result = try await runSession(ProcessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "token=$(printf 'LANEBAY-FLOOD-%s' DONE); /usr/bin/yes | /usr/bin/head -n 200000; /bin/echo \"$token\""]
        ), consumeTimeout: .seconds(8))
        let chunks = result.events.reduce(into: 0) { count, event in
            if case .output = event { count += 1 }
        }
        XCTAssertTrue(result.text.contains("LANEBAY-FLOOD-DONE"), "chunks=\(chunks) bytes=\(result.output.count) tail=\(result.text.suffix(80))")
        XCTAssertLessThan(chunks, 200, "completion sat behind \(chunks) chunks")
        guard case .exited(code: 0, signal: nil) = result.events.last else {
            return XCTFail("pipeline did not exit cleanly: \(String(describing: result.events.last))")
        }
    }

    func testSlowConsumerFloodStaysAliveAndBounded() async throws {
        let result = try await runSession(ProcessSpec(
            executable: "/usr/bin/yes", arguments: ["lanebay"]
        ), beforeConsuming: { supervisor, id in
            let highWater = try await supervisor.outputHighWaterMark(for: id)
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(1500))
            var sawPause = false
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                do {
                    let buffered = try await supervisor.bufferedOutputByteCount(for: id)
                    XCTAssertLessThanOrEqual(buffered, highWater, "Buffered output exceeded high-water mark")
                    if try await supervisor.outputReadPaused(for: id) { sawPause = true }
                } catch ProcessSupervisorError.sessionNotFound {
                    return XCTFail("Session terminated unexpectedly while consumer was stalled")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(sawPause, "Flood test never observed read-side backpressure")
            await supervisor.terminate(id, gracePeriod: .zero)
        })
        XCTAssertFalse(result.events.contains { if case .failed = $0 { true } else { false } })
        guard case .exited = result.events.last else { return XCTFail("Missing final exit event") }
        XCTAssertLessThanOrEqual(result.scrollback.count, 1_048_576)
    }

    func testExitNeverSilentlyEvictsBufferedOutput() async throws {
        let result = try await runSession(ProcessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 4000 /dev/zero"]
        ), beforeConsuming: { _, _ in
            try await Task.sleep(for: .milliseconds(200))
        })
        XCTAssertFalse(result.events.contains { if case .failed = $0 { true } else { false } })
        XCTAssertEqual(result.output.count, 4000)
        guard case .exited = result.events.last else { return XCTFail("Missing final exit event") }
    }

    func testCompletedScrollbackCanBeDiscarded() async throws {
        let supervisor = ProcessSupervisor()
        let result = try await runSession(ProcessSpec(executable: "/bin/echo", arguments: ["history"]), supervisor: supervisor)
        await supervisor.discardScrollback(for: result.id)
        do {
            _ = try await supervisor.scrollback(for: result.id)
            XCTFail("Discarded history is still retained")
        } catch ProcessSupervisorError.sessionNotFound {
            // Expected once the owner releases this completed session.
        }
    }

    func testExecutableResolution() {
        XCTAssertEqual(ProcessSupervisor.resolveExecutable("/bin/echo", path: ""), "/bin/echo")
        XCTAssertEqual(ProcessSupervisor.resolveExecutable("echo", path: "/bin"), "/bin/echo")
        XCTAssertEqual(ProcessSupervisor.resolveExecutable("definitely-not-installed-lanebay", path: ""), "definitely-not-installed-lanebay")
    }
}

extension LanebayCoreTests {
    func testLoopConfigurationValidationAndBoundedLiteralMatcher() throws {
        let loop = Loop(targetNodeID: UUID(), prompt: "continue", trigger: .outputMatch(pattern: "READY"), maxIterations: 3)
        XCTAssertNil(LoopValidator.validate(loop))
        XCTAssertTrue(LoopValidator.matches("READY", output: String(repeating: "x", count: 20_000) + "READY"))
        let regexSyntaxIsLiteral = Loop(targetNodeID: UUID(), prompt: "x", trigger: .outputMatch(pattern: #"a+$"#))
        XCTAssertNil(LoopValidator.validate(regexSyntaxIsLiteral))
        XCTAssertFalse(LoopValidator.matches("a+$", output: String(repeating: "a", count: 16_000) + "!"))
        let start = ContinuousClock.now
        for _ in 0..<100 { _ = LoopValidator.matches("a+$", output: String(repeating: "a", count: 16_000) + "!") }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "Literal matching stays bounded on maximum-sized adversarial input")
        let overlappingPrefixPattern = String(repeating: "a", count: 255) + "b"
        let longPatternStart = ContinuousClock.now
        for _ in 0..<100 { _ = LoopValidator.matches(overlappingPrefixPattern, output: String(repeating: "a", count: 16_000) + "!") }
        XCTAssertLessThan(ContinuousClock.now - longPatternStart, .seconds(2), "Overlapping pattern prefixes are scanned in linear time")
        XCTAssertTrue(LoopValidator.hasNewMatch("READY", output: "old READY + READY", previousByteCount: 10))
        XCTAssertFalse(LoopValidator.hasNewMatch("READY", output: "old READY + later", previousByteCount: 10))
        let tooLong = Loop(targetNodeID: UUID(), prompt: "x", trigger: .outputMatch(pattern: String(repeating: "a", count: 257)))
        XCTAssertNotNil(LoopValidator.validate(tooLong))
        let combiningGrapheme = "a" + String(repeating: "\u{0301}", count: 20_000)
        XCTAssertLessThanOrEqual(LoopValidator.boundedUTF8Suffix(combiningGrapheme, limit: LoopValidator.maxOutputBytes).utf8.count, LoopValidator.maxOutputBytes)
    }

    func testLegacyLoopPlaceholderDecodesDisabledAndInvalidLoopsAreDisabled() throws {
        let legacy = Data("{\"id\":\"\(UUID().uuidString)\"}".utf8)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Loop.self, from: legacy)
        XCTAssertFalse(decoded.isEnabled)
        var invalid = try JSONDecoder().decode(Loop.self, from: JSONEncoder().encode(Loop(targetNodeID: UUID(), prompt: "valid", trigger: .schedule(intervalSeconds: 1))))
        invalid.maxIterations = -9
        let invalidData = try JSONEncoder().encode(invalid)
        XCTAssertFalse(try JSONDecoder().decode(Loop.self, from: invalidData).isEnabled)
    }

    func testWorkspacePersistsLoopConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        let loop = Loop(name: "Watch", targetNodeID: UUID(), prompt: "inspect", trigger: .schedule(intervalSeconds: 60), maxIterations: 4)
        let workspace = Workspace(name: "Loops", loops: [loop])
        try store.save(workspace)
        XCTAssertEqual(try store.load(id: workspace.id).loops, [loop])
    }

  func testUsageStatsStorePersistsPrivateBoundedJSON() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = UsageStatsStore(rootURL: root)
    let workspace = UsageWorkspaceDaySummary(workspaceID: UUID(), workspaceName: "Workspace")
    try store.save(UsageStatsDocument(days: [UsageDaySummary(day: "2026-10-21", workspaces: [workspace])]))
    let loaded = try store.load()
    XCTAssertEqual(loaded.days.count, 1)
    let file = root.appendingPathComponent("usage-stats.json")
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
  }

  @MainActor
  func testUsageTrackerAggregatesPromptsLoopsAndStatusTime() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaceID = UUID()
    let tracker = UsageStatsTracker(store: UsageStatsStore(rootURL: root))
    let start = Date(timeIntervalSince1970: 1_000)
    tracker.workspaceDidChange(id: workspaceID, name: "Test", at: start)
    tracker.sessionStarted(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, workspaceID: workspaceID, workspaceName: "Test", agent: "shell", status: "running", at: start)
    tracker.recordPromptDispatch(workspaceID: workspaceID, workspaceName: "Test", count: 2, at: start)
    tracker.recordLoopIteration(workspaceID: workspaceID, workspaceName: "Test", at: start)
    tracker.sessionStatusChanged(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, status: "resting", at: start.addingTimeInterval(30)) // legacy raw value
    tracker.sessionEnded(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, at: start.addingTimeInterval(60))
    let day = try XCTUnwrap(tracker.loadDocument().days.first)
    let workspace = try XCTUnwrap(day.workspaces.first)
    XCTAssertEqual(workspace.dispatchedPrompts, 2)
    XCTAssertEqual(workspace.loopIterations, 1)
    XCTAssertEqual(workspace.sessions.count, 1)
    XCTAssertGreaterThan(workspace.runningSeconds, 0)
    XCTAssertGreaterThan(workspace.idleSeconds, 0)
  }

  func testLocalUsageLogSnapshotReaderIsOptionalAndSizeCapped() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let empty = LocalUsageLogSnapshotReader(homeRoot: home).snapshot()
    XCTAssertNil(empty)
    let logDir = home.appendingPathComponent(".codex/logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    let small = logDir.appendingPathComponent("usage.jsonl")
    let line = #"{"status":"working","durationSeconds":12,"dispatchedPrompts":3,"loopIterations":1}"#
    try Data((line + "\n").utf8).write(to: small)
    let snapshot = try XCTUnwrap(LocalUsageLogSnapshotReader(homeRoot: home).snapshot())
    XCTAssertEqual(snapshot.dispatchedPrompts, 3)
    XCTAssertEqual(snapshot.loopIterations, 1)
    XCTAssertEqual(snapshot.statusDuration.running, 12)
    let large = logDir.appendingPathComponent("session-large.log")
    try Data(repeating: 0x61, count: LocalUsageLogSnapshotReader.maxLogFileBytes + 1).write(to: large)
    let outside = home.appendingPathComponent("outside-usage.jsonl")
    try Data(#"{"status":"working","durationSeconds":999,"dispatchedPrompts":999,"loopIterations":999}"#.utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: logDir.appendingPathComponent("session-link.jsonl"), withDestinationURL: outside)
    let capped = try XCTUnwrap(LocalUsageLogSnapshotReader(homeRoot: home).snapshot())
    XCTAssertEqual(capped.dispatchedPrompts, 3)
  }

  func testAgentCatalogDetectsInstalledKnownAgentsInInjectedDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let codex = root.appendingPathComponent("codex")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: codex)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
    let installed = AgentCatalog.detectInstalledKnownAgents(searchDirectories: [root])
    XCTAssertTrue(installed.contains("codex"))
    XCTAssertFalse(installed.contains("claude"))
  }

  func testCustomExecutableValidationRejectsRelativePathAndInterpolation() throws {
    XCTAssertThrowsError(try AgentCatalog.validate(custom: CustomAgentExecutable(displayName: "Bad", executablePath: "codex"))) {
      XCTAssertEqual($0 as? AgentCatalogValidationError, .executablePathMustBeAbsolute)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("agent")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    XCTAssertThrowsError(
      try AgentCatalog.validate(custom: CustomAgentExecutable(
        displayName: "Bad Args", executablePath: executable.path, arguments: ["$(rm -rf /)"]
      ))
    ) {
      guard case .interpolatedArgument = $0 as? AgentCatalogValidationError else {
        return XCTFail("Expected interpolatedArgument")
      }
    }
  }

  func testAccountProfileValidationRejectsSecretLikeValues() {
    XCTAssertThrowsError(try AgentCatalog.validate(profile: AgentAccountProfile(
      name: "Codex Profile", agentID: "codex", environment: ["CODEX_HOME": "/tmp/codex", "OPENAI_API_KEY": "sk-abcdefghijklmnopqrstuvwxyz123456"]
    ))) {
      guard case .secretLikeValue("OPENAI_API_KEY") = $0 as? AgentCatalogValidationError else {
        return XCTFail("Expected secret-like validation error")
      }
    }
    XCTAssertTrue((AgentCatalogValidationError.secretLikeValue("OPENAI_API_KEY").localizedDescription).contains("best-effort"))
  }

  func testScreenshotLibraryImportsRenamesAnnotatesAndDeletesInInjectedRoot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ScreenshotLibraryStore(rootURL: root)
    let png = try makePNG(width: 12, height: 8)
    let item = try store.importImage(data: png, suggestedName: "Initial")
    XCTAssertEqual(item.displayName, "Initial")
    XCTAssertEqual(try store.loadItems().count, 1)
    let imageURL = store.imageURL(for: item)
    let annotationURL = store.annotationURL(for: item)
    XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: annotationURL.path))
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    let screenshotsDir = root.appendingPathComponent("screenshots", isDirectory: true)
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: screenshotsDir.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: imageURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: annotationURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)

    try store.rename(id: item.id, newName: "Renamed")
    let renamed = try XCTUnwrap(store.loadItems().first)
    XCTAssertEqual(renamed.displayName, "Renamed")
    let layers: [ScreenshotAnnotationLayer] = [
      .arrow(start: .init(x: 1, y: 1), end: .init(x: 11, y: 6), color: .init(red: 1, green: 0, blue: 0), lineWidth: 2),
      .text(position: .init(x: 2, y: 2), text: "Hello", color: .init(red: 0, green: 1, blue: 0), fontSize: 12),
    ]
    try store.saveAnnotations(ScreenshotAnnotationDocument(layers: layers), for: renamed)
    XCTAssertEqual(try store.loadAnnotations(for: renamed).layers, layers)

    try store.delete(id: renamed.id)
    XCTAssertTrue(try store.loadItems().isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: annotationURL.path))
  }

  func testScreenshotLibraryRejectsUndecodableAndOversizedImages() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ScreenshotLibraryStore(rootURL: root)
    XCTAssertThrowsError(try store.importImage(data: Data("not image".utf8), suggestedName: "bad")) { error in
      XCTAssertEqual(error as? ScreenshotLibraryError, .imageDecodeFailed)
    }
    XCTAssertThrowsError(try store.importImage(data: Data(repeating: 0x61, count: ScreenshotLibraryStore.maximumImageBytes + 1), suggestedName: "big")) { error in
      XCTAssertEqual(error as? ScreenshotLibraryError, .imageTooLarge(ScreenshotLibraryStore.maximumImageBytes))
    }
    let normal = try makePNG(width: 32, height: 32)
    XCTAssertThrowsError(try ScreenshotLibraryStore.decodeImage(data: normal, maxPixelDimension: 16)) { error in
      XCTAssertEqual(error as? ScreenshotLibraryError, .imageDimensionsTooLarge(16))
    }
  }

  func testPlannerPlanValidatorAcceptsStrictTypedActions() throws {
    let nodeID = UUID()
    let groupID = UUID()
    let payload = """
    {"actions":[
      {"type":"startConsole","nodeID":"\(nodeID.uuidString)"},
      {"type":"sendToConsole","nodeID":"\(nodeID.uuidString)","text":"echo ready"},
      {"type":"broadcastToGroup","groupID":"\(groupID.uuidString)","text":"sync"},
      {"type":"createLoop","name":"Goal loop","targetNodeID":"\(nodeID.uuidString)","prompt":"continue","trigger":{"type":"goalCheck","intervalSeconds":30,"goal":"DONE"},"maxIterations":3},
      {"type":"note","text":"Check CI after run"}
    ]}
    """
    let decoded = try PlannerPlanValidator.decodeStrict(from: payload)
    XCTAssertEqual(decoded.actions.count, 5)
    XCTAssertEqual(decoded.actions[0], .startConsole(nodeID: nodeID))
  }

  func testPlannerPlanValidatorRejectsUnknownKeysAndInvalidShapes() {
    XCTAssertThrowsError(try PlannerPlanValidator.decodeStrict(from: #"{"actions":[{"type":"startConsole","nodeID":"bad"}]}"#))
    XCTAssertThrowsError(try PlannerPlanValidator.decodeStrict(from: #"{"actions":[{"type":"note","text":"ok","extra":"x"}]}"#))
    XCTAssertThrowsError(try PlannerPlanValidator.decodeStrict(from: #"{"wrong":[]}"#))
  }

  func testPlannerPlanValidatorRejectsOutOfRangeNumericBounds() {
    let nodeID = UUID()
    XCTAssertThrowsError(try PlannerPlanValidator.decodeStrict(from: #"{"actions":[{"type":"createLoop","name":"x","targetNodeID":"\#(nodeID.uuidString)","prompt":"go","trigger":{"type":"schedule","intervalSeconds":0},"maxIterations":10}]}"#))
    XCTAssertThrowsError(try PlannerPlanValidator.decodeStrict(from: #"{"actions":[{"type":"createLoop","name":"x","targetNodeID":"\#(nodeID.uuidString)","prompt":"go","trigger":{"type":"schedule","intervalSeconds":2592001},"maxIterations":10}]}"#))
    XCTAssertThrowsError(try PlannerPlanValidator.decodeStrict(from: #"{"actions":[{"type":"createLoop","name":"x","targetNodeID":"\#(nodeID.uuidString)","prompt":"go","trigger":{"type":"idle"},"maxIterations":0}]}"#))
    XCTAssertThrowsError(try PlannerPlanValidator.decodeStrict(from: #"{"actions":[{"type":"createLoop","name":"x","targetNodeID":"\#(nodeID.uuidString)","prompt":"go","trigger":{"type":"idle"},"maxIterations":1001}]}"#))
  }

  func testNewTerminalDraftDefaultsToShellAndHome() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let draft = NewTerminalDraft.make(
      knownAgents: AgentCatalog.knownCLIs,
      customExecutables: [],
      lastUsedAgentID: nil,
      recentDirectories: [],
      defaultDirectory: nil,
      homeDirectory: home
    )
    XCTAssertEqual(draft.featuredAgents.map(\.id), ["shell", "orchestrator", "codex", "claude", "cursor-agent"])
    XCTAssertTrue(draft.customAgents.isEmpty)
    XCTAssertEqual(draft.selectedAgentID, "shell")
    XCTAssertEqual(draft.selectedDirectoryPath, home.resolvingSymlinksInPath().path)
  }

  func testNewTerminalDraftPrefersLastUsedAgentAndDirectoryOverDefault() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let other = root.appendingPathComponent("other", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let draft = NewTerminalDraft.make(
      knownAgents: AgentCatalog.knownCLIs,
      customExecutables: [],
      lastUsedAgentID: "claude",
      recentDirectories: [project],
      defaultDirectory: other,
      homeDirectory: home
    )
    XCTAssertEqual(draft.selectedAgentID, "claude")
    XCTAssertEqual(draft.selectedDirectoryPath, project.resolvingSymlinksInPath().path)
    XCTAssertEqual(draft.directories.map(\.path).first, project.resolvingSymlinksInPath().path)
    XCTAssertTrue(draft.directories.contains { $0.path == other.resolvingSymlinksInPath().path })
    XCTAssertFalse(draft.directories.contains { $0.path == home.resolvingSymlinksInPath().path })
  }

  func testNewTerminalDraftKeepsEightDirectoriesAndIncludesCustomAgents() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var folders: [URL] = []
    for index in 0..<9 {
      let folder = root.appendingPathComponent("dir-\(index)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      folders.append(folder)
    }
    let remembered = try XCTUnwrap(NewTerminalDraft.rememberedDirectories(existing: Array(folders.dropFirst()), chosen: folders[0]))
    XCTAssertEqual(remembered.count, 8)
    XCTAssertEqual(remembered[0].path, folders[0].resolvingSymlinksInPath().path)
    XCTAssertFalse(remembered.contains { $0.path == folders[8].resolvingSymlinksInPath().path })
    let file = root.appendingPathComponent("note.txt")
    try Data("x".utf8).write(to: file)
    XCTAssertNil(NewTerminalDraft.validatedDirectory(file))
    XCTAssertNil(NewTerminalDraft.validatedDirectory(root.appendingPathComponent("missing", isDirectory: true)))
    let link = root.appendingPathComponent("link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folders[0])
    XCTAssertEqual(NewTerminalDraft.validatedDirectory(link)?.path, folders[0].resolvingSymlinksInPath().path)
    let custom = CustomAgentExecutable(id: "custom-one", displayName: "My Agent", executablePath: "/bin/zsh")
    let draft = NewTerminalDraft.make(
      knownAgents: AgentCatalog.knownCLIs,
      customExecutables: [custom],
      lastUsedAgentID: "custom-one",
      recentDirectories: remembered,
      defaultDirectory: nil,
      homeDirectory: root
    )
    XCTAssertEqual(draft.selectedAgentID, "custom-one")
    XCTAssertEqual(draft.customAgents.map(\.title), ["My Agent"])
    let inserted = draft.insertingDirectory(folders[8])
    XCTAssertEqual(inserted.selectedDirectoryPath, folders[8].resolvingSymlinksInPath().path)
    XCTAssertEqual(inserted.directories.count, 8)
    XCTAssertNil(NewTerminalDraft.rememberedDirectories(existing: [], chosen: file))
    let preferences = AppPreferences(lastUsedAgentID: "bad/id", recentWorkingDirectories: [
      URL(fileURLWithPath: "/nope", isDirectory: true),
      URL(fileURLWithPath: "/nope", isDirectory: true),
      file,
    ])
    let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
    XCTAssertNil(decoded.lastUsedAgentID)
    XCTAssertEqual(decoded.recentWorkingDirectories.map(\.path), ["/nope", file.standardizedFileURL.path])
    let legacy = Data(#"{"version":3,"restoreLastWorkspace":true,"showNotifications":true}"#.utf8)
    let legacyPreferences = try JSONDecoder().decode(AppPreferences.self, from: legacy)
    XCTAssertNil(legacyPreferences.lastUsedAgentID)
    XCTAssertTrue(legacyPreferences.recentWorkingDirectories.isEmpty)
    XCTAssertTrue(legacyPreferences.askBeforeSendingToTerminal)
    XCTAssertTrue(AppPreferences().askBeforeSendingToTerminal)
  }

  func testOrchestratorCommandsStayLiteralAndAskBeforeSending() {
    XCTAssertEqual(success(OrchestratorCommands.parse("list")), .list)
    XCTAssertEqual(success(OrchestratorCommands.parse("read Claude Code")), .read(target: "Claude Code"))
    guard case let .send(rest) = success(OrchestratorCommands.parse("send Shell echo $(id)")) else {
      XCTFail("expected send")
      return
    }
    let split = success(OrchestratorCommands.splitSend(rest, titles: ["Shell", "Claude Code"]))
    XCTAssertEqual(split?.target, "Shell")
    XCTAssertEqual(split?.text, "echo $(id)")
    let claude = success(OrchestratorCommands.splitSend("Claude Code echo hi", titles: ["Claude", "Claude Code"]))
    XCTAssertEqual(claude?.target, "Claude Code")
    XCTAssertEqual(claude?.text, "echo hi")
    XCTAssertEqual(failure(OrchestratorCommands.parse(" ")), .empty)
    XCTAssertEqual(failure(OrchestratorCommands.parse("nope")), .unknown("nope"))
    XCTAssertEqual(failure(OrchestratorCommands.splitSend("Shell", titles: ["Shell"])), .missingText)
    XCTAssertEqual(
      failure(OrchestratorCommands.splitSend("Shell \(String(repeating: "a", count: 5_000))", titles: ["Shell"])),
      .textTooLong)

    let shell = UUID()
    let other = UUID()
    let orchestrator = UUID()
    let consoles = [
      OrchestratorConsoleInfo(id: shell, title: "Shell", agentID: "shell", status: "idle", running: true),
      OrchestratorConsoleInfo(id: other, title: "Shell", agentID: "shell", status: "idle", running: true),
      OrchestratorConsoleInfo(id: orchestrator, title: "Orchestrator", agentID: "orchestrator", status: "idle", running: true),
    ]
    XCTAssertEqual(
      failure(OrchestratorTargets.resolve(query: "Shell", consoles: consoles))?.message,
      "Shell matches more than one console.")
    let resolved = success(OrchestratorTargets.resolve(query: "shell", consoles: [consoles[0], consoles[2]]))
    XCTAssertEqual(resolved?.id, shell)
    let link = UUID()
    let asked = OrchestratorSendGate.decide(
      orchestratorID: orchestrator, target: consoles[0], text: "echo sub-ok", linkID: link, askBeforeSending: true)
    guard case let .needsApproval(approval) = asked else {
      XCTFail("expected approval")
      return
    }
    XCTAssertEqual(approval.targetTitle, "Shell")
    XCTAssertEqual(approval.text, "echo sub-ok")
    let open = OrchestratorSendGate.decide(
      orchestratorID: orchestrator, target: consoles[0], text: "echo sub-ok", linkID: link, askBeforeSending: false)
    XCTAssertEqual(open, .deliver(targetID: shell, linkID: link, text: "echo sub-ok"))
    let selfSend = OrchestratorSendGate.decide(
      orchestratorID: orchestrator, target: consoles[2], text: "echo sub-ok", linkID: link, askBeforeSending: false)
    XCTAssertEqual(selfSend, .rejected("Orchestrator cannot take a task."))
    XCTAssertNil(OrchestratorWait.consider(status: "resting", outputGrew: true, hook: .permissionRequest)) // legacy raw value
    XCTAssertNil(OrchestratorWait.consider(status: "needsYou", outputGrew: true, hook: nil)) // legacy raw value
    XCTAssertEqual(OrchestratorWait.consider(status: "running", outputGrew: false, hook: .stop), .hookStop)
    XCTAssertEqual(OrchestratorWait.consider(status: "resting", outputGrew: false, hook: nil), nil) // legacy raw value
    XCTAssertEqual(OrchestratorWait.consider(status: "resting", outputGrew: true, hook: nil), .idle) // legacy raw value
    XCTAssertEqual(OrchestratorWait.consider(status: "done", outputGrew: false, hook: nil), .exited) // legacy raw value
    let report = OrchestratorSummary.report(title: "Shell", status: "idle", output: "noise\nsub-ok\n", reason: .idle)
    XCTAssertTrue(report.contains("sub-ok"))
    XCTAssertEqual(
      OrchestratorSummary.boundedTail("\u{001B}[32msub-ok\u{001B}[0m", maxBytes: 100, maxLines: 4),
      "sub-ok"
    )
    XCTAssertEqual(
      OrchestratorSummary.boundedTail("echo sub-ok\r\nsub-ok\r\n> ", maxBytes: 200, maxLines: 8),
      "echo sub-ok\nsub-ok\n>"
    )
    XCTAssertTrue(report.hasPrefix("Shell is Idle."))
    let huge = (0..<100).map { "line \($0)" }.joined(separator: "\n")
    XCTAssertLessThanOrEqual(OrchestratorSummary.boundedTail(huge, maxBytes: 1_200, maxLines: 12).split(separator: "\n").count, 12)
    XCTAssertEqual(OrchestratorLinkStatus.done.label, "Finished")
    let segment = OrchestratorLinkLayout.segment(
      from: NodeFrame(x: 0, y: 0, w: 100, h: 40),
      to: NodeFrame(x: 200, y: 0, w: 100, h: 40),
      zoom: 1, panX: 0, panY: 0)
    XCTAssertEqual(segment?.startX, 100)
    XCTAssertEqual(segment?.endX, 200)
    XCTAssertEqual(segment?.badgeX, 150)
    XCTAssertEqual(segment?.startY, 20)
    XCTAssertNil(OrchestratorLinkLayout.segment(
      from: NodeFrame(x: 0, y: 0, w: 0, h: 10),
      to: NodeFrame(x: 1, y: 1, w: 10, h: 10),
      zoom: 1, panX: 0, panY: 0))
  }

  private func success<T, E>(_ result: Result<T, E>) -> T? {
    if case let .success(value) = result { return value }
    return nil
  }

  private func failure<T, E>(_ result: Result<T, E>) -> E? {
    if case let .failure(error) = result { return error }
    return nil
  }

  private func makePNG(width: Int, height: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      XCTFail("Could not create CGContext")
      return Data()
    }
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
      XCTFail("Could not create CGImage")
      return Data()
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
      XCTFail("Could not create image destination")
      return Data()
    }
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }
}
