import AppKit
import LanebayCore
import SwiftUI

/// Converts between board coordinates and the viewport the canvas draws in.
struct BoardTransform {
  let zoom: Double
  let panX: Double
  let panY: Double

  func view(_ p: WireGeometry.Point) -> CGPoint { CGPoint(x: p.x * zoom + panX, y: p.y * zoom + panY) }
  func board(_ p: CGPoint) -> WireGeometry.Point { .init(x: (p.x - panX) / zoom, y: (p.y - panY) / zoom) }
}

/// The bezier for one wire, in viewport coordinates.
struct WireCurve {
  let start: CGPoint
  let c1: CGPoint
  let c2: CGPoint
  let end: CGPoint

  init?(wire: Wire, frames: [UUID: NodeFrame], transform: BoardTransform) {
    guard let a = frames[wire.from], let b = frames[wire.to] else { return nil }
    let sides = WireGeometry.liveSides(from: a, to: b)
    let pa = WireGeometry.anchor(a, side: sides.from)
    let pb = WireGeometry.anchor(b, side: sides.to)
    let (c1, c2) = WireGeometry.curve(from: pa, side: sides.from, to: pb, side: sides.to)
    start = transform.view(pa); end = transform.view(pb)
    self.c1 = transform.view(c1); self.c2 = transform.view(c2)
  }

  init(drag: WireDrag, frames: [UUID: NodeFrame], transform: BoardTransform) {
    let a = frames[drag.from] ?? NodeFrame(x: drag.point.x, y: drag.point.y, w: 0, h: 0)
    let pa = WireGeometry.anchor(a, side: drag.side)
    var end = drag.point
    var endSide: CardSide?
    if let target = drag.hoverTarget, let frame = frames[target] {
      endSide = WireGeometry.facingSide(frame, toward: drag.point)
      end = WireGeometry.anchor(frame, side: endSide!)
    }
    let (c1, c2) = WireGeometry.curve(from: pa, side: drag.side, to: end, side: endSide)
    start = transform.view(pa); self.end = transform.view(end)
    self.c1 = transform.view(c1); self.c2 = transform.view(c2)
  }

  var path: Path {
    var path = Path()
    path.move(to: start)
    path.addCurve(to: end, control1: c1, control2: c2)
    return path
  }

  func point(at t: Double) -> CGPoint {
    let p = WireGeometry.point(
      on: .init(x: start.x, y: start.y), .init(x: c1.x, y: c1.y), .init(x: c2.x, y: c2.y), .init(x: end.x, y: end.y), t: t)
    return CGPoint(x: p.x, y: p.y)
  }

  /// A small arrow head at `t` (1 = target end), pointing along the curve.
  func arrow(at t: Double, size: CGFloat) -> Path {
    let tip = point(at: t)
    let back = point(at: max(0, t - 0.04))
    let angle = atan2(tip.y - back.y, tip.x - back.x)
    var path = Path()
    path.move(to: tip)
    path.addLine(to: CGPoint(x: tip.x - size * cos(angle - 0.45), y: tip.y - size * sin(angle - 0.45)))
    path.addLine(to: CGPoint(x: tip.x - size * cos(angle + 0.45), y: tip.y - size * sin(angle + 0.45)))
    path.closeSubpath()
    return path
  }
}

/// Wires under the cards: curves, arrow heads, hover and selection, and flowing dots when a message passes.
struct WireLayer: View {
  @Bindable var model: BoardViewModel
  let frames: [UUID: NodeFrame]
  let transform: BoardTransform
  @State private var hoveredWireID: UUID?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let flowSeconds: TimeInterval = 2.4

