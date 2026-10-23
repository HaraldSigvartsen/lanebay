import AppKit
import LanebayCore
import SwiftUI

struct GroupManagementSheet: View {
  @Bindable var model: BoardViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var selectedID: UUID?
  @State private var name = ""
  @State private var members: Set<UUID> = []
  @State private var leadNodeID: UUID?
  @State private var message = ""
  @State private var dispatchNote: String?

  var body: some View {
    // Copy model values before the view builder. AppKit lays this sheet out on the main
    // thread without a Swift executor, and reading the model from that builder aborts.
    let groups = model.workspace?.groups ?? []
    let nodes = model.workspace?.nodes ?? []
    let saved = groups.first { $0.id == selectedID }
    let unsaved = saved.map {
      $0.name != name || Set($0.nodeIDs) != members || $0.leadNodeID != leadNodeID
    } ?? false
    let messageReady = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let broadcastEnabled = !unsaved && messageReady
    let leadEnabled = broadcastEnabled && leadNodeID != nil
    let nameReady = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Manage groups").font(Typography.title)
      Picker("Group", selection: $selectedID) {
        ForEach(groups) { group in Text(group.name).tag(Optional(group.id)) }
      }.onChange(of: selectedID) { _, _ in loadSelection() }
      if selectedID != nil {
        TextField("Group name", text: $name).textFieldStyle(.roundedBorder)
        Text("Members").font(Typography.bodyEmphasis)
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(nodes) { node in
              memberRow(node)
            }
          }
        }
        .frame(maxHeight: 220)
        Text("Only running, idle consoles receive a broadcast. The lead must be running and idle.")
          .font(Typography.caption).foregroundStyle(Palette.secondaryInk)
        IdentifierTextField(text: $message, identifier: "groups.message", placeholder: "Message")
          .frame(height: 24)
        HStack(spacing: Spacing.sm) {
          AXActionButton(
            title: "Broadcast",
            systemImage: "paperplane",
            identifier: "groups.broadcast",
            accessibilityLabel: "Broadcast to idle group members",
            enabled: broadcastEnabled,
            highlighted: false,
            compact: false
          ) { deliver(.group) }
          .frame(maxWidth: .infinity, minHeight: 28)
          AXActionButton(
            title: "Send to lead",
            systemImage: "star",
            identifier: "groups.sendLead",
            accessibilityLabel: "Send to the lead",
            enabled: leadEnabled,
            highlighted: false,
            compact: false
          ) { deliver(.lead) }
          .frame(maxWidth: .infinity, minHeight: 28)
        }
        if let dispatchNote {
          Text(dispatchNote)
            .font(Typography.caption)
            .foregroundStyle(dispatchNote == "Sent." ? Palette.secondaryInk : Palette.status(.error))
        }
        HStack {
          Button("Delete group", role: .destructive) {
            let id = selectedID
            afterClick {
              if let id { self.model.deleteGroup(id) }
              self.dismiss()
            }
          }
          Spacer()
          AXActionButton(
            title: "Cancel",
            systemImage: nil,
            identifier: "groups.cancel",
            accessibilityLabel: "Cancel",
            enabled: true,
            highlighted: false,
            compact: false
          ) { afterClick { self.dismiss() } }
          .frame(width: 88, height: 28)
          AXActionButton(
            title: "Save",
            systemImage: nil,
            identifier: "groups.save",
            accessibilityLabel: "Save group",
            enabled: nameReady,
            highlighted: true,
            compact: false
          ) { save() }
          .frame(width: 88, height: 28)
        }
      }
    }
    .padding(Spacing.lg)
    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Palette.surface)
    .background(alignment: .topLeading) {
      AccessibilityMarker(identifier: "groups.manage").frame(width: 1, height: 1)
    }
    .accessibilityIdentifier("groups.manage")
    .onAppear { selectedID = model.workspace?.groups.first?.id; loadSelection() }
  }

  @ViewBuilder
  private func memberRow(_ node: Node) -> some View {
    HStack(spacing: Spacing.sm) {
      AXActionButton(
        title: node.title,
        systemImage: members.contains(node.id) ? "checkmark.circle.fill" : "circle",
        identifier: "groups.member.\(node.id.uuidString)",
        accessibilityLabel: members.contains(node.id) ? "Remove \(node.title)" : "Add \(node.title)",
        enabled: true,
        highlighted: members.contains(node.id),
        compact: false,
        selectionValue: members.contains(node.id) ? "member" : "out"
      ) {
        if members.contains(node.id) {
          members.remove(node.id)
          if leadNodeID == node.id { leadNodeID = nil }
        } else {
          members.insert(node.id)
        }
      }
      .frame(maxWidth: .infinity, minHeight: 28)
      if members.contains(node.id), node.kind == .console {
        let isLead = leadNodeID == node.id
        AXActionButton(
          title: isLead ? "Lead" : "Set lead",
          systemImage: isLead ? "star.fill" : "star",
          identifier: "groups.lead.\(node.id.uuidString)",
          accessibilityLabel: isLead ? "Clear lead" : "Set \(node.title) as lead",
          enabled: true,
          highlighted: isLead,
          compact: false,
          selectionValue: isLead ? "lead" : "member"
        ) {
          leadNodeID = isLead ? nil : node.id
        }
        .frame(width: 150, height: 28)
      }
    }
  }

  /// Model updates refresh the live terminals. Doing that inside the mouse click locks the board.
  private func save() {
    guard let selectedID else { return }
    let name = name
    let members = members
    let lead = leadNodeID
    afterClick {
      self.model.renameGroup(selectedID, name: name)
      self.model.setGroupMembers(selectedID, nodeIDs: members)
      self.model.setGroupLead(selectedID, nodeID: lead)
    }
  }

  private func deliver(_ target: DispatchTarget) {
    guard let selectedID, !hasUnsavedEdits else { return }
    let text = message
    afterClick {
      let sent: Bool
      switch target {
      case .lead: sent = self.model.sendToLead(text, groupID: selectedID)
      case .group: sent = self.model.broadcastToGroup(text, groupID: selectedID)
      }
      if sent {
        self.dispatchNote = "Sent."
        self.message = ""
      } else {
        self.dispatchNote = "Nothing was sent. Consoles need to be running and idle."
      }
    }
  }

  /// Leaves the mouse-click stack before touching the board. The queued block still runs on the main actor.
  private func afterClick(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated(body)
    }
  }

  private func loadSelection() {
    guard let group = model.workspace?.groups.first(where: { $0.id == selectedID }) else { return }
    name = group.name
    members = Set(group.nodeIDs)
    leadNodeID = group.leadNodeID
    dispatchNote = nil
  }

  private var hasUnsavedEdits: Bool {
    guard let group = model.workspace?.groups.first(where: { $0.id == selectedID }) else { return false }
    return group.name != name || Set(group.nodeIDs) != members || group.leadNodeID != leadNodeID
  }

  private enum DispatchTarget { case lead, group }
}

