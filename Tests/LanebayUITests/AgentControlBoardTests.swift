import Foundation
import XCTest
import LanebayCore
@testable import LanebayUI

@MainActor
final class AgentControlBoardTests: XCTestCase {
  private func board(installed: Set<String>) -> (BoardViewModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root.appendingPathComponent("workspaces", isDirectory: true)),
      autosaveDelay: .seconds(60),
      usageTracker: UsageStatsTracker(store: UsageStatsStore(rootURL: root.appendingPathComponent("usage", isDirectory: true))),
      settings: SettingsViewModel(store: AppPreferencesStore(rootURL: root.appendingPathComponent("preferences", isDirectory: true))),
      homeDirectory: root,
      executableIsInstalled: { installed.contains($0) })
    return (board, root)
  }

  func testProviderStatusUsesTheCatalogAndInstallCheck() {
    let (board, root) = board(installed: ["freebuff"])
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertEqual(board.agentProviderStatus("freebuff"), .ready)
    XCTAssertEqual(board.agentProviderStatus("opencode"), .notInstalled)
    XCTAssertEqual(board.agentProviderStatus("no-such-agent"), .unknown)
    XCTAssertEqual(board.agentProviderStatus(OrchestratorKind.agentID), .unknown)
  }

  func testPublishedTasksReachTheBoardAndBannerText() {
    let (board, root) = board(installed: [])
    defer { try? FileManager.default.removeItem(at: root) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let node = UUID()
    var record = AgentTaskRecord(
      id: "abcd1234", nodeID: node, provider: "freebuff", cwd: "/tmp", task: "Fix the README\ntypo",
      startedAt: start, deadline: start.addingTimeInterval(3_300), state: .running,
      taskFile: "/tmp/t.task.md", handoffFile: "/tmp/t.md")
    board.agentTasksChanged([node: record])
    XCTAssertEqual(board.agentTasks[node]?.id, "abcd1234")
    XCTAssertEqual(AgentTaskBanner.label(record), "working on: Fix the README typo")
    XCTAssertEqual(AgentTaskBanner.trailing(record, now: start.addingTimeInterval(60)), "54:00")
    record.state = .timedOut
    XCTAssertEqual(AgentTaskBanner.trailing(record, now: start), "TimedOut")
    record.task = String(repeating: "x", count: 200)
    XCTAssertEqual(AgentTaskBanner.label(record).count, "working on: ".count + 80)
  }

  func testAgentConsoleKeepsFocusForThePrograms() {
    let session = ConsoleSession(supervisor: ProcessSupervisor())
    let focusIn = Data("\u{1B}[I".utf8), focusOut = Data("\u{1B}[O".utf8)
    XCTAssertTrue(session.shouldForwardTerminalInput(focusOut))
    XCTAssertFalse(session.shouldForwardTerminalInput(focusOut), "repeated focus-out is noise")
    XCTAssertTrue(session.shouldForwardTerminalInput(focusIn))
    XCTAssertTrue(session.shouldForwardTerminalInput(Data("a".utf8)))
    session.sendAgentInput("task")
    XCTAssertFalse(session.shouldForwardTerminalInput(focusOut), "FreeBuff drops Enter while unfocused")
  }
}
