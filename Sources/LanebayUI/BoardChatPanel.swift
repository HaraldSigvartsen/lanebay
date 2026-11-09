import LanebayCore
import SwiftUI

/// The chat on the left of the board: talk to terminals by @name and watch them answer.
struct BoardChatPanel: View {
  @Bindable var model: BoardViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var composerFocused: Bool
  @State private var suggestionIndex = 0
  @State private var dragStartWidth: Double?
  @State private var hoverResize = false

  private var width: Double { model.chatPanelWidth }

  var body: some View {
    VStack(spacing: 0) {
      header
      Rectangle().fill(Palette.border).frame(height: 1)
      terminalStrip
      Rectangle().fill(Palette.border).frame(height: 1)
      transcript
      composer
    }
    .frame(width: width)
    .background(Palette.surface)
    .overlay(alignment: .trailing) { resizeHandle }
    .onChange(of: model.chatFocusRequest) { _, _ in composerFocused = true }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "bubble.left.and.text.bubble.right")
        .foregroundStyle(Palette.accent)
      Text("Chat").font(Typography.bodyEmphasis).foregroundStyle(Palette.ink)
      Spacer()
      Menu {
        Button("Tøm samtalen", role: .destructive) { model.clearChat() }
          .disabled(model.chatEntries.isEmpty)
      } label: {
        Icon.menu.image.foregroundStyle(Palette.secondaryInk).frame(width: 28, height: 28)
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .help("Chatvalg")
      Button {
        model.setChatPanel(open: false)
      } label: {
        Image(systemName: "sidebar.left").frame(width: 28, height: 28)
      }
      .buttonStyle(.lbIcon)
      .help("Skjul chat (⌘⇧C)")
      .accessibilityLabel("Skjul chat")
    }
    .padding(.horizontal, Spacing.md)
    .frame(height: 48)
  }

  // MARK: Terminals

  private var terminalStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.xs) {
        if model.consoleNodes.isEmpty {
          Text("Ingen terminaler ennå").font(Typography.caption).foregroundStyle(Palette.mutedInk)
        }
        ForEach(model.consoleNodes) { node in
          BoardChatChip(
            node: node,
            working: model.chatWorking[node.id] != nil,
            running: model.sessions[node.id]?.isRunning == true,
            isDefault: model.chatDefaultTarget == node.id,
            onTap: { model.insertChatMention(node.id) },
            onCommit: { name in
              if let name { model.renameConsole(node.id, to: name) }
            },
            onReveal: { model.revealCard(node.id) })
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
    }
  }

  // MARK: Transcript

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Spacing.md) {
          if model.chatEntries.isEmpty { emptyState }
          ForEach(model.chatEntries) { entry in
            BoardChatRow(model: model, entry: entry).id(entry.id)
          }
          Color.clear.frame(height: 1).id("bottom")
        }
        .padding(Spacing.md)
      }
      .onChange(of: model.chatEntries.count) { _, _ in
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
      }
      .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
    }
    .frame(maxHeight: .infinity)
    .background(Palette.canvas)
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Snakk med terminalene").font(Typography.bodyEmphasis).foregroundStyle(Palette.ink)
      Text("Skriv @ for å tagge en terminal, eller @alle for å sende til alle. Uten tagg går meldingen til kortet du har valgt.")
        .font(Typography.caption).foregroundStyle(Palette.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      Text("Dobbeltklikk et navn for å gi det nytt navn.")
        .font(Typography.caption).foregroundStyle(Palette.mutedInk)
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .pastelGlass(radius: 16, tint: DS.Pastel.peach, tintOpacity: 0.12, shadow: false)
  }

  // MARK: Composer

  private var suggestions: [Node] {
    guard let active = ChatMentions.activeQuery(in: model.chatDraft, cursor: model.chatDraft.count) else { return [] }
    let query = TerminalHandle.slug(active.query)
    let nodes = model.consoleNodes.filter {
      active.query.isEmpty || TerminalHandle.slug($0.title).hasPrefix(query)
        || $0.title.lowercased().contains(active.query.lowercased())
    }
    return nodes
  }

  private var showsAll: Bool {
    guard let active = ChatMentions.activeQuery(in: model.chatDraft, cursor: model.chatDraft.count) else { return false }
    return active.query.isEmpty || "alle".hasPrefix(active.query.lowercased())
  }

  private var suggestionCount: Int { suggestions.count + (showsAll ? 1 : 0) }

  private func pick(_ index: Int) {
    guard let active = ChatMentions.activeQuery(in: model.chatDraft, cursor: model.chatDraft.count) else { return }
    let handle: String
    if index < suggestions.count {
      handle = TerminalHandle.slug(suggestions[index].title)
    } else {
      handle = "alle"
    }
    model.chatDraft = ChatMentions.complete(model.chatDraft, range: active.range, handle: handle)
    suggestionIndex = 0
  }

  private func send() {
    if model.sendChat(model.chatDraft) { model.chatDraft = "" }
  }

  private var composer: some View {
    let recipients = model.chatRecipients(for: model.chatDraft)
    let parsed = ChatMentions.parse(model.chatDraft, handles: model.chatHandles)
    let tagged = parsed.all || !parsed.targets.isEmpty
    return VStack(alignment: .leading, spacing: Spacing.xs) {
      if suggestionCount > 0 { suggestionList }
      HStack(spacing: Spacing.xxs) {
        Text("Til").font(Typography.caption).foregroundStyle(Palette.mutedInk)
        if parsed.all {
          BoardChatPill(text: "@alle", color: Palette.accent)
        } else if tagged {
          ForEach(recipients.targets, id: \.self) { id in
            BoardChatPill(text: "@\(model.handle(for: id))", color: chatNameColor(model, id))
          }
        } else if let id = recipients.targets.first {
          BoardChatPill(text: model.consoleTitle(id), color: chatNameColor(model, id))
          Text("valgt kort").font(Typography.caption).foregroundStyle(Palette.mutedInk)
        } else {
          Text("ingen — tagg med @").font(Typography.caption).foregroundStyle(Palette.mutedInk)
        }
        let typing = ChatMentions.activeQuery(in: model.chatDraft, cursor: model.chatDraft.count)
          .map { TerminalHandle.slug($0.query) }
        let unknown = parsed.unknown.filter { $0 != typing }
        if !unknown.isEmpty {
          Text("ukjent: \(unknown.map { "@\($0)" }.joined(separator: ", "))")
            .font(Typography.caption).foregroundStyle(Palette.status(.error))
        }
        Spacer(minLength: 0)
      }
      .lineLimit(1)
      HStack(alignment: .bottom, spacing: Spacing.xs) {
        TextField("Skriv til @terminal …", text: $model.chatDraft, axis: .vertical)
          .textFieldStyle(.plain)
          .font(Typography.body)
          .foregroundStyle(Palette.ink)
          .lineLimit(1...8)
          .focused($composerFocused)
          .onKeyPress(phases: .down) { press in handleKey(press) }
          .onChange(of: model.chatDraft) { _, _ in suggestionIndex = min(suggestionIndex, max(0, suggestionCount - 1)) }
          .padding(.vertical, 6)
          .accessibilityLabel("Chatmelding")
        Button(action: send) {
          Icon.send.image
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(
              recipients.targets.isEmpty || recipients.body.isEmpty ? Palette.mutedInk.opacity(0.5) : Palette.accent,
              in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(recipients.targets.isEmpty || recipients.body.isEmpty)
        .help("Send (Enter). Ny linje: Shift+Enter")
        .accessibilityLabel("Send")
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xxs)
      .pastelGlass(radius: 16, tint: DS.Pastel.lavender, tintOpacity: composerFocused ? 0.16 : 0.06, shadow: false)
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(composerFocused ? DS.Pastel.lavender : .clear, lineWidth: 1.5))
      .animation(.easeOut(duration: 0.15), value: composerFocused)
    }
    .padding(Spacing.md)
    .background(Palette.surface)
    .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
  }

  private func handleKey(_ press: KeyPress) -> KeyPress.Result {
    let open = suggestionCount > 0
    switch press.key {
    case .return:
      if press.modifiers.contains(.shift) { model.chatDraft += "\n"; return .handled }
      if open { pick(suggestionIndex); return .handled }
      send()
      return .handled
    case .tab:
      if open { pick(suggestionIndex); return .handled }
      return .ignored
    case .downArrow:
      guard open else { return .ignored }
      suggestionIndex = (suggestionIndex + 1) % suggestionCount
      return .handled
    case .upArrow:
      guard open else { return .ignored }
      suggestionIndex = (suggestionIndex - 1 + suggestionCount) % suggestionCount
      return .handled
    case .escape:
      guard open else { return .ignored }
      model.chatDraft += " "
      return .handled
    default:
      return .ignored
    }
  }

  private var suggestionList: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, node in
        suggestionRow(index: index) {
          ProviderBadge(agentID: node.agentID ?? "shell", size: 16)
          Text(node.title).font(Typography.body).foregroundStyle(Palette.ink)
          Text("@\(TerminalHandle.slug(node.title))").font(Typography.caption).foregroundStyle(Palette.mutedInk)
          Spacer()
          BoardChatDot(working: model.chatWorking[node.id] != nil, running: model.sessions[node.id]?.isRunning == true)
        }
      }
      if showsAll {
        suggestionRow(index: suggestions.count) {
          Image(systemName: "person.3.fill").font(.system(size: 11)).foregroundStyle(Palette.accent).frame(width: 16)
          Text("Alle terminaler").font(Typography.body).foregroundStyle(Palette.ink)
          Text("@alle").font(Typography.caption).foregroundStyle(Palette.mutedInk)
          Spacer()
        }
      }
    }
    .padding(4)
    .pastelGlass(radius: 14, tint: DS.Pastel.lavender, tintOpacity: 0.12)
    .transition(.opacity.combined(with: .move(edge: .bottom)))
  }

  private func suggestionRow<Content: View>(index: Int, @ViewBuilder _ content: () -> Content) -> some View {
    Button { pick(index) } label: {
      HStack(spacing: Spacing.xs) { content() }
        .padding(.horizontal, Spacing.sm)
        .frame(height: 30)
        .background(
          index == suggestionIndex ? DS.Pastel.lavender.opacity(0.32) : .clear,
          in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { if $0 { suggestionIndex = index } }
  }

  // MARK: Resize

  private var resizeHandle: some View {
    Rectangle()
      .fill(hoverResize || dragStartWidth != nil ? Palette.accent.opacity(0.6) : .clear)
      .frame(width: 3)
      .contentShape(Rectangle().inset(by: -4))
      .onHover { hovering in
        hoverResize = hovering
        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
      }
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            if dragStartWidth == nil { dragStartWidth = width }
            model.setChatPanel(width: (dragStartWidth ?? width) + value.translation.width)
          }
          .onEnded { _ in dragStartWidth = nil })
      .help("Dra for å endre bredden")
  }
}

