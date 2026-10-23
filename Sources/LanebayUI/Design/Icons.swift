import SwiftUI

public enum Icon: String, CaseIterable {
    case workspace = "square.grid.2x2"
    case agents = "point.3.connected.trianglepath.dotted"
    case files = "doc.text"
    case code = "curlybraces"
    case activity = "waveform.path"
    case settings = "slider.horizontal.3"
    case terminal = "chevron.left.forwardslash.chevron.right"
    case menu = "ellipsis"
    case add = "plus"
    case close = "xmark"
    case restart = "arrow.clockwise"
    case command = "command"
    case search = "magnifyingglass"
    case send = "arrow.up"
    case check = "checkmark"
    case warning = "exclamationmark.triangle"
    case pause = "pause.fill"

    public var image: Image { Image(systemName: rawValue) }
}
