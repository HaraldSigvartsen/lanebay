import LanebayCore
import SwiftUI

/// Status colours for a console card. Kept separate from the view so the mapping can be tested.
public enum CardStatusStyle {
    /// Colours come from the design-system status palette. Idle keeps the resting grey so it stays
    /// distinguishable from a finished (done) agent.
    public static func tint(for status: AgentStatus) -> Color {
        status == .idle ? DS.Color.mutedInk : DS.Color.status(status.statusKind)
    }

    /// A stopped card stays flat; every live state gets a soft tinted halo.
    public static func glows(_ status: AgentStatus) -> Bool {
        status != .stopped
    }

    public static func pulses(_ status: AgentStatus) -> Bool {
        status == .running
    }
}

/// The latest visible line of terminal output, for the card's live activity strip.
public enum ConsoleActivityLine {
    public static func latest(in output: String, limit: Int = 120) -> String? {
        for raw in AgentTaskContract.plainText(output).split(whereSeparator: \.isNewline).reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !OutputDigest.isNoise(line) else { continue }
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }
        return nil
    }
}

public struct ConsoleCardChrome<Content: View>: View {
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isDragging = false
    public let title: String
    public let agentID: String
    public let status: AgentStatus
    public let isSelected: Bool
    public let activity: String?
    private var onHeaderSelect: (() -> Void)?
    private var onHeaderDrag: ((CGSize) -> Void)?
    private var onHeaderDragEnd: (() -> Void)?
    private var hasKeyboardFocus = false
    private var exitCode: Int32?
    private var statusIdentifier: String?
    private var controls: (() -> AnyView)?
    private let menu: (() -> AnyView)?
    private var isWorking = false
    private var editableTitle: String?
    private var isRenaming = false
    private var onRename: ((String?) -> Void)?
    private var onBeginRename: (() -> Void)?
    @State private var titleDraft = ""
    @FocusState private var titleFieldFocused: Bool
    @ViewBuilder public let content: Content

    public init<Menu: View>(
        title: String,
        agentID: String = "shell",
        status: AgentStatus,
        isSelected: Bool = false,
        activity: String? = nil,
        @ViewBuilder menu: @escaping () -> Menu,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.agentID = agentID
        self.status = status
        self.isSelected = isSelected
        self.activity = activity
        self.menu = { AnyView(menu()) }
        self.content = content()
    }

    public init(
        title: String,
        agentID: String = "shell",
        status: AgentStatus,
        isSelected: Bool = false,
        activity: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.agentID = agentID
        self.status = status
        self.isSelected = isSelected
        self.activity = activity
        self.menu = nil
        self.content = content()
    }

    public func headerDrag(onChanged: @escaping (CGSize) -> Void, onEnded: @escaping () -> Void) -> Self {
        var copy = self
        copy.onHeaderDrag = onChanged
        copy.onHeaderDragEnd = onEnded
        return copy
    }

    public func headerSelection(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.onHeaderSelect = action
        return copy
    }

    public func keyboardFocus(_ focused: Bool) -> Self {
        var copy = self
        copy.hasKeyboardFocus = focused
        return copy
    }

    /// Exit code is shown on the pill once the process has been reaped. The identifier is per card.
    public func statusDetail(exitCode: Int32?, identifier: String) -> Self {
        var copy = self
        copy.exitCode = exitCode
        copy.statusIdentifier = identifier
        return copy
    }

    /// A card working on a chat or wire message gets a "Jobber" badge and a pulsing edge.
    public func working(_ working: Bool) -> Self {
        var copy = self
        copy.isWorking = working
        return copy
    }

    /// Double-click the title to rename. `onCommit(nil)` cancels.
    public func renamable(
        name: String, isRenaming: Bool, onBegin: @escaping () -> Void, onCommit: @escaping (String?) -> Void
    ) -> Self {
        var copy = self
        copy.editableTitle = name
        copy.isRenaming = isRenaming
        copy.onBeginRename = onBegin
        copy.onRename = onCommit
        return copy
    }

    @ViewBuilder private var titleView: some View {
        if isRenaming {
            TextField("Navn", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(DS.Font.headline)
                .foregroundStyle(DS.Color.ink)
                .padding(.horizontal, DS.Space.xs)
                .frame(height: 26)
                .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Color.focus, lineWidth: 1.5))
                .frame(maxWidth: 220)
                .focused($titleFieldFocused)
                .onAppear {
                    titleDraft = editableTitle ?? title
                    // The card and its terminal hold focus during this pass; take it on the next run loop.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { titleFieldFocused = true }
                }
                .onSubmit { onRename?(titleDraft) }
                .onExitCommand { onRename?(nil) }
                .onChange(of: titleFieldFocused) { _, focused in
                    if !focused, isRenaming { onRename?(titleDraft) }
                }
                .accessibilityLabel("Nytt navn for \(title)")
        } else {
            Text(title)
                .font(DS.Font.headline)
                .foregroundStyle(DS.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
                .onTapGesture(count: 2) { onBeginRename?() }
                .help(onBeginRename == nil ? title : "Dobbeltklikk for å gi nytt navn")
        }
    }

