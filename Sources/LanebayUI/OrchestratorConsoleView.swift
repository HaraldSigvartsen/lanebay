import LanebayCore
import SwiftUI

public enum OrchestratorControl {
  public static func command(_ id: UUID) -> String { "orchestrator.command.\(id.uuidString)" }
  public static func submit(_ id: UUID) -> String { "orchestrator.submit.\(id.uuidString)" }
  public static func transcript(_ id: UUID) -> String { "orchestrator.transcript.\(id.uuidString)" }
  public static func link(_ id: UUID) -> String { "orchestrator.link.\(id.uuidString)" }
  public static let approve = "orchestrator.approve"
  public static let deny = "orchestrator.deny"
  public static let approval = "orchestrator.approval"
}

struct OrchestratorConsoleBody: View {
  @Bindable var model: BoardViewModel
  let nodeID: UUID

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      OrchestratorLeadHeader(model: model, nodeID: nodeID)
      OrchestratorMemberList(model: model, leadNodeID: nodeID)
      ScrollViewReader { proxy in
        ScrollView {
          Text(verbatim: model.orchestratorTranscripts[nodeID] ?? "")
            .font(DS.Font.mono)
            .foregroundStyle(DS.Color.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityIdentifier(OrchestratorControl.transcript(nodeID))
            .id("transcript")
        }
        .onChange(of: model.orchestratorTranscripts[nodeID]) { _, _ in
          proxy.scrollTo("transcript", anchor: .bottom)
        }
      }
      HStack(spacing: DS.Space.xs) {
        TextField(
          "Command",
          text: Binding(
            get: { model.orchestratorDrafts[nodeID] ?? "" },
            set: { model.setOrchestratorDraft(nodeID, $0) }
          )
        )
        .textFieldStyle(.plain)
        .font(DS.Font.mono)
        .accessibilityIdentifier(OrchestratorControl.command(nodeID))
        .onSubmit { model.submitOrchestratorDraft(nodeID) }
        AXActionButton(
          title: "Send",
          systemImage: nil,
          identifier: OrchestratorControl.submit(nodeID),
          accessibilityLabel: "Send orchestrator command",
          enabled: true,
          highlighted: false,
          compact: false
        ) {
          model.submitOrchestratorDraft(nodeID)
        }
        .frame(width: 64, height: 28)
      }
    }
    .padding(DS.Space.sm)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(DS.Color.raisedSurface)
  }
}

struct OrchestratorApprovalBanner: View {
  let approval: OrchestratorApprovalRequest
  let waitingCount: Int
  let onApprove: () -> Void
  let onDeny: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      Text("Ask before sending")
        .font(DS.Font.caption.weight(.semibold))
        .foregroundStyle(DS.Color.secondaryInk)
      Text("Send to \(approval.targetTitle)?")
        .font(DS.Font.title)
        .foregroundStyle(DS.Color.ink)
      Text(verbatim: approval.text)
        .font(DS.Font.mono)
        .foregroundStyle(DS.Color.ink)
        .textSelection(.enabled)
        .lineLimit(6)
        .accessibilityIdentifier(OrchestratorControl.approval)
        .accessibilityLabel("Send to \(approval.targetTitle): \(approval.text)")
      HStack(spacing: DS.Space.sm) {
        AXActionButton(
          title: "Approve",
          systemImage: nil,
          identifier: OrchestratorControl.approve,
          accessibilityLabel: "Approve send to \(approval.targetTitle)",
          enabled: true,
          highlighted: true,
          compact: false
        ) { onApprove() }
        .frame(width: 88, height: 28)
        AXActionButton(
          title: "Don't send",
          systemImage: nil,
          identifier: OrchestratorControl.deny,
          accessibilityLabel: "Don't send to \(approval.targetTitle)",
          enabled: true,
          highlighted: false,
          compact: false
        ) { onDeny() }
        .frame(width: 110, height: 28)
        if waitingCount > 1 {
          Text("\(waitingCount) waiting")
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.secondaryInk)
        }
      }
    }
    .padding(DS.Space.sm)
    .frame(maxWidth: 520, alignment: .leading)
    .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control))
    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(DS.Color.accent, lineWidth: 1.5))
    .shadow(color: DS.Elevation.raised.color, radius: DS.Elevation.raised.radius, y: DS.Elevation.raised.y)
  }
}

struct OrchestratorLinkOverlay: View {
  let links: [OrchestratorLink]
  let nodes: [Node]
  let zoom: Double
  let panX: Double
  let panY: Double

