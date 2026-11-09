import QuartzCore
import SwiftUI

extension DS {
    /// Motion recipes from `docs/REDESIGN.md`. Everything respects Reduce Motion.
    public enum Motion {
        /// Hover and selection.
        public static let snappy: SwiftUI.Animation = .spring(response: 0.3, dampingFraction: 0.85)
        /// Panels and sheets.
        public static let smooth: SwiftUI.Animation = .spring(response: 0.45, dampingFraction: 0.9)
        /// Running status lights.
        public static let pulse: SwiftUI.Animation = .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
        /// New list rows.
        public static var appear: SwiftUI.AnyTransition { .opacity.combined(with: .move(edge: .top)) }

        /// `snappy` as a layer timing. AppKit-backed controls (the sidebar rows) cannot hold a SwiftUI animation.
        public static let snappyDuration: TimeInterval = 0.22
        public static var snappyTiming: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
        }

        /// The animation to use, or `nil` (apply the change instantly) when Reduce Motion is on.
        public static func animation(_ animation: SwiftUI.Animation, reduceMotion: Bool) -> SwiftUI.Animation? {
            reduceMotion ? nil : animation
        }
    }
}
