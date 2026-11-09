import CoreGraphics

extension DS {
    /// 4 pt grid.
    public enum Space {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
    }

    /// Corner radii — always used with a `.continuous` style.
    public enum Radius {
        public static let chip: CGFloat = 8
        public static let control: CGFloat = 10
        public static let card: CGFloat = 18
        public static let sheet: CGFloat = 22
    }
}
