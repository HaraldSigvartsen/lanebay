import LanebayCore
import SwiftUI

public struct LoopPanel: View {
  @Bindable private var model: BoardViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var prompt = ""
  @State private var pattern = ""
  @State private var showingEditor = false
  @State private var triggerKind = "Idle"
  @State private var interval = "60"
  @State private var goal = ""
  @State private var maxIterations = "10"
  @State private var validationError: String?

  public init(model: BoardViewModel) { self.model = model }

  private var loops: [Loop] { model.workspace?.loops ?? [] }
  private var controlHeight: CGFloat { DS.Space.lg + DS.Space.xxs }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DS.Space.md) {
        CronJobsSection(model: model)
        Divider()
        Text("Gjentakelser i ett kort").sectionCaptionStyle()
        if loops.isEmpty && !showingEditor {
          EmptyStateView(
            symbol: "repeat",
            title: "Ingen cron-jobber ennå",
            message: "Kjør et prompt på tid, på tomgang eller når et mål er nådd.",
            actionTitle: "Ny cron-jobb",
            action: { showingEditor = true },
            identifier: "loops.empty")
          .padding(.vertical, DS.Space.lg)
        } else if !loops.isEmpty {
          VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Jobber").sectionCaptionStyle()
            ForEach(loops, id: \.id) { loop in
              loopCard(loop)
            }
          }
        }
        creationSection
      }
      .padding(DS.Space.md)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  // MARK: - Creation

  private var creationSection: some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      AXActionButton(
        title: "Ny cron-jobb",
        systemImage: showingEditor ? "chevron.up" : "plus",
        identifier: "loops.add",
        accessibilityLabel: showingEditor ? "Skjul skjema" : "Ny cron-jobb",
        enabled: true,
        highlighted: showingEditor,
        compact: false
      ) {
        showingEditor.toggle()
      }
      .frame(height: controlHeight)

      if showingEditor {
        editor
          .transition(DS.Motion.appear)
      }
    }
    .animation(DS.Motion.animation(DS.Motion.snappy, reduceMotion: reduceMotion), value: showingEditor)
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: DS.Space.sm) {
      Text("Ny cron-jobb").sectionCaptionStyle()
      Text(targetCaption)
        .font(DS.Font.caption)
        .foregroundStyle(loopTarget == nil ? DS.Color.status(.error) : DS.Color.secondaryInk)
      IdentifierTextField(text: $prompt, identifier: "loops.prompt", placeholder: "Prompt to send")
        .frame(height: DS.Space.lg)
      HStack(spacing: DS.Space.xs) {
        triggerButton("Idle", identifier: "loops.trigger.idle", kind: "Idle")
        triggerButton("Output match", identifier: "loops.trigger.output", kind: "Output match")
      }
      HStack(spacing: DS.Space.xs) {
        triggerButton("Schedule", identifier: "loops.trigger.schedule", kind: "Schedule")
        triggerButton("Goal check", identifier: "loops.trigger.goal", kind: "Goal check")
      }
      if triggerKind == "Output match" {
        IdentifierTextField(text: $pattern, identifier: "loops.pattern", placeholder: "Output contains")
          .frame(height: DS.Space.lg)
      }
      if triggerKind == "Schedule" || triggerKind == "Goal check" {
        IdentifierTextField(text: $interval, identifier: "loops.interval", placeholder: "Interval in seconds")
          .frame(height: DS.Space.lg)
      }
      if triggerKind == "Goal check" {
        IdentifierTextField(text: $goal, identifier: "loops.goal", placeholder: "Goal marker")
          .frame(height: DS.Space.lg)
      }
      IdentifierTextField(text: $maxIterations, identifier: "loops.max", placeholder: "Maximum iterations (1–1000)")
        .frame(height: DS.Space.lg)
      if let validationError {
        Text(validationError).font(DS.Font.caption).foregroundStyle(DS.Color.status(.error))
      }
      AXActionButton(
        title: "Lag cron-jobb",
        systemImage: nil,
        identifier: "loops.create",
        accessibilityLabel: "Lag cron-jobb",
        enabled: loopTarget != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        highlighted: false,
        primary: true,
        compact: false
      ) { create() }
      .frame(maxWidth: .infinity)
      .frame(height: controlHeight)
    }
    .padding(DS.Space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glass(radius: DS.Radius.control)
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
    .frame(height: controlHeight)
  }

  // MARK: - Cards

  private func loopCard(_ loop: Loop) -> some View {
    let result = CronPresentation.lastResult(loop)
    return VStack(alignment: .leading, spacing: DS.Space.xs) {
      HStack(spacing: DS.Space.xs) {
        Text(loop.name)
          .font(DS.Font.bodyEmphasis)
          .foregroundStyle(DS.Color.ink)
          .lineLimit(1)
        Spacer(minLength: DS.Space.xs)
        Toggle("Aktiv", isOn: Binding(
          get: { loop.isEnabled },
          set: { model.setLoopEnabled(loop.id, $0) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .accessibilityIdentifier("loops.toggle")
        .accessibilityLabel(loop.isEnabled ? "Stopp \(loop.name)" : "Start \(loop.name)")
      }

      Text(CronPresentation.schedule(loop.trigger))
        .font(DS.Font.mono)
        .foregroundStyle(DS.Color.secondaryInk)
        .lineLimit(1)

      HStack(spacing: DS.Space.xs) {
        StatusPill(kind: result.kind, label: result.label)
        Text(CronPresentation.nextRunLabel(loop: loop))
          .font(DS.Font.caption)
          .foregroundStyle(DS.Color.secondaryInk)
          .lineLimit(1)
        Spacer(minLength: 0)
      }

      Text(verbatim: "\(loop.iterations) / \(loop.maxIterations) · \(targetTitle(loop.targetNodeID)) · \(loop.prompt)")
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.mutedInk)
        .lineLimit(1)
        .truncationMode(.tail)

      if loop.needsReview {
        Text("Legacy regex-trigger er deaktivert. Lag jobben på nytt.")
          .font(DS.Font.caption)
          .foregroundStyle(DS.Color.status(.error))
      }
    }
    .padding(DS.Space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glass(radius: DS.Radius.control)
  }

  // MARK: - Target and creation

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

  private func targetTitle(_ id: UUID) -> String {
    model.workspace?.nodes.first { $0.id == id }?.title ?? "Console"
  }
}

/// Cron card text. Pure so the schedule, next run and last result can be tested without a view.
enum CronPresentation {
  static func schedule(_ trigger: LoopTrigger) -> String {
    switch trigger {
    case .idle:
      "ved tomgang"
    case let .outputMatch(pattern):
      "når output inneholder \"\(pattern)\""
    case let .schedule(seconds):
      "hvert \(seconds)s"
    case let .goalCheck(seconds, goal):
      "hvert \(seconds)s · mål \(goal)"
    }
  }

  static func lastResult(_ loop: Loop) -> (kind: StatusKind, label: String) {
    if loop.needsReview { return (.error, "Trenger gjennomgang") }
    guard loop.isEnabled else {
      return loop.iterations >= loop.maxIterations ? (.done, "Fullført") : (.stopped, "Stoppet")
    }
    return (.running, "Aktiv")
  }

  /// The next run relative to `now`: a countdown for timed triggers, the wait condition otherwise.
  static func nextRunLabel(loop: Loop, now: Date = Date()) -> String {
    if loop.needsReview { return "Kjører ikke" }
    guard loop.isEnabled else { return "Stoppet" }
    guard loop.iterations < loop.maxIterations else { return "Fullført" }
    switch loop.trigger {
    case .idle:
      return "ved tomgang"
    case .outputMatch:
      return "ved match"
    case let .schedule(seconds), let .goalCheck(seconds, _):
      let base = loop.lastRunAt ?? now
      let remaining = base.addingTimeInterval(TimeInterval(seconds)).timeIntervalSince(now)
      return relative(remaining)
    }
  }

  static func relative(_ seconds: TimeInterval) -> String {
    guard seconds > 0 else { return "nå" }
    if seconds < 60 { return "om \(Int(seconds.rounded())) s" }
    if seconds < 3600 { return "om \(Int(seconds / 60)) min" }
    if seconds < 86_400 { return "om \(Int(seconds / 3600)) t" }
    return "om \(Int(seconds / 86_400)) d"
  }
}
