import Darwin
import Foundation
import XCTest
@testable import LanebayCore

@MainActor
final class FakeAgentConsoles: AgentConsoleDriving {
  var providers: [String: AgentProviderStatus] = ["freebuff": .ready, "opencode": .notInstalled, "shell": .ready]
  var running: Set<UUID> = []
  var written: [UUID: [String]] = [:]
  var output: [UUID: String] = [:]
  var stopped: [UUID] = []
  var spawned: [(provider: String, cwd: URL, title: String)] = []
  var published: [UUID: AgentTaskRecord] = [:]
  var startImmediately = true

  func agentProviderStatus(_ provider: String) -> AgentProviderStatus { providers[provider] ?? .unknown }
  func spawnAgentConsole(provider: String, cwd: URL, title: String) -> UUID {
    let id = UUID()
    spawned.append((provider, cwd, title))
    if startImmediately { running.insert(id) }
    return id
  }
  func agentConsoleIsRunning(_ id: UUID) -> Bool { running.contains(id) }
  func writeToAgentConsole(_ text: String, id: UUID) -> Bool {
    guard running.contains(id) else { return false }
    written[id, default: []].append(text)
    return true
  }
  func agentConsoleOutput(_ id: UUID, maxBytes: Int) -> String? { output[id] }
  func stopAgentConsole(_ id: UUID) async { stopped.append(id); running.remove(id) }
  func agentTasksChanged(_ tasks: [UUID: AgentTaskRecord]) { published = tasks }
}

final class ManualClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_800_000_000)
  var now: Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

final class AgentTaskContractTests: XCTestCase {
  func testParseDuration() {
    XCTAssertEqual(AgentTaskContract.parseDuration("55m"), 3_300)
    XCTAssertEqual(AgentTaskContract.parseDuration("1h30m"), 5_400)
    XCTAssertEqual(AgentTaskContract.parseDuration("90s"), 90)
    XCTAssertEqual(AgentTaskContract.parseDuration("10"), 600)
    XCTAssertNil(AgentTaskContract.parseDuration("abc"))
    XCTAssertNil(AgentTaskContract.parseDuration("5x"))
    XCTAssertNil(AgentTaskContract.parseDuration("0m"))
    XCTAssertNil(AgentTaskContract.parseDuration(""))
  }

  func testValidateRefusesLongTasksBadTimeoutsAndMissingDirectories() throws {
    let files = AgentTaskFiles()
    let dir = FileManager.default.temporaryDirectory
    XCTAssertThrowsError(try files.validate(AgentSpawnRequest(provider: "freebuff", cwd: dir, task: String(repeating: "a", count: 1_501)))) {
      XCTAssertEqual($0 as? AgentSpawnError, .taskTooLong(1_501))
    }
    XCTAssertNoThrow(try files.validate(AgentSpawnRequest(provider: "freebuff", cwd: dir, task: String(repeating: "a", count: 1_500))))
    XCTAssertThrowsError(try files.validate(AgentSpawnRequest(provider: "freebuff", cwd: dir, task: "  "))) {
      XCTAssertEqual($0 as? AgentSpawnError, .emptyTask)
    }
    XCTAssertThrowsError(try files.validate(AgentSpawnRequest(provider: "freebuff", cwd: dir, task: "x", timeout: 4 * 3_600))) {
      XCTAssertEqual($0 as? AgentSpawnError, .invalidTimeout)
    }
    XCTAssertThrowsError(try files.validate(AgentSpawnRequest(provider: "freebuff", cwd: URL(fileURLWithPath: "/nope/\(UUID())"), task: "x")))
    XCTAssertThrowsError(try files.validate(AgentSpawnRequest(provider: "freebuff", cwd: dir, task: "x", contextFile: URL(fileURLWithPath: "/nope/\(UUID())"))))
  }

  func testClampNoteKeepsTwentyLines() {
    let note = (1...40).map { "line \($0)" }.joined(separator: "\n")
    let clamped = AgentTaskContract.clampNote(note)
    XCTAssertEqual(clamped.split(separator: "\n").count, 20)
    XCTAssertTrue(clamped.hasPrefix("line 1\n"))
  }

  func testPlainTextStripsAnsi() {
    XCTAssertEqual(AgentTaskContract.plainText("\u{1B}[31mred\u{1B}[0m ok\u{07}"), "red ok")
  }

