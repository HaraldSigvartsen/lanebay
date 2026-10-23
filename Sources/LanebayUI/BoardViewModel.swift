import AppKit
import Foundation
import LanebayCore
import Observation
import UserNotifications

@MainActor public protocol AgentNotificationSending {
  func notify(title: String, body: String)
}

@MainActor public protocol LoopGoalChecking {
  func isComplete(goal: String, output: String) -> Bool
}

@MainActor public struct MarkerLoopGoalChecker: LoopGoalChecking {
  public init() {}
  public func isComplete(goal: String, output: String) -> Bool { output.localizedCaseInsensitiveContains(goal) }
}

@MainActor public final class MacAgentNotifier: AgentNotificationSending {
  public init() {}
  public func notify(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }
}

struct WaitingForInputNotificationState {
  private var notified: Set<UUID> = []
  mutating func transition(id: UUID, from old: AgentStatus, to new: AgentStatus) -> Bool {
    guard new == .waitingForInput else { notified.remove(id); return false }
    guard old != .waitingForInput else { return false }
    return notified.insert(id).inserted
  }
}

public enum ConsoleAgent: String, CaseIterable, Identifiable, Sendable {
  case shell, codex, claude, opencode
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .shell: "Shell"
    case .codex: "Codex"
    case .claude: "Claude Code"
    case .opencode: "OpenCode"
    }
  }

  var executable: String {
    self == .shell ? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" : rawValue
  }
}

struct ConsoleLaunchTemplate: Sendable {
  let id: String
  let title: String
  let executable: String
  let arguments: [String]
}

/// Keeps console headers inside the canvas when a saved layout would open above or fully outside the window.
public enum BoardViewport {
  public static let revealMargin = 32.0

  public struct Pan: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
  }

  public static func panToReveal(
    frames: [NodeFrame],
    zoom: Double,
    panX: Double,
    panY: Double,
    viewportWidth: Double,
    viewportHeight: Double,
    margin: Double = revealMargin
  ) -> Pan {
    let frames = frames.filter {
      $0.x.isFinite && $0.y.isFinite && $0.w.isFinite && $0.h.isFinite && $0.w > 0 && $0.h > 0
    }
    guard zoom.isFinite, zoom > 0, margin.isFinite,
      viewportWidth.isFinite, viewportHeight.isFinite, viewportWidth > 0, viewportHeight > 0,
      panX.isFinite, panY.isFinite, !frames.isEmpty
    else { return Pan(x: panX, y: panY) }

    let minX = frames.map { $0.x * zoom + panX }.min()!
    let minY = frames.map { $0.y * zoom + panY }.min()!
    let maxX = frames.map { ($0.x + $0.w) * zoom + panX }.max()!
    let maxY = frames.map { ($0.y + $0.h) * zoom + panY }.max()!
    let intersects = maxX > 0 && minX < viewportWidth && maxY > 0 && minY < viewportHeight
    let headersInside = minY >= 0 && minY < viewportHeight
    if headersInside && intersects { return Pan(x: panX, y: panY) }

    let worldMinX = frames.map(\.x).min()!
    let worldMinY = frames.map(\.y).min()!
    return Pan(x: margin - worldMinX * zoom, y: margin - worldMinY * zoom)
  }
}

/// True when a launch executable is an absolute executable file, or a bare name on PATH.
enum ConsoleExecutableLookup {
  static func isInstalled(_ executable: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> Bool {
    if executable.hasPrefix("/") {
      return AgentCatalog.isExecutableFile(URL(fileURLWithPath: executable))
    }
    let resolved = ProcessSupervisor.resolveExecutable(executable, path: path)
    guard resolved.hasPrefix("/") else { return false }
    return AgentCatalog.isExecutableFile(URL(fileURLWithPath: resolved))
  }
}

/// Resolves a one-shot window snapshot written only for a `dist/Lanebay.app` launch.
public enum SnapshotCapturePath {
  public static func destination(bundleURL: URL, markerContents: String) -> URL? {
    let app = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    guard app.lastPathComponent == "Lanebay.app" else { return nil }
    let dist = app.deletingLastPathComponent()
    guard dist.lastPathComponent == "dist" else { return nil }
    let repo = dist.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    guard repo.path != "/" else { return nil }
    let name = markerContents.trimmingCharacters(in: .whitespacesAndNewlines)
    guard name.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression) != nil else { return nil }
    let screens = repo.appendingPathComponent("agent/screens", isDirectory: true).standardizedFileURL
    let destination = screens.appendingPathComponent(name, isDirectory: true).standardizedFileURL
    guard destination.deletingLastPathComponent().path == screens.path else { return nil }
    guard destination.path.hasPrefix(repo.path + "/") else { return nil }
    return destination
  }
}

/// A console-flow launch may reuse a home directory only when that directory is already inside the system temp folder.
public enum FlowLaunchHome {
  public static func accepted(path: String, temporaryDirectory: URL) -> URL? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 512, !trimmed.contains("\0"), !trimmed.contains(".."),
      trimmed.hasPrefix("/")
    else { return nil }
    let candidate = URL(fileURLWithPath: trimmed, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    let temporary = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let prefix = temporary.path.hasSuffix("/") ? temporary.path : temporary.path + "/"
    guard candidate.path.hasPrefix(prefix) else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    return candidate
  }
}

@MainActor @Observable
public final class BoardViewModel {
  public private(set) var workspaces: [Workspace] = []
  public private(set) var activeWorkspaceID: UUID?
  public private(set) var selectedNodeIDs: Set<UUID> = []
  public private(set) var focusedNodeID: UUID?
  public private(set) var zoom = 1.0
  public private(set) var panX = 0.0
  public private(set) var panY = 0.0
  /// Bumped so the board can close sheets it owns. Accessibility walks must not meet an open sheet.
  public private(set) var presentedChromeDismissals = 0
  public private(set) var sessions: [UUID: ConsoleSession] = [:]
  public var errorMessage: String?
  /// Shown on the card when a create/start did not launch a process.
  public private(set) var consoleLaunchErrors: [UUID: String] = [:]
  public private(set) var orchestratorTranscripts: [UUID: String] = [:]
  public private(set) var orchestratorStatuses: [UUID: AgentStatus] = [:]
  public private(set) var orchestratorDrafts: [UUID: String] = [:]
  public private(set) var orchestratorApprovals: [OrchestratorApprovalRequest] = []
  public private(set) var orchestratorLinks: [OrchestratorLink] = []

  @ObservationIgnored private let store: WorkspaceStore
  @ObservationIgnored private let supervisor: ProcessSupervisor
  @ObservationIgnored private let autosaveDelay: Duration
  @ObservationIgnored private let notifier: AgentNotificationSending
  @ObservationIgnored private let processEnvironment: [String: String]
  @ObservationIgnored private let goalChecker: any LoopGoalChecking
  @ObservationIgnored private let usageTracker: UsageStatsTracker
  @ObservationIgnored private let statusSpeaker: VoiceStatusSpeaking
  @ObservationIgnored public let settings: SettingsViewModel
  @ObservationIgnored private let executableIsInstalled: @Sendable (String) -> Bool
  @ObservationIgnored private let sleep: @MainActor @Sendable (Duration) async -> Void
  @ObservationIgnored private var notificationState = WaitingForInputNotificationState()
  @ObservationIgnored private var isShuttingDown = false
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var dirtyWorkspaceIDs: Set<UUID> = []
  @ObservationIgnored private var loopTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var outputBuffers: [UUID: String] = [:]
  @ObservationIgnored private var pendingMatches: Set<UUID> = []
  @ObservationIgnored private var goalBuffers: [UUID: String] = [:]
  @ObservationIgnored private var loopClock: @Sendable () -> Date = { .now }
  @ObservationIgnored private var viewports: [UUID: (Double, Double, Double)] = [:]
  @ObservationIgnored private var viewportRevealed: Set<UUID> = []
  /// Bumped by close and restart so an in-flight restart cannot start after the card is gone.
  @ObservationIgnored private var consoleEpoch: [UUID: Int] = [:]
  @ObservationIgnored private var orchestratorWatches: [OrchestratorWatch] = []

