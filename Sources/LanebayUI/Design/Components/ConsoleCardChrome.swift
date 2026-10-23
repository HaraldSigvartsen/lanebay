import SwiftUI

public struct ConsoleCardChrome<Content: View>: View {
    @FocusState private var isFocused: Bool
    public let title: String
    public let icon: Icon
    public let status: AgentStatus
    public let isSelected: Bool
    private var onHeaderSelect: (() -> Void)?
    private var onHeaderDrag: ((CGSize) -> Void)?
    private var onHeaderDragEnd: (() -> Void)?
    private var hasKeyboardFocus = false
    private var exitCode: Int32?
    private var statusIdentifier: String?
    private var controls: (() -> AnyView)?
    private let menu: (() -> AnyView)?
    @ViewBuilder public let content: Content

    public init<Menu: View>(title: String, icon: Icon = .terminal, status: AgentStatus, isSelected: Bool = false, @ViewBuilder menu: @escaping () -> Menu, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.status = status
        self.isSelected = isSelected
        self.menu = { AnyView(menu()) }
        self.content = content()
    }

    public init(title: String, icon: Icon = .terminal, status: AgentStatus, isSelected: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.status = status
        self.isSelected = isSelected
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

    /// Exit code is shown on the light once the process has been reaped. The identifier is per card.
    public func statusDetail(exitCode: Int32?, identifier: String) -> Self {
        var copy = self
        copy.exitCode = exitCode
        copy.statusIdentifier = identifier
        return copy
    }

    /// Header actions sit outside the drag gesture so a click reaches the button.
    public func headerControls<Controls: View>(@ViewBuilder _ controls: @escaping () -> Controls) -> Self {
        var copy = self
        copy.controls = { AnyView(controls()) }
        return copy
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    icon.image.foregroundStyle(Palette.accent)
                    Text(title).font(Typography.bodyEmphasis).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                    StatusLight(status, exitCode: exitCode, showsLabel: true, identifier: statusIdentifier).fixedSize()
                    Spacer(minLength: Spacing.xs)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { onHeaderSelect?() })
                .simultaneousGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("boardViewport"))
                    .onChanged { onHeaderDrag?($0.translation) }
                    .onEnded { _ in onHeaderDragEnd?() })
                if let controls { controls() }
                if let menu {
                    Menu { menu() } label: { Icon.menu.image.foregroundStyle(Palette.secondaryInk).frame(width: 28, height: 28).contentShape(Rectangle()) }
                        .menuStyle(.borderlessButton).accessibilityLabel("\(title) options").help("Console menu")
                }
            }
            .padding(.horizontal, Spacing.md).frame(height: 40)
            .background(Palette.raisedSurface)
            Rectangle().fill(Palette.border).frame(height: 1)
            content
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.radiusMedium))
        .overlay(RoundedRectangle(cornerRadius: Spacing.radiusMedium).stroke(isSelected ? Palette.accent : Palette.border, lineWidth: isSelected ? 2 : 1))
        .frame(minWidth: 280)
        .focusable()
        .focused($isFocused)
        .onKeyPress(.space) { isFocused = true; return .handled }
        .overlay {
            RoundedRectangle(cornerRadius: Spacing.radiusMedium)
                .stroke(Palette.focus, lineWidth: 2)
                .padding(1)
                .opacity(isFocused || hasKeyboardFocus ? 1 : 0)
                .allowsHitTesting(false)
        }
        .shadow(color: Spacing.elevationSoft.color, radius: Spacing.elevationSoft.radius, y: Spacing.elevationSoft.y)
    }
}

#Preview { ConsoleCardChrome(title: "Claude Code", status: .running, menu: { Button("Close console") {} }) { Text("$ Ready").font(Typography.terminal).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding() }.frame(width: 360, height: 220).padding() }
