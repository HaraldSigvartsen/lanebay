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
    VStack(alignment: .leading, spacing: Spacing.xs) {
      ScrollViewReader { proxy in
        ScrollView {
          Text(verbatim: model.orchestratorTranscripts[nodeID] ?? "")
            .font(Typography.terminal)
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityIdentifier(OrchestratorControl.transcript(nodeID))
            .id("transcript")
        }
        .onChange(of: model.orchestratorTranscripts[nodeID]) { _, _ in
          proxy.scrollTo("transcript", anchor: .bottom)
        }
      }
      HStack(spacing: Spacing.xs) {
        TextField(
          "Command",
          text: Binding(
            get: { model.orchestratorDrafts[nodeID] ?? "" },
            set: { model.setOrchestratorDraft(nodeID, $0) }
          )
        )
        .textFieldStyle(.plain)
        .font(Typography.terminal)
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
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Palette.raisedSurface)
  }
}

struct OrchestratorApprovalBanner: View {
  let approval: OrchestratorApprovalRequest
  let waitingCount: Int
  let onApprove: () -> Void
  let onDeny: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Ask before sending")
        .font(Typography.caption.weight(.semibold))
        .foregroundStyle(Palette.secondaryInk)
      Text("Send to \(approval.targetTitle)?")
        .font(Typography.title)
        .foregroundStyle(Palette.ink)
      Text(verbatim: approval.text)
        .font(Typography.terminal)
        .foregroundStyle(Palette.ink)
        .textSelection(.enabled)
        .lineLimit(6)
        .accessibilityIdentifier(OrchestratorControl.approval)
        .accessibilityLabel("Send to \(approval.targetTitle): \(approval.text)")
      HStack(spacing: Spacing.sm) {
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
            .font(Typography.caption)
            .foregroundStyle(Palette.secondaryInk)
        }
      }
    }
    .padding(Spacing.sm)
    .frame(maxWidth: 520, alignment: .leading)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Spacing.radiusMedium))
    .overlay(RoundedRectangle(cornerRadius: Spacing.radiusMedium).stroke(Palette.accent, lineWidth: 1.5))
    .shadow(color: Spacing.elevationRaised.color, radius: Spacing.elevationRaised.radius, y: Spacing.elevationRaised.y)
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
            ? Palette.status(.error) : Palette.accent
          context.stroke(path, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
      }
      ForEach(links) { link in
        if let source = frames[link.orchestratorID], let target = frames[link.targetID],
          let segment = OrchestratorLinkLayout.segment(
            from: source, to: target, zoom: zoom, panX: panX, panY: panY)
        {
          Text("\(link.targetTitle) · \(link.status.label)")
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(Palette.surface, in: Capsule())
            .overlay(Capsule().stroke(Palette.accent, lineWidth: 1))
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
