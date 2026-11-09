import SwiftUI

extension DS {
    /// Soft pastel accents for dialogs, chips and the chat. Each colour adapts to light and dark mode.
    public enum Pastel {
        public static let lavender = adaptive(light: (0.80, 0.76, 0.98), dark: (0.66, 0.60, 0.95))
        public static let mint = adaptive(light: (0.72, 0.93, 0.84), dark: (0.50, 0.84, 0.70))
        public static let peach = adaptive(light: (1.00, 0.84, 0.74), dark: (0.98, 0.70, 0.56))
        public static let sky = adaptive(light: (0.74, 0.87, 1.00), dark: (0.52, 0.72, 0.98))
        public static let all: [SwiftUI.Color] = [lavender, mint, sky, peach]

        /// Pastel ink: a deeper shade of a pastel, readable as text on its own soft fill.
        public static let lavenderInk = adaptive(light: (0.36, 0.28, 0.72), dark: (0.80, 0.76, 1.00))
        public static let mintInk = adaptive(light: (0.12, 0.48, 0.34), dark: (0.66, 0.94, 0.80))
        public static let peachInk = adaptive(light: (0.70, 0.36, 0.16), dark: (1.00, 0.80, 0.68))
        public static let skyInk = adaptive(light: (0.16, 0.40, 0.72), dark: (0.72, 0.85, 1.00))

        /// Edge padding and section spacing for dialogs.
        public static let dialogRadius: CGFloat = 24
        public static let dialogPadding: CGFloat = 28
        public static let sectionSpacing: CGFloat = 20
        public static let controlRadius: CGFloat = 12

        private static func adaptive(
            light: (Double, Double, Double), dark: (Double, Double, Double)
        ) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let c = isDark ? dark : light
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
            })
        }
    }
}

public extension View {
    /// Translucent glass with a faint pastel tint, a thin light border and a soft shadow.
    func pastelGlass(
        radius: CGFloat = DS.Pastel.dialogRadius, tint: SwiftUI.Color = DS.Pastel.lavender,
        tintOpacity: Double = 0.10, shadow: Bool = true
    ) -> some View {
        modifier(PastelGlass(radius: radius, tint: tint, tintOpacity: tintOpacity, shadow: shadow))
    }

    /// A soft pastel fill with a matching border, for chips, section cards and quiet buttons.
    func pastelFill(_ color: SwiftUI.Color, radius: CGFloat = DS.Pastel.controlRadius, opacity: Double = 0.22) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(color.opacity(opacity), in: shape)
            .overlay(shape.strokeBorder(color.opacity(0.45), lineWidth: 1))
    }
}

struct PastelGlass: ViewModifier {
    let radius: CGFloat
    let tint: SwiftUI.Color
    let tintOpacity: Double
    let shadow: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    // A base wash keeps text readable over a busy board.
                    shape.fill(DS.Color.surface.opacity(scheme == .dark ? 0.55 : 0.62))
                    shape.fill(
                        LinearGradient(
                            colors: [tint.opacity(tintOpacity * 1.6), tint.opacity(tintOpacity * 0.4)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(SwiftUI.Color.white.opacity(scheme == .dark ? 0.14 : 0.7), lineWidth: 1))
            .shadow(color: shadow ? .black.opacity(scheme == .dark ? 0.35 : 0.12) : .clear, radius: 30, y: 14)
    }
}