  public let homeDirectory: URL
  public var workspace: Workspace? { workspaces.first { $0.id == activeWorkspaceID } }
  var activeLoopTimerIDs: Set<UUID> { Set(loopTasks.keys) }

  /// App board. Workspaces, preferences, and usage stay in one Application Support directory under `homeDirectory`.
  public static func live(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    statusSpeaker: VoiceStatusSpeaking = SilentVoiceStatusSpeaker()
  ) -> BoardViewModel {
    let support = PanelStorage.supportRoot(homeDirectory: homeDirectory)
    return BoardViewModel(
      store: WorkspaceStore(rootURL: support.appendingPathComponent("workspaces", isDirectory: true)),
      usageTracker: UsageStatsTracker(store: UsageStatsStore(rootURL: support)),
      statusSpeaker: statusSpeaker,
      settings: SettingsViewModel(store: AppPreferencesStore(rootURL: support)),
      homeDirectory: homeDirectory
    )
  }

  func installSessionForTesting(_ session: ConsoleSession, id: UUID) { sessions[id] = session }
  func setShuttingDownForTesting(_ value: Bool) { isShuttingDown = value }
  public var commandDestination: String? {
    if selectedNodeIDs.count > 1 { return "\(selectedNodeIDs.count) selected consoles" }
    return workspace?.nodes.first { selectedNodeIDs.contains($0.id) }?.title
  }
  public var canSendCommand: Bool {
    !selectedNodeIDs.isEmpty && selectedNodeIDs.allSatisfy { sessions[$0]?.isRunning == true }
  }
  var availableAgentTemplates: [ConsoleLaunchTemplate] {
    let orchestrator = ConsoleLaunchTemplate(
      id: OrchestratorKind.agentID, title: OrchestratorKind.title, executable: "", arguments: [])
    let known = AgentCatalog.knownCLIs.map {
      ConsoleLaunchTemplate(
        id: $0.id, title: $0.displayName, executable: $0.executableName, arguments: $0.defaultArguments)
    }
    let custom = settings.preferences.customExecutables.map {
      ConsoleLaunchTemplate(
        id: $0.id, title: $0.displayName, executable: $0.executablePath, arguments: $0.arguments)
    }
    return [orchestrator] + known + custom
  }
  /// A group is the selected consoles. An empty selection would save a group the map cannot draw.
  public var canCreateGroup: Bool {
    workspace != nil && !selectedNodeIDs.isEmpty
  }

  public var idleConsoleIDs: Set<UUID> {
    let activeNodeIDs = Set(workspace?.nodes.map(\.id) ?? [])
    let running = Set(sessions.compactMap { $0.value.isRunning ? $0.key : nil })
    let idle = Set(sessions.compactMap { $0.value.status == .idle ? $0.key : nil })
    return Self.idleRecipients(activeNodeIDs: activeNodeIDs, runningIDs: running, idleIDs: idle)
  }

  static func idleRecipients(activeNodeIDs: Set<UUID>, runningIDs: Set<UUID>, idleIDs: Set<UUID>) -> Set<UUID> {
    activeNodeIDs.intersection(runningIDs).intersection(idleIDs)
  }

  static func hookRecipient(candidates: [(UUID, String?)], event: AgentEvent) -> UUID? {
    guard let eventSessionID = event.sessionID else {
      let unbound = candidates.filter { $0.1 == nil }
      return event.event == .sessionStart && unbound.count == 1 ? unbound[0].0 : nil
    }
    let exact = candidates.filter { $0.1 == eventSessionID }
    if exact.count == 1 { return exact[0].0 }
    if !exact.isEmpty { return nil }
    let unbound = candidates.filter { $0.1 == nil }
    return event.event == .sessionStart && unbound.count == 1 ? unbound[0].0 : nil
  }

  public init(
    store: WorkspaceStore = WorkspaceStore(), supervisor: ProcessSupervisor = ProcessSupervisor(),
    autosaveDelay: Duration = .milliseconds(300), notifier: AgentNotificationSending = MacAgentNotifier(),
    processEnvironment: [String: String] = [:], clock: @escaping @Sendable () -> Date = { .now },
    goalChecker: any LoopGoalChecking = MarkerLoopGoalChecker(),
    usageTracker: UsageStatsTracker = UsageStatsTracker(),
    statusSpeaker: VoiceStatusSpeaking = SilentVoiceStatusSpeaker(),
    settings: SettingsViewModel = SettingsViewModel(),
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    executableIsInstalled: (@Sendable (String) -> Bool)? = nil,
    sleep: @escaping @MainActor @Sendable (Duration) async -> Void = { duration in try? await Task.sleep(for: duration) }
  ) {
    self.store = store
    self.supervisor = supervisor
    self.autosaveDelay = autosaveDelay
    self.notifier = notifier
    self.processEnvironment = processEnvironment
    self.goalChecker = goalChecker
    self.usageTracker = usageTracker
    self.statusSpeaker = statusSpeaker
    self.settings = settings
    self.homeDirectory = homeDirectory
    self.executableIsInstalled = executableIsInstalled ?? { ConsoleExecutableLookup.isInstalled($0) }
    self.sleep = sleep
    self.loopClock = clock
    reload()
  }

  public func reload() {
    guard workspaces.isEmpty else { return }
    do {
      workspaces = try store.list().sorted { $0.createdAt < $1.createdAt }
      errorMessage = nil
      if workspaces.isEmpty {
        _ = createWorkspace()
      } else {
        let preferred = settings.preferences.restoreLastWorkspace
          ? workspaces.first(where: { $0.id == settings.preferences.lastWorkspaceID })?.id : nil
        switchWorkspace(preferred ?? workspaces[0].id)
      }
    } catch { errorMessage = error.localizedDescription }
  }

  @discardableResult
  public func createWorkspace(name: String = "Workspace") -> UUID {
    createWorkspace(name: name, repos: [])
  }

  @discardableResult
  public func createWorkspace(name: String = "Workspace", repos: [URL]) -> UUID {
    let workspace = Workspace(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Workspace" : name,
      repos: repos)
    workspaces.append(workspace)
    switchWorkspace(workspace.id)
    changed(workspace.id)
    return workspace.id
  }

  public func renameWorkspace(_ id: UUID, name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
    workspaces[index].name = name
    changed(id)
  }

  public func switchWorkspace(_ id: UUID) {
    guard workspaces.contains(where: { $0.id == id }) else { return }
    if let current = activeWorkspaceID { viewports[current] = (zoom, panX, panY) }
    activeWorkspaceID = id
    if let workspace = workspace { usageTracker.workspaceDidChange(id: workspace.id, name: workspace.name, at: loopClock()) }
    settings.recordActiveWorkspace(id)
    (zoom, panX, panY) = viewports[id] ?? (1, 0, 0)
    selectedNodeIDs = []
    focusedNodeID = nil
    reconcileLoopTimers()
    for target in idleConsoleIDs { consumePendingMatches(target: target) }
  }

