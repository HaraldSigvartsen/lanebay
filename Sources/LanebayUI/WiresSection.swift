import LanebayCore
import SwiftUI

/// The top of Orkestrering: the wires on this board, and one-click templates.
struct WiresSection: View {
  @Bindable var model: BoardViewModel
  let onDone: () -> Void
  @State private var agentID: String = "freebuff"

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.md) {
      VStack(alignment: .leading, spacing: DS.Space.xxs) {
        Text("Tråder mellom kort").sectionCaptionStyle()
        Text("Dra fra et punkt på kanten av et kort til et annet kort. Da sender det første kortet notatet sitt videre når oppgaven er ferdig.")
          .font(DS.Font.body)
          .foregroundStyle(DS.Color.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
      if model.wires.isEmpty {
        emptyState
      } else {
        VStack(spacing: DS.Space.xs) {
          ForEach(model.wires) { wire in WireRow(model: model, wire: wire) }
        }
      }
      templates
    }
    .onAppear {
      let agents = model.wireTemplateAgents
      if !agents.contains(where: { $0.id == agentID }) { agentID = agents.first?.id ?? "shell" }
    }
  }

  private var emptyState: some View {
    HStack(spacing: DS.Space.md) {
      WireDiagram(kind: nil)
        .frame(width: 120, height: 56)
      VStack(alignment: .leading, spacing: DS.Space.xxs) {
        Text("Ingen tråder ennå")
          .font(DS.Font.bodyEmphasis)
          .foregroundStyle(DS.Color.ink)
        Text("Hold musen over et kort for å se koblingspunktene, eller start med en mal under.")
          .font(DS.Font.caption)
          .foregroundStyle(DS.Color.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(DS.Space.md)
    .background(DS.Color.accentSoft.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.Color.hairline, lineWidth: 1))
  }

  private var templates: some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      HStack {
        Text("Maler").sectionCaptionStyle()
        Spacer()
        Picker("Agent på kortene", selection: $agentID) {
          ForEach(model.wireTemplateAgents, id: \.id) { Text($0.title).tag($0.id) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityIdentifier("wires.template.agent")
      }
      HStack(alignment: .top, spacing: DS.Space.sm) {
        ForEach(WireTemplate.allCases) { template in
          TemplateCard(template: template) {
            model.applyWireTemplate(template, agentID: agentID)
            onDone()
          }
        }
      }
    }
  }
}

private struct WireRow: View {
  @Bindable var model: BoardViewModel
  let wire: Wire
  @State private var hovering = false

  var body: some View {
    HStack(spacing: DS.Space.sm) {
      Image(systemName: wire.direction == .twoWay ? "arrow.left.arrow.right" : "arrow.right")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(wire.enabled ? DS.Color.accent : DS.Color.secondaryInk)
        .frame(width: 28, height: 28)
        .background(DS.Color.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text("\(model.consoleTitle(wire.from)) \(wire.direction == .twoWay ? "↔" : "→") \(model.consoleTitle(wire.to))")
          .font(DS.Font.bodyEmphasis)
          .foregroundStyle(DS.Color.ink)
          .lineLimit(1)
        Text(detail)
          .font(DS.Font.caption)
          .foregroundStyle(DS.Color.secondaryInk)
          .lineLimit(1)
      }
      Spacer(minLength: DS.Space.xs)
      Toggle("Aktiv", isOn: Binding(get: { wire.enabled }, set: { value in model.updateWire(wire.id) { $0.enabled = value } }))
        .toggleStyle(.switch)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Aktiv: \(model.consoleTitle(wire.from)) til \(model.consoleTitle(wire.to))")
      Button {
        model.selectedWireID = nil
        model.removeWire(wire.id)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.lbIcon)
      .help("Slett tråden")
      .accessibilityLabel("Slett tråden \(model.consoleTitle(wire.from)) til \(model.consoleTitle(wire.to))")
    }
    .padding(.horizontal, DS.Space.sm)
    .padding(.vertical, DS.Space.xs)
    .background(
      (hovering ? DS.Color.accentSoft.opacity(0.5) : DS.Color.surface.opacity(0.6)),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Color.hairline, lineWidth: 1))
    .onHover { hovering = $0 }
    .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.3), value: hovering)
  }

  private var detail: String {
    var parts = [wire.mode.label]
    if !wire.instruction.isEmpty { parts.append("«\(wire.instruction)»") }
    if !wire.enabled { parts.append("på pause") }
    return parts.joined(separator: " · ")
  }
}