// MARK: Pieces

@MainActor func chatNameColor(_ model: BoardViewModel, _ id: UUID?) -> Color {
  guard let id, let index = model.consoleNodes.firstIndex(where: { $0.id == id }) else { return Palette.secondaryInk }
  // Each terminal keeps its own pastel ink, in board order, so names are told apart at a glance.
  let inks = [DS.Pastel.lavenderInk, DS.Pastel.mintInk, DS.Pastel.skyInk, DS.Pastel.peachInk]
  return inks[index % inks.count]
}

struct BoardChatPill: View {
  let text: String
  let color: Color
  var body: some View {
    Text(text)
      .font(Typography.caption.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 7)
      .frame(height: 20)
      .background(color.opacity(0.12), in: Capsule())
      .overlay(Capsule().stroke(color.opacity(0.35)))
  }
}

struct BoardChatDot: View {
  let working: Bool
  let running: Bool
  var body: some View {
    Circle()
      .fill(working ? Palette.accent : running ? Palette.status(.running) : Palette.mutedInk.opacity(0.5))
      .frame(width: 7, height: 7)
      .accessibilityLabel(working ? "Jobber" : running ? "Kjører" : "Stoppet")
  }
}

struct BoardChatChip: View {
  private func finish(_ name: String?) {
    guard renaming else { return }
    renaming = false
    onCommit(name)
  }

