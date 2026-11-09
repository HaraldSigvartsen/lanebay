import SwiftUI

public struct StatusLight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false
    public let status: AgentStatus
    public var exitCode: Int32?
    public var showsLabel: Bool
    public var identifier: String?

    public init(_ status: AgentStatus, exitCode: Int32? = nil, showsLabel: Bool = true, identifier: String? = nil) {
        self.status = status
        self.exitCode = exitCode
        self.showsLabel = showsLabel
        self.identifier = identifier
    }

    public var body: some View {
        let label = status.label(exitCode: exitCode)
        let pulses = !reduceMotion && CardStatusStyle.pulses(status)
        let row = HStack(spacing: Spacing.xxs) {
            status.symbol.image
                .foregroundStyle(Palette.status(status))
                .font(Typography.caption)
                .scaleEffect(isPulsing ? 1.35 : 1)
                .opacity(isPulsing ? 0.5 : 1)
                .animation(
                    pulses ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : nil,
                    value: isPulsing)
            if showsLabel {
                Text(label).font(Typography.caption).foregroundStyle(Palette.secondaryInk)
            }
        }
        .onAppear { isPulsing = pulses }
        .onChange(of: pulses) { _, newValue in isPulsing = newValue }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(label)")
        if let identifier {
            row.accessibilityIdentifier(identifier)
        } else {
            row
        }
    }
}

extension AgentStatus {
    /// Visible status name. A reaped process includes its exit code.
    public func label(exitCode: Int32? = nil) -> String {
        switch self {
        case .running: "Kjører"
        case .waitingForInput: "Venter på deg"
        case .idle: "Ledig"
        case .stopped: "Stoppet"
        case .finished: exitCode.map { "Avsluttet \($0)" } ?? "Ferdig"
        case .error: exitCode.map { "Avsluttet \($0)" } ?? "Feil"
        }
    }
}

private extension AgentStatus {
    var symbol: Icon {
        switch self {
        case .running: .activity
        case .waitingForInput: .warning
        case .idle: .terminal
        case .stopped: .pause
        case .finished: .check
        case .error: .close
        }
    }
}

#Preview { StatusLight(.running).padding() }
