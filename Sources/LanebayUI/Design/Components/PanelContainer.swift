import SwiftUI

/// A glass card with a title and subtitle; used for grouped content on the board.
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
        VStack(alignment: .leading, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(DS.Font.title).foregroundStyle(DS.Color.ink)
                if let subtitle { Text(subtitle).font(DS.Font.body).foregroundStyle(DS.Color.secondaryInk) }
            }
            content
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(radius: DS.Radius.card)
        .elevation(DS.Elevation.raised)
    }
}

/// The shared side-panel shell used by utility panels alongside the board.
/// Header and padding match `PanelScaffold`; the body scrolls itself so panels can nest
/// their own timelines and lists.
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title).font(DS.Font.title).foregroundStyle(DS.Color.ink)
                    if let subtitle {
                        Text(subtitle).font(DS.Font.body).foregroundStyle(DS.Color.secondaryInk)
                    }
                }
                Spacer(minLength: DS.Space.xs)
                Button(action: onClose) {
                    Icon.close.image
                        .foregroundStyle(DS.Pastel.lavenderInk)
                        .frame(width: 30, height: 30)
                        .pastelFill(DS.Pastel.lavender, radius: 15)
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Lukk \(title)")
            }
            .padding(.horizontal, DS.Pastel.dialogPadding)
            .padding(.top, DS.Pastel.dialogPadding)
            .padding(.bottom, DS.Pastel.sectionSpacing)

            Rectangle().fill(DS.Color.hairline.opacity(0.6)).frame(height: 1)
                .padding(.horizontal, DS.Pastel.dialogPadding)

            content
                .padding(.horizontal, DS.Pastel.dialogPadding - DS.Space.sm)
                .padding(.top, DS.Space.sm)
                .padding(.bottom, DS.Pastel.dialogPadding - DS.Space.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pastelGlass(radius: DS.Pastel.dialogRadius, tint: DS.Pastel.lavender, tintOpacity: 0.12)
        .accessibilityIdentifier(identifier)
        .overlay(alignment: .topLeading) {
            PanelMarker(identifier: identifier, label: title)
                .frame(width: 4, height: 4)
                .allowsHitTesting(false)
        }
    }
}

#Preview { PanelContainer(title: "Workspace", subtitle: "Local agent board") { Text("Panel content").font(DS.Font.body).foregroundStyle(DS.Color.secondaryInk) }.frame(width: 420, height: 260).padding().background(DS.Color.canvas) }