  let node: Node
  let working: Bool
  let running: Bool
  let isDefault: Bool
  let onTap: () -> Void
  let onCommit: (String?) -> Void
  let onReveal: () -> Void
  @State private var draft = ""
  /// The chip edits its own name; the card header has a separate editor.
  @State private var renaming = false
  @State private var hovering = false
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 5) {
      BoardChatDot(working: working, running: running)
      if renaming {
        TextField("Navn", text: $draft)
          .textFieldStyle(.plain)
          .font(Typography.caption.weight(.semibold))
          .frame(width: 110)
          .focused($focused)
          .onAppear {
            draft = node.title
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
          }
          .onSubmit { finish(draft) }
          .onExitCommand { finish(nil) }
          .onChange(of: focused) { _, now in if !now, renaming { finish(draft) } }
      } else {
        Text(node.title).font(Typography.caption.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
      }
    }
    .padding(.horizontal, 9)
    .frame(height: 26)
    .pastelFill(isDefault ? DS.Pastel.lavender : DS.Pastel.sky, radius: 13, opacity: hovering ? 0.34 : 0.18)
    .overlay(Capsule().strokeBorder(renaming ? Palette.focus : .clear, lineWidth: 1.5))
    .contentShape(Capsule())
    .onHover { hovering = $0 }
    .onTapGesture(count: 2) { renaming = true }
    .onTapGesture { onTap() }
    .contextMenu {
      Button("Tagg @\(TerminalHandle.slug(node.title))", action: onTap)
      Button("Gi nytt navn…") { renaming = true }
      Button("Vis på brettet", action: onReveal)
    }
    .help("@\(TerminalHandle.slug(node.title)) — klikk for å tagge, dobbeltklikk for å gi nytt navn")
    .animation(.easeOut(duration: 0.15), value: hovering)
  }
}

