import LanebayCore
import SwiftUI

/// "working on: <task>" with a live countdown on consoles spawned through the control API.
public struct AgentTaskBanner: View {
  public let record: AgentTaskRecord

  public init(record: AgentTaskRecord) { self.record = record }

  public static func label(_ record: AgentTaskRecord) -> String {
    let task = record.task.replacingOccurrences(of: "\n", with: " ")
    let short = task.count > 80 ? String(task.prefix(79)) + "…" : task
    return "working on: \(short)"
  }

  public static func trailing(_ record: AgentTaskRecord, now: Date) -> String {
    record.state.isFinal ? record.state.title : AgentTaskRecord.countdown(record.remaining(now: now))
  }

  private var tint: Color {
    switch record.state {
    case .starting, .running: Palette.accent
    case .done: Palette.status(.idle)
    case .timedOut, .failed, .exited: Palette.status(.error)
    case .stopped: Palette.secondaryInk
    }
  }

  public var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(spacing: Spacing.xs) {
        Circle().fill(tint).frame(width: 7, height: 7)
        Text(Self.label(record))
          .font(Typography.caption)
          .foregroundStyle(Palette.ink)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: Spacing.xs)
        Text(Self.trailing(record, now: context.date))
          .font(Typography.caption.monospacedDigit())
          .foregroundStyle(tint)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, 4)
      .background(tint.opacity(0.14))
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("console.agentTask.\(record.nodeID.uuidString)")
    }
  }
}
