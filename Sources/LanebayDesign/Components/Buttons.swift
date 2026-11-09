import SwiftUI

/// Button styles from `docs/REDESIGN.md` ("Buttons"). Accessibility identifiers stay on the
/// call sites — the styles only change appearance, hover and press feedback.
private enum LBButtonKind {
    case primary
    case secondary
    case ghost
    case icon
}

private struct LBButtonLabel<Label: View>: View {
    let kind: LBButtonKind
    let label: Label
    let isPressed: Bool

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .font(font)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .icon ? 0 : DS.Space.md)
            .padding(.vertical, kind == .icon ? 0 : DS.Space.xs)
            .frame(width: kind == .icon ? 28 : nil, height: kind == .icon ? 28 : nil)
            .background { backgroundShape }
            .overlay { border }
            .contentShape(Rectangle())
            .scaleEffect(isPressed ? 0.97 : 1)
            .brightness(kind == .primary && isHovered ? 0.05 : 0)
            .elevation(isHovered ? DS.Elevation.raised : .flat)
            .animation(DS.Motion.animation(DS.Motion.snappy, reduceMotion: reduceMotion), value: isPressed)
            .animation(DS.Motion.animation(DS.Motion.snappy, reduceMotion: reduceMotion), value: isHovered)
            .onHover { isHovered = $0 }
    }

    private var font: Font {
        switch kind {
        case .primary, .secondary: DS.Font.headline
        case .ghost, .icon: DS.Font.body
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: DS.Color.accentInk
        case .ghost: isHovered ? DS.Color.ink : DS.Color.secondaryInk
        case .icon: isHovered ? DS.Color.accent : DS.Color.secondaryInk
        }
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(DS.Color.accentGradient)
        case .secondary: AnyShapeStyle(DS.Color.accentSoft)
        case .ghost: AnyShapeStyle(isHovered ? DS.Color.accentSoft.opacity(0.6) : Color.clear)
        case .icon: AnyShapeStyle(isHovered ? DS.Color.accentSoft : Color.clear)
        }
    }

    private var radius: CGFloat { DS.Radius.control }

    @ViewBuilder private var backgroundShape: some View {
        if kind == .icon {
            Circle().fill(fill)
        } else {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
        }
    }

    @ViewBuilder private var border: some View {
        if kind == .primary {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
    }
}

public struct LBPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        LBButtonLabel(kind: .primary, label: configuration.label, isPressed: configuration.isPressed)
    }
}

public struct LBSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        LBButtonLabel(kind: .secondary, label: configuration.label, isPressed: configuration.isPressed)
    }
}

public struct LBGhostButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        LBButtonLabel(kind: .ghost, label: configuration.label, isPressed: configuration.isPressed)
    }
}

public struct LBIconButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        LBButtonLabel(kind: .icon, label: configuration.label, isPressed: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == LBPrimaryButtonStyle {
    static var lbPrimary: LBPrimaryButtonStyle { LBPrimaryButtonStyle() }
}

public extension ButtonStyle where Self == LBSecondaryButtonStyle {
    static var lbSecondary: LBSecondaryButtonStyle { LBSecondaryButtonStyle() }
}

public extension ButtonStyle where Self == LBGhostButtonStyle {
    static var lbGhost: LBGhostButtonStyle { LBGhostButtonStyle() }
}

public extension ButtonStyle where Self == LBIconButtonStyle {
    static var lbIcon: LBIconButtonStyle { LBIconButtonStyle() }
}
