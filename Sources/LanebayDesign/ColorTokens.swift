import AppKit
import SwiftUI

/// The five coarse status states shown across the board.
public enum StatusKind: String, CaseIterable, Sendable, Codable {
    case running
    case waiting
    case done
    case error
    case stopped
}

extension DS {
    /// Adaptive semantic colours. Values adapt to the current macOS appearance
    /// (and to the accessibility high-contrast variants where a token defines one).
    public enum Color {
        public static let accent = adaptive(light: 0x5B5BF7, dark: 0x8B8BFF)
        /// Accent text on `accentSoft`. Deeper than `accent` in light mode so the pairing stays above 4.5:1.
        public static let accentInk = adaptive(light: 0x4444D8, dark: 0x8B8BFF)
        public static let accentSoft = adaptive(light: 0xE6E6FF, dark: 0x2A2A5C)
        public static let accentHot = adaptive(light: 0xE0367A, dark: 0xFF5C9A)
        public static let accentGradient = SwiftUI.LinearGradient(
            colors: [accent, accentHot],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        public static let canvas = adaptive(light: 0xE8E9F3, dark: 0x12121F)
        /// The board background: `canvas` with a soft gradient towards a slightly deeper canvas.
        public static let canvasGradient = SwiftUI.LinearGradient(
            colors: [canvasTop, canvas, canvasDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        /// A soft accent bloom drawn over `canvasGradient` behind the board.
        public static let canvasGlow = SwiftUI.RadialGradient(
            colors: [accent.opacity(0.16), accentHot.opacity(0.05), .clear],
            center: .topTrailing,
            startRadius: 40,
            endRadius: 900
        )
        /// Sidebar wash over the vibrancy material.
        public static let sidebarWash = SwiftUI.LinearGradient(
            colors: [accent.opacity(0.14), accentHot.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
        )

        public static let surface = adaptive(light: 0xFFFFFF, dark: 0x1C1B2E)
        public static let raisedSurface = adaptive(light: 0xF2F2FA, dark: 0x25243B)
        /// Hairline borders on cards, panels and sheets.
        public static let hairline = adaptive(
            light: 0xC3C7DA,
            dark: 0x38365E,
            highContrastLight: 0x71828A,
            highContrastDark: 0x82939B
        )

        /// Soft drop shadow that separates white cards from the light canvas; none in dark mode.
        public static let cardShadow = SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .clear : NSColor(srgbRed: 0.10, green: 0.10, blue: 0.25, alpha: 0.10)
        })

        public static let ink = adaptive(light: 0x14142B, dark: 0xF2F1FF)
        public static let secondaryInk = adaptive(light: 0x3E4058, dark: 0xB4B2D6)
        public static let mutedInk = adaptive(light: 0x55576F, dark: 0x9C9AC4)

        public static let focus = SwiftUI.Color(nsColor: .keyboardFocusIndicatorColor)
        public static let selection = SwiftUI.Color(nsColor: .selectedContentBackgroundColor)

        /// Status lights, card borders and glow tints.
        public static let statusColors: [StatusKind: SwiftUI.Color] = [
            .running: accent,
            .waiting: accentHot,
            .done: adaptive(light: 0x25805A, dark: 0x62C994),
            .error: adaptive(light: 0xC33D43, dark: 0xFF7778),
            .stopped: adaptive(light: 0x697780, dark: 0xA0ABB1),
        ]

        public static func status(_ kind: StatusKind) -> SwiftUI.Color {
            guard let color = statusColors[kind] else {
                preconditionFailure("Missing design colour for status: \(kind)")
            }
            return color
        }

        /// Deeper canvas used only as the far end of `canvasGradient`.
        public static let canvasDeep = adaptive(light: 0xDCDFEE, dark: 0x0B0D14)
        /// Indigo top-left end of `canvasGradient`.
        private static let canvasTop = adaptive(light: 0xE2E0F8, dark: 0x1B1446)

        // MARK: - Hex / adaptive helpers

        static func adaptive(
            light: UInt,
            dark: UInt,
            highContrastLight: UInt? = nil,
            highContrastDark: UInt? = nil
        ) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [
                    .accessibilityHighContrastDarkAqua,
                    .accessibilityHighContrastAqua,
                    .darkAqua,
                    .aqua,
                ])
                let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
                if match == .accessibilityHighContrastDarkAqua, let highContrastDark { return nsColor(highContrastDark) }
                if match == .accessibilityHighContrastAqua, let highContrastLight { return nsColor(highContrastLight) }
                return nsColor(isDark ? dark : light)
            })
        }

        static func nsColor(_ rgb: UInt) -> NSColor {
            NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}
