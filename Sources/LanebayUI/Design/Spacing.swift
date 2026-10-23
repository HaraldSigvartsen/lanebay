import SwiftUI

public enum Spacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48

    public static let radiusSmall: CGFloat = 6
    public static let radiusMedium: CGFloat = 10
    public static let radiusLarge: CGFloat = 14

    public static let shadowSoft = Color.black.opacity(0.07)
    public static let shadowRaised = Color.black.opacity(0.14)
    public static let elevationSoft = Shadow(color: shadowSoft, radius: 4, y: 2)
    public static let elevationRaised = Shadow(color: shadowRaised, radius: 12, y: 5)
}

public struct Shadow: Sendable {
    public let color: Color
    public let radius: CGFloat
    public let y: CGFloat

    public init(color: Color, radius: CGFloat, y: CGFloat) {
        self.color = color
        self.radius = radius
        self.y = y
    }
}
