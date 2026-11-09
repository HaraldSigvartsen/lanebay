import SwiftUI

extension DS {
    /// Shadow recipes from `docs/REDESIGN.md` ("Materials and elevation").
    public struct Elevation: Sendable {
        public let color: SwiftUI.Color
        public let radius: CGFloat
        public let y: CGFloat

        public init(color: SwiftUI.Color, radius: CGFloat, y: CGFloat) {
            self.color = color
            self.radius = radius
            self.y = y
        }

        public static let flat = Elevation(color: .clear, radius: 0, y: 0)
        public static let raised = Elevation(color: .black.opacity(0.10), radius: 12, y: 4)
        public static let floating = Elevation(color: .black.opacity(0.18), radius: 28, y: 12)
    }
}

public extension View {
    func elevation(_ elevation: DS.Elevation) -> some View {
        shadow(color: elevation.color, radius: elevation.radius, y: elevation.y)
    }

    /// Material background, continuous rounded clip and a hairline border.
    func glass(radius: CGFloat = DS.Radius.card, material: Material = .regularMaterial) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(material, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(DS.Color.hairline, lineWidth: 1))
    }
}
