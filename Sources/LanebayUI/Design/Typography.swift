import AppKit
import SwiftUI

public enum Typography {
    public static let caption = Font.system(size: 11, weight: .medium, design: .default)
    public static let body = Font.system(size: 13, weight: .regular, design: .default)
    public static let bodyEmphasis = Font.system(size: 13, weight: .semibold, design: .default)
    public static let title = Font.system(size: 16, weight: .semibold, design: .default)
    public static let display = Font.system(size: 24, weight: .semibold, design: .default)
    public static var terminalNSFont: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    public static let terminal = Font(terminalNSFont)
}
