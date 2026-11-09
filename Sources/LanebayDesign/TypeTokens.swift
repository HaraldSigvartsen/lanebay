import AppKit
import SwiftUI

extension DS {
    /// Type scale from `docs/REDESIGN.md`.
    public enum Font {
        public static let display = SwiftUI.Font.system(size: 28, weight: .bold, design: .rounded)
        public static let title = SwiftUI.Font.system(size: 17, weight: .semibold)
        public static let headline = SwiftUI.Font.system(size: 13, weight: .semibold)
        public static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        public static let bodyEmphasis = SwiftUI.Font.system(size: 13, weight: .semibold)
        public static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
        public static let sectionCaption = SwiftUI.Font.system(size: 11, weight: .medium)
        public static let mono = SwiftUI.Font(monoNSFont)

        /// Terminals and timestamps.
        public static var monoNSFont: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    }
}

public extension View {
    /// Uppercase, 0.6 tracking, `secondaryInk` — section captions in sheets and panels.
    func sectionCaptionStyle() -> some View {
        font(DS.Font.sectionCaption)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(DS.Color.secondaryInk)
    }
}
