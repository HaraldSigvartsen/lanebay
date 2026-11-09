import Foundation
import LanebayCore

extension BoardViewModel {
  /// The display name for an agent id ("Codex", "Shell", …).
  public func providerTitle(_ agentID: String?) -> String {
    let id = agentID ?? "shell"
    if id == OrchestratorKind.agentID { return OrchestratorKind.title }
    if let known = AgentCatalog.knownCLIs.first(where: { $0.id == id }) { return known.displayName }
    if let custom = settings.preferences.customExecutables.first(where: { $0.id == id }) { return custom.displayName }
    return id
  }

  /// Switches a card to another AI (and model). A running card restarts with the new choice;
  /// a card whose name was just the old AI's name gets the new AI's name.
  public func changeProvider(_ id: UUID, agentID: String, model: String?) async {
    guard let node = workspace?.nodes.first(where: { $0.id == id && $0.kind == .console }),
      NewTerminalDraft.isAcceptableAgentID(agentID)
    else { return }
    let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let accepted = ProviderModels.supportsModel(agentID) && ProviderModels.isAcceptableModel(trimmed) ? trimmed : nil
    let oldTitle = providerTitle(node.agentID)
    let others = (workspace?.nodes ?? []).filter { $0.id != id && $0.kind == .console }.map(\.title)
    let newTitle = TerminalNames.unique(providerTitle(agentID), existing: others)
    let changed = node.agentID != agentID || node.model != accepted
    editNode(id) { card in
      card.agentID = agentID
      card.model = accepted
      if card.title == oldTitle || card.title.hasPrefix(oldTitle + " ") { card.title = newTitle }
    }
    if changed, sessions[id]?.isRunning == true { await restartConsole(id) }
  }
}
