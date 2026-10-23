import SwiftUI

public struct StatusLight: View {
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
        let row = HStack(spacing: Spacing.xxs) {
            status.symbol.image.foregroundStyle(Palette.status(status)).font(Typography.caption)
            if showsLabel {
                Text(label).font(Typography.caption).foregroundStyle(Palette.secondaryInk)
            }
        }
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
        case .running: "Running"
        case .waitingForInput: "Waiting for input"
        case .idle: "Idle"
        case .stopped: "Stopped"
        case .finished: exitCode.map { "Exited \($0)" } ?? "Finished"
        case .error: exitCode.map { "Exited \($0)" } ?? "Error"
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
