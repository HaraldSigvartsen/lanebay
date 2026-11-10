import Foundation
import LanebayCore

/// A card busy with a message from the chat or a wire.
public struct ChatWork: Equatable, Sendable {
  public var entryID: UUID
  public var started: Date
  public var startByte: Int
  public var sent: String? = nil
}

extension BoardViewModel {
  public static let chatLimit = 300

  // MARK: Names and handles

  public var consoleNodes: [Node] { (workspace?.nodes ?? []).filter { $0.kind == .console } }

  /// `@handle` → card, from each card's name.
  public var chatHandles: [String: UUID] {
    var map: [String: UUID] = [:]
    for node in consoleNodes where map[TerminalHandle.slug(node.title)] == nil {
      map[TerminalHandle.slug(node.title)] = node.id
    }
    return map
  }

  public func handle(for id: UUID) -> String { TerminalHandle.slug(consoleTitle(id)) }

  /// Renames a card. Names stay unique in the workspace so every card has its own @-handle.
  @discardableResult
  public func renameConsole(_ id: UUID, to name: String) -> String? {
    let others = consoleNodes.filter { $0.id != id }.map(\.title)
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let unique = TerminalNames.unique(trimmed, existing: others)
    guard unique != consoleTitle(id) else { return unique }
    setConsoleTitle(id, title: unique)
    recordActivity(.status, title: unique, detail: "Nytt navn: @\(TerminalHandle.slug(unique))")
    return unique
  }

  /// Gives every card a unique name (old boards can have several "Shell" cards).
  public func makeConsoleNamesUnique() {
    var seen: [String] = []
    for node in consoleNodes {
      let unique = TerminalNames.unique(node.title, existing: seen)
      if unique != node.title { setConsoleTitle(node.id, title: unique) }
      seen.append(unique)
    }
  }

  /// Adds `@handle ` to the chat draft and opens the panel.
  public func insertChatMention(_ id: UUID) {
    let tag = "@\(handle(for: id)) "
    if !chatDraft.contains(tag) {
      if !chatDraft.isEmpty, !chatDraft.hasSuffix(" ") { chatDraft += " " }
      chatDraft += tag
    }
    if !chatPanelOpen { setChatPanel(open: true) }
    chatFocusRequest &+= 1
  }

  // MARK: Transcript

  public var chatEntries: [ChatEntry] { workspace?.chat ?? [] }

  public var chatPanelOpen: Bool { workspace?.chatOpen ?? true }
  public var chatPanelWidth: Double { workspace?.chatWidth ?? 360 }

  public func setChatPanel(open: Bool? = nil, width: Double? = nil) {
    editWorkspace { ws in
      if let open { ws.chatOpen = open }
      if let width { ws.chatWidth = min(560, max(300, width)) }
    }
  }

  func appendChat(_ entry: ChatEntry) {
    editWorkspace { ws in
      ws.chat.append(entry)
      if ws.chat.count > Self.chatLimit { ws.chat.removeFirst(ws.chat.count - Self.chatLimit) }
    }
  }

  func updateChat(_ id: UUID, _ change: (inout ChatEntry) -> Void) {
    editWorkspace { ws in
      if let index = ws.chat.firstIndex(where: { $0.id == id }) { change(&ws.chat[index]) }
    }
  }

  public func clearChat() {
    chatWorking = [:]
    editWorkspace { $0.chat = [] }
  }

  /// Who an untagged message goes to: the focused card, else the first selected one.
  public var chatDefaultTarget: UUID? {
    if let focused = focusedNodeID, consoleNodes.contains(where: { $0.id == focused }) { return focused }
    return consoleNodes.first { selectedNodeIDs.contains($0.id) }?.id
  }

  /// The cards a draft would go to.
  public func chatRecipients(for text: String) -> (targets: [UUID], all: Bool, body: String) {
    let parsed = ChatMentions.parse(text, handles: chatHandles)
    if parsed.all { return (consoleNodes.map(\.id), true, parsed.body) }
    if !parsed.targets.isEmpty { return (parsed.targets, false, parsed.body) }
    return (chatDefaultTarget.map { [$0] } ?? [], false, parsed.body)
  }

