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
      usageTracker: UsageStatsTracker(store: UsageStatsStore(rootURL: root.appendingPathComponent("usage"))),
      settings: SettingsViewModel(store: AppPreferencesStore(rootURL: root.appendingPathComponent("preferences"))),
      homeDirectory: root)
    _ = board.createWorkspace(name: "Tråder")
    return board
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