  var body: some View {
    let wires = model.wires
    let anyFlowing = !reduceMotion && model.wirePulses.values.contains { Date().timeIntervalSince($0) < Self.flowSeconds + 1 }
    ZStack(alignment: .topLeading) {
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !anyFlowing)) { timeline in
        Canvas { context, _ in
          for wire in wires {
            guard let curve = WireCurve(wire: wire, frames: frames, transform: transform) else { continue }
            draw(wire, curve: curve, in: &context, now: timeline.date)
          }
          if let drag = model.wireDrag {
            let curve = WireCurve(drag: drag, frames: frames, transform: transform)
            context.stroke(
              curve.path, with: .color(DS.Color.accentHot),
              style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 6]))
            let r: CGFloat = drag.hoverTarget == nil ? 5 : 7
            context.fill(
              Path(ellipseIn: CGRect(x: curve.end.x - r, y: curve.end.y - r, width: r * 2, height: r * 2)),
              with: .color(DS.Color.accentHot))
          }
        }
      }
      .allowsHitTesting(false)
      ForEach(wires) { wire in
        if let curve = WireCurve(wire: wire, frames: frames, transform: transform) {
          WireHitShape(curve: curve)
            .fill(Color.black.opacity(0.001))
            .onHover { inside in hoveredWireID = inside ? wire.id : (hoveredWireID == wire.id ? nil : hoveredWireID) }
            .onTapGesture {
              NSApp.keyWindow?.makeFirstResponder(nil)
              model.select(nil)
              model.selectedWireID = wire.id
            }
            .help("\(model.consoleTitle(wire.from)) → \(model.consoleTitle(wire.to)) · klikk for å endre")
            .accessibilityElement()
            .accessibilityLabel("Tråd \(model.consoleTitle(wire.from)) til \(model.consoleTitle(wire.to))")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("wire.\(wire.id.uuidString)")
          // The popover goes on the tiny anchor before `.position`, or it anchors to the whole layer.
          Color.clear
            .frame(width: 2, height: 2)
            .popover(
              isPresented: Binding(
                get: { model.selectedWireID == wire.id },
                set: { if !$0, model.selectedWireID == wire.id { model.selectedWireID = nil } }),
              arrowEdge: .bottom
            ) {
              WirePopover(model: model, wireID: wire.id)
            }
            .position(curve.point(at: 0.5))
            .allowsHitTesting(false)
        }
      }
    }
  }

  private func draw(_ wire: Wire, curve: WireCurve, in context: inout GraphicsContext, now: Date) {
    let highlighted = hoveredWireID == wire.id || model.selectedWireID == wire.id
    let color = wire.enabled ? (highlighted ? DS.Color.accentHot : DS.Color.accent) : DS.Color.secondaryInk
    // Soft glow under the line.
    context.stroke(
      curve.path, with: .color(color.opacity(highlighted ? 0.28 : 0.14)),
      style: StrokeStyle(lineWidth: highlighted ? 10 : 7, lineCap: .round))
    context.stroke(
      curve.path, with: .color(color.opacity(wire.enabled ? 0.95 : 0.6)),
      style: StrokeStyle(lineWidth: highlighted ? 3 : 2, lineCap: .round, dash: wire.enabled ? [] : [6, 6]))
    context.fill(curve.arrow(at: 1, size: 11), with: .color(color))
    if wire.direction == .twoWay {
      let reversed = WireCurveReversed(curve)
      context.fill(reversed.arrow(at: 1, size: 11), with: .color(color))
    }
    for end in [curve.start, curve.end] {
      context.fill(Path(ellipseIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8)), with: .color(color))
    }
    if let pulse = model.wirePulses[wire.id] {
      let age = now.timeIntervalSince(pulse)
      if age >= 0, age < Self.flowSeconds {
        for index in 0..<4 {
          let t = (age / Self.flowSeconds) + Double(index) * 0.08
          guard t <= 1 else { continue }
          let p = curve.point(at: t)
          let r: CGFloat = 5 - CGFloat(index)
          context.fill(
            Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
            with: .color(DS.Color.accentHot.opacity(1 - Double(index) * 0.2)))
        }
      }
    }
  }
}

/// The same curve walked from the target end, for the second arrow on a two-way wire.
private func WireCurveReversed(_ curve: WireCurve) -> WireCurveBackwards { WireCurveBackwards(curve: curve) }

private struct WireCurveBackwards {
  let curve: WireCurve
  func arrow(at t: Double, size: CGFloat) -> Path {
    let tip = curve.point(at: 1 - t)
    let back = curve.point(at: min(1, 1 - t + 0.04))
    let angle = atan2(tip.y - back.y, tip.x - back.x)
    var path = Path()
    path.move(to: tip)
    path.addLine(to: CGPoint(x: tip.x - size * cos(angle - 0.45), y: tip.y - size * sin(angle - 0.45)))
    path.addLine(to: CGPoint(x: tip.x - size * cos(angle + 0.45), y: tip.y - size * sin(angle + 0.45)))
    path.closeSubpath()
    return path
  }
}

