import SwiftUI

/// Every list or panel that can be empty shows what it is for and one button to get started.
public struct EmptyStateView: View {
    public let symbol: String
    public let title: String
    public let message: String?
    public let actionTitle: String?
    public let action: (() -> Void)?
    public let identifier: String

    public init(
        symbol: String,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        identifier: String = ""
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.identifier = identifier
    }

    public var body: some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(DS.Color.accent)
                .frame(width: 52, height: 52)
                .background(DS.Color.accentSoft, in: Circle())

            Text(title)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.lbPrimary)
                    .padding(.top, DS.Space.xxs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.lg)
        .accessibilityIdentifier(identifier)
    }
}