  func testFallbackNoteIsShortAndLabelled() {
    let output = (1...100).map { "\u{1B}[2Kout \($0)" }.joined(separator: "\n")
    let note = AgentTaskContract.fallbackNote(outcome: .timedOut, task: "do it", output: output)
    let lines = note.split(separator: "\n")
    XCTAssertLessThanOrEqual(lines.count, 20)
    XCTAssertEqual(lines.first, "RESULT: timed out")
    XCTAssertTrue(note.contains("out 100"))
  }

  func testTransitions() {
    let now = Date()
    XCTAssertEqual(AgentTaskTransition.next(state: .running, now: now, deadline: now + 10, handoffWritten: true, processRunning: true), .done)
    XCTAssertEqual(AgentTaskTransition.next(state: .running, now: now + 11, deadline: now + 10, handoffWritten: false, processRunning: true), .timedOut)
    XCTAssertEqual(AgentTaskTransition.next(state: .running, now: now, deadline: now + 10, handoffWritten: false, processRunning: false), .exited)
    XCTAssertEqual(AgentTaskTransition.next(state: .starting, now: now, deadline: now + 10, handoffWritten: false, processRunning: false), .starting)
    XCTAssertEqual(AgentTaskTransition.next(state: .done, now: now + 99, deadline: now, handoffWritten: false, processRunning: false), .done)
  }

  func testCountdown() {
    XCTAssertEqual(AgentTaskRecord.countdown(3_300), "55:00")
    XCTAssertEqual(AgentTaskRecord.countdown(3_725), "1:02:05")
    XCTAssertEqual(AgentTaskRecord.countdown(0), "00:00")
  }

  func testFreebuffAndOpencodePresetsExist() {
    let ids = AgentCatalog.knownCLIs.map(\.id)
    XCTAssertTrue(ids.contains("freebuff"))
    XCTAssertTrue(ids.contains("opencode"))
    XCTAssertEqual(AgentCatalog.knownCLIs.first { $0.id == "freebuff" }?.executableName, "freebuff")
    XCTAssertTrue(AgentCatalog.defaultExecutableSearchDirectories.map(\.path).contains { $0.hasSuffix("/.npm-global/bin") })
  }

  func testFreebuffResolvesFromNpmGlobalWithoutLoginPath() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bin = home.appendingPathComponent(".npm-global/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let exe = bin.appendingPathComponent("freebuff")
    try Data("#!/bin/sh\n".utf8).write(to: exe)
    chmod(exe.path, 0o755)
    XCTAssertEqual(AgentCatalog.resolve(executableName: "freebuff", searchDirectories: [bin])?.path, exe.path)
    // npm installs the CLI as a symlink to its package's index.js.
    let link = bin.appendingPathComponent("freebuff-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: exe)
    XCTAssertTrue(AgentCatalog.isExecutableFile(link))
    XCTAssertFalse(AgentCatalog.isExecutableFile(bin))
    // A Finder launch has a minimal PATH; the resolver still checks the user bin dirs.
    let resolved = ProcessSupervisor.resolveExecutable("definitely-not-\(UUID().uuidString.prefix(6))", path: "/usr/bin:/bin")
    XCTAssertFalse(resolved.hasPrefix("/"))
  }
}

@MainActor
final class AgentControlServiceTests: XCTestCase {
  private var cwd: URL!

