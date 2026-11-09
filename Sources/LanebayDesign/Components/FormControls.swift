import SwiftUI

/// Token-styled text field: raised surface, hairline border, chip radius. Use `.textFieldStyle(.lbField)`.
public struct LBFieldStyle: TextFieldStyle {
    public init() {}
    public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(DS.Color.raisedSurface))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .strokeBorder(DS.Color.hairline, lineWidth: 1))
    }
}

extension TextFieldStyle where Self == LBFieldStyle {
    public static var lbField: LBFieldStyle { LBFieldStyle() }
}

/// A labelled form field: caption label above the control, optional hint below.
public struct FormField<Content: View>: View {
    private let label: String
    private let hint: String?
    private let content: Content

    public init(_ label: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.hint = hint
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(label)
                .font(DS.Font.caption.weight(.semibold))
                .foregroundStyle(DS.Color.secondaryInk)
            content
            if let hint {
                Text(hint)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.mutedInk)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Multi-line editor chrome matching `.lbField`.
public struct LBEditorChrome: ViewModifier {
    let minHeight: CGFloat
    let monospaced: Bool
    public func body(content: Content) -> some View {
        content
            .font(monospaced ? DS.Font.mono : DS.Font.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(DS.Color.raisedSurface))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .strokeBorder(DS.Color.hairline, lineWidth: 1))
    }
}

extension View {
    /// Styles a `TextEditor` like `.lbField`.
    public func lbEditor(minHeight: CGFloat = 88, monospaced: Bool = false) -> some View {
        modifier(LBEditorChrome(minHeight: minHeight, monospaced: monospaced))
    }
}

/// Inline status line under a form: info, success or error tone with a matching symbol.
public struct FormStatus: View {
    public enum Tone { case info, success, error }
    private let text: String
    private let tone: Tone

    public init(_ text: String, tone: Tone = .info) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Label {
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(DS.Font.caption)
        .foregroundStyle(color)
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .fill(color.opacity(0.12)))
    }

    private var symbol: String {
        switch tone {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    private var color: SwiftUI.Color {
        switch tone {
        case .info: DS.Color.accentInk
        case .success: DS.Color.statusColors[.done] ?? DS.Color.accentInk
        case .error: DS.Color.statusColors[.error] ?? DS.Color.accentHot
        }
    }
}

/// Small footnote for a panel's safety or scope rules.
public struct PanelFootnote: View {
    private let text: String
    private let symbol: String
    public init(_ text: String, symbol: String = "lock.shield") {
        self.text = text
        self.symbol = symbol
    }
    public var body: some View {
        Label(text, systemImage: symbol)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.mutedInk)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