  @discardableResult
  public func addConsole(
    agent: ConsoleAgent, cwd: URL? = nil
  ) -> UUID {
    addConsole(agentID: agent.rawValue, cwd: cwd)
  }

  @discardableResult
  public func addConsole(agentID: String, profileID: String? = nil, cwd: URL? = nil) -> UUID {
    let template = availableAgentTemplates.first(where: { $0.id == agentID })
    let offset = Double((workspace?.nodes.count ?? 0) % 8) * 32
    let node = Node(
      kind: .console, agentID: agentID, cwd: cwd ?? settings.preferences.defaultWorkingDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
      frame: NodeFrame(
        x: -panX / zoom + 32 + offset, y: -panY / zoom + 32 + offset, w: 480, h: 320),
      profileID: profileID,
      title: template?.title ?? "Console", notStarted: true)
    editWorkspace { $0.nodes.append(node) }
    select(node.id)
    return node.id
  }

  /// The agent menu uses this. A new console starts immediately; a restored card stays not started until Start.
  @discardableResult
  public func createAndStartConsole(agentID: String, profileID: String? = nil, cwd: URL? = nil) -> UUID {
    let id = addConsole(agentID: agentID, profileID: profileID, cwd: cwd)
    Task { await startConsole(id) }
    return id
  }

  public func installedLaunchExecutable(agentID: String) -> Bool {
    if agentID == OrchestratorKind.agentID { return true }
    guard let template = availableAgentTemplates.first(where: { $0.id == agentID }) else { return false }
    return executableIsInstalled(launchExecutable(for: template))
  }

  public func moveNode(_ id: UUID, x: Double, y: Double) {
    guard x.isFinite, y.isFinite else { return }
    editNode(id) {
      $0.frame.x = x
      $0.frame.y = y
    }
  }

  public func resizeNode(_ id: UUID, width: Double, height: Double) {
    guard width.isFinite, height.isFinite else { return }
    editNode(id) {
      $0.frame.w = max(280, width)
      $0.frame.h = max(160, height)
    }
  }

