import AppKit
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

/// Lanebay's semantic color system. Colors adapt to the current macOS appearance.
public enum Palette {
    public static let canvas = adaptive(light: 0xF2F5F6, dark: 0x11191F)
    public static let surface = adaptive(light: 0xFFFFFF, dark: 0x1A252D)
    public static let raisedSurface = adaptive(light: 0xF8FAFA, dark: 0x202D36)
    public static let border = adaptive(light: 0xD8E1E4, dark: 0x30414B, highContrastLight: 0x71828A, highContrastDark: 0x82939B)
    public static let ink = adaptive(light: 0x172630, dark: 0xE6EFF1)
    public static let secondaryInk = adaptive(light: 0x60727B, dark: 0x9EAFB6)
    public static let mutedInk = adaptive(light: 0x65757C, dark: 0x8B9AA1)
    public static let accent = adaptive(light: 0x087276, dark: 0x63D6C4)
    public static let accentSoft = adaptive(light: 0xD8F1EC, dark: 0x234842)

    public static let statusColors: [AgentStatus: Color] = [
        .running: semantic(light: 0x3478D4, dark: 0x70A9FF),
        .waitingForInput: semantic(light: 0xB66A0A, dark: 0xF2B84B),
        .idle: semantic(light: 0x25805A, dark: 0x62C994),
        .stopped: semantic(light: 0x697780, dark: 0xA0ABB1),
        .finished: semantic(light: 0x7654BD, dark: 0xB79AF5),
        .error: semantic(light: 0xC33D43, dark: 0xFF7778),
    ]

    public static func status(_ status: AgentStatus) -> Color {
        guard let color = statusColors[status] else {
            preconditionFailure("Missing palette color for status: \(status)")
        }
        return color
    }

    public static let focus = Color(nsColor: .keyboardFocusIndicatorColor)
    public static let selection = Color(nsColor: .selectedContentBackgroundColor)
    public static let increasedContrastBorder = border

    private static func adaptive(light: UInt, dark: UInt, highContrastLight: UInt? = nil, highContrastDark: UInt? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            if match == .accessibilityHighContrastDarkAqua, let highContrastDark { return nsColor(highContrastDark) }
            if match == .accessibilityHighContrastAqua, let highContrastLight { return nsColor(highContrastLight) }
            return nsColor(isDark ? dark : light)
        })
    }

    private static func semantic(light: UInt, dark: UInt) -> Color {
        adaptive(light: light, dark: dark)
    }

    private static func nsColor(_ rgb: UInt) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
