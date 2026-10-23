import SwiftUI

public struct PanelContainer<Content: View>: View {
    public let title: String
    public let subtitle: String?
    @ViewBuilder public let content: Content

    public init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title).font(Typography.title).foregroundStyle(Palette.ink)
                if let subtitle { Text(subtitle).font(Typography.caption).foregroundStyle(Palette.secondaryInk) }
            }
            content
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Spacing.radiusLarge))
        .overlay(RoundedRectangle(cornerRadius: Spacing.radiusLarge).stroke(Palette.border, lineWidth: 1))
    }
}

/// The shared side-panel shell used by utility panels alongside the board.
public struct PanelHost<Content: View>: View {
    public let title: String
    public let subtitle: String?
    public let identifier: String
    public let onClose: () -> Void
    @ViewBuilder public let content: Content

    public init(
        title: String,
        subtitle: String? = nil,
        identifier: String = "panel.host",
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.identifier = identifier
        self.onClose = onClose
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title).font(Typography.title).foregroundStyle(Palette.ink)
                    if let subtitle {
                        Text(subtitle).font(Typography.caption).foregroundStyle(Palette.secondaryInk)
                    }
                }
                Spacer(minLength: Spacing.xs)
                Button(action: onClose) { Icon.close.image }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.secondaryInk)
                    .accessibilityLabel("Close \(title) panel")
            }
            .padding(Spacing.md)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.border).frame(width: 1) }
        .accessibilityIdentifier(identifier)
        .overlay(alignment: .topLeading) {
            PanelMarker(identifier: identifier, label: title)
                .frame(width: 4, height: 4)
                .allowsHitTesting(false)
        }
    }
}

#Preview { PanelContainer(title: "Workspace", subtitle: "Local agent board") { Text("Panel content").font(Typography.body).foregroundStyle(Palette.secondaryInk) }.frame(width: 420, height: 260).padding().background(Palette.canvas) }