  override func setUp() async throws {
    cwd = FileManager.default.temporaryDirectory.appendingPathComponent("lb-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
  }

  override func tearDown() async throws { try? FileManager.default.removeItem(at: cwd) }

  private func makeService(_ fake: FakeAgentConsoles, clock: ManualClock) -> AgentControlService {
    AgentControlService(
      driver: fake,
      timing: .init(startupTimeout: .seconds(1), promptDelay: .zero, submitDelay: .zero, tickInterval: .seconds(1)),
      clock: { clock.now }, sleep: { _ in await Task.yield() })
  }

  func testSpawnWritesTaskFileDeliversPromptAndFinishesWhenTheAgentWritesItsNote() async throws {
    let fake = FakeAgentConsoles(), clock = ManualClock()
    let service = makeService(fake, clock: clock)
    let context = cwd.appendingPathComponent("ctx.md")
    try Data("Repo uses Swift.".utf8).write(to: context)
    let (record, delivery) = try service.spawn(AgentSpawnRequest(provider: "freebuff", cwd: cwd, task: "Add a README line", timeout: 600, contextFile: context))
    await delivery.value
    XCTAssertEqual(fake.spawned.first?.provider, "freebuff")
    XCTAssertEqual(fake.spawned.first?.title, "freebuff · \(record.id)")
    let taskText = try String(contentsOfFile: record.taskFile, encoding: .utf8)
    XCTAssertTrue(taskText.contains("Add a README line"))
    XCTAssertTrue(taskText.contains("Repo uses Swift."))
    XCTAssertTrue(record.taskFile.hasSuffix(".lanebay/handoffs/\(record.id).task.md"))
    let writes = fake.written[record.nodeID] ?? []
    XCTAssertEqual(writes.count, 2)
    XCTAssertTrue(writes[0].contains(record.handoffFile))
    XCTAssertEqual(writes[1], "\r")
    XCTAssertEqual(service.records[record.id]?.state, .running)
    XCTAssertEqual(fake.published[record.nodeID]?.state, .running)

    service.tick()
    XCTAssertEqual(service.records[record.id]?.state, .running)
    try Data("RESULT: done\nadded line\n".utf8).write(to: URL(fileURLWithPath: record.handoffFile))
    service.tick()
    XCTAssertEqual(service.records[record.id]?.state, .done)
    XCTAssertEqual(try String(contentsOfFile: record.handoffFile, encoding: .utf8), "RESULT: done\nadded line\n")
  }

  func testShellTaskRunsOnlyTheCommandAndWritesItsOwnNote() async throws {
    let fake = FakeAgentConsoles(), clock = ManualClock()
    let service = makeService(fake, clock: clock)
    let (record, delivery) = try service.spawn(AgentSpawnRequest(provider: "shell", cwd: cwd, task: "git status --short", timeout: 600))
    await delivery.value
    let typed = try XCTUnwrap(fake.written[record.nodeID]?.first)
    XCTAssertTrue(typed.hasPrefix("export PAGER=cat GIT_PAGER=cat; git status --short; printf "))
    XCTAssertFalse(typed.contains("RESULT"), "No contract prompt for shell")
    XCTAssertFalse(typed.contains("handoff"))
    // The echoed command must not count as finished.
    fake.output[record.nodeID] = "$ \(typed)\n"
    service.tick()
    XCTAssertEqual(service.records[record.id]?.state, .running)
    fake.output[record.nodeID] = "$ \(typed)\n M Sources/a.swift\n?? new.txt\n\n__LANEBAY_DONE_\(record.id):0\n$ "
    service.tick()
    XCTAssertEqual(service.records[record.id]?.state, .done)
    let note = try String(contentsOfFile: record.handoffFile, encoding: .utf8)
    XCTAssertTrue(note.hasPrefix("RESULT: done\nTASK: git status --short\nEXIT: 0"))
    XCTAssertTrue(note.contains("M Sources/a.swift"))
    XCTAssertTrue(note.contains("?? new.txt"))
    XCTAssertFalse(note.contains("printf"))
  }

  func testZshShellTaskHidesTheMarkerBehindAnInvisibleHook() async throws {
    let fake = FakeAgentConsoles(), clock = ManualClock()
    let service = AgentControlService(
      driver: fake,
      timing: .init(startupTimeout: .seconds(1), promptDelay: .zero, submitDelay: .zero, tickInterval: .seconds(1)),
      clock: { clock.now }, sleep: { _ in await Task.yield() }, shellHooks: true)
    let (record, delivery) = try service.spawn(AgentSpawnRequest(provider: "shell", cwd: cwd, task: "git status --short", timeout: 600))
    await delivery.value
    let writes = try XCTUnwrap(fake.written[record.nodeID])
    XCTAssertTrue(writes[0].hasPrefix(" export PAGER=cat GIT_PAGER=cat; __lb_hook()"))
    XCTAssertTrue(writes[0].hasSuffix("clear"))
    XCTAssertEqual(writes[1], "\r", "Return goes in its own write")
    XCTAssertEqual(writes[2], "git status --short", "The visible line is only the command")
    let id = record.id
    let esc = "\u{1B}", bel = "\u{07}"
    fake.output[record.nodeID] = "\(esc)]777;lanebay-start;\(id)\(bel)$ git status --short\n"
    service.tick()
    XCTAssertEqual(service.records[id]?.state, .running)
    fake.output[record.nodeID]! += " M Sources/a.swift\n?? new.txt\n\(esc)]777;lanebay-done;\(id);0\(bel)$ "
    service.tick()
    XCTAssertEqual(service.records[id]?.state, .done)
    let note = try String(contentsOfFile: record.handoffFile, encoding: .utf8)
    XCTAssertTrue(note.hasPrefix("RESULT: done\nTASK: git status --short\nEXIT: 0"))
    XCTAssertTrue(note.contains("  M Sources/a.swift"))
    XCTAssertFalse(note.contains("$ git status"), "Prompt and echoed command are dropped")
    XCTAssertEqual(AgentTaskContract.shellExitCode(in: "x\(esc)]777;lanebay-done;\(id);2\(bel)", id: id), 2)
    XCTAssertTrue(AgentTaskContract.shellSupportsHook("/bin/zsh"))
    XCTAssertFalse(AgentTaskContract.shellSupportsHook("/bin/bash"))
  }

  func testShellNoteReportsAFailingExitCode() {
    let output = "$ false; printf '\\n__LANEBAY_DONE_%s:%d\\n' ab12 $?\nboom\n__LANEBAY_DONE_ab12:1\n"
    XCTAssertEqual(AgentTaskContract.shellExitCode(in: output, id: "ab12"), 1)
    XCTAssertNil(AgentTaskContract.shellExitCode(in: output, id: "other"))
    let note = AgentTaskContract.shellNote(task: "false", id: "ab12", exitCode: 1, output: output)
    XCTAssertTrue(note.hasPrefix("RESULT: blocked (exit 1)"))
    XCTAssertTrue(note.contains("  boom"))
    XCTAssertEqual(AgentTaskContract.shellCommand(task: "a\nb", id: "x"), "export PAGER=cat GIT_PAGER=cat; a; b; printf '\\n__LANEBAY_DONE_%s:%d\\n' x $?")
  }

  func testTimeoutMarksTimedOutAndWritesAFallbackNote() async throws {
    let fake = FakeAgentConsoles(), clock = ManualClock()
    let service = makeService(fake, clock: clock)
    let (record, delivery) = try service.spawn(AgentSpawnRequest(provider: "freebuff", cwd: cwd, task: "Long job", timeout: 60))
    await delivery.value
    fake.output[record.nodeID] = "working...\nstill working"
    clock.advance(61)
    service.tick()
    XCTAssertEqual(service.records[record.id]?.state, .timedOut)
    let note = try String(contentsOfFile: record.handoffFile, encoding: .utf8)
    XCTAssertTrue(note.hasPrefix("RESULT: timed out"))
    XCTAssertTrue(note.contains("still working"))
    XCTAssertLessThanOrEqual(note.split(separator: "\n").count, 20)
  }

  func testLongAgentNoteIsClampedOnFinish() async throws {
    let fake = FakeAgentConsoles(), clock = ManualClock()
    let service = makeService(fake, clock: clock)
    let (record, delivery) = try service.spawn(AgentSpawnRequest(provider: "freebuff", cwd: cwd, task: "x", timeout: 60))
    await delivery.value
    try Data((1...50).map { "l\($0)" }.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: record.handoffFile))
    service.tick()
    XCTAssertEqual(try String(contentsOfFile: record.handoffFile, encoding: .utf8).split(separator: "\n").count, 20)
  }

