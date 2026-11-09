import LanebayCore
import SwiftUI

/// First-launch welcome card. Shows on the empty board — no workspace at all, or a workspace with no consoles.
public struct OnboardingCard: View {
    public let hasWorkspace: Bool
    public let onStart: () -> Void
    public let onDocs: () -> Void
    public let onCreateWorkspace: () -> Void

    public init(
        hasWorkspace: Bool = true,
        onStart: @escaping () -> Void,
        onDocs: @escaping () -> Void,
        onCreateWorkspace: @escaping () -> Void
    ) {
        self.hasWorkspace = hasWorkspace
        self.onStart = onStart
        self.onDocs = onDocs
        self.onCreateWorkspace = onCreateWorkspace
    }

    /// Onboarding is for the empty board only: no workspace, or a workspace without nodes.
    public static func shouldShow(workspace: Workspace?) -> Bool {
        workspace?.nodes.isEmpty ?? true
    }

    private static let steps = [
        "Start en terminal",
        "Velg leverandør og modell",
        "Følg med i Aktivitet",
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Velkommen til Lanebay")
                .font(DS.Font.display)
                .foregroundStyle(DS.Color.ink)
                .accessibilityAddTraits(.isHeader)

            Text("Ett brett for alle kodeagentene dine: start terminaler, gi dem oppgaver og se status med ett blikk.")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: DS.Space.xs) {
                        Text("\(index + 1)")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.accentInk)
                            .frame(width: 20, height: 20)
                            .background(DS.Color.accentSoft, in: Circle())
                        Text(step)
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.ink)
                    }
                }
            }

            HStack(spacing: DS.Space.xs) {
                Button(hasWorkspace ? "Start første terminal" : "Lag et arbeidsområde") {
                    if hasWorkspace { onStart() } else { onCreateWorkspace() }
                }
                .buttonStyle(.lbPrimary)
                .accessibilityIdentifier("onboarding.start")

                Button("Les mer", action: onDocs)
                    .buttonStyle(.lbGhost)
                    .accessibilityIdentifier("onboarding.docs")
            }
            .padding(.top, DS.Space.xxs)
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: 420, alignment: .leading)
        .glass(radius: DS.Radius.sheet)
        .elevation(DS.Elevation.floating)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.card")
    }
}

#Preview {
    OnboardingCard(onStart: {}, onDocs: {}, onCreateWorkspace: {})
        .padding(DS.Space.xl)
        .background(DS.Color.canvasGradient)
}
