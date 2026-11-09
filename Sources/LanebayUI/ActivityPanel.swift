import LanebayCore
import SwiftUI

/// The board's newest-first log of console activity, with per-kind filters and a timeline.
public struct ActivityPanel: View {
  @Bindable private var model: BoardViewModel
  @State private var kinds: Set<ActivityKind> = []

  public init(model: BoardViewModel) {
    self.model = model
  }

  private var events: [ActivityEvent] { model.activity.filtered(kinds) }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: DS.Space.xs) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: DS.Space.xxs) {
            ForEach(ActivityKind.allCases, id: \.self) { kind in
              filterChip(kind)
            }
          }
          .padding(.vertical, DS.Space.xxs)
        }
        Button("Tøm") { model.clearActivity() }
          .buttonStyle(.lbGhost)
          .disabled(model.activity.events.isEmpty)
          .accessibilityIdentifier("activity.clear")
      }
      .padding(.horizontal, DS.Space.md)
      .padding(.top, DS.Space.sm)

      if events.isEmpty {
        EmptyStateView(
          symbol: "waveform.path",
          title: "Ingen aktivitet ennå",
          message: "Statusendringer, sendinger og nye agenter dukker opp her.",
          identifier: "activity.empty")
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(events) { event in
              row(event)
                .transition(DS.Motion.appear)
            }
          }
          .padding(.horizontal, DS.Space.md)
          .padding(.vertical, DS.Space.xs)
          .animation(DS.Motion.smooth, value: events.map(\.id))
        }
        .accessibilityIdentifier("activity.list")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func row(_ event: ActivityEvent) -> some View {
    HStack(alignment: .top, spacing: DS.Space.sm) {
      ZStack(alignment: .top) {
        Rectangle()
          .fill(DS.Color.hairline)
          .frame(width: 1)
          .frame(maxHeight: .infinity)
        Circle()
          .fill(event.kind.tint)
          .frame(width: DS.Radius.chip, height: DS.Radius.chip)
          .padding(.top, DS.Space.xs)
      }
      .frame(width: DS.Radius.chip)

      VStack(alignment: .leading, spacing: DS.Space.xxs) {
        HStack(spacing: DS.Space.xs) {
          Text(ActivityFeed.timestamp(event.date))
            .font(DS.Font.mono)
            .foregroundStyle(DS.Color.secondaryInk)
          chip(event.kind)
          Text(event.title)
            .font(DS.Font.bodyEmphasis)
            .foregroundStyle(DS.Color.ink)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        Text(event.detail)
          .font(DS.Font.caption)
          .foregroundStyle(DS.Color.secondaryInk)
          .lineLimit(2)
      }
      .padding(.bottom, DS.Space.sm)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("activity.row")
  }

  private func chip(_ kind: ActivityKind) -> some View {
    Text(kind.panelTitle)
      .font(DS.Font.caption)
      .foregroundStyle(kind.tint)
      .padding(.horizontal, DS.Space.xxs)
      .padding(.vertical, DS.Space.xxs / 2)
      .background(kind.tint.opacity(0.16), in: Capsule())
  }

  private func filterChip(_ kind: ActivityKind) -> some View {
    let isOn = kinds.contains(kind)
    return Button {
      if isOn {
        kinds.remove(kind)
      } else {
        kinds.insert(kind)
      }
    } label: {
      HStack(spacing: DS.Space.xxs) {
        Circle()
          .fill(kind.tint)
          .frame(width: DS.Space.xs, height: DS.Space.xs)
        Text(kind.panelTitle)
          .font(DS.Font.caption)
      }
      .padding(.horizontal, DS.Space.xs)
      .padding(.vertical, DS.Space.xxs)
      .foregroundStyle(isOn ? DS.Color.accentInk : DS.Color.secondaryInk)
      .background(isOn ? DS.Color.accentSoft : DS.Color.raisedSurface, in: Capsule())
      .overlay(
        Capsule().strokeBorder(isOn ? DS.Color.accent.opacity(0.5) : DS.Color.hairline, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("activity.filter.\(kind.rawValue)")
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

extension ActivityKind {
  var panelTitle: String {
    switch self {
    case .status: "Status"
    case .send: "Send"
    case .spawn: "Spawn"
    case .handoff: "Handoff"
    case .stop: "Stop"
    case .start: "Start"
    case .wire: "Tråd"
    }
  }

  /// The colour role of a kind. Pure, so the timeline mapping can be pinned by a test.
  var rowTone: ActivityRowTone {
    switch self {
    case .status: .accent
    case .send: .accentInk
    case .spawn: .accentHot
    case .handoff: .handoff
    case .start, .stop: .neutral
    case .wire: .accent
    }
  }

  var tint: Color {
    switch rowTone {
    case .accent: DS.Color.accent
    case .accentInk: DS.Color.accentInk
    case .accentHot: DS.Color.accentHot
    case .handoff: DS.Color.status(.done)
    case .neutral: DS.Color.secondaryInk
    }
  }
}

enum ActivityRowTone: Hashable {
  case accent
  case accentInk
  case accentHot
  case handoff
  case neutral
}
