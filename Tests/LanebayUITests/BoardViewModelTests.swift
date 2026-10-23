import AppKit
import Darwin
import LanebayCore
import SwiftUI
import XCTest

@testable import LanebayUI

@MainActor
private final class RecordingNotifier: AgentNotificationSending {
  var count = 0
  func notify(title: String, body: String) { count += 1 }
}

@MainActor
private final class RecordingStatusSpeaker: VoiceStatusSpeaking {
  var spoken: [String] = []
  func speakShortStatus(_ text: String) { spoken.append(text) }
}

@MainActor
final class BoardViewModelTests: XCTestCase {
  private func fixture() -> (BoardViewModel, WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
    let preferencesRoot = root.appendingPathComponent("preferences", isDirectory: true)
    let usageRoot = root.appendingPathComponent("usage", isDirectory: true)
    try? FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: preferencesRoot, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: usageRoot, withIntermediateDirectories: true)
    let store = WorkspaceStore(rootURL: workspacesRoot)
    let settings = SettingsViewModel(store: AppPreferencesStore(rootURL: preferencesRoot))
    return (
      BoardViewModel(
        store: store, autosaveDelay: .seconds(60), usageTracker: usageTracker(root), settings: settings,
        homeDirectory: root),
      store, root)
  }

  private func settings(_ root: URL) -> SettingsViewModel {
    SettingsViewModel(store: AppPreferencesStore(rootURL: root.appendingPathComponent("preferences", isDirectory: true)))
  }

  private func usageTracker(_ root: URL) -> UsageStatsTracker {
    UsageStatsTracker(store: UsageStatsStore(rootURL: root.appendingPathComponent("usage", isDirectory: true)))
  }

  private func waitForScrollback(
    _ needle: String, sessionID: SessionID, supervisor: ProcessSupervisor
  ) async throws -> String {
    let deadline = ContinuousClock.now + .seconds(15)
    var latest = ""
    while ContinuousClock.now < deadline {
      latest = String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self)
      if latest.contains(needle) { return latest }
      try await Task.sleep(for: .milliseconds(30))
    }
    return latest
  }

  private func waitForShellPID(sessionID: SessionID, supervisor: ProcessSupervisor) async -> pid_t? {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      guard let data = try? await supervisor.scrollback(for: sessionID) else { return nil }
      let text = String(decoding: data, as: UTF8.self)
      if let pid = shellPID(in: text) { return pid }
      try? await Task.sleep(for: .milliseconds(30))
    }
    return nil
  }

  private func shellPID(in text: String) -> pid_t? {
    let marker = "LANEBAY-PID:"
    var found: pid_t?
    var search = text.startIndex
    while let range = text.range(of: marker, range: search..<text.endIndex) {
      var index = range.upperBound
      var value: Int32 = 0
      var digits = 0
      while index < text.endIndex, let digit = text[index].wholeNumberValue {
        value = value * 10 + Int32(digit)
        digits += 1
        index = text.index(after: index)
        if digits > 8 { value = 0; break }
      }
      if digits > 0, value > 1 { found = value }
      search = range.upperBound
    }
    return found
  }

  func testIdleRecipientsAreActiveWorkspaceOnlyAndExcludeStoppedConsoles() {
    let active = UUID(), hidden = UUID(), stopped = UUID()
    XCTAssertEqual(
      BoardViewModel.idleRecipients(
        activeNodeIDs: [active], runningIDs: [active, hidden], idleIDs: [active, hidden]),
      [active])
    XCTAssertTrue(BoardViewModel.idleRecipients(
      activeNodeIDs: [stopped], runningIDs: [], idleIDs: [stopped]).isEmpty)
  }

  func testPreferencesControlStartupDirectoryAndNotifications() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaceStore = WorkspaceStore(rootURL: root.appendingPathComponent("workspaces"))
    let first = Workspace(name: "Oldest", createdAt: Date(timeIntervalSince1970: 1))
    let last = Workspace(name: "Last used", createdAt: Date(timeIntervalSince1970: 2))
    try workspaceStore.save(first); try workspaceStore.save(last)
    let preferencesStore = AppPreferencesStore(rootURL: root.appendingPathComponent("settings"))
    let initialSettings = SettingsViewModel(store: preferencesStore)
    let project = root.appendingPathComponent("project", isDirectory: true)
    initialSettings.setDefaultWorkingDirectory(project)
    initialSettings.recordActiveWorkspace(last.id)
    let settings = SettingsViewModel(store: preferencesStore)
    let notifier = RecordingNotifier()
    let board = BoardViewModel(store: workspaceStore, notifier: notifier, usageTracker: usageTracker(root), settings: settings)
    XCTAssertEqual(board.activeWorkspaceID, last.id, "Startup restores the last active workspace")
    let consoleID = board.addConsole(agent: .shell)
    XCTAssertEqual(board.workspace?.nodes.first(where: { $0.id == consoleID })?.cwd, project)
    let session = ConsoleSession(supervisor: ProcessSupervisor())
    session.setRunningForTesting(true)
    session.setStatus(.waitingForInput)
    board.installSessionForTesting(session, id: consoleID)
    settings.setShowNotifications(false)
    board.handleStatusTransition(for: consoleID, from: .running)
    XCTAssertEqual(notifier.count, 0)
    settings.setShowNotifications(true)
    board.handleStatusTransition(for: consoleID, from: .waitingForInput)
    board.handleStatusTransition(for: consoleID, from: .running)
    XCTAssertEqual(notifier.count, 1)

    settings.setRestoreLastWorkspace(false)
    let fresh = BoardViewModel(store: workspaceStore, usageTracker: usageTracker(root), settings: settings)
    XCTAssertEqual(fresh.activeWorkspaceID, first.id, "Disabling restore selects the oldest workspace")
  }

  func testWaitingForInputTTSRespectsPreferenceToggle() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaceStore = WorkspaceStore(rootURL: root.appendingPathComponent("workspaces"))
    let settings = SettingsViewModel(store: AppPreferencesStore(rootURL: root.appendingPathComponent("settings")))
    let speaker = RecordingStatusSpeaker()
    let board = BoardViewModel(
      store: workspaceStore,
      notifier: RecordingNotifier(),
      usageTracker: usageTracker(root),
      statusSpeaker: speaker,
      settings: settings
    )
    let consoleID = board.addConsole(agent: ConsoleAgent.shell)
    let session = ConsoleSession(supervisor: ProcessSupervisor())
    session.setRunningForTesting(true)
    session.setStatus(.waitingForInput)
    board.installSessionForTesting(session, id: consoleID)

    settings.setSpeakWaitingForInputStatus(false)
    board.handleStatusTransition(for: consoleID, from: AgentStatus.running)
    XCTAssertTrue(speaker.spoken.isEmpty)

    session.setStatus(.running)
    board.handleStatusTransition(for: consoleID, from: AgentStatus.waitingForInput)
    session.setStatus(.waitingForInput)
    settings.setSpeakWaitingForInputStatus(true)
    board.handleStatusTransition(for: consoleID, from: AgentStatus.running)
    XCTAssertEqual(speaker.spoken.count, 1)
    XCTAssertTrue(speaker.spoken[0].contains("waiting for input"))
  }

  func testHookRoutingPrioritizesExactBindingAndBindsOnlyUniqueLaunchCandidate() {
    let bound = UUID(), unbound = UUID()
    let known = AgentEvent(agent: "claude", event: .stop, sessionID: "known")
    XCTAssertEqual(BoardViewModel.hookRecipient(candidates: [(bound, "known"), (unbound, nil)], event: known), bound)
    let launch = AgentEvent(agent: "claude", event: .sessionStart, sessionID: "new")
    XCTAssertEqual(BoardViewModel.hookRecipient(candidates: [(bound, "known"), (unbound, nil)], event: launch), unbound)
    XCTAssertNil(BoardViewModel.hookRecipient(candidates: [(bound, nil), (unbound, nil)], event: launch))
  }

  func testWaitingForInputNotificationsAreDeduplicatedUntilStatusClears() {
    let id = UUID()
    var state = WaitingForInputNotificationState()
    XCTAssertTrue(state.transition(id: id, from: .running, to: .waitingForInput))
    XCTAssertFalse(state.transition(id: id, from: .waitingForInput, to: .waitingForInput))
    XCTAssertFalse(state.transition(id: id, from: .waitingForInput, to: .running))
    XCTAssertTrue(state.transition(id: id, from: .running, to: .waitingForInput))
  }

  func testAddMoveResizeAndCloseConsole() async throws {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for agent in ConsoleAgent.allCases {
      let id = board.addConsole(agent: agent, cwd: root)
      let node = try XCTUnwrap(board.workspace?.nodes.last)
      XCTAssertEqual(node.id, id)
      XCTAssertEqual(node.agentID, agent.rawValue)
      XCTAssertTrue(node.notStarted)
      XCTAssertEqual(board.selectedNodeIDs, [id])
      board.moveNode(id, x: -50, y: 120)
      board.resizeNode(id, width: 10, height: 5)
      let moved = try XCTUnwrap(board.workspace?.nodes.last)
      XCTAssertEqual(moved.frame, NodeFrame(x: -50, y: 120, w: 280, h: 160))
      await board.closeConsole(id)
      XCTAssertFalse(board.workspace!.nodes.contains { $0.id == id })
      XCTAssertTrue(board.selectedNodeIDs.isEmpty)
    }
  }

  func testZoomClampsAndKeepsAnchorFixed() {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    board.pan(dx: 20, dy: -10)
    board.setZoom(10, anchorX: 100, anchorY: 50)
    XCTAssertEqual(board.zoom, 2)
    XCTAssertEqual(board.panX, -60)
    XCTAssertEqual(board.panY, -70)
    board.setZoom(0.01)
    XCTAssertEqual(board.zoom, 0.25)
    board.setZoom(.nan)
    XCTAssertEqual(board.zoom, 0.25)
  }

  func testSelectionIsIndependentOfKeyboardFocusAndTabSwitch() throws {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = board.addConsole(agent: .shell)
    let second = board.addConsole(agent: .codex)
    board.select(first, extending: true)
    XCTAssertEqual(board.selectedNodeIDs, [first, second])
    board.focus(first)
    XCTAssertEqual(board.focusedNodeID, first)
    XCTAssertEqual(board.selectedNodeIDs, [first, second])
    let original = try XCTUnwrap(board.workspace?.id)
    let other = board.createWorkspace(name: "Other")
    XCTAssertEqual(board.workspace?.id, other)
    XCTAssertNil(board.focusedNodeID)
    XCTAssertTrue(board.selectedNodeIDs.isEmpty)
    board.switchWorkspace(original)
    XCTAssertEqual(board.workspace?.nodes.count, 2)
  }

  func testWorkspacePersistenceAndNotStartedRestore() throws {
    let (board, store, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try XCTUnwrap(board.workspace?.id)
    let node = board.addConsole(agent: .claude)
    board.moveNode(node, x: 140, y: -80)
    board.resizeNode(node, width: 640, height: 400)
    board.renameWorkspace(original, name: "Project")
    let other = board.createWorkspace(name: "Second")
    _ = board.addConsole(agent: .opencode)
    try board.saveNow()
    let restored = BoardViewModel(store: store, usageTracker: usageTracker(root), settings: settings(root))
    XCTAssertEqual(restored.workspaces.count, 2)
    restored.switchWorkspace(original)
    XCTAssertEqual(restored.workspace?.name, "Project")
    XCTAssertEqual(
      restored.workspace?.nodes.first?.frame, NodeFrame(x: 140, y: -80, w: 640, h: 400))
    XCTAssertEqual(restored.workspace?.nodes.first?.notStarted, true)
    XCTAssertTrue(restored.sessions.isEmpty)
    restored.switchWorkspace(other)
    XCTAssertEqual(restored.workspace?.nodes.first?.agentID, "opencode")
  }

  func testQuitSaveRestoresConsoleLayoutAndStartsInTheSavedDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let workspaces = root.appendingPathComponent("workspaces", isDirectory: true)
    let shellDir = root.appendingPathComponent("layout-shell", isDirectory: true)
    let otherDir = root.appendingPathComponent("layout-other", isDirectory: true)
    try FileManager.default.createDirectory(at: shellDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(rootURL: workspaces)
    let environment = [
      "HOME": root.path, "ZDOTDIR": root.path, "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]
    let board = BoardViewModel(
      store: store, autosaveDelay: .seconds(60), processEnvironment: environment,
      usageTracker: usageTracker(root), settings: settings(root))
    let shell = board.addConsole(agent: .shell, cwd: shellDir)
    board.moveNode(shell, x: 48, y: 36)
    board.resizeNode(shell, width: 520, height: 280)
    let other = board.addConsole(agent: .shell, cwd: otherDir)
    board.moveNode(other, x: 600, y: 96)
    board.resizeNode(other, width: 360, height: 200)
    await board.startConsole(shell)
    XCTAssertEqual(board.sessions[shell]?.isRunning, true)
    XCTAssertEqual(board.workspace?.nodes.first { $0.id == shell }?.notStarted, false)
    try board.saveNow()
    let saved = try String(contentsOf: workspaces.appendingPathComponent("\(board.workspace!.id.uuidString).json"), encoding: .utf8)
    XCTAssertTrue(saved.contains("\"notStarted\":false"))
    let loaded = try store.load(id: try XCTUnwrap(board.workspace?.id))
    XCTAssertEqual(loaded.nodes.first { $0.id == shell }?.notStarted, true)
    XCTAssertEqual(loaded.nodes.first { $0.id == shell }?.frame, NodeFrame(x: 48, y: 36, w: 520, h: 280))
    await board.shutdown()

    let restored = BoardViewModel(
      store: store, autosaveDelay: .seconds(60), processEnvironment: environment,
      usageTracker: usageTracker(root), settings: settings(root))
    XCTAssertTrue(restored.sessions.isEmpty)
    let shellNode = try XCTUnwrap(restored.workspace?.nodes.first { $0.id == shell })
    let otherNode = try XCTUnwrap(restored.workspace?.nodes.first { $0.id == other })
    XCTAssertEqual(shellNode.frame, NodeFrame(x: 48, y: 36, w: 520, h: 280))
    XCTAssertEqual(otherNode.frame, NodeFrame(x: 600, y: 96, w: 360, h: 200))
    XCTAssertEqual(shellNode.cwd.standardizedFileURL.path, shellDir.standardizedFileURL.path)
    XCTAssertEqual(otherNode.cwd.standardizedFileURL.path, otherDir.standardizedFileURL.path)
    XCTAssertEqual(shellNode.agentID, "shell")
    XCTAssertTrue(shellNode.notStarted)
    XCTAssertTrue(otherNode.notStarted)
    await restored.startConsole(shell)
    XCTAssertEqual(restored.sessions[shell]?.launchedWorkingDirectory, shellDir.standardizedFileURL.path)
    XCTAssertNil(restored.sessions[other])
    XCTAssertTrue(restored.writeToConsole("pwd\r", nodeID: shell))
    let wanted = shellDir.resolvingSymlinksInPath().path
    let deadline = ContinuousClock.now + .seconds(8)
    var sawDirectory = false
    while ContinuousClock.now < deadline {
      let text = restored.recentConsoleOutput(shell, maxBytes: 8_000) ?? ""
      if text.contains(wanted) || text.contains(shellDir.standardizedFileURL.path) {
        sawDirectory = true
        break
      }
      try await Task.sleep(for: .milliseconds(40))
    }
    XCTAssertTrue(sawDirectory, "Restored shell did not print its saved directory")
    await restored.shutdown()
  }

  func testLiveRelaunchRestoresPositionsSizesAndDirectoriesWithoutStarting() async {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let shellDir = home.appendingPathComponent("layout-shell", isDirectory: true)
    let otherDir = home.appendingPathComponent("layout-other", isDirectory: true)
    try? FileManager.default.createDirectory(at: shellDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let board = BoardViewModel.live(homeDirectory: home)
    let shell = board.addConsole(agent: .shell, cwd: shellDir)
    board.moveNode(shell, x: 40, y: 48)
    board.resizeNode(shell, width: 520, height: 280)
    let other = board.addConsole(agent: .codex, cwd: otherDir)
    board.moveNode(other, x: 40, y: 360)
    board.resizeNode(other, width: 440, height: 220)
    let workspaceID = board.activeWorkspaceID
    try? board.saveNow()
    await board.shutdown()

    let restored = BoardViewModel.live(homeDirectory: home)
    XCTAssertEqual(restored.activeWorkspaceID, workspaceID)
    XCTAssertTrue(restored.sessions.isEmpty)
    let shellNode = restored.workspace?.nodes.first { $0.id == shell }
    let otherNode = restored.workspace?.nodes.first { $0.id == other }
    XCTAssertEqual(shellNode?.frame, NodeFrame(x: 40, y: 48, w: 520, h: 280))
    XCTAssertEqual(otherNode?.frame, NodeFrame(x: 40, y: 360, w: 440, h: 220))
    XCTAssertEqual(shellNode?.cwd.standardizedFileURL.path, shellDir.standardizedFileURL.path)
    XCTAssertEqual(otherNode?.cwd.standardizedFileURL.path, otherDir.standardizedFileURL.path)
    XCTAssertEqual(shellNode?.agentID, "shell")
    XCTAssertEqual(otherNode?.agentID, "codex")
    XCTAssertEqual(shellNode?.notStarted, true)
    XCTAssertEqual(otherNode?.notStarted, true)
    await restored.shutdown()
  }

  func testBoardViewRetainsPanelModelsAcrossUnrelatedBoardChanges() throws {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let view = BoardView(model: board)
    let initialPanelState = Mirror(reflecting: view).children.first { $0.label == "_docsPanelModel" }?.value
    XCTAssertNotNil(initialPanelState)
    board.addConsole(agent: .shell)
    let currentPanelState = Mirror(reflecting: view).children.first { $0.label == "_docsPanelModel" }?.value
    XCTAssertEqual(String(reflecting: initialPanelState), String(reflecting: currentPanelState))
  }

  func testCreateGroupRefusesAnEmptySelection() throws {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = board.addConsole(agent: .shell)
    XCTAssertTrue(board.canCreateGroup)
    board.select(nil)
    XCTAssertFalse(board.canCreateGroup)
    XCTAssertNil(board.createGroup(name: "Nobody"))
    XCTAssertNil(board.createGroup(name: "Nobody", nodeIDs: []))
    XCTAssertTrue(board.workspace?.groups.isEmpty == true)
    board.select(id)
    XCTAssertNotNil(board.createGroup(name: "Lane"))
  }

  func testMarkedFieldCommitReachesTheHandlerWithoutTouchingATextField() {
    var received: String?
    MarkedFieldRegistry.register(identifier: "groups.message") { received = $0 }
    XCTAssertTrue(MarkedFieldRegistry.hasCommit("groups.message"))
    XCTAssertTrue(MarkedFieldRegistry.commit(identifier: "groups.message", text: "echo lanebay-crew-ok"))
    XCTAssertEqual(received, "echo lanebay-crew-ok")
    MarkedFieldRegistry.unregister(identifier: "groups.message")
    XCTAssertFalse(MarkedFieldRegistry.hasCommit("groups.message"))
    XCTAssertFalse(MarkedFieldRegistry.commit(identifier: "groups.message", text: "later"))
  }

  func testLeadMarkAndStatusDotSitAboveTheCard() {
    let frame = NodeFrame(x: 40, y: 80, w: 480, h: 320)
    let card = GroupMapLayout.cardRect(frame, zoom: 1, panX: 0, panY: 0)
    let badge = GroupMapLayout.leadBadge(frame: frame, zoom: 1, panX: 0, panY: 0)
    let dot = GroupMapLayout.statusDot(frame: frame, zoom: 1, panX: 0, panY: 0)
    let caption = GroupMapLayout.statusCaption(frame: frame, zoom: 1, panX: 0, panY: 0)
    let band = GroupMapLayout.groupBounds(frames: [frame], zoom: 1, panX: 0, panY: 0)
    XCTAssertFalse(badge.intersects(card))
    XCTAssertFalse(dot.intersects(card))
    XCTAssertFalse(caption.intersects(card))
    XCTAssertTrue(band.contains(badge))
    XCTAssertTrue(band.contains(dot))
    XCTAssertTrue(band.contains(caption))
    XCTAssertFalse(badge.intersects(dot))
    XCTAssertFalse(badge.intersects(caption))
  }

  func testGroupsManageMembershipAndPersistWithWorkspace() throws {
    let (board, store, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = board.addConsole(agent: .shell)
    let second = board.addConsole(agent: .codex)
    let third = board.addConsole(agent: .claude)
    let groupID = try XCTUnwrap(board.createGroup(name: "Build team", nodeIDs: [first, second, UUID()]))
    XCTAssertEqual(Set(board.workspace?.groups.first?.nodeIDs ?? []), [first, second])
    board.renameGroup(groupID, name: "Release team")
    board.setGroupMembers(groupID, nodeIDs: [second, third])
    try board.saveNow()
    let restored = try store.load(id: try XCTUnwrap(board.workspace?.id))
    XCTAssertEqual(restored.groups.first?.name, "Release team")
    XCTAssertEqual(Set(restored.groups.first?.nodeIDs ?? []), [second, third])
    board.deleteGroup(groupID)
    XCTAssertTrue(board.workspace?.groups.isEmpty == true)
  }

  func testLeadSelectionClearsWhenRemovedAndPersists() async throws {
    let (board, store, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let leader = board.addConsole(agent: .claude)
    let member = board.addConsole(agent: .shell)
    let group = try XCTUnwrap(board.createGroup(name: "Team", nodeIDs: [leader, member]))
    board.setGroupLead(group, nodeID: leader)
    XCTAssertEqual(board.workspace?.groups.first?.leadNodeID, leader)
    board.setGroupMembers(group, nodeIDs: [member])
    XCTAssertNil(board.workspace?.groups.first?.leadNodeID)
    board.setGroupMembers(group, nodeIDs: [leader, member])
    board.setGroupLead(group, nodeID: leader)
    try board.saveNow()
    XCTAssertEqual(try store.load(id: try XCTUnwrap(board.workspace?.id)).groups.first?.leadNodeID, leader)
    await board.closeConsole(leader)
    XCTAssertNil(board.workspace?.groups.first?.leadNodeID)
  }

  func testLeadAndGroupDispatchRequireActiveIdleRunningConsoles() throws {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let leader = board.addConsole(agent: .claude)
    let member = board.addConsole(agent: .shell)
    let groupID = try XCTUnwrap(board.createGroup(name: "Team", nodeIDs: [leader, member]))
    board.setGroupLead(groupID, nodeID: leader)
    let leaderSession = ConsoleSession(supervisor: ProcessSupervisor())
    leaderSession.setRunningForTesting(true); leaderSession.setStatus(.idle)
    let memberSession = ConsoleSession(supervisor: ProcessSupervisor())
    memberSession.setRunningForTesting(true); memberSession.setStatus(.idle)
    board.installSessionForTesting(leaderSession, id: leader)
    board.installSessionForTesting(memberSession, id: member)
    XCTAssertTrue(board.sendToLead("task", groupID: groupID))
    XCTAssertTrue(board.broadcastToGroup("task", groupID: groupID))
    memberSession.setStatus(.running)
    leaderSession.setStatus(.running)
    XCTAssertFalse(board.broadcastToGroup("task", groupID: groupID))
    XCTAssertFalse(board.sendToLead("task", groupID: groupID))
    leaderSession.setStatus(.idle)
    leaderSession.setRunningForTesting(false)
    XCTAssertFalse(board.sendToLead("task", groupID: groupID))
    leaderSession.setRunningForTesting(true); leaderSession.setStatus(.idle)
    let otherWorkspace = board.createWorkspace(name: "Other")
    XCTAssertFalse(board.sendToLead("task", groupID: groupID), "Groups in hidden workspaces cannot receive dispatch")
    board.switchWorkspace(try XCTUnwrap(board.workspaces.first(where: { $0.groups.contains(where: { $0.id == groupID }) })?.id))
    XCTAssertTrue(board.sendToLead("task", groupID: groupID))
    XCTAssertEqual(board.activeWorkspaceID, try XCTUnwrap(board.workspace?.id))
    _ = otherWorkspace
  }

  func testBroadcastRejectsClosedAndShutdownSessions() async throws {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = board.addConsole(agent: .shell)
    let session = ConsoleSession(supervisor: ProcessSupervisor())
    session.setRunningForTesting(true); session.setStatus(.idle)
    board.installSessionForTesting(session, id: target)
    await session.close()
    session.setRunningForTesting(true)
    XCTAssertFalse(board.broadcastToIdle("no"), "Closed sessions are never recipients")
    let live = ConsoleSession(supervisor: ProcessSupervisor())
    live.setRunningForTesting(true); live.setStatus(.idle)
    board.installSessionForTesting(live, id: target)
    board.setShuttingDownForTesting(true)
    XCTAssertFalse(board.broadcastToIdle("no"), "Shutdown rejects dispatch before session teardown")
  }

  func testSendPresetAndSendToConsoleDeliverToLiveSessionAndExcludeInvalidRecipients() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let supervisor = ProcessSupervisor()
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root), supervisor: supervisor,
      processEnvironment: ["HOME": root.path, "SHELL": "/bin/sh"], usageTracker: usageTracker(root), settings: settings(root))
    let target = board.addConsole(agent: .shell, cwd: root)
    await board.startConsole(target)
    let session = try XCTUnwrap(board.sessions[target])
    let sessionID = try XCTUnwrap(session.sessionID)
    let deadline = ContinuousClock.now + .seconds(5)
    session.setStatus(.idle)
    XCTAssertTrue(board.sendToConsole("printf 'DIRECT_OK\\n'", nodeID: target))
    var directDelivered = false
    while ContinuousClock.now < deadline {
      if String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self).contains("DIRECT_OK") {
        directDelivered = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(directDelivered, "sendToConsole should write bytes to the live PTY")
    session.setStatus(.idle)
    XCTAssertTrue(board.sendPreset("printf 'PRESET_OK\\n'", targetAgentKind: "shell"))
    var presetDelivered = false
    while ContinuousClock.now < deadline {
      if String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self).contains("PRESET_OK") {
        presetDelivered = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(presetDelivered, "sendPreset should route to idle shell recipients")
    XCTAssertFalse(board.sendPreset("echo no", targetAgentKind: "claude"), "Agent-kind filtering excludes unmatched recipients")
    session.setStatus(.running)
    XCTAssertFalse(board.sendToConsole("echo no", nodeID: target), "Busy recipients are excluded")
    session.setStatus(.idle)
    session.setRunningForTesting(false)
    XCTAssertFalse(board.sendToConsole("echo no", nodeID: target), "Stopped recipients are excluded")
    session.setRunningForTesting(true)
    _ = board.createWorkspace(name: "Other")
    XCTAssertFalse(board.sendToConsole("echo no", nodeID: target), "Inactive workspace recipients are excluded")
    board.switchWorkspace(try XCTUnwrap(board.workspaces.first(where: { $0.nodes.contains(where: { $0.id == target }) })?.id))
    board.setShuttingDownForTesting(true)
    XCTAssertFalse(board.sendToConsole("echo no", nodeID: target), "Shutdown excludes recipients")
    XCTAssertFalse(board.sendPreset("echo no", targetAgentKind: "shell"), "Shutdown also blocks preset dispatch")
    board.setShuttingDownForTesting(false)
    await session.close()
    session.setRunningForTesting(true)
    XCTAssertFalse(board.sendToConsole("echo no", nodeID: target), "Closed recipients are excluded")
    await board.shutdown()
  }

  func testDebouncedAutosaveIncludesEditsAcrossTabs() async throws {
    let (_, store, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let board = BoardViewModel(store: store, autosaveDelay: .milliseconds(20), usageTracker: usageTracker(root), settings: settings(root))
    let first = try XCTUnwrap(board.workspace?.id)
    let node = board.addConsole(agent: .shell)
    board.moveNode(node, x: 50, y: 60)
    let second = board.createWorkspace(name: "Next")
    board.renameWorkspace(second, name: "Renamed")
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
      if let saved = try? store.list(), saved.count == 2,
        saved.first(where: { $0.id == second })?.name == "Renamed"
      {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(try store.load(id: first).nodes.first?.frame.x, 50)
    XCTAssertEqual(try store.load(id: second).name, "Renamed")
  }

  func testLiveSessionSurvivesTabSwitchAndCloseTerminatesProcess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let supervisor = ProcessSupervisor()
    let startup = root.appendingPathComponent("zsh", isDirectory: true)
    try FileManager.default.createDirectory(at: startup, withIntermediateDirectories: true)
    try Data().write(to: startup.appendingPathComponent(".zshenv"))
    try Data().write(to: startup.appendingPathComponent(".zprofile"))
    try Data("PROMPT='LANEBAY_READY> '\n".utf8).write(to: startup.appendingPathComponent(".zshrc"))
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root), supervisor: supervisor,
      processEnvironment: ["ZDOTDIR": startup.path, "HOME": root.path], usageTracker: usageTracker(root), settings: settings(root))
    let original = try XCTUnwrap(board.workspace?.id)
    let id = board.addConsole(agent: .shell, cwd: root)
    await board.startConsole(id)
    let console = try XCTUnwrap(board.sessions[id])
    let sessionID = try XCTUnwrap(console.sessionID)
    addTeardownBlock {
      await board.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    let startupDeadline = ContinuousClock.now + .seconds(15)
    var shellReady = false
    while ContinuousClock.now < startupDeadline {
      let output = String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self)
      if output.contains("LANEBAY_READY>") { shellReady = true; break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(shellReady, "Isolated login shell did not emit its readiness prompt")
    guard shellReady else { return }
    board.sendCommand("printf 'BOARD_%s:%s\\n' READY $$; exec /bin/sleep 30")
    var processID: pid_t?
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      let text = String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self)
      if let range = text.range(of: "BOARD_READY:") {
        processID = pid_t(text[range.upperBound...].prefix(while: { $0.isNumber }))
        if processID != nil { break }
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let pid = try XCTUnwrap(processID, "Shell did not reach the readiness marker")
    _ = board.createWorkspace(name: "Another")
    XCTAssertTrue(board.sessions[id] === console)
    board.switchWorkspace(original)
    XCTAssertEqual(board.workspace?.nodes.first?.notStarted, false)
    await board.startConsole(id)
    XCTAssertEqual(
      board.sessions[id]?.sessionID, sessionID, "Repeated start must not launch another child")
    await board.closeConsole(id)
    XCTAssertTrue(console.hasFinished)
    XCTAssertNil(board.sessions[id])
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
    do {
      _ = try await supervisor.scrollback(for: sessionID)
      XCTFail("Closing a console must discard completed history")
    } catch let error as ProcessSupervisorError {
      guard case .sessionNotFound = error else { throw error }
    }
  }

  func testRestartRespawnsTheShellAndCloseKillsTheReplacement() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let supervisor = ProcessSupervisor()
    let startup = root.appendingPathComponent("zsh", isDirectory: true)
    try FileManager.default.createDirectory(at: startup, withIntermediateDirectories: true)
    try Data().write(to: startup.appendingPathComponent(".zshenv"))
    try Data().write(to: startup.appendingPathComponent(".zprofile"))
    try Data("PROMPT='LANEBAY_READY> '\n".utf8).write(to: startup.appendingPathComponent(".zshrc"))
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root), supervisor: supervisor,
      processEnvironment: ["ZDOTDIR": startup.path, "HOME": root.path, "SHELL": "/bin/zsh"],
      usageTracker: usageTracker(root), settings: settings(root))
    let id = board.addConsole(agent: .shell, cwd: root)
    let groupID = try XCTUnwrap(board.createGroup(name: "Lane", nodeIDs: [id]))
    board.setGroupLead(groupID, nodeID: id)
    addTeardownBlock {
      await board.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    await board.restartConsole(id)
    let first = try XCTUnwrap(board.sessions[id])
    let firstSession = try XCTUnwrap(first.sessionID)
    let ready = try await waitForScrollback("LANEBAY_READY>", sessionID: firstSession, supervisor: supervisor)
    XCTAssertTrue(ready.contains("LANEBAY_READY>"))
    XCTAssertTrue(board.writeToConsole("printf 'LANEBAY-PID:%s\\n' $$\r", nodeID: id))
    let firstPIDValue = await waitForShellPID(sessionID: firstSession, supervisor: supervisor)
    let firstPID = try XCTUnwrap(firstPIDValue, "Shell did not print its process id")
    await board.restartConsole(id)
    let replacement = try XCTUnwrap(board.sessions[id])
    let replacementSession = try XCTUnwrap(replacement.sessionID)
    XCTAssertNotEqual(replacementSession, firstSession)
    XCTAssertFalse(replacement === first)
    XCTAssertEqual(kill(firstPID, 0), -1)
    XCTAssertEqual(errno, ESRCH)
    XCTAssertEqual(board.workspace?.nodes.contains { $0.id == id }, true)
    XCTAssertEqual(board.workspace?.nodes.first { $0.id == id }?.notStarted, false)
    XCTAssertEqual(board.workspace?.groups.first { $0.id == groupID }?.nodeIDs, [id])
    XCTAssertEqual(board.workspace?.groups.first { $0.id == groupID }?.leadNodeID, id)
    let restarted = try await waitForScrollback("LANEBAY_READY>", sessionID: replacementSession, supervisor: supervisor)
    XCTAssertTrue(restarted.contains("LANEBAY_READY>"))
    XCTAssertTrue(
      board.writeToConsole("printf 'LANEBAY-PID:%s\\nLANEBAY-RESTART:%s\\n' $$ ok\r", nodeID: id))
    let secondOutput = try await waitForScrollback("LANEBAY-RESTART:ok", sessionID: replacementSession, supervisor: supervisor)
    let secondPIDValue = await waitForShellPID(sessionID: replacementSession, supervisor: supervisor)
    let secondPID = try XCTUnwrap(secondPIDValue)
    XCTAssertNotEqual(secondPID, firstPID)
    XCTAssertTrue(secondOutput.contains("LANEBAY-RESTART:ok"))
    await board.closeConsole(id)
    XCTAssertFalse(board.workspace?.nodes.contains { $0.id == id } == true)
    XCTAssertNil(board.sessions[id])
    XCTAssertEqual(board.workspace?.groups.first { $0.id == groupID }?.nodeIDs, [])
    XCTAssertNil(board.workspace?.groups.first { $0.id == groupID }?.leadNodeID)
    XCTAssertEqual(kill(secondPID, 0), -1)
    XCTAssertEqual(errno, ESRCH)
    do {
      _ = try await supervisor.scrollback(for: replacementSession)
      XCTFail("Closing a restarted console must discard its history")
    } catch let error as ProcessSupervisorError {
      guard case .sessionNotFound = error else { throw error }
    }
  }

  func testShutdownWaitsForLaunchAndConcurrentClose() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let board = BoardViewModel(store: WorkspaceStore(rootURL: root), usageTracker: usageTracker(root), settings: settings(root))
    let launchingID = board.addConsole(agent: .shell, cwd: root)
    let launch = Task { await board.startConsole(launchingID) }
    let deadline = ContinuousClock.now + .seconds(2)
    while board.sessions[launchingID] == nil, ContinuousClock.now < deadline { await Task.yield() }
    let launching = try XCTUnwrap(board.sessions[launchingID])
    let close = Task { await board.closeConsole(launchingID) }
    while board.workspace?.nodes.contains(where: { $0.id == launchingID }) == true,
      ContinuousClock.now < deadline
    { await Task.yield() }
    await board.shutdown()
    XCTAssertTrue(launching.hasFinished, "Shutdown must join pending launch and close operations")
    XCTAssertTrue(board.sessions.isEmpty)
    await launch.value
    await close.value
  }

  func testSaveFailureIsReportedAndCanBeRetried() throws {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
    try FileManager.default.removeItem(at: workspacesRoot)
    try Data("blocked".utf8).write(to: workspacesRoot)
    _ = board.addConsole(agent: .shell)
    XCTAssertThrowsError(try board.saveNow())
    XCTAssertNotNil(board.errorMessage)
    try FileManager.default.removeItem(at: workspacesRoot)
    try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
    try board.saveNow()
    XCTAssertNil(board.errorMessage)
  }
}

extension BoardViewModelTests {
  func testRestoredScheduledLoopsReconcileOnWorkspaceActivation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(rootURL: root)
    let firstTarget = UUID(), secondTarget = UUID()
    let firstLoop = Loop(targetNodeID: firstTarget, prompt: "tick", trigger: .schedule(intervalSeconds: 1), maxIterations: 1)
    let secondLoop = Loop(targetNodeID: secondTarget, prompt: "tick", trigger: .schedule(intervalSeconds: 1), maxIterations: 1)
    let missingTargetLoop = Loop(targetNodeID: UUID(), prompt: "tick", trigger: .schedule(intervalSeconds: 1))
    let first = Workspace(name: "First", nodes: [Node(id: firstTarget, kind: .console, cwd: root, frame: NodeFrame(x: 0, y: 0, w: 400, h: 300), title: "first")], loops: [firstLoop], createdAt: Date(timeIntervalSince1970: 1))
    let second = Workspace(name: "Second", nodes: [Node(id: secondTarget, kind: .console, cwd: root, frame: NodeFrame(x: 0, y: 0, w: 400, h: 300), title: "second")], loops: [secondLoop, missingTargetLoop], createdAt: Date(timeIntervalSince1970: 2))
    try store.save(first); try store.save(second)
    let board = BoardViewModel(store: store, usageTracker: usageTracker(root), settings: settings(root), sleep: { _ in
      while !Task.isCancelled { await Task.yield() }
    })
    XCTAssertEqual(board.workspace?.id, first.id)
    XCTAssertEqual(board.activeLoopTimerIDs, [firstLoop.id])
    let firstSession = ConsoleSession(supervisor: ProcessSupervisor())
    firstSession.setRunningForTesting(true)
    firstSession.setStatus(.idle)
    board.installSessionForTesting(firstSession, id: firstTarget)
    board.switchWorkspace(second.id)
    XCTAssertEqual(board.activeLoopTimerIDs, [secondLoop.id])
    XCTAssertEqual(board.workspace?.id, second.id)
    board.fireLoop(firstLoop.id)
    XCTAssertEqual(board.workspaces.first(where: { $0.id == first.id })?.loops.first?.iterations, 0, "Hidden-workspace dispatch remains blocked even with a running, idle target")
    XCTAssertEqual(firstSession.status, .idle)
    board.switchWorkspace(first.id)
    XCTAssertEqual(board.activeLoopTimerIDs, [firstLoop.id], "Reactivation restarts the original workspace timer")
    await board.shutdown()
  }

  func testPendingOutputMatchIsConsumedWhenWorkspaceBecomesActiveAgain() async throws {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = board.addConsole(agent: .shell, cwd: root)
    let loopID = try XCTUnwrap(board.createLoop(targetNodeID: target, prompt: "continue", trigger: .outputMatch(pattern: "READY")))
    let session = ConsoleSession(supervisor: ProcessSupervisor())
    session.setRunningForTesting(true)
    board.installSessionForTesting(session, id: target)
    board.handleLoopOutput("READY", target: target)
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == loopID })?.iterations, 0)
    try await Task.sleep(for: .milliseconds(20)) // Let the off-main matcher record the pending match.
    let originalWorkspace = try XCTUnwrap(board.activeWorkspaceID)
    let hiddenWorkspace = board.createWorkspace(name: "Hidden")
    session.setStatus(.idle)
    board.switchWorkspace(originalWorkspace)
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == loopID })?.iterations, 1)
    board.switchWorkspace(hiddenWorkspace)
    await board.shutdown()
  }

  func testOutputMatchArrivingAcrossImmediateWorkspaceSwitchIsRetainedForOwner() async throws {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = board.addConsole(agent: .shell, cwd: root)
    let loopID = try XCTUnwrap(board.createLoop(targetNodeID: target, prompt: "continue", trigger: .outputMatch(pattern: "READY")))
    let session = ConsoleSession(supervisor: ProcessSupervisor())
    session.setRunningForTesting(true)
    board.installSessionForTesting(session, id: target)
    let owner = try XCTUnwrap(board.activeWorkspaceID)
    board.handleLoopOutput("READY", target: target, workspaceID: owner)
    _ = board.createWorkspace(name: "Switched immediately")
    session.setStatus(.idle)
    await Task.yield()
    board.switchWorkspace(owner)
    let deadline = ContinuousClock.now + .seconds(2)
    while board.workspace?.loops.first(where: { $0.id == loopID })?.iterations != 1 && ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == loopID })?.iterations, 1)
    await board.shutdown()
  }

  func testClosingConsolePreservesPendingMatchesInHiddenWorkspace() async throws {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = board.addConsole(agent: .shell)
    let loopID = try XCTUnwrap(board.createLoop(targetNodeID: target, prompt: "continue", trigger: .outputMatch(pattern: "READY")))
    let session = ConsoleSession(supervisor: ProcessSupervisor())
    session.setRunningForTesting(true)
    board.installSessionForTesting(session, id: target)
    board.handleLoopOutput("READY", target: target)
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == loopID })?.iterations, 0)
    try await Task.sleep(for: .milliseconds(20))
    let originalWorkspace = try XCTUnwrap(board.activeWorkspaceID)
    let otherWorkspace = board.createWorkspace(name: "Other")
    let unrelated = board.addConsole(agent: .shell)
    await board.closeConsole(unrelated)
    session.setStatus(.idle)
    board.switchWorkspace(originalWorkspace)
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == loopID })?.iterations, 1)
    board.switchWorkspace(otherWorkspace)
    await board.shutdown()
  }

  func testOutputMatchDispatchesOncePerNewMarkerAndProductionSessionIsReleased() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let supervisor = ProcessSupervisor()
    let board = BoardViewModel(store: WorkspaceStore(rootURL: root), supervisor: supervisor, autosaveDelay: .seconds(60), processEnvironment: ["HOME": root.path, "ZDOTDIR": root.path], usageTracker: usageTracker(root), settings: settings(root))
    let target = board.addConsole(agent: .shell, cwd: root)
    let id = try XCTUnwrap(board.createLoop(targetNodeID: target, prompt: "printf 'DELIVERED\\n'", trigger: .outputMatch(pattern: "READY"), maxIterations: 3))
    await board.startConsole(target)
    var console: ConsoleSession? = board.sessions[target]
    weak var weakConsole: ConsoleSession?
    weakConsole = console
    let sessionID = try XCTUnwrap(console?.sessionID)
    console?.send(Data("printf 'READY\\n'\r".utf8))
    let outputDeadline = ContinuousClock.now + .seconds(5)
    var sawReady = false
    while ContinuousClock.now < outputDeadline {
      let data = try await supervisor.scrollback(for: sessionID)
      if String(decoding: data, as: UTF8.self).contains("READY") { sawReady = true; break }
      await Task.yield()
    }
    XCTAssertTrue(sawReady, "Trigger command produced output in the PTY")
    // The actual output callback has observed READY. It was produced while the shell
    // was busy, so dispatch waits for the status transition to idle.
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == id })?.iterations, 0)
    try await Task.sleep(for: .milliseconds(20))
    console?.setStatus(.idle)
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == id })?.iterations, 1)
    let deliveryDeadline = ContinuousClock.now + .seconds(5)
    var delivered = false
    while ContinuousClock.now < deliveryDeadline {
      let data = try await supervisor.scrollback(for: sessionID)
      if String(decoding: data, as: UTF8.self).contains("DELIVERED") { delivered = true; break }
      await Task.yield()
    }
    XCTAssertTrue(delivered, "Loop prompt bytes reached the live PTY")
    board.handleLoopOutput(" unrelated output", target: target)
    await Task.yield()
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == id })?.iterations, 1, "Retained READY context does not dispatch again")
    board.stopLoop(id)
    console?.setStatus(.running)
    let shutdownLoop = try XCTUnwrap(board.createLoop(targetNodeID: target, prompt: "late", trigger: .idle))
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == shutdownLoop })?.iterations, 0, "A working console does not take an idle loop at creation")
    await board.shutdown()
    board.fireLoop(shutdownLoop)
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == shutdownLoop })?.iterations, 0, "Shutdown rejects pending loop dispatch")
    await board.closeConsole(target)
    console = nil
    XCTAssertNil(weakConsole, "Closing a console detaches its callbacks and releases the session")
  }

  func testGroupBroadcastDeliversToLivePTY() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let supervisor = ProcessSupervisor()
    try Data("printf 'LANEBAY_READY\\n'\n".utf8).write(to: root.appendingPathComponent(".profile"))
    let board = BoardViewModel(store: WorkspaceStore(rootURL: root), supervisor: supervisor, processEnvironment: ["HOME": root.path, "SHELL": "/bin/sh"], usageTracker: usageTracker(root), settings: settings(root))
    let target = board.addConsole(agent: .shell, cwd: root)
    let group = try XCTUnwrap(board.createGroup(name: "Team", nodeIDs: [target]))
    await board.startConsole(target)
    let session = try XCTUnwrap(board.sessions[target])
    let sessionID = try XCTUnwrap(session.sessionID)
    addTeardownBlock { await board.shutdown(); try? FileManager.default.removeItem(at: root) }
    let deadline = ContinuousClock.now + .seconds(5)
    var ready = false
    while ContinuousClock.now < deadline {
      if String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self).contains("LANEBAY_READY") { ready = true; break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(ready)
    session.setStatus(.idle)
    XCTAssertTrue(board.broadcastToGroup("printf 'GROUP_DELIVERED\\n'", groupID: group))
    var delivered = false
    while ContinuousClock.now < deadline {
      if String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self).contains("GROUP_DELIVERED") { delivered = true; break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(delivered, "Broadcast bytes reached the live PTY")
    await board.shutdown()
  }

  func testGoalCheckUsesDeterministicMarkerAndStopsWhenSatisfied() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let board = BoardViewModel(store: WorkspaceStore(rootURL: root), usageTracker: usageTracker(root), settings: settings(root), sleep: { _ in await Task.yield() })
    let target = board.addConsole(agent: .shell)
    let loopID = try XCTUnwrap(board.createLoop(targetNodeID: target, prompt: "continue", trigger: .goalCheck(intervalSeconds: 30, goal: "DONE"), maxIterations: 3))
    board.handleLoopOutput("DONE", target: target)
    let deadline = ContinuousClock.now + .seconds(2)
    while board.activeLoopTimerIDs.contains(loopID) && ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == loopID })?.iterations, 0)
    XCTAssertFalse(board.activeLoopTimerIDs.contains(loopID), "A satisfied goal cancels its timer")
    XCTAssertFalse(try XCTUnwrap(board.workspace?.loops.first(where: { $0.id == loopID })).isEnabled)
    await board.shutdown()
  }

  func testIdleLoopFiresAtCreationOnlyWhenTheTargetIsAlreadyIdle() throws {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let busy = board.addConsole(agent: .shell, cwd: root)
    let busySession = ConsoleSession(supervisor: ProcessSupervisor())
    busySession.setRunningForTesting(true)
    board.installSessionForTesting(busySession, id: busy)
    let waiting = try XCTUnwrap(board.createLoop(targetNodeID: busy, prompt: "later", trigger: .idle, maxIterations: 3))
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == waiting })?.iterations, 0)
    XCTAssertTrue(try XCTUnwrap(board.workspace?.loops.first(where: { $0.id == waiting })).isEnabled)

    let idleConsole = board.addConsole(agent: .shell, cwd: root)
    let idleSession = ConsoleSession(supervisor: ProcessSupervisor())
    idleSession.setRunningForTesting(true)
    idleSession.setStatus(.idle)
    board.installSessionForTesting(idleSession, id: idleConsole)
    let fired = try XCTUnwrap(board.createLoop(targetNodeID: idleConsole, prompt: "now", trigger: .idle, maxIterations: 1))
    let loop = try XCTUnwrap(board.workspace?.loops.first(where: { $0.id == fired }))
    XCTAssertEqual(loop.iterations, 1)
    XCTAssertFalse(loop.isEnabled)
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == waiting })?.iterations, 0)
  }

  func testIdleLoopReachesAnIdleShellOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let supervisor = ProcessSupervisor()
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root.appendingPathComponent("workspaces", isDirectory: true)),
      supervisor: supervisor,
      processEnvironment: ["HOME": root.path, "ZDOTDIR": root.path, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
      usageTracker: usageTracker(root),
      settings: settings(root)
    )
    let target = board.addConsole(agent: .shell, cwd: root)
    await board.startConsole(target)
    let session = try XCTUnwrap(board.sessions[target])
    let sessionID = try XCTUnwrap(session.sessionID)
    addTeardownBlock { await board.shutdown() }
    XCTAssertTrue(board.writeToConsole("printf 'SHELL_READY\\n'\r", nodeID: target))
    let ready = try await waitForScrollback("SHELL_READY", sessionID: sessionID, supervisor: supervisor)
    XCTAssertTrue(ready.contains("SHELL_READY"))
    if session.status != .idle { session.setStatus(.idle) }
    XCTAssertTrue(board.idleConsoleIDs.contains(target))
    let id = try XCTUnwrap(board.createLoop(
      targetNodeID: target, prompt: "printf 'LANEBAY_LOOP_OK\\n'", trigger: .idle, maxIterations: 1))
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == id })?.iterations, 1)
    let delivered = try await waitForScrollback("LANEBAY_LOOP_OK", sessionID: sessionID, supervisor: supervisor)
    XCTAssertTrue(delivered.contains("LANEBAY_LOOP_OK"), "Idle loop bytes reached the live PTY")
    session.setStatus(.running)
    session.setStatus(.idle)
    let loop = try XCTUnwrap(board.workspace?.loops.first(where: { $0.id == id }))
    XCTAssertEqual(loop.iterations, 1)
    XCTAssertFalse(loop.isEnabled)
    await board.shutdown()
  }

  func testLoopPanelCreatesAnIdleLoopFromAppKitControls() async throws {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = board.addConsole(agent: .shell, cwd: root)
    board.select(target)
    let session = ConsoleSession(supervisor: ProcessSupervisor())
    session.setRunningForTesting(true)
    session.setStatus(.idle)
    board.installSessionForTesting(session, id: target)
    let host = NSHostingView(rootView: LoopPanel(model: board))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    for _ in 0..<6 {
      window.layoutIfNeeded()
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(40))
    }
    let add = try XCTUnwrap(Self.button(identifier: "loops.add", in: host))
    add.performClick(nil)
    let fieldsReady = await waitUntilFields(["loops.prompt", "loops.max"])
    XCTAssertTrue(fieldsReady)
    XCTAssertTrue(MarkedFieldRegistry.commit(identifier: "loops.max", text: "1"))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(MarkedFieldRegistry.commit(identifier: "loops.prompt", text: "echo loop-panel-ok"))
    let enabled = await waitUntilEnabled("loops.create", in: host)
    XCTAssertTrue(enabled)
    let create = try XCTUnwrap(Self.button(identifier: "loops.create", in: host))
    create.performClick(nil)
    try await Task.sleep(for: .milliseconds(200))
    let loop = try XCTUnwrap(board.workspace?.loops.first)
    XCTAssertEqual(loop.targetNodeID, target)
    XCTAssertEqual(loop.prompt, "echo loop-panel-ok")
    XCTAssertEqual(loop.maxIterations, 1)
    XCTAssertEqual(loop.trigger, .idle)
    XCTAssertEqual(loop.iterations, 1)
    XCTAssertFalse(loop.isEnabled)
  }

  func testLoopPanelCreatesOutputScheduleAndGoalLoopsFromAppKitControls() async throws {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = board.addConsole(agent: .shell, cwd: root)
    board.select(target)
    let session = ConsoleSession(supervisor: ProcessSupervisor())
    session.setRunningForTesting(true)
    session.setStatus(.idle)
    board.installSessionForTesting(session, id: target)
    let host = NSHostingView(rootView: LoopPanel(model: board))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 720),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    try await layout(window, host: host)
    try await createLoopFromPanel(
      trigger: "loops.trigger.output",
      fields: [("loops.pattern", "lanebay-panel-match")],
      prompt: "echo panel-match",
      max: "2",
      in: host)
    let matched = try XCTUnwrap(board.workspace?.loops.first { $0.prompt == "echo panel-match" })
    XCTAssertEqual(matched.trigger, .outputMatch(pattern: "lanebay-panel-match"))
    XCTAssertEqual(matched.iterations, 0, "An output match does not send until the marker appears")
    XCTAssertTrue(matched.isEnabled)
    XCTAssertEqual(matched.maxIterations, 2)

    try await layout(window, host: host)
    try await createLoopFromPanel(
      trigger: "loops.trigger.schedule",
      fields: [("loops.interval", "30")],
      prompt: "echo panel-schedule",
      max: "2",
      in: host)
    let scheduled = try XCTUnwrap(board.workspace?.loops.first { $0.prompt == "echo panel-schedule" })
    XCTAssertEqual(scheduled.trigger, .schedule(intervalSeconds: 30))
    XCTAssertEqual(scheduled.iterations, 0, "A schedule does not send when it is created")
    XCTAssertTrue(scheduled.isEnabled)
    board.stopLoop(scheduled.id)

    try await layout(window, host: host)
    try await createLoopFromPanel(
      trigger: "loops.trigger.goal",
      fields: [("loops.interval", "30"), ("loops.goal", "lanebay-panel-goal")],
      prompt: "echo panel-goal",
      max: "3",
      in: host)
    let goal = try XCTUnwrap(board.workspace?.loops.first { $0.prompt == "echo panel-goal" })
    XCTAssertEqual(goal.trigger, .goalCheck(intervalSeconds: 30, goal: "lanebay-panel-goal"))
    XCTAssertEqual(goal.iterations, 0, "A goal check does not send until its interval elapses")
    XCTAssertTrue(goal.isEnabled)
    board.stopLoop(matched.id)
    board.stopLoop(goal.id)
    await board.shutdown()
  }

  func testScheduleAndGoalLoopsReachALiveShell() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let supervisor = ProcessSupervisor()
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root.appendingPathComponent("workspaces", isDirectory: true)),
      supervisor: supervisor,
      processEnvironment: ["HOME": root.path, "ZDOTDIR": root.path, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
      usageTracker: usageTracker(root),
      settings: settings(root)
    )
    let target = board.addConsole(agent: .shell, cwd: root)
    await board.startConsole(target)
    let session = try XCTUnwrap(board.sessions[target])
    let sessionID = try XCTUnwrap(session.sessionID)
    addTeardownBlock { await board.shutdown() }
    XCTAssertTrue(board.writeToConsole("printf 'SHELL_READY\\n'\r", nodeID: target))
    let ready = try await waitForScrollback("SHELL_READY", sessionID: sessionID, supervisor: supervisor)
    XCTAssertTrue(ready.contains("SHELL_READY"))
    if session.status != .idle { session.setStatus(.idle) }
    XCTAssertTrue(board.idleConsoleIDs.contains(target))

    let scheduleID = try XCTUnwrap(board.createLoop(
      targetNodeID: target, prompt: "printf 'lanebay-schedule-ok\\n'",
      trigger: .schedule(intervalSeconds: 1), maxIterations: 1))
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == scheduleID })?.iterations, 0)
    let scheduled = try await waitForScrollback("lanebay-schedule-ok", sessionID: sessionID, supervisor: supervisor)
    XCTAssertTrue(scheduled.contains("lanebay-schedule-ok"), "Schedule loop bytes reached the live PTY")
    let schedule = try XCTUnwrap(board.workspace?.loops.first(where: { $0.id == scheduleID }))
    XCTAssertEqual(schedule.iterations, 1)
    XCTAssertFalse(schedule.isEnabled)

    let goalDeadline = ContinuousClock.now + .seconds(6)
    while session.status != .idle, ContinuousClock.now < goalDeadline { await Task.yield() }
    if session.status != .idle { session.setStatus(.idle) }
    let goalID = try XCTUnwrap(board.createLoop(
      targetNodeID: target, prompt: "printf 'lanebay-goal-sent lanebay-goal-done\\n'",
      trigger: .goalCheck(intervalSeconds: 2, goal: "lanebay-goal-done"), maxIterations: 3))
    XCTAssertEqual(board.workspace?.loops.first(where: { $0.id == goalID })?.iterations, 0)
    let goalOutput = try await waitForScrollback("lanebay-goal-sent", sessionID: sessionID, supervisor: supervisor)
    XCTAssertTrue(goalOutput.contains("lanebay-goal-done"))
    let stopDeadline = ContinuousClock.now + .seconds(6)
    while ContinuousClock.now < stopDeadline {
      let loop = board.workspace?.loops.first { $0.id == goalID }
      if loop?.iterations == 1 && loop?.isEnabled == false { break }
      try await Task.sleep(for: .milliseconds(40))
    }
    let goal = try XCTUnwrap(board.workspace?.loops.first(where: { $0.id == goalID }))
    XCTAssertEqual(goal.iterations, 1, "The goal marker stops the loop before a second send")
    XCTAssertFalse(goal.isEnabled)
    await board.shutdown()
  }

  private func layout(_ window: NSWindow, host: NSView) async throws {
    for _ in 0..<6 {
      window.layoutIfNeeded()
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(40))
    }
  }

  private func createLoopFromPanel(
    trigger: String, fields: [(String, String)], prompt: String, max: String, in host: NSView
  ) async throws {
    if Self.button(identifier: "loops.create", in: host) == nil {
      let add = try XCTUnwrap(Self.button(identifier: "loops.add", in: host))
      add.performClick(nil)
    }
    let fieldsReady = await waitUntilFields(["loops.prompt", "loops.max"])
    XCTAssertTrue(fieldsReady)
    let triggerButton = try XCTUnwrap(Self.button(identifier: trigger, in: host))
    triggerButton.performClick(nil)
    let extrasReady = await waitUntilFields(fields.map(\.0))
    XCTAssertTrue(extrasReady, fields.map(\.0).joined(separator: ","))
    let selected = await waitUntilSelected(trigger, in: host)
    XCTAssertTrue(selected, trigger)
    XCTAssertTrue(MarkedFieldRegistry.commit(identifier: "loops.max", text: max))
    try await Task.sleep(for: .milliseconds(150))
    for (identifier, text) in fields {
      XCTAssertTrue(MarkedFieldRegistry.commit(identifier: identifier, text: text), identifier)
      try await Task.sleep(for: .milliseconds(150))
    }
    XCTAssertTrue(MarkedFieldRegistry.commit(identifier: "loops.prompt", text: prompt))
    try await Task.sleep(for: .milliseconds(150))
    for (identifier, text) in fields {
      XCTAssertTrue(MarkedFieldRegistry.commit(identifier: identifier, text: text), identifier)
    }
    XCTAssertTrue(MarkedFieldRegistry.commit(identifier: "loops.max", text: max))
    XCTAssertTrue(MarkedFieldRegistry.commit(identifier: "loops.prompt", text: prompt))
    let enabled = await waitUntilEnabled("loops.create", in: host)
    XCTAssertTrue(enabled)
    let create = try XCTUnwrap(Self.button(identifier: "loops.create", in: host))
    create.performClick(nil)
    try await Task.sleep(for: .milliseconds(200))
  }

  private func waitUntilSelected(_ identifier: String, in host: NSView) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
      if (Self.button(identifier: identifier, in: host)?.accessibilityValue() as? String) == "selected" {
        return true
      }
      try? await Task.sleep(for: .milliseconds(40))
    }
    return (Self.button(identifier: identifier, in: host)?.accessibilityValue() as? String) == "selected"
  }

  private func waitUntilFields(_ identifiers: [String]) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
      if identifiers.allSatisfy({ MarkedFieldRegistry.hasCommit($0) }) { return true }
      try? await Task.sleep(for: .milliseconds(40))
    }
    return identifiers.allSatisfy({ MarkedFieldRegistry.hasCommit($0) })
  }

  private func waitUntilEnabled(_ identifier: String, in host: NSView) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
      if Self.button(identifier: identifier, in: host)?.isEnabled == true { return true }
      try? await Task.sleep(for: .milliseconds(40))
    }
    return Self.button(identifier: identifier, in: host)?.isEnabled == true
  }

  func testLoopCreationValidationAndStopPersistWithWorkspace() throws {
    let (board, store, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = board.addConsole(agent: .shell)
    XCTAssertNil(board.createLoop(targetNodeID: UUID(), prompt: "run", trigger: .idle))
    XCTAssertNil(board.createLoop(targetNodeID: target, prompt: "", trigger: .idle))
    let id = try XCTUnwrap(board.createLoop(targetNodeID: target, prompt: "run", trigger: .idle, maxIterations: 2))
    board.stopLoop(id)
    XCTAssertFalse(try XCTUnwrap(board.workspace?.loops.first).isEnabled)
    try board.saveNow()
    XCTAssertEqual(try store.load(id: board.workspace!.id).loops.first?.id, id)
  }

  func testStartConsoleUsesCustomExecutableAndAppliesAccountProfileEnvironment() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("fake-agent")
    try Data("#!/bin/sh\nprintf 'PROFILE:%s' \"$CODEX_HOME\"\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let settings = SettingsViewModel(
      store: AppPreferencesStore(rootURL: root.appendingPathComponent("preferences", isDirectory: true)),
      executableSearchDirectories: [root]
    )
    XCTAssertTrue(settings.upsertCustomExecutable(CustomAgentExecutable(
      id: "custom-fake", displayName: "Fake Agent", executablePath: executable.path
    )))
    XCTAssertTrue(settings.upsertAccountProfile(AgentAccountProfile(
      id: "profile-codex-home", name: "Codex Home", agentID: "custom-fake", environment: ["CODEX_HOME": "/tmp/profile-home"]
    )))
    let supervisor = ProcessSupervisor()
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root.appendingPathComponent("workspaces", isDirectory: true)),
      supervisor: supervisor,
      processEnvironment: ["HOME": root.path],
      usageTracker: usageTracker(root),
      settings: settings
    )
    let id = board.addConsole(agentID: "custom-fake", profileID: "profile-codex-home", cwd: root)
    await board.startConsole(id)
    let sessionID = try XCTUnwrap(board.sessions[id]?.sessionID)
    let deadline = ContinuousClock.now + .seconds(5)
    var sawProfile = false
    while ContinuousClock.now < deadline {
      if String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self).contains("PROFILE:/tmp/profile-home") {
        sawProfile = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(sawProfile)
    await board.shutdown()
  }

  func testStartConsoleShowsErrorWhenCustomAgentIsMissingAndDoesNotFallbackToShell() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root.appendingPathComponent("workspaces", isDirectory: true)),
      usageTracker: usageTracker(root),
      settings: SettingsViewModel(store: AppPreferencesStore(rootURL: root.appendingPathComponent("preferences", isDirectory: true)))
    )
    let id = board.addConsole(agentID: "custom-removed", cwd: root)
    await board.startConsole(id)
    XCTAssertNil(board.sessions[id], "Missing custom agent must not launch a fallback shell")
    XCTAssertNil(board.errorMessage)
    XCTAssertTrue((board.consoleLaunchErrors[id] ?? "").contains("no longer available"))
    XCTAssertTrue(board.workspace?.nodes.first(where: { $0.id == id })?.notStarted == true)
  }

  func testLiveBoardPersistsPreferencesInInjectedHomeSupportDirectory() async {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let board = BoardViewModel.live(homeDirectory: home)
    let workspaceID = board.activeWorkspaceID
    XCTAssertNotNil(workspaceID)
    board.settings.setShowNotifications(false)
    await board.shutdown()

    let restored = BoardViewModel.live(homeDirectory: home)
    XCTAssertFalse(restored.settings.preferences.showNotifications)
    XCTAssertEqual(restored.settings.preferences.lastWorkspaceID, workspaceID)
    XCTAssertEqual(restored.activeWorkspaceID, workspaceID)
    let preferences = home.appendingPathComponent("Library/Application Support/Lanebay/preferences.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: preferences.path))
    XCTAssertFalse(preferences.path.contains("Lanebay-default-preferences"))
    await restored.shutdown()
  }

  func testPanToRevealPullsOffscreenConsoleHeadersToTheMargin() {
    let above = NodeFrame(x: -40, y: -200, w: 480, h: 320)
    let pulled = BoardViewport.panToReveal(
      frames: [above], zoom: 1, panX: 0, panY: 0, viewportWidth: 1000, viewportHeight: 700)
    XCTAssertEqual(pulled.x, 72, accuracy: 0.001)
    XCTAssertEqual(pulled.y, 232, accuracy: 0.001)
    XCTAssertEqual(above.y * 1 + pulled.y, 32, accuracy: 0.001)

    let zoomed = BoardViewport.panToReveal(
      frames: [NodeFrame(x: -40, y: -20, w: 480, h: 320)],
      zoom: 2, panX: 0, panY: 0, viewportWidth: 1000, viewportHeight: 700)
    XCTAssertEqual(-20 * 2 + zoomed.y, 32, accuracy: 0.001)
    XCTAssertEqual(-40 * 2 + zoomed.x, 32, accuracy: 0.001)

    let beside = BoardViewport.panToReveal(
      frames: [NodeFrame(x: 2000, y: 40, w: 480, h: 320)],
      zoom: 1, panX: 0, panY: 0, viewportWidth: 800, viewportHeight: 600)
    XCTAssertEqual(2000 + beside.x, 32, accuracy: 0.001)
    XCTAssertEqual(40 + beside.y, 32, accuracy: 0.001)
  }

  func testPanToRevealLeavesAVisibleHeaderAloneAndIgnoresInvalidFrames() {
    let visible = NodeFrame(x: 32, y: 48, w: 480, h: 320)
    let same = BoardViewport.panToReveal(
      frames: [visible], zoom: 1, panX: 12, panY: -4, viewportWidth: 1000, viewportHeight: 700)
    XCTAssertEqual(same, BoardViewport.Pan(x: 12, y: -4))

    let clipped = BoardViewport.panToReveal(
      frames: [NodeFrame(x: 32, y: -8, w: 480, h: 400)],
      zoom: 1, panX: 0, panY: 0, viewportWidth: 1000, viewportHeight: 700)
    XCTAssertEqual(clipped.y, 40, accuracy: 0.001)

    let ignored = BoardViewport.panToReveal(
      frames: [NodeFrame(x: .nan, y: -400, w: 10, h: 10), NodeFrame(x: 0, y: 0, w: 0, h: 10)],
      zoom: 1, panX: 3, panY: 4, viewportWidth: 800, viewportHeight: 600)
    XCTAssertEqual(ignored, BoardViewport.Pan(x: 3, y: 4))

    let unstable = BoardViewport.panToReveal(
      frames: [visible], zoom: .infinity, panX: 1, panY: 2, viewportWidth: 800, viewportHeight: 600)
    XCTAssertEqual(unstable, BoardViewport.Pan(x: 1, y: 2))
  }

  func testRevealRunsOncePerWorkspaceAfterTheViewportIsReal() throws {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try XCTUnwrap(board.workspace?.id)
    board.revealConsolesInViewport(width: 200, height: 100)
    XCTAssertEqual(board.panX, 0)
    XCTAssertEqual(board.panY, 0)

    let console = board.addConsole(agent: .shell, cwd: root)
    board.moveNode(console, x: 16, y: -180)
    board.revealConsolesInViewport(width: 900, height: 600)
    XCTAssertEqual(board.panX, 16, accuracy: 0.001)
    XCTAssertEqual(board.panY, 212, accuracy: 0.001)
    XCTAssertGreaterThanOrEqual(16 * board.zoom + board.panX, 0)
    XCTAssertGreaterThanOrEqual(-180 * board.zoom + board.panY, 0)

    board.pan(dx: 8, dy: -20)
    board.revealConsolesInViewport(width: 900, height: 600)
    XCTAssertEqual(board.panX, 24, accuracy: 0.001)
    XCTAssertEqual(board.panY, 192, accuracy: 0.001)

    let second = board.createWorkspace(name: "Other")
    let other = board.addConsole(agent: .codex, cwd: root)
    board.moveNode(other, x: 0, y: -50)
    board.revealConsolesInViewport(width: 900, height: 600)
    XCTAssertEqual(board.panY, 82, accuracy: 0.001)
    board.switchWorkspace(first)
    XCTAssertEqual(board.panY, 192, accuracy: 0.001)
    board.revealConsolesInViewport(width: 900, height: 600)
    XCTAssertEqual(board.panY, 192, accuracy: 0.001)
    XCTAssertNotEqual(second, first)
  }

  func testRevealDoesNotLockAnEmptyBoard() {
    let (board, _, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    board.revealConsolesInViewport(width: 900, height: 600)
    XCTAssertEqual(board.panY, 0)
    let console = board.addConsole(agent: .claude, cwd: root)
    board.moveNode(console, x: 0, y: -90)
    board.revealConsolesInViewport(width: 900, height: 600)
    XCTAssertEqual(board.panY, 122, accuracy: 0.001)
  }

  func testSnapshotCapturePathStaysInsideTheDistCheckout() {
    let repo = URL(fileURLWithPath: "/tmp/lanebay-snapshot", isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    let bundle = repo.appendingPathComponent("dist/Lanebay.app", isDirectory: true)
    let captured = SnapshotCapturePath.destination(bundleURL: bundle, markerContents: "20261022-093300\n")
    XCTAssertEqual(
      captured?.path,
      repo.appendingPathComponent("agent/screens/20261022-093300").path)

    XCTAssertNil(SnapshotCapturePath.destination(
      bundleURL: URL(fileURLWithPath: "/Applications/Lanebay.app", isDirectory: true),
      markerContents: "20261022-093300"))
    XCTAssertNil(SnapshotCapturePath.destination(bundleURL: bundle, markerContents: "../secret"))
    XCTAssertNil(SnapshotCapturePath.destination(bundleURL: bundle, markerContents: "20261022-093300/extra"))
    XCTAssertNil(SnapshotCapturePath.destination(
      bundleURL: URL(fileURLWithPath: "/dist/Lanebay.app", isDirectory: true),
      markerContents: "20261022-093300"))
  }

  func testFlowLaunchHomeAcceptsATempChildAndRejectsEscapes() throws {
    let temporary = FileManager.default.temporaryDirectory
    let child = temporary.appendingPathComponent("lanebay-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: child) }
    let accepted = FlowLaunchHome.accepted(path: "  \(child.path)\n", temporaryDirectory: temporary)
    XCTAssertEqual(accepted?.path, child.resolvingSymlinksInPath().path)
    XCTAssertNil(FlowLaunchHome.accepted(path: temporary.path, temporaryDirectory: temporary))
    XCTAssertNil(FlowLaunchHome.accepted(path: child.path + "/../\(child.lastPathComponent)", temporaryDirectory: temporary))
    XCTAssertNil(FlowLaunchHome.accepted(path: "relative/home", temporaryDirectory: temporary))
    XCTAssertNil(FlowLaunchHome.accepted(path: child.appendingPathComponent("missing").path, temporaryDirectory: temporary))
    XCTAssertNil(FlowLaunchHome.accepted(
      path: FileManager.default.homeDirectoryForCurrentUser.path, temporaryDirectory: temporary))
    let link = temporary.appendingPathComponent("lanebay-home-link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: FileManager.default.homeDirectoryForCurrentUser)
    defer { try? FileManager.default.removeItem(at: link) }
    XCTAssertNil(FlowLaunchHome.accepted(path: link.path, temporaryDirectory: temporary))
  }

  func testExecutableLookupFindsZshAndRejectsUnknownNames() {
    XCTAssertTrue(ConsoleExecutableLookup.isInstalled("/bin/zsh"))
    XCTAssertTrue(ConsoleExecutableLookup.isInstalled("zsh", path: "/usr/bin:/bin"))
    XCTAssertFalse(ConsoleExecutableLookup.isInstalled("lanebay-missing-agent-bin", path: "/usr/bin:/bin"))
    XCTAssertFalse(ConsoleExecutableLookup.isInstalled("/tmp/lanebay-missing-agent-bin"))
  }

  func testCreateAndStartMissingAgentShowsInlineErrorWithoutLaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root.appendingPathComponent("workspaces", isDirectory: true)),
      usageTracker: usageTracker(root),
      settings: settings(root),
      executableIsInstalled: { $0 == "zsh" || $0 == "/bin/zsh" }
    )
    let id = board.createAndStartConsole(agentID: "codex", cwd: root)
    let deadline = ContinuousClock.now + .seconds(2)
    while board.consoleLaunchErrors[id] == nil && ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertNil(board.sessions[id])
    XCTAssertTrue(board.workspace?.nodes.first { $0.id == id }?.notStarted == true)
    let message = try XCTUnwrap(board.consoleLaunchErrors[id])
    XCTAssertTrue(message.contains("not installed"))
    XCTAssertTrue(message.contains("nothing was started"))
    XCTAssertFalse(board.installedLaunchExecutable(agentID: "codex"))
    await board.shutdown()
  }

  func testCreateAndStartConsoleFeedsEchoToLivePTY() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let supervisor = ProcessSupervisor()
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root.appendingPathComponent("workspaces", isDirectory: true)),
      supervisor: supervisor,
      processEnvironment: ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
      usageTracker: usageTracker(root),
      settings: settings(root)
    )
    let id = board.createAndStartConsole(agentID: "shell", cwd: root)
    let started = ContinuousClock.now + .seconds(8)
    while board.sessions[id]?.isRunning != true && ContinuousClock.now < started {
      try await Task.sleep(for: .milliseconds(30))
    }
    let sessionID = try XCTUnwrap(board.sessions[id]?.sessionID)
    XCTAssertEqual(board.workspace?.nodes.first { $0.id == id }?.notStarted, false)
    board.sessions[id]?.send(Data("echo lanebay-ok\r".utf8))
    let deadline = ContinuousClock.now + .seconds(6)
    var saw = false
    while ContinuousClock.now < deadline {
      if String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self).contains("lanebay-ok") {
        saw = true
        break
      }
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertTrue(saw)
    let added = board.addConsole(agent: .shell, cwd: root)
    XCTAssertTrue(board.workspace?.nodes.first { $0.id == added }?.notStarted == true)
    XCTAssertNil(board.sessions[added])
    await board.shutdown()
  }

  func testCommandVPasteReachesLivePTY() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent(".zshenv"))
    try Data().write(to: root.appendingPathComponent(".zprofile"))
    try Data().write(to: root.appendingPathComponent(".zlogin"))
    try Data("PROMPT='READY> '\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
    let supervisor = ProcessSupervisor()
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root.appendingPathComponent("workspaces", isDirectory: true)),
      supervisor: supervisor,
      processEnvironment: [
        "HOME": root.path, "ZDOTDIR": root.path, "SHELL": "/bin/zsh",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      ],
      usageTracker: usageTracker(root),
      settings: settings(root)
    )
    addTeardownBlock {
      await board.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    let id = board.createAndStartConsole(agentID: "shell", cwd: root)
    let started = ContinuousClock.now + .seconds(8)
    while board.sessions[id]?.isRunning != true && ContinuousClock.now < started {
      try await Task.sleep(for: .milliseconds(30))
    }
    let session = try XCTUnwrap(board.sessions[id])
    let sessionID = try XCTUnwrap(session.sessionID)
    let ready = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < ready {
      if String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self).contains("READY>") { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    let view = session.terminalView()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView?.addSubview(view)
    view.frame = window.contentView?.bounds ?? view.frame
    let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
    window.contentView?.addSubview(other)
    window.makeKey()
    let previousClipboard = NSPasteboard.general.string(forType: .string)
    defer {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      if let previousClipboard { pasteboard.setString(previousClipboard, forType: .string) }
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("/bin/echo lanebay-paste-9f3", forType: .string)
    XCTAssertTrue(window.makeFirstResponder(other))
    let commandV = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
    XCTAssertNotNil(TerminalPasteShortcuts.handle(commandV))
    try await Task.sleep(for: .milliseconds(150))
    let beforeFocus = String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self)
    XCTAssertFalse(beforeFocus.contains("lanebay-paste-9f3"), "An unfocused terminal must not take Command-V")
    XCTAssertTrue(window.makeFirstResponder(view))
    XCTAssertNil(TerminalPasteShortcuts.handle(commandV))
    if let enter = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
      view.keyDown(with: enter)
    }
    let deadline = ContinuousClock.now + .seconds(6)
    var saw = false
    while ContinuousClock.now < deadline {
      if String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self).contains("lanebay-paste-9f3") {
        saw = true
        break
      }
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertTrue(saw)
    await board.shutdown()
    // SwiftTerm faults if its view is released with the window during test teardown.
    RetainedTestWindows.keep(window)
  }

  func testAgentPickerRowsAreRealButtonsForEveryCatalogAgent() {
    let agents = AgentCatalog.knownCLIs.map { AgentPickerAgent(id: $0.id, title: $0.displayName) }
    let rows = AgentPickerCatalog.rows(agents: agents, profiles: [])
    XCTAssertEqual(rows.map(\.identifier), agents.map { "agent.\($0.id)" })
    XCTAssertEqual(rows.first?.identifier, "agent.shell")
    XCTAssertEqual(rows.first?.title, "Shell")
    XCTAssertTrue(rows.contains { $0.identifier == "agent.codex" && $0.title == "Codex" && $0.profileID == nil })
    XCTAssertTrue(rows.contains { $0.identifier == "agent.claude" && $0.title == "Claude Code" })
    XCTAssertTrue(rows.contains { $0.identifier == "agent.cursor-agent" && $0.title == "Cursor Agent" })

    let profiled = AgentPickerCatalog.rows(
      agents: [AgentPickerAgent(id: "shell", title: "Shell")],
      profiles: [AgentAccountProfile(id: "work", name: "Work", agentID: "shell", environment: ["LANG": "en_US.UTF-8"])])
    XCTAssertEqual(profiled.map(\.identifier), ["agent.shell", "agent.shell.profile.work"])
    XCTAssertEqual(profiled.map(\.profileID), [nil, "work"])
    XCTAssertEqual(AgentPickerCatalog.accessibilityIdentifier(agentID: "shell"), "agent.shell")
  }

  func testMarkdownRailCaptionFitsWithoutAnEllipsis() async throws {
    let narrow = NSButton(title: "Markdown", target: nil, action: nil)
    narrow.isBordered = false
    narrow.font = .systemFont(ofSize: 11)
    narrow.frame = NSRect(x: 0, y: 0, width: 52, height: BoardRailMetrics.buttonHeight)
    XCTAssertFalse(BoardRailMetrics.captionFits(narrow), "A 52 pt rail button clips Markdown to an ellipsis")
    XCTAssertGreaterThan(BoardRailMetrics.buttonWidth, 52)

    let panels = [BoardRailPanel(id: "board", icon: .workspace, title: "Board", isSelected: false) {}]
      + BoardSidePanel.railOrder.map { panel in
        BoardRailPanel(id: panel.rawValue, icon: panel.icon, title: panel.railTitle, isSelected: panel == .markdown) {}
      }
    let rail = BoardRail(
      panels: panels,
      canCreateGroup: true,
      canManageGroups: true,
      onCreateGroup: {},
      onManageGroups: {}
    ) {
      AXActionButton(
        title: "Console",
        systemImage: "plus",
        identifier: "rail.addConsole",
        accessibilityLabel: "Add console",
        enabled: true,
        highlighted: false,
        compact: true
      ) {}
      .frame(width: BoardRailMetrics.buttonWidth, height: BoardRailMetrics.buttonHeight)
    }
    let host = NSHostingView(rootView: rail)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 800),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    RetainedTestWindows.keep(window)
    for _ in 0..<8 {
      window.layoutIfNeeded()
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(40))
    }
    let markdown = try XCTUnwrap(Self.button(identifier: "rail.panel.markdown", in: host))
    XCTAssertEqual(markdown.title, "Markdown")
    XCTAssertTrue(BoardRailMetrics.captionFits(markdown))
    XCTAssertGreaterThanOrEqual(markdown.bounds.width, BoardRailMetrics.buttonWidth - 0.5)
    for identifier in ["rail.panel.settings", "rail.panel.github", "rail.addConsole", "rail.createGroup", "rail.manageGroups"] {
      let button = try XCTUnwrap(Self.button(identifier: identifier, in: host), identifier)
      XCTAssertTrue(BoardRailMetrics.captionFits(button), identifier)
    }
    window.orderOut(nil)
  }

  func testPinnedRailActionsStayOnScreenAndClickAt800Points() async throws {
    let clicks = RailClickFlags()
    let panels = (0..<14).map { index in
      BoardRailPanel(icon: .workspace, title: "Panel \(index)", isSelected: index == 0) {}
    }
    let rail = BoardRail(
      panels: panels,
      canCreateGroup: true,
      canManageGroups: true,
      onCreateGroup: { clicks.group = true },
      onManageGroups: { clicks.manage = true }
    ) {
      AXActionButton(
        title: "Console",
        systemImage: "plus",
        identifier: "rail.addConsole",
        accessibilityLabel: "Add console",
        enabled: true,
        highlighted: false,
        compact: true
      ) { clicks.add = true }
      .frame(width: BoardRailMetrics.buttonWidth, height: BoardRailMetrics.buttonHeight)
    }
    let host = NSHostingView(rootView: rail)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 800),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false)
    window.contentMinSize = NSSize(width: 800, height: 800)
    window.contentMaxSize = NSSize(width: 800, height: 800)
    window.contentView = host
    window.setContentSize(NSSize(width: 800, height: 800))
    window.makeKeyAndOrderFront(nil)
    RetainedTestWindows.keep(window)
    for _ in 0..<8 {
      window.layoutIfNeeded()
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
    }

    XCTAssertLessThanOrEqual(host.bounds.height, 801)
    let clip = try XCTUnwrap(Self.deepestClipView(in: host))
    let document = try XCTUnwrap(Self.descendant(named: "DocumentView", in: clip))
    XCTAssertGreaterThan(
      document.bounds.height, clip.bounds.height,
      "Panel list must scroll inside the space left by Add console, Group, and Manage")
    let clipFrame = clip.convert(clip.bounds, to: host)
    for identifier in ["rail.addConsole", "rail.createGroup", "rail.manageGroups"] {
      let button = try XCTUnwrap(Self.button(identifier: identifier, in: host), identifier)
      let frame = button.convert(button.bounds, to: host)
      let center = CGPoint(x: frame.midX, y: frame.midY)
      XCTAssertTrue(host.bounds.contains(center), "\(identifier) center \(center) outside \(host.bounds)")
      XCTAssertFalse(
        clipFrame.intersects(frame.insetBy(dx: 2, dy: 2)),
        "\(identifier) overlaps the scrolling panels")
      button.performClick(nil)
    }
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(clicks.add)
    XCTAssertTrue(clicks.group)
    XCTAssertTrue(clicks.manage)
    window.orderOut(nil)
  }

  func testSidePanelToggleKeepsASinglePanelOpen() {
    XCTAssertEqual(BoardSidePanel.toggled(nil, .settings), .settings)
    XCTAssertEqual(BoardSidePanel.toggled(.settings, .docs), .docs)
    XCTAssertNil(BoardSidePanel.toggled(.docs, .docs))
    XCTAssertEqual(BoardSidePanel.railOrder.last, .planner)
    XCTAssertFalse(BoardSidePanel.railOrder.contains(.loops))
    XCTAssertEqual(BoardSidePanel.planner.railIdentifier, "rail.panel.planner")
    XCTAssertEqual(BoardSidePanel.shots.hostTitle, "Screenshots")
    let home = URL(fileURLWithPath: "/tmp/lanebay-panel-home", isDirectory: true)
    XCTAssertEqual(
      PanelStorage.supportRoot(homeDirectory: home).path,
      "/tmp/lanebay-panel-home/Library/Application Support/Lanebay")
    XCTAssertEqual(
      PanelStorage.chatRoot(homeDirectory: home).path,
      "/tmp/lanebay-panel-home/Library/Application Support/Lanebay/Chat")
  }

  func testLivePanelsUseTheBoardHome() async {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("lanebay-panels-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let board = BoardViewModel.live(homeDirectory: home)
    let view = BoardView(model: board)
    XCTAssertEqual(board.homeDirectory.resolvingSymlinksInPath().path, home.path)
    XCTAssertEqual(view.memoryHomeRoot.resolvingSymlinksInPath().path, home.path)
    XCTAssertEqual(
      view.panelSupportRoot.resolvingSymlinksInPath().path,
      PanelStorage.supportRoot(homeDirectory: home).resolvingSymlinksInPath().path)
    let userSupport = PanelStorage.supportRoot(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    ).resolvingSymlinksInPath().path
    XCTAssertNotEqual(view.panelSupportRoot.resolvingSymlinksInPath().path, userSupport)
    await board.shutdown()
  }

  func testHiddenRailPanelScrollsIntoTheClipWithoutCoveringActions() async throws {
    let panels = [BoardRailPanel(id: "board", icon: .workspace, title: "Board", isSelected: true) {}]
      + BoardSidePanel.railOrder.map { panel in
        BoardRailPanel(id: panel.rawValue, icon: panel.icon, title: panel.railTitle, isSelected: false) {}
      }
    let rail = BoardRail(
      panels: panels,
      canCreateGroup: true,
      canManageGroups: true,
      onCreateGroup: {},
      onManageGroups: {}
    ) {
      AXActionButton(
        title: "Console",
        systemImage: "plus",
        identifier: "rail.addConsole",
        accessibilityLabel: "Add console",
        enabled: true,
        highlighted: false,
        compact: true
      ) {}
      .frame(width: BoardRailMetrics.buttonWidth, height: BoardRailMetrics.buttonHeight)
    }
    let host = NSHostingView(rootView: rail)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 800),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false)
    window.contentView = host
    window.setContentSize(NSSize(width: 800, height: 800))
    window.makeKeyAndOrderFront(nil)
    RetainedTestWindows.keep(window)
    for _ in 0..<8 {
      window.layoutIfNeeded()
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
    }
    let clip = try XCTUnwrap(Self.deepestClipView(in: host))
    let planner = try XCTUnwrap(Self.button(identifier: "rail.panel.planner", in: host))
    let plannerFrame = planner.convert(planner.bounds, to: clip)
    XCTAssertFalse(
      clip.bounds.contains(CGPoint(x: plannerFrame.midX, y: plannerFrame.midY)),
      "Planner starts below the fold at 800pt")
    planner.scrollToVisible(planner.bounds)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let revealed = planner.convert(planner.bounds, to: clip)
    XCTAssertTrue(clip.bounds.contains(CGPoint(x: revealed.midX, y: revealed.midY)))
    let add = try XCTUnwrap(Self.button(identifier: "rail.addConsole", in: host))
    let addFrame = add.convert(add.bounds, to: host)
    let clipFrame = clip.convert(clip.bounds, to: host)
    XCTAssertTrue(host.bounds.contains(CGPoint(x: addFrame.midX, y: addFrame.midY)))
    XCTAssertFalse(clipFrame.intersects(addFrame.insetBy(dx: 2, dy: 2)))
    window.orderOut(nil)
  }

  private static func button(identifier: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.accessibilityIdentifier() == identifier { return button }
    for child in view.subviews {
      if let found = button(identifier: identifier, in: child) { return found }
    }
    return nil
  }

  private static func deepestClipView(in view: NSView) -> NSClipView? {
    var best: NSClipView?
    func walk(_ view: NSView) {
      if let clip = view as? NSClipView, clip.bounds.height > (best?.bounds.height ?? 0) { best = clip }
      for child in view.subviews { walk(child) }
    }
    walk(view)
    return best
  }

  private static func descendant(named name: String, in view: NSView) -> NSView? {
    if String(describing: type(of: view)) == name { return view }
    for child in view.subviews {
      if let found = descendant(named: name, in: child) { return found }
    }
    return nil
  }

  func testTerminalResizeUpdatesPtyAndShellColumns() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent(".zshenv"))
    try Data().write(to: root.appendingPathComponent(".zprofile"))
    try Data().write(to: root.appendingPathComponent(".zlogin"))
    try Data("unset RPROMPT\nPROMPT='> '\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
    let supervisor = ProcessSupervisor()
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root.appendingPathComponent("workspaces", isDirectory: true)),
      supervisor: supervisor,
      processEnvironment: [
        "HOME": root.path, "ZDOTDIR": root.path, "SHELL": "/bin/zsh",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color",
      ],
      usageTracker: usageTracker(root),
      settings: settings(root)
    )
    let id = board.createAndStartConsole(agentID: "shell", cwd: root)
    let started = ContinuousClock.now + .seconds(8)
    while board.sessions[id]?.isRunning != true && ContinuousClock.now < started {
      try await Task.sleep(for: .milliseconds(30))
    }
    let session = try XCTUnwrap(board.sessions[id])
    let sessionID = try XCTUnwrap(session.sessionID)
    // The app creates the view after the PTY is already running at 80x24.
    let view = session.terminalView()
    let host = TerminalHostView(terminal: view)
    RetainedTestWindows.keep(host)
    addTeardownBlock {
      await board.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    let initial = try await waitForShellSize(
      matching: { (cols: view.terminalDimensions.cols, rows: view.terminalDimensions.rows) },
      marker: "B", session: session, sessionID: sessionID, supervisor: supervisor)
    XCTAssertEqual(initial.cols, view.terminalDimensions.cols)
    XCTAssertEqual(initial.rows, view.terminalDimensions.rows)
    XCTAssertGreaterThan(initial.cols, 1)
    host.setFrameSize(NSSize(width: 1100, height: 700))
    host.layoutSubtreeIfNeeded()
    let resized = try await waitForShellSize(
      matching: { (cols: view.terminalDimensions.cols, rows: view.terminalDimensions.rows) },
      marker: "A", session: session, sessionID: sessionID, supervisor: supervisor)
    XCTAssertEqual(resized.cols, view.terminalDimensions.cols)
    XCTAssertEqual(resized.rows, view.terminalDimensions.rows)
    XCTAssertGreaterThan(resized.cols, initial.cols)
    XCTAssertGreaterThan(resized.rows, initial.rows)
    let kernel = try await supervisor.windowSize(for: sessionID)
    XCTAssertEqual(Int(kernel.columns), resized.cols)
    XCTAssertEqual(Int(kernel.rows), resized.rows)
    session.send(Data("printf 'ZRUN '; printf '%*s' \"$COLUMNS\" '' | /usr/bin/tr ' ' 0\r".utf8))
    let zeros = try await waitForZeroRun(sessionID: sessionID, supervisor: supervisor)
    XCTAssertEqual(zeros, resized.cols, "shell COLUMNS must match the terminal grid so the prompt does not overlap the command")
  }

  func testStatusLabelIncludesExitCodeAndLaunchFailureIsAnError() {
    XCTAssertEqual(AgentStatus.finished.label(exitCode: 0), "Exited 0")
    XCTAssertEqual(AgentStatus.error.label(exitCode: 3), "Exited 3")
    XCTAssertEqual(AgentStatus.error.label(exitCode: nil), "Error")
    XCTAssertEqual(AgentStatus.running.label(exitCode: 3), "Running")
    XCTAssertEqual(ConsoleCardStatus.resolve(sessionStatus: nil, hasLaunchError: true), .error)
    XCTAssertEqual(ConsoleCardStatus.resolve(sessionStatus: nil, hasLaunchError: false), .stopped)
    XCTAssertEqual(ConsoleCardStatus.resolve(sessionStatus: .idle, hasLaunchError: true), .idle)
  }

  func testShellStatusLightTracksIdleInputAndExitCode() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent(".zshenv"))
    try Data().write(to: root.appendingPathComponent(".zprofile"))
    try Data().write(to: root.appendingPathComponent(".zlogin"))
    let pad = String(repeating: "p", count: 120)
    try Data("unset RPROMPT\nPROMPT=$'\\e[35m❯ \(pad)\\e[0m'\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
    let supervisor = ProcessSupervisor()
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root.appendingPathComponent("workspaces", isDirectory: true)),
      supervisor: supervisor,
      notifier: RecordingNotifier(),
      processEnvironment: [
        "HOME": root.path, "ZDOTDIR": root.path, "SHELL": "/bin/zsh",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color",
      ],
      usageTracker: usageTracker(root),
      settings: settings(root)
    )
    addTeardownBlock {
      await board.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    let id = board.createAndStartConsole(agentID: "shell", cwd: root)
    let session = try await waitForRunningSession(id, on: board)
    try await waitForStatus(.idle, session: session, timeout: .seconds(8))
    session.send(Data("sleep 4\r".utf8))
    try await Task.sleep(for: .seconds(2.5))
    XCTAssertEqual(session.status, .running, "a running sleep must stay Running. tail=\(statusTail(session))")
    XCTAssertNil(session.exitCode)
    try await waitForStatus(.idle, session: session, timeout: .seconds(8))
    session.send(Data("printf 'Enter value: '; read -r reply\r".utf8))
    try await waitForStatus(.waitingForInput, session: session, timeout: .seconds(4))
    session.send(Data("ok\r".utf8))
    try await waitForStatus(.idle, session: session, timeout: .seconds(6))
    session.send(Data("echo bye; exit 3\r".utf8))
    try await waitForExit(code: 3, session: session, timeout: .seconds(6))
    XCTAssertEqual(session.status, .error)
    XCTAssertEqual(session.status.label(exitCode: session.exitCode), "Exited 3")
    try await Task.sleep(for: .seconds(2.4))
    XCTAssertEqual(session.status, .error, "output after exit must not put the light back on Working")
    XCTAssertEqual(session.exitCode, 3)
    XCTAssertFalse(session.isRunning)
  }

  func testHeavyOutputKeepsTheShellAliveAndTheMainActorResponsive() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent(".zshenv"))
    try Data().write(to: root.appendingPathComponent(".zprofile"))
    try Data().write(to: root.appendingPathComponent(".zlogin"))
    try Data("unset RPROMPT\nPROMPT='> '\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
    let supervisor = ProcessSupervisor()
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root.appendingPathComponent("workspaces", isDirectory: true)),
      supervisor: supervisor,
      processEnvironment: [
        "HOME": root.path, "ZDOTDIR": root.path, "SHELL": "/bin/zsh",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color",
      ],
      usageTracker: usageTracker(root),
      settings: settings(root)
    )
    addTeardownBlock {
      await board.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    let id = board.createAndStartConsole(agentID: "shell", cwd: root)
    let started = ContinuousClock.now + .seconds(8)
    while board.sessions[id]?.isRunning != true && ContinuousClock.now < started {
      try await Task.sleep(for: .milliseconds(30))
    }
    let session = try XCTUnwrap(board.sessions[id])
    let sessionID = try XCTUnwrap(session.sessionID)
    let view = session.terminalView()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView?.addSubview(view)
    view.frame = window.contentView?.bounds ?? view.frame
    RetainedTestWindows.keep(window)
    let ready = ContinuousClock.now + .seconds(6)
    while ContinuousClock.now < ready {
      if String(decoding: session.recentOutput, as: UTF8.self).contains(">") { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    let gate = FloodObservation()
    let sampler = Task.detached { () -> Duration in
      var worst: Duration = .zero
      let deadline = ContinuousClock.now + .seconds(15)
      while ContinuousClock.now < deadline {
        let start = ContinuousClock.now
        let stop = await gate.stop
        let gap = start.duration(to: .now)
        if gap > worst { worst = gap }
        if stop { break }
        try? await Task.sleep(for: .milliseconds(12))
      }
      return worst
    }
    // The marker is assembled in the shell so the typed command line is not a false completion.
    session.send(Data("token=$(printf 'LANEBAY-FLOOD-%s' DONE); /usr/bin/yes | /usr/bin/head -n 200000; /bin/echo \"$token\"\r".utf8))
    let floodDeadline = ContinuousClock.now + .seconds(12)
    var floodText = ""
    var published = ""
    while ContinuousClock.now < floodDeadline {
      floodText = String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self)
      published = String(decoding: session.recentOutput, as: UTF8.self)
      if floodText.contains("LANEBAY-FLOOD-DONE"), published.contains("LANEBAY-FLOOD-DONE") { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertTrue(
      published.contains("LANEBAY-FLOOD-DONE"),
      "scrollbackHasToken=\(floodText.contains("LANEBAY-FLOOD-DONE")) bytes=\(floodText.utf8.count)")
    XCTAssertGreaterThan(floodText.utf8.count, 100_000, "the pipeline did not produce a heavy burst")
    XCTAssertTrue(session.isRunning)
    XCTAssertNil(session.failureMessage)
    XCTAssertFalse(session.hasFinished)
    session.send(Data("echo lanebay-after-flood\r".utf8))
    let afterDeadline = ContinuousClock.now + .seconds(6)
    var after = floodText
    var publishedAfter = ""
    while ContinuousClock.now < afterDeadline {
      after = String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self)
      publishedAfter = String(decoding: session.recentOutput, as: UTF8.self)
      if after.contains("lanebay-after-flood"), publishedAfter.contains("lanebay-after-flood") { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertTrue(after.contains("lanebay-after-flood"), "shell did not accept input after the burst. tail=\(after.suffix(180))")
    XCTAssertTrue(
      publishedAfter.contains("lanebay-after-flood"),
      "terminal dropped the follow-up after the burst. tail=\(publishedAfter.suffix(180))")
    XCTAssertTrue(session.isRunning)
    XCTAssertNil(session.failureMessage)
    gate.finish()
    let worst = await sampler.value
    XCTAssertGreaterThan(worst, .zero)
    XCTAssertLessThan(worst, .milliseconds(400), "main actor stalled for \(worst) while drawing the burst")
  }

  private func waitForRunningSession(_ id: UUID, on board: BoardViewModel) async throws -> ConsoleSession {
    let deadline = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < deadline {
      if board.sessions[id]?.isRunning == true { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    let session = try XCTUnwrap(board.sessions[id])
    XCTAssertTrue(session.isRunning)
    return session
  }

  private func waitForStatus(_ wanted: AgentStatus, session: ConsoleSession, timeout: Duration) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if session.status == wanted { return }
      try await Task.sleep(for: .milliseconds(40))
    }
    XCTAssertEqual(session.status, wanted, "tail=\(statusTail(session))")
  }

  private func waitForExit(code: Int32, session: ConsoleSession, timeout: Duration) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if session.exitCode == code, session.status == (code == 0 ? .finished : .error) { return }
      try await Task.sleep(for: .milliseconds(40))
    }
    XCTAssertEqual(session.exitCode, code, "status=\(session.status) tail=\(statusTail(session))")
  }

  private func statusTail(_ session: ConsoleSession) -> String {
    let text = String(decoding: session.recentOutput.suffix(160), as: UTF8.self)
    let visible = text.unicodeScalars.filter { $0.value >= 0x20 || $0.value == 0x0A }.map(Character.init)
    return String(String(visible).suffix(80))
  }

  private func waitForShellSize(
    matching grid: () -> (cols: Int, rows: Int),
    marker: String,
    session: ConsoleSession,
    sessionID: SessionID,
    supervisor: ProcessSupervisor
  ) async throws -> (cols: Int, rows: Int) {
    let deadline = ContinuousClock.now + .seconds(5)
    var attempt = 0
    var last = ""
    while ContinuousClock.now < deadline {
      attempt += 1
      let token = "\(marker)\(attempt) "
      session.send(Data("printf '\(token)'; /bin/stty size\r".utf8))
      let appear = min(deadline, ContinuousClock.now + .seconds(1))
      while ContinuousClock.now < appear {
        last = String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self)
        if let size = Self.lastSize(marker: token, in: last) {
          let wanted = grid()
          if size.cols == wanted.cols && size.rows == wanted.rows { return size }
          break
        }
        try await Task.sleep(for: .milliseconds(30))
      }
    }
    XCTFail("stty did not match \(grid()). tail=\(last.suffix(500))")
    return (0, 0)
  }

  private func waitForZeroRun(sessionID: SessionID, supervisor: ProcessSupervisor) async throws -> Int {
    let deadline = ContinuousClock.now + .seconds(4)
    var last = ""
    while ContinuousClock.now < deadline {
      last = String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self)
      if let count = Self.zeroCount(after: "ZRUN", in: last), count > 0 { return count }
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTFail("missing zero run. tail=\(last.suffix(500))")
    return 0
  }

  private static func lastSize(marker: String, in text: String) -> (cols: Int, rows: Int)? {
    var search = Substring(text)
    var found: (cols: Int, rows: Int)?
    while let range = search.range(of: marker) {
      let tail = search[range.upperBound...]
      if let size = leadingSize(in: tail) { found = (cols: size.cols, rows: size.rows) }
      search = tail
    }
    return found
  }

  private static func leadingSize(in text: Substring) -> (rows: Int, cols: Int)? {
    var digits: [Int] = []
    var current = ""
    var started = false
    for character in text {
      if character.isNumber {
        started = true
        current.append(character)
      } else if started {
        if let value = Int(current) { digits.append(value) }
        current = ""
        if digits.count == 2 { break }
        if character != " " && character != "\t" && character != "\r" && character != "\n" { return nil }
      } else if character != " " && character != "\t" && character != "\r" && character != "\n" {
        return nil
      }
    }
    if digits.count < 2, let value = Int(current) { digits.append(value) }
    guard digits.count >= 2 else { return nil }
    return (digits[0], digits[1])
  }

  private static func zeroCount(after marker: String, in text: String) -> Int? {
    guard let range = text.range(of: marker, options: .backwards) else { return nil }
    var count = 0
    var started = false
    for character in text[range.upperBound...] {
      if character == "0" {
        started = true
        count += 1
      } else if started {
        break
      } else if character == " " || character == "\t" {
        continue
      } else {
        break
      }
    }
    return started ? count : nil
  }

  func testCardResizeDragGrowsDownwardAndIncrementHopsToMainActor() async {
    let downRight = CardResizeMath.translation(from: CGPoint(x: 10, y: 80), to: CGPoint(x: 40, y: 50))
    XCTAssertEqual(downRight.width, 30)
    XCTAssertEqual(downRight.height, 30)
    let upLeft = CardResizeMath.translation(from: CGPoint(x: 40, y: 50), to: CGPoint(x: 10, y: 80))
    XCTAssertEqual(upLeft.width, -30)
    XCTAssertEqual(upLeft.height, -30)
    let grip = CardResizeGripView()
    var amounts: [CGFloat] = []
    grip.onAdjust = { amounts.append($0) }
    XCTAssertTrue(grip.accessibilityPerformIncrement())
    XCTAssertTrue(grip.accessibilityPerformDecrement())
    let deadline = ContinuousClock.now + .seconds(1)
    while amounts.count < 2 && ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(amounts, [32, -32])
  }

  func testCanvasPanFollowsPointerAndScrollDirection() {
    let down = CanvasPan.drag(deltaX: 0, deltaY: -12)
    XCTAssertEqual(down.x, 0)
    XCTAssertEqual(down.y, 12)
    let up = CanvasPan.drag(deltaX: 4, deltaY: 8)
    XCTAssertEqual(up.x, 4)
    XCTAssertEqual(up.y, -8)
    let notch = CanvasPan.scroll(deltaX: -1, deltaY: 2, precise: false)
    XCTAssertEqual(notch.x, -12)
    XCTAssertEqual(notch.y, 24)
    let trackpad = CanvasPan.scroll(deltaX: 3, deltaY: -5, precise: true)
    XCTAssertEqual(trackpad.x, 3)
    XCTAssertEqual(trackpad.y, -5)
  }

  func testNewTerminalRemembersAgentAndDirectoryAndRejectsTheRestOfTheCatalog() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let fallback = root.appendingPathComponent("fallback", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent(".zshenv"))
    try Data().write(to: root.appendingPathComponent(".zprofile"))
    try Data().write(to: root.appendingPathComponent(".zlogin"))
    try Data("PROMPT='READY> '\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
    let file = root.appendingPathComponent("note.txt")
    try Data("x".utf8).write(to: file)
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root.appendingPathComponent("workspaces", isDirectory: true)),
      processEnvironment: [
        "HOME": root.path, "ZDOTDIR": root.path, "SHELL": "/bin/zsh",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      ],
      usageTracker: usageTracker(root),
      settings: settings(root)
    )
    addTeardownBlock {
      await board.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    board.settings.setDefaultWorkingDirectory(fallback)
    XCTAssertNil(board.createConsoleFromNewTerminal(agentID: "opencode", directory: project))
    XCTAssertNil(board.createConsoleFromNewTerminal(agentID: "shell", directory: file))
    XCTAssertTrue(board.workspace?.nodes.isEmpty == true)
    XCTAssertEqual(board.newTerminalError, "Choose a folder that exists.")
    let id = try XCTUnwrap(board.createConsoleFromNewTerminal(agentID: "shell", directory: project))
    let resolved = project.resolvingSymlinksInPath().path
    XCTAssertEqual(board.workspace?.nodes.first { $0.id == id }?.cwd.resolvingSymlinksInPath().path, resolved)
    XCTAssertEqual(board.settings.preferences.lastUsedAgentID, "shell")
    XCTAssertEqual(board.settings.preferences.recentWorkingDirectories.first?.resolvingSymlinksInPath().path, resolved)
    let draft = board.settings.newTerminalDraft(homeDirectory: root)
    XCTAssertEqual(draft.selectedAgentID, "shell")
    XCTAssertEqual(draft.selectedDirectoryPath, resolved)
    XCTAssertFalse(board.showingNewTerminal)
    let started = ContinuousClock.now + .seconds(6)
    while board.sessions[id]?.isRunning != true && ContinuousClock.now < started {
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertEqual(board.sessions[id]?.isRunning, true)
    await board.closeConsole(id)
  }

  func testOrchestratorAsksBeforeSendingThenReportsShellOutput() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent(".zshenv"))
    try Data().write(to: root.appendingPathComponent(".zprofile"))
    try Data().write(to: root.appendingPathComponent(".zlogin"))
    try Data("unset RPROMPT\nPROMPT='> '\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
    let supervisor = ProcessSupervisor()
    let board = BoardViewModel(
      store: WorkspaceStore(rootURL: root.appendingPathComponent("workspaces", isDirectory: true)),
      supervisor: supervisor,
      processEnvironment: [
        "HOME": root.path, "ZDOTDIR": root.path, "SHELL": "/bin/zsh",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      ],
      usageTracker: usageTracker(root),
      settings: settings(root)
    )
    addTeardownBlock {
      await board.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    XCTAssertTrue(board.settings.preferences.askBeforeSendingToTerminal)
    XCTAssertTrue(board.installedLaunchExecutable(agentID: "orchestrator"))
    XCTAssertEqual(board.availableAgentTemplates.first?.id, "orchestrator")
    let orchestrator = board.createAndStartConsole(agentID: "orchestrator", cwd: root)
    let shell = board.createAndStartConsole(agentID: "shell", cwd: root)
    let started = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < started {
      if board.orchestratorTranscripts[orchestrator]?.contains("Orchestrator ready") == true,
        board.sessions[shell]?.isRunning == true { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertNil(board.sessions[orchestrator])
    let session = try XCTUnwrap(board.sessions[shell])
    XCTAssertEqual(session.isRunning, true)
    let sessionID = try XCTUnwrap(session.sessionID)
    try await waitForStatus(.idle, session: session, timeout: .seconds(8))
    board.setOrchestratorDraft(orchestrator, "list")
    board.submitOrchestratorDraft(orchestrator)
    XCTAssertTrue(board.orchestratorTranscripts[orchestrator]?.contains("Shell —") == true)

    board.setOrchestratorDraft(orchestrator, "send Shell echo lanebay-deny-7")
    board.submitOrchestratorDraft(orchestrator)
    let approval = try XCTUnwrap(board.orchestratorApprovals.first)
    XCTAssertEqual(approval.targetTitle, "Shell")
    XCTAssertEqual(approval.text, "echo lanebay-deny-7")
    XCTAssertEqual(board.orchestratorStatuses[orchestrator], .waitingForInput)
    board.noteOrchestratorProgress(target: shell, hook: .permissionRequest)
    XCTAssertEqual(board.orchestratorApprovals.first?.id, approval.id)
    var deniedOutput = String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self)
    XCTAssertFalse(deniedOutput.contains("lanebay-deny-7"))
    XCTAssertTrue(board.denyOrchestratorSend(approval.id))
    deniedOutput = String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self)
    XCTAssertFalse(deniedOutput.contains("lanebay-deny-7"))
    XCTAssertTrue(board.orchestratorApprovals.isEmpty)
    XCTAssertEqual(board.orchestratorLinks.first { $0.targetID == shell }?.status, .denied)

    board.settings.setAskBeforeSendingToTerminal(false)
    board.setOrchestratorDraft(orchestrator, "send Shell echo lanebay-open-7")
    board.submitOrchestratorDraft(orchestrator)
    XCTAssertTrue(board.orchestratorApprovals.isEmpty)
    let opened = ContinuousClock.now + .seconds(8)
    var openTranscript = ""
    var openOutput = ""
    while ContinuousClock.now < opened {
      openTranscript = board.orchestratorTranscripts[orchestrator] ?? ""
      openOutput = String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self)
      if openTranscript.contains("lanebay-open-7") { break }
      try await Task.sleep(for: .milliseconds(40))
    }
    XCTAssertTrue(
      openOutput.contains("lanebay-open-7"),
      "status=\(session.status) output=\(openOutput.suffix(500)) transcript=\(openTranscript)")
    XCTAssertTrue(openTranscript.contains("lanebay-open-7"), "status=\(session.status) transcript=\(openTranscript)")

    board.settings.setAskBeforeSendingToTerminal(true)
    board.setOrchestratorDraft(orchestrator, "send Shell echo sub-ok")
    board.submitOrchestratorDraft(orchestrator)
    let send = try XCTUnwrap(board.orchestratorApprovals.first)
    XCTAssertEqual(send.text, "echo sub-ok")
    let before = String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self)
    XCTAssertFalse(before.contains("sub-ok"))
    XCTAssertTrue(board.approveOrchestratorSend(send.id))
    board.noteOrchestratorProgress(target: shell, hook: .permissionRequest)
    XCTAssertTrue(board.orchestratorApprovals.isEmpty)
    let finished = ContinuousClock.now + .seconds(12)
    var transcript = ""
    var output = ""
    while ContinuousClock.now < finished {
      transcript = board.orchestratorTranscripts[orchestrator] ?? ""
      output = String(decoding: try await supervisor.scrollback(for: sessionID), as: UTF8.self)
      if transcript.contains("sub-ok"), output.contains("sub-ok") { break }
      try await Task.sleep(for: .milliseconds(40))
    }
    XCTAssertTrue(output.contains("sub-ok"), output)
    XCTAssertTrue(transcript.contains("sub-ok"), transcript)
    XCTAssertTrue(transcript.contains("Nothing was sent in reply."), transcript)
    XCTAssertEqual(board.orchestratorLinks.first { $0.targetID == shell }?.status, .done)
    await board.closeConsole(orchestrator)
    XCTAssertNil(board.orchestratorTranscripts[orchestrator])
    XCTAssertFalse(board.orchestratorLinks.contains { $0.orchestratorID == orchestrator })
  }
}

@MainActor
private final class FloodObservation {
  var stop = false
  func finish() { stop = true }
}

@MainActor
private final class RailClickFlags {
  var add = false
  var group = false
  var manage = false
}

@MainActor
private enum RetainedTestWindows {
  static var windows: [NSWindow] = []
  static var views: [NSView] = []
  static func keep(_ window: NSWindow) { windows.append(window) }
  static func keep(_ view: NSView) { views.append(view) }
}
