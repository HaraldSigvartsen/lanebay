import SwiftUI

/// Panel files live next to the board, under the same home the board was given.
enum PanelStorage {
  static func supportRoot(homeDirectory: URL) -> URL {
    homeDirectory.appendingPathComponent("Library/Application Support/Lanebay", isDirectory: true)
  }

  static func chatRoot(homeDirectory: URL) -> URL {
    supportRoot(homeDirectory: homeDirectory).appendingPathComponent("Chat", isDirectory: true)
  }
}

/// One side panel at a time. Opening another replaces the current one; opening the same one closes it.
public enum BoardSidePanel: String, CaseIterable, Identifiable, Sendable {
  case settings, docs, code, markdown, skills, memory, presets, chat, github, usage, git, shots, planner, loops

  public var id: String { rawValue }

  public static let railOrder: [BoardSidePanel] = [
    .settings, .docs, .code, .markdown, .skills, .memory, .presets, .chat, .github, .usage, .git, .shots, .planner,
  ]

  public var railTitle: String {
    switch self {
    case .settings: "Settings"
    case .docs: "Docs"
    case .code: "Code"
    case .markdown: "Markdown"
    case .skills: "Skills"
    case .memory: "Memory"
    case .presets: "Presets"
    case .chat: "Chat"
    case .github: "GitHub"
    case .usage: "Usage"
    case .git: "Git"
    case .shots: "Shots"
    case .planner: "Planner"
    case .loops: "Loops"
    }
  }

  public var hostTitle: String {
    self == .shots ? "Screenshots" : railTitle
  }

  public var icon: Icon {
    switch self {
    case .settings: .settings
    case .docs, .markdown, .skills, .shots: .files
    case .code: .code
    case .memory: .agents
    case .presets, .chat, .git, .planner, .loops: .command
    case .github, .usage: .activity
    }
  }

  public var width: CGFloat {
    switch self {
    case .settings: 360
    case .docs, .skills, .memory: 620
    case .code, .markdown, .planner: 720
    case .presets, .github, .usage: 520
    case .chat: 420
    case .git: 580
    case .shots: 760
    case .loops: 300
    }
  }

  public var railIdentifier: String { "rail.panel.\(rawValue)" }
  public var hostIdentifier: String { "panel.host.\(rawValue)" }
  public var marker: String { "panel.marker.\(rawValue)" }

  public static func toggled(_ current: BoardSidePanel?, _ panel: BoardSidePanel) -> BoardSidePanel? {
    current == panel ? nil : panel
  }
}

/// AppKit marker. SwiftUI accessibility identifiers are not always a view the in-app probe can find.
struct PanelMarker: NSViewRepresentable {
  var identifier: String
  var label: String

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.staticText)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    view.setAccessibilityElement(true)
    view.setAccessibilityIdentifier(identifier)
    view.setAccessibilityLabel(label)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
    CGSize(width: 4, height: 4)
  }
}