/// The in-app probe sets text through this instead of the field.
/// Setting `stringValue` and calling `textDidChange` stalls the main thread inside the sheet.
public enum MarkedFieldRegistry {
  private final class Handler {
    var commit: (@MainActor (String) -> Void)?
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var storage: [String: Handler] = [:]

  public static func register(identifier: String, commit: @escaping @MainActor (String) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    let handler = storage[identifier] ?? Handler()
    handler.commit = commit
    storage[identifier] = handler
  }

  public static func unregister(identifier: String) {
    lock.lock()
    storage[identifier] = nil
    lock.unlock()
  }

  public static func hasCommit(_ identifier: String) -> Bool {
    lock.lock()
    let present = storage[identifier]?.commit != nil
    lock.unlock()
    return present
  }

  @MainActor
  @discardableResult
  public static func commit(identifier: String, text: String) -> Bool {
    lock.lock()
    let commit = storage[identifier]?.commit
    lock.unlock()
    guard let commit else { return false }
    commit(text)
    return true
  }
}

/// Editable field the in-app probe can find by identifier. SwiftUI text fields do not expose one.
struct IdentifierTextField: NSViewRepresentable {
  @Binding var text: String
  var identifier: String
  var placeholder: String

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  func makeNSView(context: Context) -> MarkedTextField {
    let field = MarkedTextField(string: text)
    field.placeholderString = placeholder
    field.isEditable = true
    field.isBezeled = true
    field.font = .systemFont(ofSize: 13)
    field.identifier = NSUserInterfaceItemIdentifier(identifier)
    field.setAccessibilityIdentifier(identifier)
    installCommit(context: context)
    return field
  }

  func updateNSView(_ field: MarkedTextField, context: Context) {
    context.coordinator.text = $text
    field.onChange = { context.coordinator.text.wrappedValue = $0 }
    field.placeholderString = placeholder
    field.identifier = NSUserInterfaceItemIdentifier(identifier)
    field.setAccessibilityIdentifier(identifier)
    installCommit(context: context)
    if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
  }

  static func dismantleNSView(_ nsView: MarkedTextField, coordinator: Coordinator) {
    if let identifier = nsView.identifier?.rawValue {
      MarkedFieldRegistry.unregister(identifier: identifier)
    }
    _ = coordinator
  }

  private func installCommit(context: Context) {
    let identifier = identifier
    let coordinator = context.coordinator
    MarkedFieldRegistry.register(identifier: identifier) { value in
      coordinator.text.wrappedValue = value
    }
  }

  final class Coordinator {
    var text: Binding<String>
    init(text: Binding<String>) { self.text = text }
  }
}

/// Posts its string when the user edits. The probe commits through `MarkedFieldRegistry` instead.
final class MarkedTextField: NSTextField {
  var onChange: ((String) -> Void)?

  override func textDidChange(_ notification: Notification) {
    super.textDidChange(notification)
    let value = stringValue
    let change = onChange
    DispatchQueue.main.async {
      MainActor.assumeIsolated { change?(value) }
    }
  }
}

/// AppKit marker so a same-process check can see the sheet without an accessibility walk.
private struct AccessibilityMarker: NSViewRepresentable {
  var identifier: String

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    view.setAccessibilityElement(true)
    view.setAccessibilityIdentifier(identifier)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    nsView.setAccessibilityIdentifier(identifier)
  }
}
