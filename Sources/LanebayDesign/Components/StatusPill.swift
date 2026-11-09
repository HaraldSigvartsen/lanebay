import SwiftUI

/// Coloured status dot plus label in a capsule. The dot pulses while running.
public struct StatusPill: View {
    public let kind: StatusKind
    public let label: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    public init(kind: StatusKind, label: String) {
        self.kind = kind
        self.label = label
    }

    private var color: Color { DS.Color.status(kind) }
    private var pulses: Bool { kind == .running && !reduceMotion }

    public var body: some View {
        HStack(spacing: DS.Space.xxs) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .scaleEffect(isPulsing ? 1.35 : 1)
                .opacity(isPulsing ? 0.55 : 1)
                .animation(DS.Motion.animation(DS.Motion.pulse, reduceMotion: reduceMotion), value: isPulsing)

            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryInk)
        }
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, DS.Space.xxs)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.rawValue): \(label)")
        .onAppear { isPulsing = pulses }
        .onChange(of: kind) { _, _ in isPulsing = pulses }
    }
}
