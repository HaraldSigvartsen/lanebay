import Foundation

/// Input modes a TUI turned on in its terminal, read from the output stream.
///
/// Agent input arrives without a key press, so it has to look the way the
/// terminal would send it: pasted text in bracketed-paste markers, and a
/// focus-in report first when the app gates Enter on focus (FreeBuff does).
public struct TerminalInputModes: Equatable, Sendable {
  public private(set) var bracketedPaste = false
  public private(set) var focusReporting = false
  /// Tail of the last chunk, so a mode switch split across reads is still seen.
  private var carry = ""

  public init() {}

  public mutating func scan(_ text: String) {
    let joined = carry + text
    for (mode, on) in Self.switches(in: joined) {
      switch mode {
      case "2004": bracketedPaste = on
      case "1004": focusReporting = on
      default: break
      }
    }
    // Re-reading a switch kept in the carry is harmless: it sets the same value again, in order.
    carry = String(joined.suffix(8))
  }

  /// Bytes for agent text. A lone "\r" is a submit.
  public func encode(_ text: String) -> Data {
    var out = focusReporting ? "\u{1B}[I" : ""
    if text == "\r" || !bracketedPaste {
      out += text
    } else {
      out += "\u{1B}[200~" + text + "\u{1B}[201~"
    }
    return Data(out.utf8)
  }

  private static func switches(in text: String) -> [(String, Bool)] {
    var found: [(String, Bool)] = []
    var index = text.startIndex
    while let range = text.range(of: "\u{1B}[?", range: index..<text.endIndex) {
      var cursor = range.upperBound
      var params = ""
      while cursor < text.endIndex, text[cursor].isNumber || text[cursor] == ";" {
        params.append(text[cursor])
        cursor = text.index(after: cursor)
      }
      guard cursor < text.endIndex else { break }
      let final = text[cursor]
      if final == "h" || final == "l" {
        for mode in params.split(separator: ";") { found.append((String(mode), final == "h")) }
      }
      index = cursor
    }
    return found
  }
}
