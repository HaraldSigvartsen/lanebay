import AppKit
import LanebayCore
import QuartzCore
import SwiftUI

public struct AgentPickerAgent: Equatable, Sendable {
  public var id: String
  public var title: String

  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

public struct AgentPickerRow: Equatable, Sendable, Identifiable {
  public var identifier: String
  public var title: String
  public var agentID: String
  public var profileID: String?

  public var id: String { identifier }

  public init(identifier: String, title: String, agentID: String, profileID: String?) {
    self.identifier = identifier
    self.title = title
    self.agentID = agentID
    self.profileID = profileID
  }
}

/// Stable accessibility identifiers for the in-window console list.
/// SwiftUI menus do not publish their items to the app accessibility tree.
public enum AgentPickerCatalog {
  public static func accessibilityIdentifier(agentID: String, profileID: String? = nil) -> String {
    guard let profileID, !profileID.isEmpty else { return "agent.\(agentID)" }
    return "agent.\(agentID).profile.\(profileID)"
  }

  public static func rows(agents: [AgentPickerAgent], profiles: [AgentAccountProfile]) -> [AgentPickerRow] {
    agents.flatMap { agent in
      var rows = [
        AgentPickerRow(
          identifier: accessibilityIdentifier(agentID: agent.id),
          title: agent.title,
          agentID: agent.id,
          profileID: nil)
      ]
      for profile in profiles where profile.agentID == agent.id {
        rows.append(
          AgentPickerRow(
            identifier: accessibilityIdentifier(agentID: agent.id, profileID: profile.id),
            title: profile.name,
            agentID: agent.id,
            profileID: profile.id))
      }
      return rows
    }
  }
}

struct AgentPickerList: View {
  @Bindable var model: BoardViewModel
  var onChoose: () -> Void

  var body: some View {
    let rows = AgentPickerCatalog.rows(
      agents: model.availableAgentTemplates.map { AgentPickerAgent(id: $0.id, title: $0.title) },
      profiles: model.settings.accountProfiles)
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text("Add console")
        .font(Typography.caption)
        .foregroundStyle(Palette.secondaryInk)
        .padding(.horizontal, Spacing.sm)
        .padding(.top, Spacing.sm)
        .accessibilityAddTraits(.isHeader)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row in
            AXActionButton(
              title: row.title,
              systemImage: nil,
              identifier: row.identifier,
              accessibilityLabel: row.title,
              enabled: model.workspace != nil,
              highlighted: false,
              compact: false,
              indented: row.profileID != nil
            ) {
              _ = model.createAndStartConsole(agentID: row.agentID, profileID: row.profileID)
              onChoose()
            }
          }
        }
        .padding(.bottom, Spacing.xs)
      }
    }
    .frame(width: 240, height: 420)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Spacing.radiusMedium))
    .overlay(RoundedRectangle(cornerRadius: Spacing.radiusMedium).stroke(Palette.border))
    .shadow(
      color: Spacing.elevationRaised.color, radius: Spacing.elevationRaised.radius,
      y: Spacing.elevationRaised.y
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("agent.picker")
  }
}

/// AppKit button. SwiftUI's accessibility press runs the action on the AX caller and traps off the main actor.
struct AXActionButton: NSViewRepresentable {
  var title: String
  var systemImage: String?
  var identifier: String
  var accessibilityLabel: String
  var enabled: Bool
  var highlighted: Bool
  /// Filled primary button: white title on the caller's gradient background.
  var primary: Bool = false
  var compact: Bool
  var indented: Bool = false
  /// Icon-sized header control. The visible title is omitted so the card header stays one line.
  var headerIcon: Bool = false
  /// One-row sidebar item: icon and label on a line, left aligned, pill selection and a hover fill.
  var row: Bool = false
  var keyEquivalent: String = ""
  var selectionValue: String? = nil
  var action: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(action: action) }

  func makeNSView(context: Context) -> NSButton {
    let button = AXActionButtonView(title: title, target: context.coordinator, action: #selector(Coordinator.press))
    button.bezelStyle = .recessed
    button.setButtonType(.momentaryPushIn)
    button.isBordered = false
    button.wantsLayer = true
    button.setAccessibilityElement(true)
    button.setAccessibilityRole(.button)
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.action = action
    button.alignment = headerIcon || compact ? .center : .left
    if row {
      button.alignment = .left
      button.imagePosition = systemImage == nil ? .noImage : .imageLeading
      button.imageHugsTitle = true
      button.attributedTitle = NSAttributedString(
        string: title,
        attributes: [
          .font: NSFont.systemFont(ofSize: 13, weight: .medium),
          .foregroundColor: NSColor(highlighted ? Palette.accentInk : Palette.ink),
          .paragraphStyle: {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            return paragraph
          }(),
        ])
      (button as? AXActionButtonView)?.rowStyle = true
      (button as? AXActionButtonView)?.iconTint = NSColor(highlighted ? Palette.accentInk : Palette.accent)
      (button as? AXActionButtonView)?.hoverFill = NSColor(Palette.accentSoft).withAlphaComponent(0.65)
      (button as? AXActionButtonView)?.baseFill = highlighted ? NSColor(Palette.accentSoft) : nil
    } else if headerIcon {
      button.title = ""
      button.imagePosition = .imageOnly
    } else {
      let text = indented ? "    \(title)" : title
      button.imagePosition = systemImage == nil ? .noImage : (compact ? .imageAbove : .imageLeading)
      if primary {
        button.attributedTitle = NSAttributedString(
          string: text,
          attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
          ])
      } else if compact {
        button.attributedTitle = BoardRailMetrics.fittedCaption(
          text,
          color: highlighted ? NSColor(Palette.accentInk) : NSColor(Palette.secondaryInk))
      } else {
        button.title = text
      }
    }
    button.font = .systemFont(ofSize: compact ? 11 : 13)
    button.toolTip = accessibilityLabel
    button.image = systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    button.image?.isTemplate = true
    button.contentTintColor =
      primary
      ? NSColor.white
      : NSColor(highlighted ? Palette.accentInk : (row ? Palette.ink : Palette.secondaryInk))
    button.isEnabled = enabled
    button.keyEquivalent = keyEquivalent
    button.keyEquivalentModifierMask = []
    button.setAccessibilityIdentifier(identifier)
    button.setAccessibilityLabel(accessibilityLabel)
    if let selectionValue { button.setAccessibilityValue(selectionValue) }
    if row {
      button.layer?.cornerRadius = DS.Radius.control
      button.layer?.cornerCurve = .continuous
    } else {
      button.layer?.backgroundColor =
        highlighted && !primary ? NSColor(Palette.accentSoft).cgColor : nil
      button.layer?.cornerRadius = compact ? 14 : 0
      button.layer?.cornerCurve = .continuous
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
    if headerIcon { return CGSize(width: proposal.width ?? 28, height: proposal.height ?? 28) }
    if row { return CGSize(width: proposal.width ?? BoardRailMetrics.sidebarWidth, height: proposal.height ?? BoardRailMetrics.rowHeight) }
    if compact { return CGSize(width: proposal.width ?? BoardRailMetrics.buttonWidth, height: proposal.height ?? BoardRailMetrics.buttonHeight) }
    return CGSize(width: proposal.width ?? 220, height: 28)
  }

  /// AXPress arrives on the probe thread. A click already on the main thread must run now:
  /// a queued main-actor task does not start while AppKit is still inside the click.
  @MainActor
  final class Coordinator: NSObject {
    var action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc nonisolated func press() {
      if Thread.isMainThread {
        MainActor.assumeIsolated { self.action() }
      } else {
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self.action() }
        }
      }
    }
  }
}

