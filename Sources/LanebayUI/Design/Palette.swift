import SwiftUI

public enum AgentStatus: String, CaseIterable, Sendable, Codable {
    case running
    case waitingForInput
    case idle
    case stopped
    case finished
    case error

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let value = AgentStatus(rawValue: raw) {
            self = value
            return
        }
        switch raw {
        case "working": self = .running // legacy key
        case "needsYou": self = .waitingForInput // legacy key
        case "resting": self = .idle // legacy key
        case "paused": self = .stopped // legacy key
        case "done": self = .finished // legacy key
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown agent status: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension AgentStatus {
    /// The coarse design-system state this agent status maps to.
    public var statusKind: StatusKind {
        switch self {
        case .running: .running
        case .waitingForInput: .waiting
        case .idle: .done
        case .stopped: .stopped
        case .finished: .done
        case .error: .error
        }
    }
}

/// Lanebay's semantic color system, forwarded to the shared `LanebayDesign` tokens.
/// Colors adapt to the current macOS appearance.
public enum Palette {
    public static let canvas = DS.Color.canvas
    public static let surface = DS.Color.surface
    public static let raisedSurface = DS.Color.raisedSurface
    public static let border = DS.Color.hairline
    public static let ink = DS.Color.ink
    public static let secondaryInk = DS.Color.secondaryInk
    public static let mutedInk = DS.Color.mutedInk
    public static let accent = DS.Color.accent
    public static let accentSoft = DS.Color.accentSoft
    public static let accentInk = DS.Color.accentInk
    public static let accentHot = DS.Color.accentHot
    public static let accentGradient = DS.Color.accentGradient

    public static let statusColors: [AgentStatus: Color] = Dictionary(
        uniqueKeysWithValues: AgentStatus.allCases.map { ($0, DS.Color.status($0.statusKind)) }
    )

    public static func status(_ status: AgentStatus) -> Color {
        DS.Color.status(status.statusKind)
    }

    public static let focus = DS.Color.focus
    public static let selection = DS.Color.selection
    public static let increasedContrastBorder = border
}
