import Foundation
import LanebayCore
import XCTest

@testable import LanebayUI

@MainActor
final class WireBoardTests: XCTestCase {
  private func board() -> BoardViewModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    for name in ["workspaces", "preferences", "usage"] {
      try? FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root.appendingPathComponent("workspaces")), autosaveDelay: .seconds(60),
      processEnvironment: [
        "HOME": root.path, "ZDOTDIR": root.path, "HISTFILE": root.appendingPathComponent("history").path,
        "SHELL": "/bin/zsh"
      ],
      usageTracker: UsageStatsTracker(store: UsageStatsStore(rootURL: root.appendingPathComponent("usage"))),
      settings: SettingsViewModel(store: AppPreferencesStore(rootURL: root.appendingPathComponent("preferences"))),
      homeDirectory: root)
    _ = board.createWorkspace(name: "Tråder")
    return board
  }

  func testFinishedReplyRoutesOriginalWiresAfterWorkspaceSwitch() async throws {
    for mode in [WireMode.everyReply, .handoff] {
      let board = board()
      addTeardownBlock { await board.shutdown() }
      let owner = try XCTUnwrap(board.activeWorkspaceID)
      let source = board.addConsole(agentID: "opencode")
      let target = board.addConsole(agentID: "shell", cwd: board.homeDirectory)
      board.renameConsole(source, to: "Original source")
      board.renameConsole(target, to: "Original target")
      guard case .success = board.addWire(from: source, to: target, mode: mode) else {
        return XCTFail("wire missing")
      }
      board.beginChatReply(for: source)
      let work = try XCTUnwrap(board.chatWorking[source])
      let other = board.createWorkspace(name: "Other")
      let decoy = board.addConsole(agentID: "shell")
      board.renameConsole(decoy, to: "Original target")
      board.finishReply(source, work: work, status: .done, note: nil, screenAnswer: "Workspace reply marker")

      let deadline = Date().addingTimeInterval(8)
      while Date() < deadline, !String(decoding: board.sessions[target]?.recentOutput ?? Data(), as: UTF8.self).contains("Workspace reply marker") {
        try await Task.sleep(for: .milliseconds(100))
      }
      XCTAssertEqual(board.activeWorkspaceID, other)
      XCTAssertTrue(board.chatEntries.isEmpty)
      XCTAssertNil(board.sessions[decoy])
      XCTAssertTrue(board.sessions[target]?.isRunning == true, "stopped target in original workspace must start")
      XCTAssertTrue(String(decoding: board.sessions[target]?.recentOutput ?? Data(), as: UTF8.self).contains("Workspace reply marker"))
      let original = try XCTUnwrap(board.workspaces.first { $0.id == owner })
      let entry = try XCTUnwrap(original.chat.first { $0.kind == .wire })
      XCTAssertEqual(entry.from, source)
      XCTAssertEqual(entry.to, target)
      XCTAssertTrue(entry.text.contains("Original source"))
      XCTAssertTrue(entry.text.contains("Workspace reply marker"))
      XCTAssertEqual(original.nodes.first { $0.id == target }?.notStarted, false)
      board.switchWorkspace(owner)
      await board.closeConsole(target)
    }
  }

  func testWireAIReplyBelongsToSourceWorkspace() throws {
    let board = board()
    addTeardownBlock { await board.shutdown() }
    let owner = try XCTUnwrap(board.activeWorkspaceID)
    let source = board.addConsole(agentID: "shell")
    let target = board.addConsole(agentID: "opencode")
    guard case .success = board.addWire(from: source, to: target, mode: .everyReply) else {
      return XCTFail("wire missing")
    }
    _ = board.createWorkspace(name: "Other")
    board.deliverAlongWires(from: source, mode: .everyReply, body: "Original reply")
    XCTAssertTrue(board.chatEntries.isEmpty)
    XCTAssertEqual(board.chatWorking[target]?.workspaceID, owner)
    XCTAssertEqual(board.workspaces.first { $0.id == owner }?.chat.map(\.kind), [.wire, .reply])
    // Cancel before the scheduled delivery can start an external CLI.
    board.setShuttingDownForTesting(true)
  }

  func testDraggingFromAPortOntoACardMakesAFacingWire() {
    let board = board()
    let a = board.addConsole(agentID: "shell"), b = board.addConsole(agentID: "shell")
    board.moveNode(a, x: 0, y: 0)
    board.moveNode(b, x: 800, y: 0)
    let frames = Dictionary(uniqueKeysWithValues: board.consoleFrames())
    let bFrame = try! XCTUnwrap(frames[b])
    board.wireDrag = WireDrag(from: a, side: .right, point: .init(x: bFrame.x + 40, y: bFrame.y + 40))
    let wire = board.finishWireDrag()
    XCTAssertNil(board.wireDrag)
    XCTAssertEqual(wire?.from, a)
    XCTAssertEqual(wire?.to, b)
    XCTAssertEqual(wire?.toSide, .left)
    XCTAssertEqual(board.wires.count, 1)
    // Dropping on empty board or back on itself makes nothing.
    board.wireDrag = WireDrag(from: a, side: .right, point: .init(x: 5_000, y: 5_000))
    XCTAssertNil(board.finishWireDrag())
    board.wireDrag = WireDrag(from: a, side: .right, point: .init(x: 10, y: 10))
    XCTAssertNil(board.finishWireDrag())
    // A second identical wire is refused.
    if case .success = board.addWire(from: a, to: b) { XCTFail("duplicate wire was added") }
    XCTAssertEqual(board.wires.count, 1)
  }

  func testWireEditRemoveAndCardCloseCleanUp() async {
    let board = board()
    let a = board.addConsole(agentID: "shell"), b = board.addConsole(agentID: "shell"), c = board.addConsole(agentID: "shell")
    guard case let .success(ab) = board.addWire(from: a, to: b), case .success = board.addWire(from: a, to: c) else {
      return XCTFail("wires were not added")
    }
    board.updateWire(ab.id) { $0.enabled = false; $0.instruction = "se over" }
    XCTAssertEqual(board.wire(ab.id)?.enabled, false)
    XCTAssertEqual(board.wire(ab.id)?.instruction, "se over")
    board.selectedWireID = ab.id
    board.removeWire(ab.id)
    XCTAssertNil(board.selectedWireID)
    XCTAssertEqual(board.wires.count, 1)
    await board.closeConsole(c)
    XCTAssertTrue(board.wires.isEmpty)
  }

  func testTemplatesLayOutCardsAndWires() {
    let board = board()
    let pipeline = board.applyWireTemplate(.pipeline, agentID: "shell")
    XCTAssertEqual(pipeline.count, 3)
    XCTAssertEqual(board.wires.count, 2)
    XCTAssertEqual(board.consoleTitle(pipeline[1]), "Utvikler")
    let lead = board.applyWireTemplate(.leadWorkers, agentID: "shell")
    XCTAssertEqual(lead.count, 4)
    XCTAssertEqual(board.wires.filter { $0.from == lead[0] }.count, 3)
    XCTAssertTrue(board.wires.allSatisfy { $0.direction == .oneWay || $0.from == lead[0] })
    XCTAssertTrue(board.activity.events.contains { $0.kind == .wire })
  }
}
