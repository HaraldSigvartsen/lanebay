import Foundation
import LanebayCore
import XCTest

@testable import LanebayUI

@MainActor
final class ChatBoardTests: XCTestCase {
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
    _ = board.createWorkspace(name: "Chat")
    return board
  }

  func testRenameKeepsNamesUniqueAndMakesHandles() {
    let board = board()
    let a = board.addConsole(agentID: "shell"), b = board.addConsole(agentID: "shell")
    XCTAssertEqual(board.renameConsole(a, to: "Utvikler"), "Utvikler")
    XCTAssertEqual(board.renameConsole(b, to: "utvikler"), "utvikler 2")
    XCTAssertNil(board.renameConsole(b, to: "   "))
    XCTAssertEqual(board.chatHandles["utvikler"], a)
    XCTAssertEqual(board.chatHandles["utvikler-2"], b)
    XCTAssertEqual(board.resolveCard("@utvikler"), a)
  }

  func testRecipientsFollowTagsAllAndSelection() {
    let board = board()
    let a = board.addConsole(agentID: "shell"), b = board.addConsole(agentID: "shell")
    board.renameConsole(a, to: "Planlegger")
    board.renameConsole(b, to: "Reviewer")
    XCTAssertEqual(board.chatRecipients(for: "@reviewer se over").targets, [b])
    XCTAssertEqual(board.chatRecipients(for: "@reviewer se over").body, "se over")
    XCTAssertEqual(Set(board.chatRecipients(for: "@alle status").targets), [a, b])
    XCTAssertEqual(Set(board.chatRecipients(for: "@planlegger @reviewer hei").targets), [a, b])
    board.select(a)
    XCTAssertEqual(board.chatRecipients(for: "hei").targets, [a])
  }

  func testSendWithoutRecipientAddsSystemNoteAndPanelPersists() {
    let board = board()
    _ = board.addConsole(agentID: "shell")
    board.select(nil)
    XCTAssertFalse(board.sendChat("hei"))
    XCTAssertEqual(board.chatEntries.last?.kind, .system)
    board.setChatPanel(open: false, width: 999)
    XCTAssertFalse(board.chatPanelOpen)
    XCTAssertEqual(board.chatPanelWidth, 560)
    board.clearChat()
    XCTAssertTrue(board.chatEntries.isEmpty)
  }

  func testChangeProviderKeepsCustomNameAndStoresModel() async {
    let board = board()
    let a = board.addConsole(agentID: "shell"), b = board.addConsole(agentID: "shell")
    board.renameConsole(b, to: "Utvikler")
    await board.changeProvider(a, agentID: "codex", model: "gpt-6-sol")
    await board.changeProvider(b, agentID: "freebuff", model: "ignored")
    let nodes = board.workspace?.nodes ?? []
    let first = nodes.first { $0.id == a }, second = nodes.first { $0.id == b }
    XCTAssertEqual(first?.agentID, "codex")
    XCTAssertEqual(first?.model, "gpt-6-sol")
    XCTAssertEqual(first?.title, "Codex")
    XCTAssertEqual(second?.agentID, "freebuff")
    XCTAssertNil(second?.model, "FreeBuff picks its model itself")
    XCTAssertEqual(second?.title, "Utvikler")
  }

  func testCronJobsAddValidateAndRun() {
    let board = board()
    let a = board.addConsole(agentID: "shell")
    board.renameConsole(a, to: "Bygger")
    XCTAssertThrowsError(try board.addCronJob(name: "x", card: "Finnes ikke", prompt: "hei", schedule: .every(minutes: 5)).get())
    XCTAssertThrowsError(try board.addCronJob(name: "x", card: "Bygger", prompt: " ", schedule: .every(minutes: 5)).get())
    let job = try? board.addCronJob(name: "Morgen", card: "@bygger", prompt: "echo hei", schedule: .every(minutes: 5)).get()
    XCTAssertNotNil(job)
    XCTAssertTrue(board.cronJobs.count == 1)
    board.runDueCronJobs(now: Date().addingTimeInterval(60))
    XCTAssertNil(board.cronJobs.first?.lastRun, "not due yet")
    board.runDueCronJobs(now: Date().addingTimeInterval(6 * 60))
    XCTAssertNotNil(board.cronJobs.first?.lastRun)
    XCTAssertEqual(board.cronJobs.first?.lastResult, "Sendt til Bygger")
    XCTAssertTrue(board.chatEntries.contains { $0.kind == .system && $0.text.contains("Morgen") })
    let listed = try? board.controlCron(["action": "list"]).get()
    XCTAssertTrue(listed?.contains("Morgen") == true)
    _ = board.controlCron(["action": "rm", "id": String(job!.id.uuidString.prefix(8))])
    XCTAssertTrue(board.cronJobs.isEmpty)
  }

  func testNewCronJobWaitsItsIntervalAfterLongAppUptime() throws {
    let board = board()
    let card = board.addConsole(agentID: "shell")
    board.renameConsole(card, to: "Bygger")
    board.cronReference = Date().addingTimeInterval(-3600)
    let job = try board.addCronJob(
      name: "Ny jobb", card: "Bygger", prompt: "echo scheduled", schedule: .every(minutes: 30)
    ).get()

    board.runDueCronJobs(now: Date().addingTimeInterval(29 * 60))

    XCTAssertNil(board.cronJobs.first { $0.id == job.id }?.lastRun)
    XCTAssertTrue(board.chatEntries.isEmpty, "A newly added job must not dispatch early")
    XCTAssertNil(board.sessions[card], "It must not start the target before the interval has elapsed")

    let due = Date().addingTimeInterval(31 * 60)
    board.runDueCronJobs(now: due)
    XCTAssertEqual(board.cronJobs.first { $0.id == job.id }?.lastRun, due)
    XCTAssertEqual(board.cronJobs.first { $0.id == job.id }?.lastResult, "Sendt til Bygger")
    let chatCount = board.chatEntries.count
    board.runDueCronJobs(now: due)
    XCTAssertEqual(board.chatEntries.count, chatCount, "The next tick must not repeat the delivery")
  }
}