  @discardableResult
  public func createGroup(name: String, color: String = "accent", nodeIDs: Set<UUID>? = nil) -> UUID? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let workspace else { return nil }
    let validIDs = Set(workspace.nodes.map(\.id))
    let members = (nodeIDs ?? selectedNodeIDs).intersection(validIDs)
    guard !members.isEmpty else { return nil }
    let group = Group(name: name, nodeIDs: workspace.nodes.map(\.id).filter(members.contains), color: color)
    editWorkspace { $0.groups.append(group) }
    return group.id
  }

  public func renameGroup(_ id: UUID, name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    editGroup(id) { $0.name = name }
  }

  public func setGroupMembers(_ id: UUID, nodeIDs: Set<UUID>) {
    guard let validIDs = workspace.map({ Set($0.nodes.map(\.id)) }) else { return }
    editGroup(id) {
      $0.nodeIDs = nodeIDs.filter(validIDs.contains).sorted { $0.uuidString < $1.uuidString }
      if let lead = $0.leadNodeID, !$0.nodeIDs.contains(lead) { $0.leadNodeID = nil }
    }
  }

  public func setGroupLead(_ groupID: UUID, nodeID: UUID?) {
    guard let group = workspace?.groups.first(where: { $0.id == groupID }) else { return }
    if let nodeID {
      guard group.nodeIDs.contains(nodeID), workspace?.nodes.contains(where: { $0.id == nodeID && $0.kind == .console }) == true else { return }
    }
    editGroup(groupID) { $0.leadNodeID = nodeID }
  }

  @discardableResult
  public func sendToLead(_ text: String, groupID: UUID) -> Bool {
    guard let group = workspace?.groups.first(where: { $0.id == groupID }),
      let lead = group.leadNodeID, idleConsoleIDs.contains(lead),
      sessions[lead]?.isRunning == true, sessions[lead]?.isClosed == false else { return false }
    return broadcast(text, to: [lead])
  }

  /// Writes bytes to a running console. Does not wait for an idle prompt.
  @discardableResult
  public func writeToConsole(_ text: String, nodeID: UUID) -> Bool {
    guard let session = sessions[nodeID], session.isRunning, !session.isClosed else { return false }
    session.send(Data(text.utf8))
    return true
  }

  @discardableResult public func sendToConsole(_ text: String, nodeID: UUID) -> Bool {
    guard idleConsoleIDs.contains(nodeID), sessions[nodeID]?.isClosed == false else { return false }
    return broadcast(text, to: [nodeID])
  }

  public func recentConsoleOutput(_ nodeID: UUID, maxBytes: Int = 2_048) -> String? {
    if let session = sessions[nodeID], session.isRunning {
      let data = session.recentOutput
      guard !data.isEmpty else { return nil }
      return String(decoding: data.suffix(max(1, maxBytes)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let transcript = orchestratorTranscripts[nodeID], !transcript.isEmpty else { return nil }
    return String(transcript.suffix(max(1, maxBytes)))
  }

  /// Columns and rows the terminal view is drawing. Nil until the view exists.
  public func consoleGrid(for nodeID: UUID) -> (columns: Int, rows: Int)? {
    sessions[nodeID]?.currentGrid()
  }

  /// Kernel PTY size. This is what `stty size` reads.
  public func consolePtyWindow(for nodeID: UUID) async -> (columns: Int, rows: Int)? {
    guard let id = sessions[nodeID]?.sessionID else { return nil }
    guard let size = try? await supervisor.windowSize(for: id) else { return nil }
    return (Int(size.columns), Int(size.rows))
  }

  @discardableResult
  public func broadcastToGroup(_ text: String, groupID: UUID) -> Bool {
    guard let group = workspace?.groups.first(where: { $0.id == groupID }) else { return false }
    return broadcast(text, to: Set(group.nodeIDs).intersection(idleConsoleIDs))
  }

  public func deleteGroup(_ id: UUID) {
    editWorkspace { $0.groups.removeAll { $0.id == id } }
  }

  public var showingNewTerminal = false
  public private(set) var newTerminalError: String?

  public func beginNewTerminal() {
    guard workspace != nil else { return }
    newTerminalError = nil
    showingNewTerminal = true
  }

  /// Creates a console from the New terminal sheet and remembers the agent and folder.
  @discardableResult
  public func createConsoleFromNewTerminal(agentID: String, directory: URL) -> UUID? {
    guard workspace != nil else {
      newTerminalError = "Open a workspace first."
      return nil
    }
    guard settings.offersNewTerminalAgent(agentID) else {
      newTerminalError = "Choose an agent."
      return nil
    }
    guard let directory = settings.validatedWorkingDirectory(directory) else {
      newTerminalError = "Choose a folder that exists."
      return nil
    }
    let id = createAndStartConsole(agentID: agentID, cwd: directory)
    _ = settings.rememberNewTerminal(agentID: agentID, directory: directory)
    newTerminalError = nil
    showingNewTerminal = false
    return id
  }

  public func dismissPresentedChrome() {
    presentedChromeDismissals += 1
    showingNewTerminal = false
  }

  public func pan(dx: Double, dy: Double) {
    guard dx.isFinite, dy.isFinite else { return }
    panX += dx
    panY += dy
  }

  /// Once per workspace show, shift the default pan so console headers are not above the canvas.
  /// An empty board does not consume that one shot: consoles added later are placed in view.
  public func revealConsolesInViewport(width: Double, height: Double) {
    guard width >= 320, height >= 240, let id = activeWorkspaceID else { return }
    guard !viewportRevealed.contains(id) else { return }
    let frames = (workspace?.nodes ?? []).filter { $0.kind == .console }.map(\.frame)
    guard !frames.isEmpty else { return }
    let pan = BoardViewport.panToReveal(
      frames: frames, zoom: zoom, panX: panX, panY: panY,
      viewportWidth: width, viewportHeight: height)
    panX = pan.x
    panY = pan.y
    viewportRevealed.insert(id)
  }

  public func setZoom(_ value: Double, anchorX: Double = 0, anchorY: Double = 0) {
    guard value.isFinite, anchorX.isFinite, anchorY.isFinite else { return }
    let clamped = min(2, max(0.25, value))
    let ratio = clamped / zoom
    panX = anchorX - (anchorX - panX) * ratio
    panY = anchorY - (anchorY - panY) * ratio
    zoom = clamped
  }

  public func select(_ id: UUID?, extending: Bool = false) {
    guard let id else {
      selectedNodeIDs = []
      focusedNodeID = nil
      return
    }
    guard workspace?.nodes.contains(where: { $0.id == id }) == true else { return }
    if extending {
      if !selectedNodeIDs.insert(id).inserted { selectedNodeIDs.remove(id) }
    } else {
      selectedNodeIDs = [id]
    }
  }

  public func focus(_ id: UUID?, selecting: Bool = true) {
    focusedNodeID = id
    if selecting, let id, !selectedNodeIDs.contains(id) { select(id) }
  }

  public func startConsole(_ id: UUID) async {
    guard !isShuttingDown, sessions[id] == nil,
      let node = workspace?.nodes.first(where: { $0.id == id && $0.kind == .console })
    else { return }
    let workspaceID = activeWorkspaceID
    let requestedAgentID = node.agentID ?? "shell"
    if requestedAgentID == OrchestratorKind.agentID {
      beginOrchestrator(id, workspaceID: workspaceID)
      return
    }
    guard let template = availableAgentTemplates.first(where: { $0.id == requestedAgentID }) else {
      if requestedAgentID != "shell" {
        recordLaunchError(id, "Console agent '\(requestedAgentID)' is no longer available. Re-add it in Settings or switch this console to another agent.")
        return
      }
      recordLaunchError(id, "Shell launch template is missing.")
      return
    }
    let executable = launchExecutable(for: template)
    guard executableIsInstalled(executable) else {
      recordLaunchError(id, "\(template.title) is not installed. \(executable) was not found, so nothing was started.")
      return
    }
    consoleLaunchErrors[id] = nil
    let profileEnvironment = settings.preferences.accountProfiles.first(where: {
      $0.id == node.profileID && $0.agentID == template.id
    })?.environment ?? [:]
    let console = ConsoleSession(supervisor: supervisor)
    sessions[id] = console
    console.onSelect = { [weak self] extending in
      guard let self, self.activeWorkspaceID == workspaceID else { return }
      self.select(id, extending: extending)
    }
    console.onFocus = { [weak self] focused in
      guard let self, self.activeWorkspaceID == workspaceID else { return }
      if focused {
        self.focus(id, selecting: !NSEvent.modifierFlags.contains(.shift))
      } else if self.focusedNodeID == id {
        self.focus(nil)
      }
    }
    console.onStatusTransition = { [weak self] oldStatus in
      self?.handleStatusTransition(for: id, from: oldStatus)
      guard let self else { return }
      if self.sessions[id]?.status == .idle {
        self.fireLoops(trigger: .idle, target: id)
        self.consumePendingMatches(target: id)
      }
    }
    console.onOutput = { [weak self] text in self?.handleLoopOutput(text, target: id, workspaceID: workspaceID) }
    await console.start(
      spec: ProcessSpec(
        executable: executable,
        arguments: template.id == "shell" ? ["-l"] : template.arguments,
        environment: ["TERM": "xterm-256color", "COLORTERM": "truecolor"]
          .merging(processEnvironment) { _, override in override }
          .merging(profileEnvironment) { _, profile in profile },
        workingDirectory: node.cwd))
    guard sessions[id] === console, !console.isClosed else { return }
    if let message = console.failureMessage, console.sessionID == nil {
      sessions.removeValue(forKey: id)
      recordLaunchError(id, message)
    } else {
      editNode(id, workspaceID: workspaceID) { $0.notStarted = false }
      if let workspaceID, let workspace = workspaces.first(where: { $0.id == workspaceID }) {
        usageTracker.sessionStarted(
          id: id, workspaceID: workspaceID, workspaceName: workspace.name,
          agent: template.id, status: console.status.rawValue, at: loopClock())
      }
    }
  }

  public func createLoop(name: String = "Loop", targetNodeID: UUID, prompt: String, trigger: LoopTrigger, maxIterations: Int = 10) -> UUID? {
    guard (1...1000).contains(maxIterations) else { return nil }
    let loop = Loop(name: name, targetNodeID: targetNodeID, prompt: prompt, trigger: trigger, maxIterations: maxIterations)
    guard LoopValidator.validate(loop) == nil, workspace?.nodes.contains(where: { $0.id == targetNodeID && $0.kind == .console }) == true else { return nil }
    editWorkspace { $0.loops.append(loop) }
    reconcileLoopTimers()
    // An idle loop created against a console that is already idle has no later
    // transition to wait for. Fire that first iteration now.
    if case .idle = loop.trigger { fireLoop(loop.id) }
    return loop.id
  }

  public func stopLoop(_ id: UUID) {
    loopTasks.removeValue(forKey: id)?.cancel()
    pendingMatches.remove(id)
    editWorkspace { if let i = $0.loops.firstIndex(where: { $0.id == id }) { $0.loops[i].isEnabled = false } }
    reconcileLoopTimers()
  }

  public func checkLoopGoal(_ id: UUID, isComplete: Bool) {
    guard let loop = workspace?.loops.first(where: { $0.id == id }), case .goalCheck = loop.trigger else { return }
    if isComplete { stopLoop(id) } else { fireLoop(id) }
  }

  private func reconcileLoopTimers() {
    let valid = (workspace?.loops ?? []).filter { LoopValidator.validate($0) == nil }
    if let workspaceIndex = workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) {
      for loopIndex in workspaces[workspaceIndex].loops.indices where LoopValidator.validate(workspaces[workspaceIndex].loops[loopIndex]) != nil {
        workspaces[workspaceIndex].loops[loopIndex].isEnabled = false
      }
    }
    let eligible = Set((workspace?.loops ?? []).filter { loop in
      valid.contains(loop) && loop.isEnabled && loop.iterations < loop.maxIterations
        && workspace?.nodes.contains(where: { $0.id == loop.targetNodeID && $0.kind == .console }) == true
        && ({ if case .schedule = loop.trigger { return true }; if case .goalCheck = loop.trigger { return true }; return false }())
    }.map(\.id))
    for id in Array(loopTasks.keys) where !eligible.contains(id) { loopTasks.removeValue(forKey: id)?.cancel() }
    for loop in workspace?.loops ?? [] where eligible.contains(loop.id) && loopTasks[loop.id] == nil { startLoopTimer(loop) }
  }

  private func startLoopTimer(_ loop: Loop) {
    loopTasks[loop.id]?.cancel()
    let seconds: Int
    switch loop.trigger { case .schedule(let value), .goalCheck(let value, _): seconds = value; default: return }
    loopTasks[loop.id] = Task { [weak self] in
      while !Task.isCancelled {
        await self?.sleep(.seconds(seconds))
        guard !Task.isCancelled, let self else { return }
        if case .schedule = loop.trigger { self.fireLoop(loop.id) }
        if case let .goalCheck(_, goal) = loop.trigger {
          let complete = self.goalChecker.isComplete(goal: goal, output: self.goalBuffers[loop.id, default: ""])
          self.checkLoopGoal(loop.id, isComplete: complete)
        }
      }
    }
  }

  func handleLoopOutput(_ text: String, target: UUID, workspaceID: UUID? = nil) {
    guard let ownerID = workspaceID ?? activeWorkspaceID,
      let ownerIndex = workspaces.firstIndex(where: { $0.id == ownerID }) else { return }
    let previous = outputBuffers[target, default: ""]
    var buffer = previous + text
    var previousCount = previous.utf8.count
    if buffer.utf8.count > LoopValidator.maxOutputBytes { buffer = LoopValidator.boundedUTF8Suffix(buffer, limit: LoopValidator.maxOutputBytes) }
    previousCount = max(0, previousCount - max(0, previous.utf8.count + text.utf8.count - buffer.utf8.count))
    outputBuffers[target] = buffer
    noteOrchestratorProgress(target: target)
    let loops = workspaces[ownerIndex].loops
    var matchChecks: [(UUID, String)] = []
    for loop in loops {
      if loop.targetNodeID == target, case .goalCheck = loop.trigger {
        goalBuffers[loop.id, default: ""] += text
        if goalBuffers[loop.id, default: ""].utf8.count > LoopValidator.maxOutputBytes {
          goalBuffers[loop.id] = LoopValidator.boundedUTF8Suffix(goalBuffers[loop.id, default: ""], limit: LoopValidator.maxOutputBytes)
        }
      }
      guard loop.isEnabled else { continue }
      if loop.targetNodeID == target, case .outputMatch(let pattern) = loop.trigger { matchChecks.append((loop.id, pattern)) }
    }
    guard !matchChecks.isEmpty else { return }
    Task.detached(priority: .utility) { [weak self, buffer, previousCount, matchChecks] in
      let matchedIDs = matchChecks.compactMap { id, pattern in
        LoopValidator.hasNewMatch(pattern, output: buffer, previousByteCount: previousCount) ? id : nil
      }
      await self?.dispatchOutputMatches(matchedIDs, workspaceID: ownerID)
    }
  }

  private func dispatchOutputMatches(_ ids: [UUID], workspaceID: UUID) {
    guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
    for id in ids {
      if workspaces[index].loops.contains(where: { $0.id == id && $0.isEnabled }) {
        pendingMatches.insert(id)
      }
    }
    if activeWorkspaceID == workspaceID {
      for id in ids {
        guard let loop = workspaces[index].loops.first(where: { $0.id == id }) else { continue }
        if idleConsoleIDs.contains(loop.targetNodeID) { consumePendingMatches(target: loop.targetNodeID) }
      }
    }
  }

  func consumePendingMatches(target: UUID) {
    let matches = pendingMatches.filter { id in workspace?.loops.contains(where: { $0.id == id && $0.targetNodeID == target && $0.isEnabled }) == true }
    pendingMatches.subtract(matches)
    for id in matches { fireLoop(id) }
  }

  func fireLoops(trigger: LoopTrigger, target: UUID) {
    for loop in workspace?.loops ?? [] where loop.targetNodeID == target && loop.trigger == trigger { fireLoop(loop.id) }
  }

  func fireLoop(_ id: UUID) {
    guard !isShuttingDown, let loop = workspace?.loops.first(where: { $0.id == id }), loop.isEnabled,
      loop.iterations < loop.maxIterations, workspace?.nodes.contains(where: { $0.id == loop.targetNodeID && $0.kind == .console }) == true,
      idleConsoleIDs.contains(loop.targetNodeID), sessions[loop.targetNodeID]?.isRunning == true,
      sessions[loop.targetNodeID]?.isClosed == false else {
        if !isShuttingDown, let loop = workspace?.loops.first(where: { $0.id == id }), loop.isEnabled, loop.iterations < loop.maxIterations,
          workspace?.nodes.contains(where: { $0.id == loop.targetNodeID && $0.kind == .console }) == true,
          case .outputMatch = loop.trigger { pendingMatches.insert(id) }
        return
      }
    sessions[loop.targetNodeID]?.send(Data((loop.prompt + "\r").utf8))
    editWorkspace { if let i = $0.loops.firstIndex(where: { $0.id == id }) {
      $0.loops[i].iterations += 1; $0.loops[i].lastRunAt = loopClock()
      if $0.loops[i].iterations >= $0.loops[i].maxIterations { $0.loops[i].isEnabled = false }
    } }
    if let workspace = workspace {
      usageTracker.recordLoopIteration(workspaceID: workspace.id, workspaceName: workspace.name, at: loopClock())
    }
    reconcileLoopTimers()
  }

  public func closeConsole(_ id: UUID) async {
    _ = bumpConsoleEpoch(id)
    let targetLoopIDs = Set(workspaces.flatMap(\.loops).filter { $0.targetNodeID == id }.map(\.id))
    editWorkspace {
      $0.nodes.removeAll { $0.id == id }
      for index in $0.groups.indices {
        $0.groups[index].nodeIDs.removeAll { $0 == id }
        if $0.groups[index].leadNodeID == id { $0.groups[index].leadNodeID = nil }
      }
    }
    selectedNodeIDs.remove(id)
    consoleLaunchErrors[id] = nil
    if focusedNodeID == id { focusedNodeID = nil }
    for loopID in targetLoopIDs { loopTasks.removeValue(forKey: loopID)?.cancel() }
    pendingMatches.subtract(targetLoopIDs)
    for loopID in targetLoopIDs { goalBuffers.removeValue(forKey: loopID) }
    await releaseConsoleSession(id)
    consoleEpoch.removeValue(forKey: id)
  }

  /// Stops the live process and starts the same card again. The node, group, and lead stay.
  public func restartConsole(_ id: UUID) async {
    guard !isShuttingDown,
      workspace?.nodes.contains(where: { $0.id == id && $0.kind == .console }) == true
    else { return }
    let epoch = bumpConsoleEpoch(id)
    await releaseConsoleSession(id)
    guard !isShuttingDown, consoleEpoch[id] == epoch,
      workspace?.nodes.contains(where: { $0.id == id && $0.kind == .console }) == true
    else { return }
    await startConsole(id)
  }

  private func bumpConsoleEpoch(_ id: UUID) -> Int {
    let next = (consoleEpoch[id] ?? 0) + 1
    consoleEpoch[id] = next
    return next
  }

  /// Ends the process and drops its output. The session stays visible until close finishes so shutdown can join it.
  private func releaseConsoleSession(_ id: UUID) async {
    let console = sessions[id]
    outputBuffers.removeValue(forKey: id)
    let targetLoopIDs = workspaces.flatMap(\.loops).filter { $0.targetNodeID == id }.map(\.id)
    for loopID in targetLoopIDs { goalBuffers.removeValue(forKey: loopID) }
    pendingMatches.subtract(targetLoopIDs)
    console?.onStatusTransition = nil
    console?.onOutput = nil
    console?.onSelect = nil
    console?.onFocus = nil
    detachOrchestrator(around: id)
    await console?.close()
    if sessions[id] === console { sessions.removeValue(forKey: id) }
    if console != nil { usageTracker.sessionEnded(id: id, at: loopClock()) }
    if workspace?.nodes.contains(where: { $0.id == id }) == true {
      editNode(id) { $0.notStarted = true }
    }
  }

  @discardableResult public func sendCommand(_ text: String) -> Bool {
    broadcast(text, to: selectedNodeIDs)
  }

  @discardableResult public func broadcastToIdle(_ text: String) -> Bool { broadcast(text, to: idleConsoleIDs) }

  @discardableResult public func sendPreset(_ text: String, targetAgentKind: String?) -> Bool {
    let recipients = idleConsoleIDs.filter { id in
      guard let node = workspace?.nodes.first(where: { $0.id == id }) else { return false }
      return targetAgentKind == nil || node.agentID == targetAgentKind
    }
    return broadcast(text, to: Set(recipients))
  }

  public var runningDraftTargets: [GitDraftTarget] {
    guard let workspace else { return [] }
    return workspace.nodes.compactMap { node in
      guard node.kind == .console,
        let session = sessions[node.id],
        session.isRunning,
        !session.isClosed else { return nil }
      return GitDraftTarget(id: node.id, title: node.title)
    }
  }

  public var runningScreenshotTargets: [ScreenshotAttachTarget] {
    guard let workspace else { return [] }
    return workspace.nodes.compactMap { node in
      guard node.kind == .console,
        let session = sessions[node.id],
        session.isRunning,
        !session.isClosed else { return nil }
      return ScreenshotAttachTarget(id: node.id, title: node.title)
    }
  }

  @discardableResult
  public func requestCommitDraftFromConsole(_ text: String, nodeID: UUID) -> Bool {
    sendToConsole(text, nodeID: nodeID)
  }

  public func openClonedRepositoryAsWorkspace(_ repositoryURL: URL) {
    let name = repositoryURL.lastPathComponent.isEmpty ? "Workspace" : repositoryURL.lastPathComponent
    _ = createWorkspace(name: name, repos: [repositoryURL])
  }

  public func receive(hook event: AgentEvent) {
    let candidates = sessions.filter { $0.value.matches(hook: event) }
    guard let id = Self.hookRecipient(candidates: candidates.map { ($0.key, $0.value.hookSessionID) }, event: event) else { return }
    receive(hook: event, for: id)
  }

  func receive(hook event: AgentEvent, for nodeID: UUID) {
    guard let session = sessions[nodeID], session.matches(hook: event) else { return }
    let oldStatus = session.status
    session.receive(hook: event)
    handleStatusTransition(for: nodeID, from: oldStatus)
    noteOrchestratorProgress(target: nodeID, hook: event.event)
  }

  func handleStatusTransition(for id: UUID, from oldStatus: AgentStatus) {
    guard let session = sessions[id] else { return }
    noteOrchestratorProgress(target: id)
    usageTracker.sessionStatusChanged(id: id, status: session.status.rawValue, at: loopClock())
    if session.status == .finished || session.status == .error {
      usageTracker.sessionEnded(id: id, at: loopClock())
    }
    guard settings.preferences.showNotifications || settings.preferences.speakWaitingForInputStatus else { return }
    let transitionedToWaitingForInput = notificationState.transition(id: id, from: oldStatus, to: session.status)
    guard transitionedToWaitingForInput else { return }
    let title = "\(workspace?.nodes.first(where: { $0.id == id })?.title ?? "Agent") is waiting for input"
    if settings.preferences.showNotifications {
      notifier.notify(title: title, body: "An agent is waiting for your attention.")
    }
    if settings.preferences.speakWaitingForInputStatus {
      statusSpeaker.speakShortStatus(title)
    }
  }

  @discardableResult private func broadcast(_ text: String, to recipients: Set<UUID>) -> Bool {
    guard !recipients.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
    !isShuttingDown, recipients.allSatisfy({ sessions[$0]?.isRunning == true && sessions[$0]?.isClosed == false }) else {
      return false
    }
    for id in recipients { sessions[id]?.send(Data((text + "\r").utf8)) }
    if let workspace = workspace {
      usageTracker.recordPromptDispatch(
        workspaceID: workspace.id, workspaceName: workspace.name, count: recipients.count, at: loopClock())
    }
    return true
  }

  public func saveNow() throws {
    saveTask?.cancel()
    saveTask = nil
    do {
      for workspace in workspaces where dirtyWorkspaceIDs.contains(workspace.id) {
        try store.save(workspace)
        dirtyWorkspaceIDs.remove(workspace.id)
      }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  public func shutdown() async {
    isShuttingDown = true
    loopTasks.values.forEach { $0.cancel() }; loopTasks.removeAll()
    pendingMatches.removeAll(); outputBuffers.removeAll(); goalBuffers.removeAll()
    for console in sessions.values { console.onStatusTransition = nil; console.onOutput = nil; console.onSelect = nil; console.onFocus = nil }
    do { try saveNow() } catch {
      // Keep the visible save error for retry.
    }
    let consoles = Array(sessions.values)
    for console in consoles { await console.close() }
    sessions.removeAll()
    orchestratorWatches.removeAll()
    orchestratorApprovals.removeAll()
    orchestratorLinks.removeAll()
    orchestratorTranscripts.removeAll()
    orchestratorStatuses.removeAll()
    orchestratorDrafts.removeAll()
  }

  private func launchExecutable(for template: ConsoleLaunchTemplate) -> String {
    template.id == "shell" ? processEnvironment["SHELL"] ?? template.executable : template.executable
  }

  private func recordLaunchError(_ id: UUID, _ message: String) {
    consoleLaunchErrors[id] = message
  }

  private func editNode(_ id: UUID, workspaceID: UUID? = nil, _ edit: (inout Node) -> Void) {
    guard
      let workspaceIndex = workspaces.firstIndex(where: {
        $0.id == (workspaceID ?? activeWorkspaceID)
      }),
      let nodeIndex = workspaces[workspaceIndex].nodes.firstIndex(where: { $0.id == id })
    else { return }
    edit(&workspaces[workspaceIndex].nodes[nodeIndex])
    changed(workspaces[workspaceIndex].id)
  }

  private func editWorkspace(_ edit: (inout Workspace) -> Void) {
    guard let index = workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) else { return }
    edit(&workspaces[index])
    changed(workspaces[index].id)
  }

  private func editGroup(_ id: UUID, _ edit: (inout Group) -> Void) {
    guard let index = workspaces.firstIndex(where: { $0.id == activeWorkspaceID }),
      let groupIndex = workspaces[index].groups.firstIndex(where: { $0.id == id }) else { return }
    edit(&workspaces[index].groups[groupIndex])
    changed(workspaces[index].id)
  }

  private func changed(_ id: UUID) {
    guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
    workspaces[index].updatedAt = .now
    dirtyWorkspaceIDs.insert(id)
    saveTask?.cancel()
    saveTask = Task { [weak self, autosaveDelay] in
      do {
        try await Task.sleep(for: autosaveDelay)
        try self?.saveNow()
      } catch is CancellationError {} catch { self?.errorMessage = error.localizedDescription }
    }
  }
}

private struct OrchestratorWatch {
  var orchestratorID: UUID
  var targetID: UUID
  var linkID: UUID
  var baselineBytes: Int
  var outputGrew: Bool
  var notedWaitingForInput: Bool
}

extension BoardViewModel {
  public func setOrchestratorDraft(_ id: UUID, _ text: String) {
    guard orchestratorTranscripts[id] != nil else { return }
    orchestratorDrafts[id] = String(text.prefix(8_192))
  }

  public func submitOrchestratorDraft(_ id: UUID) {
    let line = orchestratorDrafts[id] ?? ""
    orchestratorDrafts[id] = ""
    performOrchestratorCommand(id, line: line)
  }

  @discardableResult
  public func approveOrchestratorSend(_ approvalID: UUID) -> Bool {
    guard let index = orchestratorApprovals.firstIndex(where: { $0.id == approvalID }) else { return false }
    let approval = orchestratorApprovals.remove(at: index)
    deliverOrchestratorSend(
      orchestratorID: approval.orchestratorID, targetID: approval.targetID,
      title: approval.targetTitle, linkID: approval.linkID, text: approval.text)
    return true
  }

  @discardableResult
  public func denyOrchestratorSend(_ approvalID: UUID) -> Bool {
    guard let index = orchestratorApprovals.firstIndex(where: { $0.id == approvalID }) else { return false }
    let approval = orchestratorApprovals.remove(at: index)
    updateOrchestratorLink(approval.linkID, status: .denied)
    appendOrchestrator(approval.orchestratorID, "Did not send to \(approval.targetTitle).")
    refreshOrchestratorStatus(approval.orchestratorID)
    return true
  }

  func noteOrchestratorProgress(target: UUID, hook: AgentHookEvent? = nil) {
    guard !isShuttingDown else { return }
    let status = sessions[target]?.status.rawValue
      ?? orchestratorStatuses[target]?.rawValue
      ?? AgentStatus.stopped.rawValue
    let bytes = sessions[target]?.outputByteCount ?? 0
    var finished: [(OrchestratorWatch, OrchestratorWaitReason)] = []
    for index in orchestratorWatches.indices where orchestratorWatches[index].targetID == target {
      if bytes > orchestratorWatches[index].baselineBytes {
        orchestratorWatches[index].outputGrew = true
      }
      if hook == .permissionRequest || status == AgentStatus.waitingForInput.rawValue {
        if !orchestratorWatches[index].notedWaitingForInput {
          orchestratorWatches[index].notedWaitingForInput = true
          appendOrchestrator(
            orchestratorWatches[index].orchestratorID,
            "\(consoleTitle(target)) is waiting for input. Nothing was sent in reply.")
        }
      }
      if let reason = OrchestratorWait.consider(
        status: status, outputGrew: orchestratorWatches[index].outputGrew, hook: hook)
      {
        finished.append((orchestratorWatches[index], reason))
      }
    }
    for (watch, reason) in finished {
      completeOrchestratorWatch(watch, reason: reason, status: status)
    }
  }

  private func beginOrchestrator(_ id: UUID, workspaceID: UUID?) {
    guard !isShuttingDown, orchestratorTranscripts[id] == nil,
      workspace?.nodes.contains(where: { $0.id == id && $0.kind == .console }) == true
    else { return }
    orchestratorTranscripts[id] = OrchestratorKind.greeting
    orchestratorDrafts[id] = ""
    orchestratorStatuses[id] = .idle
    consoleLaunchErrors[id] = nil
    editNode(id, workspaceID: workspaceID) { $0.notStarted = false }
    if let workspaceID, let workspace = workspaces.first(where: { $0.id == workspaceID }) {
      usageTracker.sessionStarted(
        id: id, workspaceID: workspaceID, workspaceName: workspace.name,
        agent: OrchestratorKind.agentID, status: AgentStatus.idle.rawValue, at: loopClock())
    }
  }

  private func detachOrchestrator(around id: UUID) {
    let lost = orchestratorWatches.filter { $0.targetID == id && $0.orchestratorID != id }
    for watch in lost {
      appendOrchestrator(watch.orchestratorID, "\(consoleTitle(id)) closed before it finished.")
      updateOrchestratorLink(watch.linkID, status: .failed)
    }
    orchestratorWatches.removeAll { $0.targetID == id || $0.orchestratorID == id }
    let dropped = orchestratorApprovals.filter { $0.targetID == id && $0.orchestratorID != id }
    for approval in dropped {
      appendOrchestrator(approval.orchestratorID, "Did not send to \(approval.targetTitle).")
      updateOrchestratorLink(approval.linkID, status: .denied)
    }
    orchestratorApprovals.removeAll { $0.targetID == id || $0.orchestratorID == id }
    if orchestratorTranscripts[id] != nil {
      usageTracker.sessionEnded(id: id, at: loopClock())
      orchestratorTranscripts[id] = nil
      orchestratorStatuses[id] = nil
      orchestratorDrafts[id] = nil
      orchestratorLinks.removeAll { $0.orchestratorID == id }
    }
    for orchestratorID in Set(lost.map(\.orchestratorID) + dropped.map(\.orchestratorID)) {
      refreshOrchestratorStatus(orchestratorID)
    }
  }

  private func performOrchestratorCommand(_ id: UUID, line: String) {
    guard orchestratorTranscripts[id] != nil else { return }
    switch OrchestratorCommands.parse(line) {
    case let .failure(error):
      appendOrchestrator(id, error.message)
    case .success(.list):
      let lines = orchestratorCatalog().map(OrchestratorSummary.listLine)
      appendOrchestrator(id, lines.isEmpty ? "No consoles." : lines.joined(separator: "\n"))
    case let .success(.send(rest)):
      sendFromOrchestrator(id, rest: rest)
    case let .success(.read(target)):
      quoteOrchestrator(id, query: target, kind: .read)
    case let .success(.wait(target)):
      waitFromOrchestrator(id, query: target)
    case let .success(.summarize(target)):
      quoteOrchestrator(id, query: target, kind: .summarize)
    }
  }

  private enum OrchestratorQuote {
    case read, summarize
  }

  private func sendFromOrchestrator(_ id: UUID, rest: String) {
    let catalog = orchestratorCatalog()
    let split: (target: String, text: String)
    switch OrchestratorCommands.splitSend(rest, titles: catalog.map(\.title)) {
    case let .success(value):
      split = value
    case let .failure(error):
      appendOrchestrator(id, error.message)
      return
    }
    let target: OrchestratorConsoleInfo
    switch OrchestratorTargets.resolve(query: split.target, consoles: catalog) {
    case let .success(value):
      target = value
    case let .failure(error):
      appendOrchestrator(id, error.message)
      return
    }
    let linkID = upsertOrchestratorLink(
      orchestratorID: id, targetID: target.id, title: target.title, status: .pending)
    switch OrchestratorSendGate.decide(
      orchestratorID: id, target: target, text: split.text, linkID: linkID,
      askBeforeSending: settings.preferences.askBeforeSendingToTerminal)
    {
    case let .rejected(message):
      updateOrchestratorLink(linkID, status: .failed)
      appendOrchestrator(id, message)
      refreshOrchestratorStatus(id)
    case let .needsApproval(approval):
      orchestratorApprovals.removeAll { $0.orchestratorID == id && $0.targetID == target.id }
      guard orchestratorApprovals.count < OrchestratorKind.maxPendingApprovals else {
        updateOrchestratorLink(linkID, status: .failed)
        appendOrchestrator(id, "Too many sends are waiting for approval.")
        refreshOrchestratorStatus(id)
        return
      }
      orchestratorApprovals.append(approval)
      appendOrchestrator(id, "Waiting for approval to send to \(target.title).")
      refreshOrchestratorStatus(id)
    case let .deliver(targetID, link, text):
      deliverOrchestratorSend(
        orchestratorID: id, targetID: targetID, title: target.title, linkID: link, text: text)
    }
  }

  private func deliverOrchestratorSend(
    orchestratorID: UUID, targetID: UUID, title: String, linkID: UUID, text: String
  ) {
    let baseline = sessions[targetID]?.outputByteCount ?? 0
    var payload = text
    if !payload.hasSuffix("\r"), !payload.hasSuffix("\n") { payload += "\r" }
    guard writeToConsole(payload, nodeID: targetID) else {
      updateOrchestratorLink(linkID, status: .failed)
      appendOrchestrator(orchestratorID, "\(title) is not running.")
      refreshOrchestratorStatus(orchestratorID)
      return
    }
    updateOrchestratorLink(linkID, status: .waiting)
    orchestratorWatches.removeAll { $0.orchestratorID == orchestratorID && $0.targetID == targetID }
    orchestratorWatches.append(OrchestratorWatch(
      orchestratorID: orchestratorID, targetID: targetID, linkID: linkID,
      baselineBytes: baseline, outputGrew: false, notedWaitingForInput: false))
    appendOrchestrator(orchestratorID, "Sent to \(title). Waiting for it to finish.")
    refreshOrchestratorStatus(orchestratorID)
    noteOrchestratorProgress(target: targetID)
  }

  private func quoteOrchestrator(_ id: UUID, query: String, kind: OrchestratorQuote) {
    switch resolvedOrchestratorTarget(query) {
    case let .failure(error):
      appendOrchestrator(id, error.message)
    case let .success(target):
      let output = orchestratorOutputText(target.id)
      let line: String
      switch kind {
      case .read:
        line = OrchestratorSummary.readReport(title: target.title, output: output)
      case .summarize:
        line = OrchestratorSummary.report(title: target.title, status: target.status, output: output)
      }
      appendOrchestrator(id, line)
    }
  }

  private func waitFromOrchestrator(_ id: UUID, query: String) {
    switch resolvedOrchestratorTarget(query) {
    case let .failure(error):
      appendOrchestrator(id, error.message)
    case let .success(target):
      if target.id == id || target.agentID == OrchestratorKind.agentID {
        appendOrchestrator(id, "\(target.title) cannot take a task.")
        return
      }
      let linkID = upsertOrchestratorLink(
        orchestratorID: id, targetID: target.id, title: target.title, status: .waiting)
      if target.status == AgentStatus.finished.rawValue || target.status == AgentStatus.error.rawValue {
        updateOrchestratorLink(linkID, status: .done)
        appendOrchestrator(id, OrchestratorSummary.report(
          title: target.title, status: target.status, output: orchestratorOutputText(target.id), reason: .exited))
        return
      }
      orchestratorWatches.removeAll { $0.orchestratorID == id && $0.targetID == target.id }
      orchestratorWatches.append(OrchestratorWatch(
        orchestratorID: id, targetID: target.id, linkID: linkID,
        baselineBytes: sessions[target.id]?.outputByteCount ?? 0,
        outputGrew: false, notedWaitingForInput: false))
      appendOrchestrator(id, "Waiting for \(target.title).")
      refreshOrchestratorStatus(id)
      noteOrchestratorProgress(target: target.id)
    }
  }

  private func resolvedOrchestratorTarget(_ query: String) -> Result<OrchestratorConsoleInfo, OrchestratorTargetError> {
    OrchestratorTargets.resolve(query: query, consoles: orchestratorCatalog())
  }

  private func orchestratorCatalog() -> [OrchestratorConsoleInfo] {
    guard let workspace else { return [] }
    return workspace.nodes.compactMap { node -> OrchestratorConsoleInfo? in
      guard node.kind == .console else { return nil }
      let status: String
      if let session = sessions[node.id] {
        status = session.status.rawValue
      } else if let orchestrator = orchestratorStatuses[node.id] {
        status = orchestrator.rawValue
      } else if consoleLaunchErrors[node.id] != nil {
        status = AgentStatus.error.rawValue
      } else {
        status = AgentStatus.stopped.rawValue
      }
      let sessionRunning = sessions[node.id]?.isRunning == true && sessions[node.id]?.isClosed == false
      return OrchestratorConsoleInfo(
        id: node.id,
        title: node.title,
        agentID: node.agentID ?? "",
        status: status,
        running: sessionRunning || orchestratorTranscripts[node.id] != nil)
    }.sorted { lhs, rhs in
      if lhs.title != rhs.title { return lhs.title < rhs.title }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  private func orchestratorOutputText(_ id: UUID) -> String {
    if let data = sessions[id]?.recentOutput, !data.isEmpty {
      return String(decoding: data, as: UTF8.self)
    }
    return orchestratorTranscripts[id] ?? ""
  }

  private func completeOrchestratorWatch(_ watch: OrchestratorWatch, reason: OrchestratorWaitReason, status: String) {
    orchestratorWatches.removeAll {
      $0.orchestratorID == watch.orchestratorID && $0.targetID == watch.targetID && $0.linkID == watch.linkID
    }
    updateOrchestratorLink(watch.linkID, status: .done)
    appendOrchestrator(watch.orchestratorID, OrchestratorSummary.report(
      title: consoleTitle(watch.targetID), status: status,
      output: orchestratorOutputText(watch.targetID), reason: reason))
    refreshOrchestratorStatus(watch.orchestratorID)
  }

  private func upsertOrchestratorLink(
    orchestratorID: UUID, targetID: UUID, title: String, status: OrchestratorLinkStatus
  ) -> UUID {
    if let index = orchestratorLinks.firstIndex(where: {
      $0.orchestratorID == orchestratorID && $0.targetID == targetID
    }) {
      orchestratorLinks[index].status = status
      orchestratorLinks[index].targetTitle = title
      return orchestratorLinks[index].id
    }
    let link = OrchestratorLink(
      orchestratorID: orchestratorID, targetID: targetID, targetTitle: title, status: status)
    orchestratorLinks.append(link)
    if orchestratorLinks.count > 32 {
      orchestratorLinks.removeFirst(orchestratorLinks.count - 32)
    }
    return link.id
  }

  private func updateOrchestratorLink(_ id: UUID, status: OrchestratorLinkStatus) {
    guard let index = orchestratorLinks.firstIndex(where: { $0.id == id }) else { return }
    orchestratorLinks[index].status = status
  }

  private func refreshOrchestratorStatus(_ id: UUID) {
    guard orchestratorTranscripts[id] != nil else { return }
    if orchestratorApprovals.contains(where: { $0.orchestratorID == id }) {
      orchestratorStatuses[id] = .waitingForInput
    } else if orchestratorWatches.contains(where: { $0.orchestratorID == id }) {
      orchestratorStatuses[id] = .running
    } else {
      orchestratorStatuses[id] = .idle
    }
  }

  private func appendOrchestrator(_ id: UUID, _ text: String) {
    guard var current = orchestratorTranscripts[id] else { return }
    if !current.isEmpty { current += "\n" }
    current += text
    if current.utf8.count > 16_384 {
      current = LoopValidator.boundedUTF8Suffix(current, limit: 12_000)
    }
    orchestratorTranscripts[id] = current
  }

  private func consoleTitle(_ id: UUID) -> String {
    workspace?.nodes.first { $0.id == id }?.title ?? "Console"
  }
}