private struct TemplateCard: View {
  let template: WireTemplate
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: DS.Space.xs) {
        WireDiagram(kind: template)
          .frame(height: 64)
          .frame(maxWidth: .infinity)
          .padding(DS.Space.xs)
          .background(DS.Color.accentSoft.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        Text(template.title)
          .font(DS.Font.bodyEmphasis)
          .foregroundStyle(DS.Color.ink)
        Text(template.summary)
          .font(DS.Font.caption)
          .foregroundStyle(DS.Color.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Text("Legg på tavlen")
          .font(DS.Font.caption.weight(.semibold))
          .foregroundStyle(DS.Color.accentInk)
      }
      .padding(DS.Space.xs)
      .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
      .background(DS.Color.surface.opacity(hovering ? 0.95 : 0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(hovering ? DS.Color.accent : DS.Color.hairline, lineWidth: hovering ? 1.5 : 1))
      .scaleEffect(hovering ? 1.01 : 1)
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(PressableStyle())
    .onHover { hovering = $0 }
    .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.3), value: hovering)
    .accessibilityLabel("Mal: \(template.title)")
    .accessibilityIdentifier("wires.template.\(template.rawValue)")
  }
}

private struct PressableStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1)
  }
}

/// A tiny picture of cards and wires for the empty state and the template cards.
private struct WireDiagram: View {
  let kind: WireTemplate?

  var body: some View {
    Canvas { context, size in
      let boxes: [CGRect]
      let links: [(Int, Int)]
      let w = size.width, h = size.height
      switch kind {
      case .pipeline:
        let bw = w * 0.22, bh = h * 0.42
        boxes = (0..<3).map { CGRect(x: w * 0.04 + Double($0) * w * 0.37, y: (h - bh) / 2, width: bw, height: bh) }
        links = [(0, 1), (1, 2)]
      case .leadWorkers:
        let bw = w * 0.2, bh = h * 0.32
        boxes = [CGRect(x: (w - bw) / 2, y: 2, width: bw, height: bh)]
          + (0..<3).map { CGRect(x: w * 0.06 + Double($0) * w * 0.33, y: h - bh - 2, width: bw, height: bh) }
        links = [(0, 1), (0, 2), (0, 3)]
      case nil:
        let bw = w * 0.32, bh = h * 0.6
        boxes = [CGRect(x: 2, y: (h - bh) / 2, width: bw, height: bh), CGRect(x: w - bw - 2, y: (h - bh) / 2, width: bw, height: bh)]
        links = [(0, 1)]
      }
      for (a, b) in links {
        let ra = boxes[a], rb = boxes[b]
        let vertical = kind == .leadWorkers || abs(rb.midY - ra.midY) > abs(rb.midX - ra.midX) * 0.6
        let start = vertical ? CGPoint(x: ra.midX, y: ra.maxY) : CGPoint(x: ra.maxX, y: ra.midY)
        let end = vertical ? CGPoint(x: rb.midX, y: rb.minY) : CGPoint(x: rb.minX, y: rb.midY)
        var path = Path()
        path.move(to: start)
        if vertical {
          path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + 14), control2: CGPoint(x: end.x, y: end.y - 14))
        } else {
          path.addCurve(to: end, control1: CGPoint(x: start.x + 16, y: start.y), control2: CGPoint(x: end.x - 16, y: end.y))
        }
        context.stroke(path, with: .color(DS.Color.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        context.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)), with: .color(DS.Color.accentHot))
      }
      for box in boxes {
        let shape = Path(roundedRect: box, cornerRadius: 5, style: .continuous)
        context.fill(shape, with: .color(DS.Color.surface))
        context.stroke(shape, with: .color(DS.Color.accent.opacity(0.7)), lineWidth: 1.2)
        let bar = CGRect(x: box.minX + 4, y: box.minY + 4, width: box.width * 0.5, height: 3)
        context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(DS.Color.secondaryInk.opacity(0.5)))
      }
    }
    .accessibilityHidden(true)
  }
}