    private var workingBadge: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            Text("Jobber").font(DS.Font.caption.weight(.semibold))
        }
        .foregroundStyle(DS.Color.accentInk)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(DS.Color.accentSoft, in: Capsule())
        .overlay(Capsule().stroke(DS.Color.accent.opacity(0.5), lineWidth: 1))
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .accessibilityLabel("Jobber")
    }

    /// Header actions sit outside the drag gesture so a click reaches the button.
    public func headerControls<Controls: View>(@ViewBuilder _ controls: @escaping () -> Controls) -> Self {
        var copy = self
        copy.controls = { AnyView(controls()) }
        return copy
    }

    public var body: some View {
        let tint = CardStatusStyle.tint(for: status)
        let isFloating = isSelected || isHovering || isDragging
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.xs) {
                    ProviderBadge(agentID: agentID, size: 18)
                    titleView
                    if isWorking { workingBadge } else { statusPill }
                    Spacer(minLength: DS.Space.xs)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { onHeaderSelect?() })
                .simultaneousGesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .named("boardViewport"))
                        .onChanged { value in
                            if !isDragging { isDragging = true }
                            onHeaderDrag?(value.translation)
                        }
                        .onEnded { _ in
                            isDragging = false
                            onHeaderDragEnd?()
                        })
                if let controls { controls() }
                if let menu {
                    Menu { menu() } label: {
                        Icon.menu.image.foregroundStyle(DS.Color.secondaryInk)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("\(title) options")
                    .help("Console menu")
                }
            }
            .padding(.horizontal, DS.Space.md)
            .frame(height: 44)
            .background(
                LinearGradient(
                    colors: [tint.opacity(0.26), tint.opacity(0.06)],
                    startPoint: .leading, endPoint: .trailing))
            .background(DS.Color.raisedSurface)
            activityStrip
            Rectangle().fill(DS.Color.hairline).frame(height: 1)
            content
                .padding(DS.Space.sm)
        }
        .background(
            DS.Color.surface.opacity(0.85),
            in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .glass(radius: DS.Radius.card)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .stroke(tint, lineWidth: isSelected ? 2.5 : 1.5))
        .frame(minWidth: 420)
        .scaleEffect(isHovering ? 1.01 : 1)
        .elevation(isFloating ? DS.Elevation.floating : DS.Elevation.raised)
        .shadow(
            color: CardStatusStyle.glows(status) ? tint.opacity(0.35) : .clear,
            radius: 14)
        .animation(DS.Motion.animation(DS.Motion.snappy, reduceMotion: reduceMotion), value: isHovering)
        .animation(DS.Motion.animation(DS.Motion.snappy, reduceMotion: reduceMotion), value: isSelected)
        .animation(DS.Motion.animation(DS.Motion.snappy, reduceMotion: reduceMotion), value: activity)
        .animation(.easeInOut(duration: 0.25), value: status)
        .animation(DS.Motion.animation(DS.Motion.snappy, reduceMotion: reduceMotion), value: isWorking)
        .overlay {
            if isWorking {
                WorkingEdge(radius: DS.Radius.card, color: DS.Color.accent, reduceMotion: reduceMotion)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering in isHovering = hovering }
        .focusable()
        .focused($isFocused)
        .onKeyPress(.space) { isFocused = true; return .handled }
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .stroke(DS.Color.focus, lineWidth: 2)
                .padding(1)
                .opacity(isFocused || hasKeyboardFocus ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    private var statusPill: some View {
        let pill = StatusPill(kind: status.statusKind, label: status.label(exitCode: exitCode))
        return Group {
            if let statusIdentifier {
                pill.accessibilityIdentifier(statusIdentifier)
            } else {
                pill
            }
        }
        .fixedSize()
    }

    /// One line of live activity: the newest output line, or the short task the agent is running.
    @ViewBuilder private var activityStrip: some View {
        if let activity {
            Text(activity)
                .font(DS.Font.mono)
                .foregroundStyle(DS.Color.secondaryInk)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.md)
                .padding(.bottom, DS.Space.xxs)
                .id(activity)
                .transition(DS.Motion.appear)
                .accessibilityIdentifier("console.activity")
        }
    }
}

#Preview {
    ConsoleCardChrome(
        title: "Claude Code", agentID: "claude", status: .running,
        activity: "working on: Ship the board polish",
        menu: { Button("Close console") {} }
    ) {
        Text("$ Ready")
            .font(DS.Font.mono)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
    }
    .frame(width: 360, height: 220)
    .padding()
}


/// A soft breathing ring around a card that is answering a message.
struct WorkingEdge: View {
    let radius: CGFloat
    let color: Color
    let reduceMotion: Bool
    @State private var lit = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(color.opacity(lit ? 0.9 : 0.35), lineWidth: 2.5)
            .shadow(color: color.opacity(lit ? 0.45 : 0.1), radius: lit ? 16 : 6)
            .onAppear {
                guard !reduceMotion else { lit = true; return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { lit = true }
            }
    }
}