/// A fat invisible band around a wire so it is easy to hover and click.
struct WireHitShape: Shape {
  let curve: WireCurve
  func path(in rect: CGRect) -> Path {
    curve.path.strokedPath(StrokeStyle(lineWidth: 16, lineCap: .round))
  }
}

/// Connection ports on all four sides of every card, plus the drop-target ring while dragging.
struct WirePortsLayer: View {
  @Bindable var model: BoardViewModel
  let frames: [UUID: NodeFrame]
  let order: [UUID]
  let transform: BoardTransform
  let hoveredCard: UUID?

  var body: some View {
    ZStack(alignment: .topLeading) {
      if let drag = model.wireDrag, let target = drag.hoverTarget, let frame = frames[target] {
        let origin = transform.view(.init(x: frame.x, y: frame.y))
        RoundedRectangle(cornerRadius: 16 * transform.zoom, style: .continuous)
          .strokeBorder(DS.Color.accentHot, lineWidth: 2.5)
          .background(
            RoundedRectangle(cornerRadius: 16 * transform.zoom, style: .continuous)
              .fill(DS.Color.accentHot.opacity(0.06)))
          .frame(width: frame.w * transform.zoom + 12, height: frame.h * transform.zoom + 12)
          .position(
            x: origin.x + frame.w * transform.zoom / 2, y: origin.y + frame.h * transform.zoom / 2)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
      ForEach(order, id: \.self) { id in
        if let frame = frames[id] {
          ForEach(CardSide.allCases, id: \.self) { side in
            WirePort(
              model: model, nodeID: id, side: side, frame: frame, transform: transform,
              visible: model.wireDrag != nil || hoveredCard == id || model.selectedNodeIDs.contains(id))
          }
        }
      }
    }
  }
}

/// One port: a small ring on a card edge. Dragging it pulls out a wire.
struct WirePort: View {
  @Bindable var model: BoardViewModel
  let nodeID: UUID
  let side: CardSide
  let frame: NodeFrame
  let transform: BoardTransform
  let visible: Bool
  @State private var hovering = false

  var body: some View {
    let anchor = transform.view(WireGeometry.anchor(frame, side: side))
    let isSource = model.wireDrag?.from == nodeID && model.wireDrag?.side == side
    let size: CGFloat = hovering || isSource ? 18 : 13
    Circle()
      .fill(hovering || isSource ? DS.Color.accentHot : DS.Color.surface)
      .overlay(Circle().strokeBorder(hovering || isSource ? Color.white.opacity(0.9) : DS.Color.accent, lineWidth: 2))
      .overlay(
        Image(systemName: "plus")
          .font(.system(size: 8, weight: .heavy))
          .foregroundStyle(Color.white)
          .opacity(hovering ? 1 : 0))
      .frame(width: size, height: size)
      .shadow(color: DS.Color.accent.opacity(hovering ? 0.6 : 0.25), radius: hovering ? 8 : 3)
      .frame(width: 26, height: 26)
      .contentShape(Circle())
      .opacity(visible ? 1 : 0.0)
      .position(anchor)
      .animation(DS.Motion.snappy, value: hovering)
      .animation(DS.Motion.snappy, value: visible)
      .onHover { hovering = $0 }
      .gesture(
        DragGesture(minimumDistance: 2, coordinateSpace: .named("boardViewport"))
          .onChanged { value in
            let point = transform.board(value.location)
            let others = model.consoleFrames().filter { $0.0 != nodeID }
            let target = WireGeometry.card(at: point, in: others)
            model.wireDrag = WireDrag(from: nodeID, side: side, point: point, hoverTarget: target)
          }
          .onEnded { _ in
            withAnimation(DS.Motion.snappy) { _ = model.finishWireDrag() }
          }
      )
      .help("Dra til et annet kort for å koble dem sammen")
      .accessibilityElement()
      .accessibilityLabel("Koblingspunkt \(side.rawValue) på \(model.consoleTitle(nodeID))")
      .accessibilityIdentifier("wire.port.\(side.rawValue).\(nodeID.uuidString)")
      .allowsHitTesting(visible)
  }
}

/// Small editor for one wire: direction, what passes, an optional instruction, pause and delete.
struct WirePopover: View {
  @Bindable var model: BoardViewModel
  let wireID: UUID
  @State private var instruction = ""
  @FocusState private var instructionFocused: Bool
  @FocusState private var popoverFocused: Bool