  // MARK: Sending

  /// Sends a chat message to every tagged card (or the selected one). Stopped cards are started first.
  @discardableResult
  public func sendChat(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let recipients = chatRecipients(for: trimmed)
    guard !recipients.body.isEmpty else { return false }
    guard !recipients.targets.isEmpty else {
      appendChat(ChatEntry(kind: .system, text: "Ingen mottaker. Tagg en terminal med @navn, skriv @alle, eller velg et kort."))
      return false
    }
    appendChat(ChatEntry(kind: .user, text: trimmed, targets: recipients.targets))
    for target in recipients.targets {
      resetWireHops(target)
      beginChatReply(for: target, sent: recipients.body)
      let title = consoleTitle(target)
      deliverToCard(recipients.body, to: target) { [weak self] delivered in
        guard let self, !delivered, let work = self.chatWorking[target] else { return }
        self.updateChat(work.entryID) { $0.text = "\(title) kunne ikke startes."; $0.status = .failed }
        self.chatWorking[target] = nil
      }
      recordActivity(.send, title: title, detail: BoardViewModel.activityPreview(recipients.body))
    }
    return true
  }

  /// Opens a reply block for `id` and watches its output until it goes quiet.
  func beginChatReply(for id: UUID, sent: String? = nil) {
    if let old = chatWorking[id] {
      updateChat(old.entryID) { if $0.status == .working { $0.status = .done } }
    }
    let entry = ChatEntry(kind: .reply, text: "", from: id, status: .working)
    appendChat(entry)
    let startByte = sessions[id].map { $0.isRunning && !$0.isClosed ? $0.outputByteCount : 0 } ?? 0
    let work = ChatWork(entryID: entry.id, started: Date(), startByte: startByte, sent: sent)
    chatWorking[id] = work
    Task { @MainActor [weak self] in await self?.watchReply(id, work: work) }
  }

  /// A reply is done per ReplyCompletion: never while the card shows Jobber; AI cards wait longer than a shell.
  private func watchReply(_ id: UUID, work: ChatWork) async {
    var lastBytes = -1
    var lastAnswer = ""
    var quietSince = Date()
    let deadline = Date().addingTimeInterval(45 * 60)
    try? await Task.sleep(for: .seconds(2))
    while Date() < deadline {
      guard chatWorking[id] == work else { return }
      guard let session = sessions[id] else {
        finishReply(id, work: work, status: .failed, note: "Kortet ble lukket.", screenAnswer: lastAnswer)
        return
      }
      let bytes = session.outputByteCount
      let agentID = workspace?.nodes.first(where: { $0.id == id })?.agentID
      var tail = String(decoding: session.recentOutput.suffix(1500), as: UTF8.self)
      if !ReplyCompletion.isShell(agentID), let screen = session.screenText() {
        // AI TUIs redraw ads and spinners forever: judge quiet by the visible answer, not by bytes.
        let answer = ReplyCompletion.screenReply(screen: screen, sent: work.sent)
        if answer != lastAnswer { lastAnswer = answer; quietSince = Date() }
        tail = String(screen.suffix(1500))
      } else if bytes != lastBytes { lastBytes = bytes; quietSince = Date() }
      let quiet = Date().timeIntervalSince(quietSince)
      let answerPending = !ReplyCompletion.isShell(agentID) && lastAnswer.isEmpty && quiet < 60 && session.isRunning
      if !answerPending, ReplyCompletion.isDone(
        agentID: agentID, processRunning: session.isRunning, working: ReplyCompletion.isWorking(agentID: agentID, statusRunning: session.status == .running, tail: tail),
        quietFor: quiet, newBytes: bytes - work.startByte, tail: tail)
      {
        finishReply(id, work: work, status: .done, note: nil, screenAnswer: lastAnswer)
        return
      }
      try? await Task.sleep(for: .milliseconds(500))
    }
    finishReply(id, work: work, status: .done, note: nil, screenAnswer: lastAnswer)
  }