/// Borderless AppKit button that paints its own pill fill and hover, the AppKit twin of `.lbGhost`.
final class AXActionButtonView: NSButton {
  override class var cellClass: AnyClass? {
    get { RailRowButtonCell.self }
    set {}
  }

  var rowStyle = false {
    didSet { (cell as? RailRowButtonCell)?.rowLayout = rowStyle }
  }
  /// Sidebar row icon colour (accent); nil keeps the template tint.
  var iconTint: NSColor? {
    get { (cell as? RailRowButtonCell)?.iconTint }
    set { (cell as? RailRowButtonCell)?.iconTint = newValue; needsDisplay = true }
  }
  var baseFill: NSColor? {
    didSet { paint(animated: false) }
  }
  var hoverFill: NSColor? {
    didSet { paint(animated: false) }
  }
  private var isHovered = false
  private var hoverTrackingArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    paint(animated: true)
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    paint(animated: true)
  }

  private func paint(animated: Bool) {
    guard rowStyle, let layer else { return }
    let fill = isHovered ? hoverFill : baseFill
    CATransaction.begin()
    CATransaction.setDisableActions(!animated)
    if animated {
      CATransaction.setAnimationDuration(DS.Motion.snappyDuration)
      CATransaction.setAnimationTimingFunction(DS.Motion.snappyTiming)
    }
    layer.backgroundColor = fill?.cgColor ?? NSColor.clear.cgColor
    CATransaction.commit()
  }
}

/// Sidebar row layout: 12 pt leading inset, icon in an 18 pt box, 10 pt gap, title centred.
/// Non-row buttons draw exactly like a plain `NSButtonCell`.
final class RailRowButtonCell: NSButtonCell {
  static let leadingInset: CGFloat = 12
  static let iconBox: CGFloat = 18
  static let iconGap: CGFloat = 10
  var rowLayout = false
  var iconTint: NSColor?

  override func imageRect(forBounds rect: NSRect) -> NSRect {
    guard rowLayout else { return super.imageRect(forBounds: rect) }
    let box = Self.iconBox
    return NSRect(x: rect.minX + Self.leadingInset, y: rect.midY - box / 2, width: box, height: box)
  }

  override func titleRect(forBounds rect: NSRect) -> NSRect {
    guard rowLayout else { return super.titleRect(forBounds: rect) }
    let x = rect.minX + Self.leadingInset + (image == nil ? 0 : Self.iconBox + Self.iconGap)
    let height = ceil(attributedTitle.size().height)
    return NSRect(x: x, y: rect.midY - height / 2, width: max(0, rect.maxX - x - Self.leadingInset), height: height)
  }

  override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
    guard rowLayout else { return super.drawInterior(withFrame: cellFrame, in: controlView) }
    if let image {
      let box = imageRect(forBounds: cellFrame)
      let size = image.size
      let scale = min(box.width / max(size.width, 1), box.height / max(size.height, 1), 1.2)
      let drawn = NSRect(
        x: box.midX - size.width * scale / 2, y: box.midY - size.height * scale / 2,
        width: size.width * scale, height: size.height * scale)
      let tint = iconTint ?? (controlView as? NSButton)?.contentTintColor ?? .labelColor
      let tinted = NSImage(size: image.size, flipped: false) { bounds in
        image.draw(in: bounds)
        tint.set()
        bounds.fill(using: .sourceAtop)
        return true
      }
      tinted.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.4, respectFlipped: true, hints: nil)
    }
    attributedTitle.draw(in: titleRect(forBounds: cellFrame))
  }
}