  var body: some View {
    let frames = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.frame) })
    ZStack(alignment: .topLeading) {
      Canvas { context, _ in
        for link in links {
          guard let source = frames[link.orchestratorID], let target = frames[link.targetID],
            let segment = OrchestratorLinkLayout.segment(
              from: source, to: target, zoom: zoom, panX: panX, panY: panY)
          else { continue }
          var path = Path()
          path.move(to: CGPoint(x: segment.startX, y: segment.startY))
          path.addLine(to: CGPoint(x: segment.endX, y: segment.endY))
          let color = link.status == .failed || link.status == .denied
            ? DS.Color.status(.error) : DS.Color.accent
          context.stroke(path, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
      }
      ForEach(links) { link in
        if let source = frames[link.orchestratorID], let target = frames[link.targetID],
          let segment = OrchestratorLinkLayout.segment(
            from: source, to: target, zoom: zoom, panX: panX, panY: panY)
        {
          Text("\(link.targetTitle) · \(link.status.label)")
            .font(DS.Font.caption.weight(.semibold))
            .foregroundStyle(DS.Color.ink)
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, 2)
            .background(DS.Color.surface, in: Capsule())
            .overlay(Capsule().stroke(DS.Color.accent, lineWidth: 1))
            .fixedSize()
            .position(x: segment.badgeX, y: segment.badgeY)
            .accessibilityIdentifier(OrchestratorControl.link(link.id))
            .accessibilityLabel("\(link.targetTitle) \(link.status.label)")
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .allowsHitTesting(false)
    .accessibilityElement(children: .contain)
  }
}

/// The lead console's own header: provider badge, title, a live pulse while it runs and a status pill.
struct OrchestratorLeadHeader: View {
  @Bindable var model: BoardViewModel
  let nodeID: UUID

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isPulsing = false

  private var status: AgentStatus { model.orchestratorStatuses[nodeID] ?? .stopped }
  private var title: String { model.workspace?.nodes.first { $0.id == nodeID }?.title ?? OrchestratorKind.title }
  private var isLead: Bool { model.workspace?.groups.contains { $0.leadNodeID == nodeID } == true }

  var body: some View {
    HStack(spacing: DS.Space.xs) {
      ProviderBadge(agentID: OrchestratorKind.agentID, size: DS.Space.md + DS.Space.xxs)
      VStack(alignment: .leading, spacing: DS.Space.xxs) {
        Text(isLead ? "★ \(title) · Lead" : title)
          .font(DS.Font.bodyEmphasis)
          .foregroundStyle(DS.Color.ink)
          .lineLimit(1)
        if status == .running {
          HStack(spacing: DS.Space.xxs) {
            Circle()
              .fill(DS.Color.status(.running))
              .frame(width: DS.Space.xs, height: DS.Space.xs)
              .scaleEffect(isPulsing ? 1.4 : 1)
              .opacity(isPulsing ? 0.5 : 1)
              .animation(DS.Motion.animation(DS.Motion.pulse, reduceMotion: reduceMotion), value: isPulsing)
            Text("Live").font(DS.Font.caption).foregroundStyle(DS.Color.secondaryInk)
          }
        }
      }
      Spacer(minLength: DS.Space.xs)
      StatusPill(kind: status.statusKind, label: status.label())
    }
    .padding(.horizontal, DS.Space.xs)
    .onAppear { isPulsing = status == .running && !reduceMotion }
    .onChange(of: status) { _, _ in isPulsing = status == .running && !reduceMotion }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(status.label())")
  }
}

/// The consoles the lead steers, as rows with provider badge, status and last activity line.
struct OrchestratorMemberList: View {
  @Bindable var model: BoardViewModel
  let leadNodeID: UUID

  private var members: [Node] {
    (model.workspace?.nodes ?? []).filter { $0.kind == .console && $0.id != leadNodeID }
  }

  var body: some View {
    if members.isEmpty {
      Text("Ingen medlemmer ennå")
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.mutedInk)
        .padding(.horizontal, DS.Space.xs)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(members.prefix(6)) { node in
          row(node)
        }
        if members.count > 6 {
          Text("+\(members.count - 6) flere")
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.mutedInk)
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, DS.Space.xxs)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("orchestrator.members")
    }
  }

  private func row(_ node: Node) -> some View {
    let status = status(for: node)
    return HStack(spacing: DS.Space.xs) {
      ProviderBadge(agentID: node.agentID ?? "shell", size: DS.Space.md)
      Text(node.title)
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.ink)
        .lineLimit(1)
      Spacer(minLength: DS.Space.xs)
      Text(activityLine(for: node) ?? "Ingen aktivitet")
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.secondaryInk)
        .lineLimit(1)
        .truncationMode(.tail)
      StatusPill(kind: status.statusKind, label: status.label())
    }
    .padding(.horizontal, DS.Space.xs)
    .padding(.vertical, DS.Space.xxs)
    .accessibilityElement(children: .combine)
  }

  private func status(for node: Node) -> AgentStatus {
    if let session = model.sessions[node.id] { return session.status }
    if let status = model.orchestratorStatuses[node.id] { return status }
    return model.consoleLaunchErrors[node.id] != nil ? .error : .stopped
  }

  private func activityLine(for node: Node) -> String? {
    let _ = model.sessions[node.id]?.outputByteCount
    guard let output = model.recentConsoleOutput(node.id, maxBytes: 4_096) else { return nil }
    return ConsoleActivityLine.latest(in: output)
  }
}
