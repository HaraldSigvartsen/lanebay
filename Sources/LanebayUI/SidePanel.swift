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

/// How the sidebar groups a side panel: the five section places, or a tool under `Verktøy`.
public enum RailSection: String, CaseIterable, Sendable {
  case primary, tools
}

/// One side panel at a time. Opening another replaces the current one; opening the same one closes it.
public enum BoardSidePanel: String, CaseIterable, Identifiable, Sendable {
  case settings, activity, docs, code, markdown, skills, memory, presets, chat, github, usage, git, shots, planner,
    loops

  public var id: String { rawValue }

  /// The five places in the sidebar. The board itself (`Agenter`) is not a panel.
  public static let primaryOrder: [BoardSidePanel] = [.planner, .loops, .activity, .settings]
  /// The old rail Chat (agent-to-agent log) is replaced by the board chat panel (⌘⇧C), so it is not in the rail.
  public static let toolOrder: [BoardSidePanel] = [
    .docs, .code, .markdown, .skills, .memory, .presets, .github, .usage, .git, .shots,
  ]
  public static let railOrder: [BoardSidePanel] = primaryOrder + toolOrder

  public var section: RailSection {
    Self.primaryOrder.contains(self) ? .primary : .tools
  }

  public var railTitle: String {
    switch self {
    case .settings: "Innstillinger"
    case .activity: "Aktivitet"
    case .docs: "Docs"
    case .code: "Code"
    case .markdown: "Markdown"
    case .skills: "Skills"
    case .memory: "Memory"
    case .presets: "Maler"
    case .chat: "Chat"
    case .github: "GitHub"
    case .usage: "Usage"
    case .git: "Git"
    case .shots: "Shots"
    case .planner: "Orkestrering"
    case .loops: "Cron"
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
    case .activity, .github, .usage: .activity
    }
  }

  public var width: CGFloat {
    switch self {
    case .settings: 460
    case .activity: 440
    case .docs, .skills, .memory: 620
    case .code, .markdown, .planner: 720
    case .presets, .github, .usage: 520
    case .chat: 460
    case .git: 580
    case .shots: 760
    case .loops: 440
    }
  }

  public var railIdentifier: String { "rail.panel.\(rawValue)" }
  public var hostIdentifier: String { "panel.host.\(rawValue)" }
  public var marker: String { "panel.marker.\(rawValue)" }

  public static func toggled(_ current: BoardSidePanel?, _ panel: BoardSidePanel) -> BoardSidePanel? {
    current == panel ? nil : panel
  }
}

/// A sidebar place a keyboard shortcut can go to: the board itself, or one side panel.
public enum BoardNavigation: Equatable, Sendable {
  case board
  case panel(BoardSidePanel)

  public var title: String {
    switch self {
    case .board: "Agenter"
    case let .panel(panel): panel.railTitle
    }
  }
}

/// A navigation request from the app menu (⌘1–⌘5).
/// The token lets the board run the same request twice in a row.
public struct BoardNavigationRequest: Equatable, Sendable {
  public let token: Int
  public let target: BoardNavigation

  public init(token: Int, target: BoardNavigation) {
    self.token = token
    self.target = target
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