  var body: some View {
    if let wire = model.wire(wireID) {
      VStack(alignment: .leading, spacing: DS.Space.md) {
        HStack(spacing: DS.Space.xs) {
          Image(systemName: "point.3.connected.trianglepath.dotted")
            .foregroundStyle(DS.Pastel.skyInk)
            .frame(width: 28, height: 28)
            .pastelFill(DS.Pastel.sky, radius: 9)
          Text("\(model.consoleTitle(wire.from)) \(wire.direction == .twoWay ? "↔" : "→") \(model.consoleTitle(wire.to))")
            .font(DS.Font.title)
            .foregroundStyle(DS.Color.ink)
            .lineLimit(1)
        }
        field("Retning") {
          Picker("Retning", selection: binding(\.direction)) {
            ForEach(WireDirection.allCases, id: \.self) { Text($0.label).tag($0) }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
        field("Hva sendes") {
          Picker("Hva sendes", selection: binding(\.mode)) {
            Text("Notatet når oppgaven er ferdig").tag(WireMode.handoff)
            Text("Hvert svar").tag(WireMode.everyReply)
          }
          .pickerStyle(.radioGroup)
          .labelsHidden()
        }
        field("Instruks (valgfritt)") {
          TextField("F.eks. «se over dette» eller «fiks feilene»", text: $instruction)
            .textFieldStyle(.roundedBorder)
            .focused($instructionFocused)
            .onSubmit { commitInstruction() }
            .onChange(of: instruction) { _, _ in commitInstruction() }
        }
        Toggle("Aktiv", isOn: binding(\.enabled))
          .toggleStyle(.switch)
        Text("Meldinger får overskriften «[Fra \(model.consoleTitle(wire.from))]» og kortes ned til \(WireMessage.maxCharacters) tegn.")
          .font(DS.Font.caption)
          .foregroundStyle(DS.Color.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
        Divider()
        HStack {
          Button(role: .destructive) {
            model.removeWire(wireID)
          } label: {
            Label("Slett tråd", systemImage: "trash")
          }
          .buttonStyle(.lbGhost)
          .foregroundStyle(DS.Color.status(.error))
          .keyboardShortcut(.delete, modifiers: [.command])
          Spacer()
          Button("Ferdig") { model.selectedWireID = nil }
            .buttonStyle(.lbPrimary)
            .keyboardShortcut(.defaultAction)
        }
      }
      .padding(DS.Pastel.dialogPadding - 4)
      .frame(width: 360)
      .pastelGlass(radius: 20, tint: DS.Pastel.sky, tintOpacity: 0.12, shadow: false)
      .focusable()
      .focusEffectDisabled()
      .focused($popoverFocused)
      // Delete removes the wire unless the instruction field is being edited.
      .onKeyPress(keys: [.delete, .deleteForward]) { _ in
        guard !instructionFocused else { return .ignored }
        model.removeWire(wireID)
        return .handled
      }
      .onAppear {
        instruction = wire.instruction
        popoverFocused = true
      }
    }
  }

  private func commitInstruction() {
    let text = instruction
    model.updateWire(wireID) { $0.instruction = text }
  }

  private func binding<T>(_ keyPath: WritableKeyPath<Wire, T>) -> Binding<T> {
    Binding(
      get: { model.wire(wireID)?[keyPath: keyPath] ?? Wire(from: UUID(), to: UUID())[keyPath: keyPath] },
      set: { value in model.updateWire(wireID) { $0[keyPath: keyPath] = value } })
  }

  @ViewBuilder
  private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.xxs) {
      Text(title.uppercased())
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.secondaryInk)
      content()
    }
  }
}
