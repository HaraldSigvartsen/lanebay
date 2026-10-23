import AppKit
import LanebayCore
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
  var compact: Bool
  var indented: Bool = false
  /// Icon-sized header control. The visible title is omitted so the card header stays one line.
  var headerIcon: Bool = false
  var keyEquivalent: String = ""
  var selectionValue: String? = nil
  var action: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(action: action) }

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.press))
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
    if headerIcon {
      button.title = ""
      button.imagePosition = .imageOnly
    } else {
      button.title = indented ? "    \(title)" : title
      button.imagePosition = systemImage == nil ? .noImage : (compact ? .imageAbove : .imageLeading)
    }
    button.font = .systemFont(ofSize: compact ? 11 : 13)
    button.toolTip = accessibilityLabel
    button.image = systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    button.image?.isTemplate = true
    button.contentTintColor = highlighted ? NSColor(Palette.accent) : NSColor(Palette.secondaryInk)
    button.isEnabled = enabled
    button.keyEquivalent = keyEquivalent
    button.keyEquivalentModifierMask = []
    button.setAccessibilityIdentifier(identifier)
    button.setAccessibilityLabel(accessibilityLabel)
    if let selectionValue { button.setAccessibilityValue(selectionValue) }
    button.layer?.backgroundColor = highlighted ? NSColor(Palette.accentSoft).cgColor : nil
    button.layer?.cornerRadius = compact ? 6 : 0
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
    if headerIcon { return CGSize(width: proposal.width ?? 28, height: proposal.height ?? 28) }
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
