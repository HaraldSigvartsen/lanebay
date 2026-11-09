import SwiftUI

/// Forwarded to the shared `LanebayDesign` spacing scale.
public enum Spacing {
    public static let xxs: CGFloat = DS.Space.xxs
    public static let xs: CGFloat = DS.Space.xs
    public static let sm: CGFloat = DS.Space.sm
    public static let md: CGFloat = DS.Space.md
    public static let lg: CGFloat = DS.Space.lg
    public static let xl: CGFloat = DS.Space.xl
    public static let xxl: CGFloat = 48

    public static let radiusSmall: CGFloat = 6
    public static let radiusMedium: CGFloat = DS.Radius.control
    public static let radiusLarge: CGFloat = DS.Radius.card
    public static let radiusXL: CGFloat = DS.Radius.sheet

    public static let shadowSoft = Color.black.opacity(0.07)
    public static let shadowRaised = Color.black.opacity(0.14)
    public static let elevationSoft = Shadow(color: shadowSoft, radius: 4, y: 2)
    public static let elevationRaised = Shadow(color: shadowRaised, radius: 12, y: 5)
}

/// The design system's elevation recipe; kept under its old name for existing call sites.
public typealias Shadow = DS.Elevation