  func testConsoleThatNeverStartsFails() async throws {
    let fake = FakeAgentConsoles(), clock = ManualClock()
    fake.startImmediately = false
    let service = makeService(fake, clock: clock)
    let (record, delivery) = try service.spawn(AgentSpawnRequest(provider: "freebuff", cwd: cwd, task: "x", timeout: 60))
    await delivery.value
    XCTAssertEqual(service.records[record.id]?.state, .failed)
    XCTAssertTrue(FileManager.default.fileExists(atPath: record.handoffFile))
  }

  func testRefusesUnknownUninstalledAndOversizedTasks() {
    let fake = FakeAgentConsoles(), clock = ManualClock()
    let service = makeService(fake, clock: clock)
    XCTAssertThrowsError(try service.spawn(AgentSpawnRequest(provider: "nope", cwd: cwd, task: "x"))) {
      XCTAssertEqual($0 as? AgentSpawnError, .unknownProvider("nope"))
    }
    XCTAssertThrowsError(try service.spawn(AgentSpawnRequest(provider: "opencode", cwd: cwd, task: "x"))) {
      XCTAssertEqual($0 as? AgentSpawnError, .providerNotInstalled("opencode"))
    }
    XCTAssertThrowsError(try service.spawn(AgentSpawnRequest(provider: "freebuff", cwd: cwd, task: String(repeating: "y", count: 2_000))))
    XCTAssertTrue(fake.spawned.isEmpty)
  }

