import AppKit
import SwiftUI

/// Forwarded to the shared `LanebayDesign` type scale.
public enum Typography {
    public static let caption = DS.Font.caption
    public static let body = DS.Font.body
    public static let bodyEmphasis = DS.Font.bodyEmphasis
    public static let title = DS.Font.title
    public static let display = DS.Font.display
    public static var terminalNSFont: NSFont { DS.Font.monoNSFont }
    public static var terminal: Font { DS.Font.mono }
}
