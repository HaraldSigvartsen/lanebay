import LanebayCore
import SwiftUI

public struct LoopPanel: View {
  @Bindable private var model: BoardViewModel
  @State private var prompt = ""
  @State private var pattern = ""
  @State private var showingEditor = false
  @State private var triggerKind = "Idle"
  @State private var interval = "60"
  @State private var goal = ""
  @State private var maxIterations = "10"
  @State private var validationError: String?

  public init(model: BoardViewModel) { self.model = model }

  public var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        Text("Loops").font(Typography.title)
        Spacer()
        AXActionButton(
          title: "Add",
          systemImage: "plus",
          identifier: "loops.add",
          accessibilityLabel: showingEditor ? "Hide loop editor" : "Add loop",
          enabled: true,
          highlighted: showingEditor,
          compact: false
        ) { showingEditor.toggle() }
        .frame(width: 88, height: 28)
      }
      if showingEditor { editor }
      ForEach(Array(model.workspace?.loops ?? [Loop]()), id: \.id) { loop in
        loopRow(loop)
      }
      Spacer(minLength: 0)
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Palette.surface)
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text(targetCaption)
        .font(Typography.caption)
        .foregroundStyle(loopTarget == nil ? Palette.status(.error) : Palette.secondaryInk)
      IdentifierTextField(text: $prompt, identifier: "loops.prompt", placeholder: "Prompt to send")
        .frame(height: 24)
      HStack(spacing: Spacing.xs) {
        triggerButton("Idle", identifier: "loops.trigger.idle", kind: "Idle")
        triggerButton("Output match", identifier: "loops.trigger.output", kind: "Output match")
      }
      HStack(spacing: Spacing.xs) {
        triggerButton("Schedule", identifier: "loops.trigger.schedule", kind: "Schedule")
        triggerButton("Goal check", identifier: "loops.trigger.goal", kind: "Goal check")
      }
      if triggerKind == "Output match" {
        IdentifierTextField(text: $pattern, identifier: "loops.pattern", placeholder: "Output contains")
          .frame(height: 24)
      }
      if triggerKind == "Schedule" || triggerKind == "Goal check" {
        IdentifierTextField(text: $interval, identifier: "loops.interval", placeholder: "Interval in seconds")
          .frame(height: 24)
      }
      if triggerKind == "Goal check" {
        IdentifierTextField(text: $goal, identifier: "loops.goal", placeholder: "Goal marker")
          .frame(height: 24)
      }
      IdentifierTextField(text: $maxIterations, identifier: "loops.max", placeholder: "Maximum iterations (1–1000)")
        .frame(height: 24)
      if let validationError {
        Text(validationError).font(Typography.caption).foregroundStyle(Palette.status(.error))
      }
      AXActionButton(
        title: "Create loop",
        systemImage: nil,
        identifier: "loops.create",
        accessibilityLabel: "Create loop",
        enabled: loopTarget != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        highlighted: false,
        compact: false
      ) { create() }
      .frame(maxWidth: .infinity)
      .frame(height: 28)
    }
  }

  private func triggerButton(_ title: String, identifier: String, kind: String) -> some View {
    AXActionButton(
      title: title,
      systemImage: nil,
      identifier: identifier,
      accessibilityLabel: "\(title) trigger",
      enabled: true,
      highlighted: triggerKind == kind,
      compact: false,
      selectionValue: triggerKind == kind ? "selected" : "unselected"
    ) { triggerKind = kind }
    .frame(maxWidth: .infinity)
    .frame(height: 28)
  }

  private var loopTarget: Node? {
    let consoles = model.workspace?.nodes.filter { $0.kind == .console } ?? []
    if let focused = model.focusedNodeID, let node = consoles.first(where: { $0.id == focused }) {
      return node
    }
    let selected = consoles.filter { model.selectedNodeIDs.contains($0.id) }
    if selected.count == 1 { return selected[0] }
    if consoles.count == 1 { return consoles[0] }
    return nil
  }

  private var targetCaption: String {
    guard let target = loopTarget else { return "Select one console" }
    return "Sends to \(target.title)"
  }

  private func create() {
    guard let target = loopTarget?.id else {
      validationError = "Select one console."
      return
    }
    let seconds = Int(interval) ?? 0
    let limit = Int(maxIterations) ?? 0
    guard (1...1000).contains(limit) else {
      validationError = "Maximum iterations must be between 1 and 1000."
      return
    }
    let trigger: LoopTrigger
    switch triggerKind {
    case "Output match": trigger = .outputMatch(pattern: pattern)
    case "Schedule": trigger = .schedule(intervalSeconds: seconds)
    case "Goal check": trigger = .goalCheck(intervalSeconds: seconds, goal: goal)
    default: trigger = .idle
    }
    if model.createLoop(targetNodeID: target, prompt: prompt, trigger: trigger, maxIterations: limit) != nil {
      prompt = ""
      pattern = ""
      goal = ""
      validationError = nil
      showingEditor = false
    } else {
      validationError = LoopValidator.validate(
        Loop(targetNodeID: target, prompt: prompt, trigger: trigger, maxIterations: limit)
      ) ?? "Select a valid console target."
    }
  }

  private func loopRow(_ loop: Loop) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(loop.name).font(Typography.bodyEmphasis).foregroundStyle(Palette.ink)
        Text("\(triggerLabel(loop.trigger)) · \(targetTitle(loop.targetNodeID))")
          .font(Typography.caption).foregroundStyle(Palette.secondaryInk)
        Text(loop.prompt).font(Typography.caption).foregroundStyle(Palette.ink).lineLimit(1)
        if loop.needsReview {
          Text("Needs review · legacy regex trigger disabled")
            .font(Typography.caption).foregroundStyle(Palette.status(.error))
        }
        Text("\(loop.iterations) / \(loop.maxIterations) · \(loop.isEnabled ? "Active" : "Stopped")")
          .font(Typography.caption).foregroundStyle(Palette.secondaryInk)
      }
      Spacer()
      if loop.isEnabled {
        Button("Stop") { model.stopLoop(loop.id) }.buttonStyle(.bordered)
      }
    }
    .padding(Spacing.sm)
    .background(Palette.raisedSurface, in: RoundedRectangle(cornerRadius: Spacing.radiusSmall))
  }

  private func targetTitle(_ id: UUID) -> String {
    model.workspace?.nodes.first { $0.id == id }?.title ?? "Console"
  }

  private func triggerLabel(_ trigger: LoopTrigger) -> String {
    switch trigger {
    case .idle: "Idle"
    case let .outputMatch(pattern): "Output contains \(pattern)"
    case let .schedule(seconds): "Every \(seconds)s"
    case let .goalCheck(seconds, goal): "Goal \(goal) every \(seconds)s"
    }
  }
}
