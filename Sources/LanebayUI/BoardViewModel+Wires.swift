import Foundation
import LanebayCore

/// A wire being dragged out of a card port. Points are board coordinates (unzoomed, unpanned).
public struct WireDrag: Equatable, Sendable {
  public var from: UUID
  public var side: CardSide
  public var point: WireGeometry.Point
  public var hoverTarget: UUID?

  public init(from: UUID, side: CardSide, point: WireGeometry.Point, hoverTarget: UUID? = nil) {
    self.from = from; self.side = side; self.point = point; self.hoverTarget = hoverTarget
  }
}

/// Wires: cards connected so their agents can talk.
extension BoardViewModel {
  public var wires: [Wire] { workspace?.wires ?? [] }

  public func wire(_ id: UUID) -> Wire? { wires.first { $0.id == id } }

  func consoleFrames() -> [(UUID, NodeFrame)] {
    (workspace?.nodes ?? []).filter { $0.kind == .console }.map { ($0.id, displayedFrame($0)) }
  }

  // MARK: Editing

  /// Adds a wire between two cards. Sides default to the ones that face each other.
  @discardableResult
  public func addWire(
    from: UUID, to: UUID, fromSide: CardSide? = nil, toSide: CardSide? = nil,
    direction: WireDirection = .oneWay, mode: WireMode = .handoff, instruction: String = ""
  ) -> Result<Wire, WireRules.AddError> {
    let frames = Dictionary(uniqueKeysWithValues: consoleFrames())
    guard let a = frames[from], let b = frames[to] else { return .failure(.unknownCard) }
    let sa = fromSide ?? WireGeometry.facingSide(a, toward: .init(x: b.x + b.w / 2, y: b.y + b.h / 2))
    let sb = toSide ?? WireGeometry.facingSide(b, toward: .init(x: a.x + a.w / 2, y: a.y + a.h / 2))
    let wire = Wire(from: from, to: to, fromSide: sa, toSide: sb, direction: direction, mode: mode, instruction: instruction)
    if let error = WireRules.validate(wire, existing: wires, nodeIDs: Set(frames.keys)) { return .failure(error) }
    editWorkspace { $0.wires.append(wire) }
    recordActivity(.wire, title: "\(consoleTitle(from)) → \(consoleTitle(to))", detail: "Ny tråd")
    return .success(wire)
  }

  public func updateWire(_ id: UUID, _ edit: (inout Wire) -> Void) {
    editWorkspace { workspace in
      guard let index = workspace.wires.firstIndex(where: { $0.id == id }) else { return }
      edit(&workspace.wires[index])
    }
  }

  public func removeWire(_ id: UUID) {
    guard let wire = wire(id) else { return }
    editWorkspace { $0.wires.removeAll { $0.id == id } }
    if selectedWireID == id { selectedWireID = nil }
    wirePulses[id] = nil
    recordActivity(.wire, title: "\(consoleTitle(wire.from)) → \(consoleTitle(wire.to))", detail: "Tråd fjernet")
  }

  /// Ends a port drag: drops on a card make a wire, drops on empty board do nothing.
  @discardableResult
  public func finishWireDrag() -> Wire? {
    guard let drag = wireDrag else { return nil }
    wireDrag = nil
    let target = drag.hoverTarget ?? WireGeometry.card(at: drag.point, in: consoleFrames())
    guard let target, target != drag.from,
      let frame = consoleFrames().first(where: { $0.0 == target })?.1
    else { return nil }
    let side = WireGeometry.facingSide(frame, toward: drag.point)
    switch addWire(from: drag.from, to: target, fromSide: drag.side, toSide: side) {
    case let .success(wire):
      selectedWireID = nil
      return wire
    case let .failure(error):
      errorMessage = error.localizedDescription
      return nil
    }
  }

  /// Creates the template's cards (not started) in a row and wires them.
  @discardableResult
  public func applyWireTemplate(_ template: WireTemplate, agentID: String) -> [UUID] {
    let originX = -panX / zoom + 48, originY = -panY / zoom + 96
    var ids: [UUID] = []
    for (index, title) in template.cardTitles.enumerated() {
      let id = addConsole(agentID: agentID)
      setConsoleTitle(id, title: title)
      let x: Double, y: Double
      switch template {
      case .pipeline:
        x = originX + Double(index) * 620; y = originY
      case .leadWorkers:
        if index == 0 { x = originX + 620; y = originY } else { x = originX + Double(index - 1) * 620; y = originY + 500 }
      }
      moveNode(id, x: x, y: y)
      ids.append(id)
    }
    // Zoom out just enough that the whole template is in view.
    let width = 3 * 620.0 - 140
    let available = max(400, lastViewportWidth - 96)
    if width * zoom > available {
      setZoom(max(0.45, available / width))
      pan(dx: (48 - originX * zoom) - panX, dy: (96 - originY * zoom) - panY)
    }
    let made = template.wires(for: ids)
    editWorkspace { $0.wires.append(contentsOf: made) }
    recordActivity(.wire, title: template.title, detail: "\(ids.count) kort og \(made.count) tråder")
    return ids
  }

  // MARK: Routing

  /// A person (or the CLI) gave this card a fresh task, so its message chain starts over.
  public func resetWireHops(_ id: UUID) { wireRouter.resetHops(for: id) }

  /// A task ended with a handoff note: send the note along `handoff` wires.
  func routeHandoff(_ record: AgentTaskRecord, state: AgentTaskState) {
    guard state == .done else { return }
    let note = (try? String(contentsOfFile: record.handoffFile, encoding: .utf8)) ?? ""
    deliverAlongWires(from: record.nodeID, mode: .handoff, body: note)
  }