  /// The output a card has printed since `work` started.
  public func chatOutput(_ id: UUID, since work: ChatWork) -> String {
    guard let session = sessions[id] else { return "" }
    let text = String(decoding: session.recentOutput, as: UTF8.self)
    let fresh = max(0, session.outputByteCount - work.startByte)
    return String(text.suffix(min(text.count, fresh)))
  }

  func finishReply(_ id: UUID, work: ChatWork, status: ChatEntryStatus, note: String?, screenAnswer: String = "") {
    var digest = OutputDigest.make(raw: chatOutput(id, since: work), sent: work.sent)
    // Full-screen AI tools: read the answer off the screen instead of the raw stream.
    let agentID = workspace?.nodes.first(where: { $0.id == id })?.agentID
    if !ReplyCompletion.isShell(agentID) {
      var answer = screenAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
      if answer.isEmpty, let screen = sessions[id]?.screenText() {
        answer = ReplyCompletion.screenReply(screen: screen, sent: work.sent)
      }
      // Prefer a short final answer line (AI tools often leave thinking noise above it).
      if let pick = ReplyCompletion.preferredAnswer(answer) { answer = pick }
      if !answer.isEmpty { digest = OutputDigest(steps: [], reply: answer, truncated: false) }
    }
    updateChat(work.entryID) { entry in
      entry.status = status
      entry.steps = digest.steps
      entry.text = note ?? (digest.reply.isEmpty ? "Ingen ny tekst i terminalen." : digest.reply)
      entry.truncated = digest.truncated
      entry.finished = Date()
    }
    if chatWorking[id] == work { chatWorking[id] = nil }
    // A finished chat reply counts as "done" for wires in both modes, also for full-screen AI tools
    // whose terminal status never settles.
    if status == .done, note == nil, !digest.reply.isEmpty {
      let body = String(digest.reply.suffix(4000))
      deliverAlongWires(from: id, mode: .everyReply, body: body)
      deliverAlongWires(from: id, mode: .handoff, body: body)
    }
  }

  // MARK: Delivery

  /// Writes text into a card as typed input, starting the card first when it is stopped.
  func deliverToCard(_ text: String, to id: UUID, completion: (@MainActor (Bool) -> Void)? = nil) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      let ready = await self.ensureRunning(id)
      guard ready, let session = self.sessions[id] else { completion?(false); return }
      session.sendAgentInput(text)
      try? await Task.sleep(for: .milliseconds(400))
      guard let again = self.sessions[id], again.isRunning else { completion?(false); return }
      again.sendAgentInput("\r")
      completion?(true)
    }
  }

  /// Starts a stopped card and waits until its program is up and has stopped printing its banner.
  func ensureRunning(_ id: UUID) async -> Bool {
    if let session = sessions[id], session.isRunning, !session.isClosed { return true }
    await restartConsole(id)
    let deadline = Date().addingTimeInterval(25)
    var lastBytes = -1
    var quietSince = Date()
    while Date() < deadline {
      if let session = sessions[id], session.isRunning {
        if session.outputByteCount != lastBytes { lastBytes = session.outputByteCount; quietSince = Date() }
        if lastBytes > 0, Date().timeIntervalSince(quietSince) >= 1.5 { return true }
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return sessions[id]?.isRunning == true
  }

  /// Shows a card on the board: selects it and pans so it is in view.
  public func revealCard(_ id: UUID) {
    guard let node = consoleNodes.first(where: { $0.id == id }) else { return }
    select(id)
    let frame = node.frame
    let width = lastViewportWidth
    let targetX = width / 2 - (frame.x + frame.w / 2) * zoom
    let targetY = 160 - frame.y * zoom
    pan(dx: targetX - panX, dy: targetY - panY)
  }
}
