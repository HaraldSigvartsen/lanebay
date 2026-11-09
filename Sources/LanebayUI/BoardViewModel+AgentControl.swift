import Foundation
import LanebayCore

/// Lets the control API (and agents behind it) drive consoles on this board.
extension BoardViewModel: AgentConsoleDriving {
  public func agentProviderStatus(_ provider: String) -> AgentProviderStatus {
    guard provider != OrchestratorKind.agentID,
      availableAgentTemplates.contains(where: { $0.id == provider }) else { return .unknown }
    return installedLaunchExecutable(agentID: provider) ? .ready : .notInstalled
  }

  public func spawnAgentConsole(provider: String, cwd: URL, title: String) -> UUID {
    let id = createAndStartConsole(agentID: provider, cwd: cwd)
    setConsoleTitle(id, title: title)
    recordActivity(.spawn, title: title, detail: "\(provider) · \(cwd.lastPathComponent)")
    // A spawned agent is live, so a tidy pulls it up among the other live cards where it can be seen.
    tidyBoard(viewportWidth: lastViewportWidth, leading: [id])
    return id
  }

  public func agentConsoleIsRunning(_ id: UUID) -> Bool {
    guard let session = sessions[id] else { return false }
    return session.isRunning && !session.isClosed
  }

  @discardableResult
  public func writeToAgentConsole(_ text: String, id: UUID) -> Bool {
    guard let session = sessions[id], session.isRunning, !session.isClosed else { return false }
    session.sendAgentInput(text)
    // Work from a person or the CLI starts a fresh wire chain for this card.
    if text != "\r" { resetWireHops(id) }
    let detail = BoardViewModel.activityPreview(text)
    // The hidden zsh hook setup is plumbing, not something the user sent.
    if !detail.isEmpty, !text.hasPrefix(" export PAGER=cat") {
      let title = workspace?.nodes.first(where: { $0.id == id })?.title ?? "Console"
      recordActivity(.send, title: title, detail: detail)
    }
    return true
  }

  public func agentConsoleOutput(_ id: UUID, maxBytes: Int) -> String? { recentConsoleOutput(id, maxBytes: maxBytes) }

  public func stopAgentConsole(_ id: UUID) async { await closeConsole(id) }

  public func agentTasksChanged(_ tasks: [UUID: AgentTaskRecord]) { agentTasks = tasks }

  /// Called when a short agent task reaches a final state, so the handoff is visible on the activity feed.
  public func recordAgentHandoff(_ record: AgentTaskRecord, state: AgentTaskState) {
    let title = workspace?.nodes.first(where: { $0.id == record.nodeID })?.title ?? record.provider
    let file = URL(fileURLWithPath: record.handoffFile).lastPathComponent
    recordActivity(.handoff, title: title, detail: "\(state.title) · \(file)")
    routeHandoff(record, state: state)
  }
}