  func testHandleCoversAllOperations() async throws {
    let fake = FakeAgentConsoles(), clock = ManualClock()
    let service = makeService(fake, clock: clock)
    let spawn = await service.handle(ControlRequest(token: "", op: "spawn", args: ["provider": "freebuff", "cwd": cwd.path, "task": "hello", "timeout": "55m"]))
    XCTAssertTrue(spawn.ok, spawn.error ?? "")
    let id = try XCTUnwrap(spawn.task?.id)
    XCTAssertEqual(spawn.task.map { $0.deadline.timeIntervalSince($0.startedAt) }, 3_300)
    for _ in 0..<20 { await Task.yield() }
    let nodeID = try XCTUnwrap(spawn.task?.nodeID)
    fake.output[nodeID] = "a\nb\n\u{1B}[1mc\u{1B}[0m"
    let read = await service.handle(ControlRequest(token: "", op: "read", args: ["id": id, "tail": "2"]))
    XCTAssertEqual(read.output, "b\nc")
    let send = await service.handle(ControlRequest(token: "", op: "send", args: ["id": id, "text": "more"]))
    XCTAssertTrue(send.ok, send.error ?? "")
    let list = await service.handle(ControlRequest(token: "", op: "list"))
    XCTAssertEqual(list.tasks?.map(\.id), [id])
    let status = await service.handle(ControlRequest(token: "", op: "status", args: ["id": id]))
    XCTAssertEqual(status.task?.id, id)
    let stop = await service.handle(ControlRequest(token: "", op: "stop", args: ["id": id]))
    XCTAssertEqual(stop.task?.state, .stopped)
    XCTAssertEqual(fake.stopped, [nodeID])
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(stop.task?.handoffFile)))
    let bad = await service.handle(ControlRequest(token: "", op: "spawn", args: ["cwd": "relative", "task": "x"]))
    XCTAssertFalse(bad.ok)
    let badTimeout = await service.handle(ControlRequest(token: "", op: "spawn", args: ["cwd": cwd.path, "task": "x", "timeout": "soon"]))
    XCTAssertFalse(badTimeout.ok)
  }
}

final class ControlServerTests: XCTestCase {
  private func makePaths() -> ControlPaths {
    ControlPaths(directory: URL(fileURLWithPath: "/tmp/lbc-\(UUID().uuidString.prefix(8))", isDirectory: true))
  }

  func testRoundTripPermissionsAndTokenCheck() throws {
    let paths = makePaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let server = ControlServer(paths: paths, token: "secret-token-for-test") { request in
      ControlResponse(output: "\(request.op):\(request.args["id"] ?? "")")
    }
    try server.start()
    defer { server.stop() }
    let attributes = { (url: URL) in try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }
    XCTAssertEqual(try attributes(paths.directory), 0o700)
    XCTAssertEqual(try attributes(paths.token), 0o600)
    XCTAssertEqual(try attributes(paths.socket), 0o600)

    let client = ControlClient(paths: paths)
    XCTAssertEqual(try client.token(), "secret-token-for-test")
    let response = try client.send(op: .read, args: ["id": "abc"])
    XCTAssertTrue(response.ok)
    XCTAssertEqual(response.output, "read:abc")

    try Data("wrong\n".utf8).write(to: paths.token)
    let denied = try client.send(op: .list)
    XCTAssertFalse(denied.ok)
    XCTAssertEqual(denied.error, "Invalid control token.")
  }

  func testSecondServerOnTheSameSocketIsRefusedAndStaleSocketsAreReplaced() throws {
    let paths = makePaths()
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    let first = ControlServer(paths: paths) { _ in ControlResponse() }
    try first.start()
    let second = ControlServer(paths: paths) { _ in ControlResponse() }
    XCTAssertThrowsError(try second.start()) {
      XCTAssertEqual($0 as? ControlSocketError, .alreadyRunning(paths.socket.path))
    }
    first.stop()
    XCTAssertThrowsError(try ControlClient(paths: paths).send(op: .list))
    // A leftover socket file with no listener is replaced.
    FileManager.default.createFile(atPath: paths.socket.path, contents: nil)
    let third = ControlServer(paths: paths) { _ in ControlResponse(output: "third") }
    try third.start()
    defer { third.stop() }
    XCTAssertEqual(try ControlClient(paths: paths).send(op: .list).output, "third")
  }

  func testConstantTimeEqual() {
    XCTAssertTrue(ControlServer.constantTimeEqual("abc", "abc"))
    XCTAssertFalse(ControlServer.constantTimeEqual("abc", "abd"))
    XCTAssertFalse(ControlServer.constantTimeEqual("", ""))
    XCTAssertFalse(ControlServer.constantTimeEqual("ab", "abc"))
  }
}
