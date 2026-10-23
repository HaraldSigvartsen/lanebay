import Foundation
import LanebayCore
import SwiftUI

public struct UsageWorkspaceRow: Identifiable, Equatable {
    public var id: UUID { workspaceID }
    public let workspaceID: UUID
    public let workspaceName: String
    public let dispatchedPrompts: Int
    public let loopIterations: Int
    public let runningSeconds: Double
    public let idleSeconds: Double
    public let waitingForInputSeconds: Double
    public let sessions: [UsageSessionSummary]
}

public struct UsageDayRow: Identifiable, Equatable {
    public var id: String { day }
    public let day: String
    public let workspaces: [UsageWorkspaceRow]
}

@MainActor
@Observable
public final class UsagePanelModel {
    public private(set) var days: [UsageDayRow] = []
    public private(set) var optionalLogSnapshot: UsageLogSnapshot?
    public private(set) var errorMessage: String?

    private let store: UsageStatsStore
    private let logHomeRoot: URL?

    public init(
        store: UsageStatsStore = UsageStatsStore(),
        homeRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.store = store
        self.logHomeRoot = homeRoot
    }

    public func refresh() async {
        do {
            let document = try store.load()
            days = document.days.sorted { $0.day > $1.day }.map { day in
                UsageDayRow(
                    day: day.day,
                    workspaces: day.workspaces.map { workspace in
                        UsageWorkspaceRow(
                            workspaceID: workspace.workspaceID,
                            workspaceName: workspace.workspaceName,
                            dispatchedPrompts: workspace.dispatchedPrompts,
                            loopIterations: workspace.loopIterations,
                            runningSeconds: workspace.runningSeconds,
                            idleSeconds: workspace.idleSeconds,
                            waitingForInputSeconds: workspace.waitingForInputSeconds,
                            sessions: workspace.sessions.sorted { $0.startedAt > $1.startedAt }
                        )
                    }.sorted { $0.workspaceName.localizedCaseInsensitiveCompare($1.workspaceName) == .orderedAscending }
                )
            }
            errorMessage = nil
        } catch {
            days = []
            errorMessage = error.localizedDescription
        }
        let logHomeRoot = self.logHomeRoot
        optionalLogSnapshot = await Task.detached(priority: .utility) {
            guard let logHomeRoot else { return nil }
            return LocalUsageLogSnapshotReader(homeRoot: logHomeRoot).snapshot()
        }.value
    }
}

public struct UsagePanel: View {
    @Bindable private var model: UsagePanelModel

    public init(model: UsagePanelModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("Local offline usage")
                    .font(Typography.bodyEmphasis)
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
            }

            if let message = model.errorMessage {
                Text(message).font(Typography.caption).foregroundStyle(Palette.status(.error))
            } else if model.days.isEmpty {
                ContentUnavailableView("No usage yet", systemImage: "clock", description: Text("Start a console and dispatch prompts to populate local usage stats."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(model.days) { day in
                            GroupBox(day.day) {
                                VStack(alignment: .leading, spacing: Spacing.sm) {
                                    ForEach(day.workspaces) { workspace in
                                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                                            Text(workspace.workspaceName).font(Typography.bodyEmphasis)
                                            Text("Prompts: \(workspace.dispatchedPrompts) · Loop iterations: \(workspace.loopIterations)")
                                                .font(Typography.caption).foregroundStyle(Palette.secondaryInk)
                                            Text("Status time — running \(formattedDuration(workspace.runningSeconds)), idle \(formattedDuration(workspace.idleSeconds)), waiting for input \(formattedDuration(workspace.waitingForInputSeconds))")
                                                .font(Typography.caption).foregroundStyle(Palette.secondaryInk)
                                            if workspace.sessions.isEmpty {
                                                Text("No completed sessions").font(Typography.caption).foregroundStyle(Palette.mutedInk)
                                            } else {
                                                ForEach(workspace.sessions.prefix(6)) { session in
                                                    Text("\(session.agent) session · \(formattedDuration(session.durationSeconds))")
                                                        .font(Typography.caption)
                                                }
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if let snapshot = model.optionalLogSnapshot {
                Text("Optional local log snapshot: prompts \(snapshot.dispatchedPrompts), loops \(snapshot.loopIterations), status \(formattedDuration(snapshot.statusDuration.running))/\(formattedDuration(snapshot.statusDuration.idle))/\(formattedDuration(snapshot.statusDuration.waitingForInput))")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.mutedInk)
            }
            Text("Local only · Offline only · No telemetry")
                .font(Typography.caption)
                .foregroundStyle(Palette.mutedInk)
        }
        .padding(Spacing.sm)
        .background(Palette.surface)
        .task { await model.refresh() }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let clamped = max(0, Int(seconds.rounded()))
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let remaining = clamped % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(remaining)s" }
        return "\(remaining)s"
    }
}
