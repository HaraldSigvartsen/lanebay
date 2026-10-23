import SwiftUI

public struct RailButton: View {
    public let icon: Icon
    public let title: String
    public var isSelected: Bool
    public let action: () -> Void

    public init(_ icon: Icon, title: String, isSelected: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.xxs) {
                icon.image.font(.system(size: 17, weight: .medium))
                Text(title).font(Typography.caption).lineLimit(1)
            }
            .foregroundStyle(isSelected ? Palette.accent : Palette.secondaryInk)
            .frame(width: BoardRailMetrics.buttonWidth, height: BoardRailMetrics.buttonHeight)
            .background(isSelected ? Palette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Spacing.radiusSmall))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview { VStack { RailButton(.workspace, title: "Board", isSelected: true) {}; RailButton(.settings, title: "Settings") {} }.padding().background(Palette.canvas) }
