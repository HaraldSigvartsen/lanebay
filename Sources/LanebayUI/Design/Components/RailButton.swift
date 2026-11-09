import SwiftUI

public struct RailButton: View {
    public let icon: Icon
    public let title: String
    public var isSelected: Bool
    public let action: () -> Void

    @State private var isHovering = false

    public init(_ icon: Icon, title: String, isSelected: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.xxs) {
                icon.image.font(.system(size: 18, weight: .medium))
                Text(title).font(Typography.caption).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(isSelected ? Palette.accentInk : Palette.secondaryInk)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.sm)
            .frame(width: BoardRailMetrics.buttonWidth, height: BoardRailMetrics.buttonHeight)
            .background(isSelected ? Palette.accentSoft : Color.clear, in: Capsule())
            .overlay {
                if isSelected {
                    Capsule().stroke(Palette.accent.opacity(0.35), lineWidth: 1)
                }
            }
            .scaleEffect(isHovering ? 1.02 : 1)
            .shadow(
                color: isHovering ? Spacing.elevationRaised.color : .clear,
                radius: Spacing.elevationRaised.radius,
                y: Spacing.elevationRaised.y
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isHovering = hovering } }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSelected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview { VStack(spacing: Spacing.xs) { RailButton(.workspace, title: "Board", isSelected: true) {}; RailButton(.settings, title: "Settings") {} }.padding().background(Palette.canvas) }