struct BoardChatRow: View {
  let model: BoardViewModel
  let entry: ChatEntry
  @State private var showSteps = false
  @State private var expanded = false
  @State private var hovering = false

  var body: some View {
    switch entry.kind {
    case .user: userBubble
    case .reply: replyBlock
    case .wire: wireRow
    case .system:
      Text(entry.text).font(Typography.caption).foregroundStyle(Palette.mutedInk)
        .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  private var userBubble: some View {
    HStack {
      Spacer(minLength: 40)
      Text(entry.text)
        .font(Typography.body)
        .foregroundStyle(Palette.ink)
        .textSelection(.enabled)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .pastelFill(DS.Pastel.lavender, radius: 16, opacity: 0.32)
    }
  }

  private var wireRow: some View {
    HStack(spacing: 6) {
      Rectangle().fill(Palette.border).frame(height: 1)
      Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.system(size: 10))
      Text("\(chatTitle(entry.from)) → \(chatTitle(entry.to))")
        .font(Typography.caption.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
      Rectangle().fill(Palette.border).frame(height: 1)
    }
    .foregroundStyle(Palette.secondaryInk)
    .help(entry.text)
  }

  private func chatTitle(_ id: UUID?) -> String { id.map { model.consoleTitle($0) } ?? "Ukjent" }

  private var title: String { chatTitle(entry.from) }

  private var lines: [String] { entry.text.components(separatedBy: "\n") }

  private var replyBlock: some View {
    let color = chatNameColor(model, entry.from)
    let agentID = model.consoleNodes.first(where: { $0.id == entry.from })?.agentID ?? "shell"
    return VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        ProviderBadge(agentID: agentID, size: 18)
        Text(title).font(Typography.bodyEmphasis).foregroundStyle(color)
        if entry.status == .working {
          BoardChatWorking(name: title, since: entry.date)
        } else if entry.status == .failed {
          Text("feilet").font(Typography.caption).foregroundStyle(Palette.status(.error))
        } else if let finished = entry.finished {
          Text(chatElapsed(finished.timeIntervalSince(entry.date)))
            .font(Typography.caption).foregroundStyle(Palette.mutedInk)
        }
        Spacer(minLength: 0)
      }
      if !entry.steps.isEmpty {
        Button {
          withAnimation(.easeOut(duration: 0.2)) { showSteps.toggle() }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
              .rotationEffect(.degrees(showSteps ? 90 : 0))
            Text("Hva den gjorde · \(entry.steps.count) steg").font(Typography.caption)
          }
          .foregroundStyle(Palette.secondaryInk)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if showSteps {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(entry.steps.enumerated()), id: \.offset) { _, step in
              HStack(alignment: .top, spacing: 6) {
                Circle().fill(Palette.mutedInk).frame(width: 4, height: 4).padding(.top, 6)
                Text(step).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondaryInk)
                  .lineLimit(2)
              }
            }
          }
          .padding(.leading, Spacing.xs)
          .transition(.opacity)
        }
      }
      if entry.status != .working || !entry.text.isEmpty {
        let long = lines.count > 10
        Text(long && !expanded ? lines.suffix(10).joined(separator: "\n") : entry.text)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(Palette.ink)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        if long || entry.truncated {
          Button(expanded ? "Vis mindre" : "Vis mer") {
            withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
          }
          .buttonStyle(.plain)
          .font(Typography.caption.weight(.semibold))
          .foregroundStyle(Palette.accent)
        }
      }
    }
    .padding(Spacing.sm)
    .pastelGlass(radius: 16, tint: entry.status == .working ? DS.Pastel.sky : DS.Pastel.mint, tintOpacity: hovering ? 0.14 : 0.07, shadow: false)
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(entry.status == .working ? DS.Pastel.sky : .clear, lineWidth: 1.5))
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { if let id = entry.from { model.revealCard(id) } }
    .help("Klikk for å vise kortet på brettet")
    .animation(.easeOut(duration: 0.15), value: hovering)
  }
}

struct BoardChatWorking: View {
  let name: String
  let since: Date
  var body: some View {
    HStack(spacing: 5) {
      ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 12, height: 12)
      TimelineView(.periodic(from: since, by: 1)) { context in
        Text("\(name) jobber… \(chatElapsed(context.date.timeIntervalSince(since)))")
          .font(Typography.caption).foregroundStyle(Palette.secondaryInk).monospacedDigit()
      }
    }
  }
}

func chatElapsed(_ seconds: TimeInterval) -> String {
  let s = max(0, Int(seconds))
  return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
}
