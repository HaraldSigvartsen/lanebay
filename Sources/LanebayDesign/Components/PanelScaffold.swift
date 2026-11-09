import SwiftUI

/// One scaffold for every side panel: header, divider, scrollable content, same padding everywhere.
/// An uppercase caption above a glass card. The unit every side panel groups its content in.
public struct PanelSection<Content: View>: View {
    private let caption: String
    private let fillsHeight: Bool
    private let content: Content

    /// - Parameter fillsHeight: lets the card grow into the panel's leftover height, for split file browsers.
    public init(_ caption: String, fillsHeight: Bool = false, @ViewBuilder content: () -> Content) {
        self.caption = caption
        self.fillsHeight = fillsHeight
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(caption).sectionCaptionStyle()
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                content
            }
            .padding(DS.Space.sm)
            .frame(
                maxWidth: .infinity,
                maxHeight: fillsHeight ? .infinity : nil,
                alignment: .topLeading)
            .glass(radius: DS.Radius.card)
            .shadow(color: DS.Color.cardShadow, radius: 6, y: 2)
        }
    }
}

/// A selectable row inside a panel list: 12 pt vertical padding and an `accentSoft` hover fill.
public struct PanelRow<Content: View>: View {
    public let isSelected: Bool
    private let content: Content

    @State private var isHovered = false

    public init(isSelected: Bool = false, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, DS.Space.sm)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(isHovered || isSelected ? DS.Color.accentSoft : Color.clear)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

public struct PanelScaffold<Content: View, Actions: View>: View {
    private let title: String
    private let subtitle: String?
    private let actions: Actions
    private let content: Content

    public init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title)
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Color.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.secondaryInk)
                    }
                }
                Spacer(minLength: DS.Space.xs)
                actions
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)

            Rectangle()
                .fill(DS.Color.hairline)
                .frame(height: 1)

            ScrollView {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(DS.Space.md)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