  /// An agent finished a reply (running → idle or waiting): send its latest output along `everyReply` wires.
  func routeReplyIfFinished(_ id: UUID, from old: AgentStatus, to new: AgentStatus) {
    // A chat reply in progress routes itself when it finishes (see finishReply).
    guard old == .running, new == .idle || new == .waitingForInput, chatWorking[id] == nil,
      wires.contains(where: { $0.mode == .everyReply && $0.target(sending: id) != nil })
    else { return }
    let raw = recentConsoleOutput(id, maxBytes: 16_384) ?? ""
    let lines = AgentTaskContract.plainText(raw).split(separator: "\n").map(String.init)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    deliverAlongWires(from: id, mode: .everyReply, body: lines.suffix(30).joined(separator: "\n"))
  }

  /// Routes one message from `source` and writes it into each target console.
  public func deliverAlongWires(from source: UUID, mode: WireMode, body: String, now: Date = Date()) {
    let current = wires
    guard current.contains(where: { $0.target(sending: source) != nil }) else { return }
    let result = wireRouter.route(from: source, mode: mode, wires: current, now: now)
    let sourceTitle = consoleTitle(source)
    for (wireID, reason) in result.skipped where reason == .tooManyHops || reason == .coolingDown {
      guard let wire = wire(wireID), let target = wire.target(sending: source) else { continue }
      let why = reason == .tooManyHops ? "Stoppet: for mange ledd i kjeden (sløyfevern)" : "Venter: sendte nettopp på denne tråden"
      recordActivity(.wire, title: "\(sourceTitle) → \(consoleTitle(target))", detail: why)
    }
    for delivery in result.deliveries {
      guard let wire = wire(delivery.wireID) else { continue }
      let targetTitle = consoleTitle(delivery.target)
      let message = WireMessage.compose(fromTitle: sourceTitle, instruction: wire.instruction, body: body)
      let targetIsShell = AgentTaskContract.isShellProvider(
        workspace?.nodes.first { $0.id == delivery.target }?.agentID ?? "shell")
      let text = targetIsShell ? WireMessage.forShell(message) : message
      let target = delivery.target
      let wasRunning = sessions[target]?.isRunning == true
      deliverToCard(text, to: target) { [weak self] delivered in
        guard let self else { return }
        if !delivered {
          self.recordActivity(.wire, title: "\(sourceTitle) → \(targetTitle)", detail: "Ikke sendt: \(targetTitle) kunne ikke startes")
        }
      }
      if !wasRunning {
        recordActivity(.wire, title: "\(sourceTitle) → \(targetTitle)", detail: "Starter \(targetTitle) før meldingen sendes")
      }
      appendChat(ChatEntry(kind: .wire, text: message, from: source, to: target))
      if !targetIsShell { beginChatReply(for: target) }
      wirePulses[wire.id] = now
      recordActivity(
        .wire, title: "\(sourceTitle) → \(targetTitle)",
        detail: BoardViewModel.activityPreview(message))
    }
  }
}

extension BoardViewModel: WireControlling {
  public func controlSendToCard(_ id: UUID, text: String) -> Bool {
    sendChat("@\(handle(for: id)) \(text)")
  }

  public func resolveCard(_ reference: String) -> UUID? {
    let consoles = (workspace?.nodes ?? []).filter { $0.kind == .console }
    if let exact = consoles.first(where: { $0.title.caseInsensitiveCompare(reference) == .orderedSame }) { return exact.id }
    let handle = TerminalHandle.slug(reference.hasPrefix("@") ? String(reference.dropFirst()) : reference)
    if let named = consoles.first(where: { TerminalHandle.slug($0.title) == handle }) { return named.id }
    let lower = reference.lowercased()
    let byID = consoles.filter { $0.id.uuidString.lowercased().hasPrefix(lower) }
    if lower.count >= 4, byID.count == 1 { return byID[0].id }
    return nil
  }

  public func controlAddWire(
    from: UUID, to: UUID, direction: WireDirection, mode: WireMode, instruction: String
  ) -> Result<Wire, WireRules.AddError> {
    addWire(from: from, to: to, direction: direction, mode: mode, instruction: instruction)
  }

  public func controlRemoveWire(_ reference: String) -> Bool {
    let lower = reference.lowercased()
    let matches = wires.filter { $0.id.uuidString.lowercased().hasPrefix(lower) }
    guard lower.count >= 4, matches.count == 1 else { return false }
    removeWire(matches[0].id)
    return true
  }

  public func controlWireLines() -> [String] {
    wires.map { wire in
      let arrow = wire.direction == .twoWay ? "↔" : "→"
      var line = "\(wire.id.uuidString.prefix(8).lowercased())  \(consoleTitle(wire.from)) \(arrow) \(consoleTitle(wire.to))  ·  \(wire.mode.shortLabel)"
      if !wire.enabled { line += "  ·  pause" }
      if !wire.instruction.isEmpty { line += "  ·  «\(wire.instruction)»" }
      return line
    }
  }
}

extension BoardViewModel {
  /// Agents a template can put on its cards: installed CLIs, then Shell.
  public var wireTemplateAgents: [(id: String, title: String)] {
    let installed = availableAgentTemplates
      .filter { $0.id != OrchestratorKind.agentID && $0.id != "shell" && installedLaunchExecutable(agentID: $0.id) }
      .map { (id: $0.id, title: $0.title) }
    return installed + [(id: "shell", title: "Shell")]
  }
}
