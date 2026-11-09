import Foundation
import LanebayCore
import LanebayDesign
import SwiftUI
import Darwin

public struct GitHubCommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}

public protocol GitHubCommandRunning: Sendable {
    func run(arguments: [String], workingDirectory: URL?, timeout: Duration, maxOutputBytes: Int) async throws -> GitHubCommandResult
}

public enum GitHubRunnerError: LocalizedError {
    case timeout
    case couldNotStart(String)

    public var errorDescription: String? {
        switch self {
        case .timeout: "The GitHub CLI command timed out."
        case .couldNotStart(let reason): "Could not start GitHub CLI: \(reason)"
        }
    }
}

public struct GitHubCLIRunner: GitHubCommandRunning {
    private let executableCandidates: [URL]
    private let killGracePeriod: Duration

    public init(
        executableCandidates: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin/gh"),
            URL(fileURLWithPath: "/usr/local/bin/gh"),
            URL(fileURLWithPath: "/usr/bin/gh"),
        ],
        killGracePeriod: Duration = .milliseconds(300)
    ) {
        self.executableCandidates = executableCandidates
        self.killGracePeriod = killGracePeriod
    }

    public func run(arguments: [String], workingDirectory: URL?, timeout: Duration, maxOutputBytes: Int) async throws -> GitHubCommandResult {
        guard let executableURL = resolveExecutable() else {
            throw GitHubRunnerError.couldNotStart("gh executable not found in known locations")
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = OutputCollector(maxBytes: maxOutputBytes)
        let stderrCollector = OutputCollector(maxBytes: maxOutputBytes)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw GitHubRunnerError.couldNotStart(error.localizedDescription)
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    await waitForExit(process)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    await terminateWithEscalation(process, gracePeriod: killGracePeriod)
                    throw GitHubRunnerError.timeout
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            await terminateWithEscalation(process, gracePeriod: .zero)
            _ = await waitForExit(process)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutCollector.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrCollector.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        return GitHubCommandResult(
            exitCode: process.terminationStatus,
            stdout: stdoutCollector.string,
            stderr: stderrCollector.string
        )
    }

    private func waitForExit(_ process: Process) async {
        if !process.isRunning { return }
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
    }

    private func resolveExecutable() -> URL? {
        let manager = FileManager.default
        for candidate in executableCandidates {
            guard manager.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate
        }
        return nil
    }

    private func terminateWithEscalation(_ process: Process, gracePeriod: Duration) async {
        guard process.isRunning else { return }
        process.terminate()
        if gracePeriod > .zero {
            try? await Task.sleep(for: gracePeriod)
        }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if pid > 0 {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var storage = Data()

    init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !chunk.isEmpty, storage.count < maxBytes else { return }
        let remaining = maxBytes - storage.count
        storage.append(chunk.prefix(remaining))
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }
}

public struct GitHubIssueSummary: Identifiable, Equatable {
    public let id: Int
    public let number: Int
    public let title: String
    public let url: URL
    public let updatedAt: Date?
}

public struct GitHubPRSummary: Identifiable, Equatable {
    public let id: Int
    public let number: Int
    public let title: String
    public let branch: String
    public let url: URL
    public let checksSummary: String
    public let updatedAt: Date?
}

@MainActor
@Observable
public final class GitHubPanelModel {
    public private(set) var projectRoots: [URL]
    public private(set) var selectedRoot: URL?
    public private(set) var repositoryName = ""
    public private(set) var currentBranch = "Unknown"
    public private(set) var openPullRequests: [GitHubPRSummary] = []
    public private(set) var recentIssues: [GitHubIssueSummary] = []
    public private(set) var checkStatus = "No checks found"
    public private(set) var isLoading = false
    public private(set) var emptyStateMessage: String?
    public private(set) var errorMessage: String?

    private let runner: GitHubCommandRunning
    private let timeout: Duration
    private let maxOutputBytes: Int

    public init(
        workspace: Workspace?,
        runner: GitHubCommandRunning = GitHubCLIRunner(),
        timeout: Duration = .seconds(4),
        maxOutputBytes: Int = 131_072
    ) {
        self.runner = runner
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        var seen = Set<String>()
        projectRoots = (workspace?.repos ?? []).sorted { $0.path < $1.path }
            .filter { seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
        selectedRoot = projectRoots.first
    }

    public func update(workspace: Workspace?) {
        var seen = Set<String>()
        let nextRoots = (workspace?.repos ?? []).sorted { $0.path < $1.path }
            .filter { seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
        guard nextRoots != projectRoots else { return }
        let previous = selectedRoot
        projectRoots = nextRoots
        selectedRoot = nextRoots.first(where: { $0 == previous }) ?? nextRoots.first
        clearData()
    }

    public func selectRoot(_ root: URL) {
        guard projectRoots.contains(root) else { return }
        selectedRoot = root
        clearData()
    }

    public func refresh() async {
        clearErrors()
        guard let root = selectedRoot else {
            clearData()
            emptyStateMessage = "Add a project folder to this workspace to load GitHub details."
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let auth = try await run(["auth", "status"])
            guard auth.exitCode == 0 else {
                clearData()
                emptyStateMessage = "GitHub panel requires GitHub CLI authentication (`gh auth login`)."
                return
            }

            let repoResponse = try await run(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], in: root)
            guard repoResponse.exitCode == 0 else {
                clearData()
                emptyStateMessage = unavailableMessage(from: repoResponse.stderr)
                return
            }
            repositoryName = repoResponse.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            let statusResponse = try await run(["pr", "status", "--json", "number,title,headRefName,url,statusCheckRollup,updatedAt"], in: root)
            if statusResponse.exitCode == 0 {
                applyStatusJSON(statusResponse.stdout)
            } else {
                openPullRequests = []
                currentBranch = "Unknown"
                checkStatus = "No checks found"
            }

            let issuesResponse = try await run(["issue", "list", "--state", "open", "--limit", "8", "--json", "number,title,url,updatedAt"], in: root)
            if issuesResponse.exitCode == 0 {
                recentIssues = decodeIssues(issuesResponse.stdout)
            } else {
                recentIssues = []
            }

            if repositoryName.isEmpty {
                emptyStateMessage = "No GitHub repository is configured for this workspace folder."
            } else {
                emptyStateMessage = nil
            }
        } catch let error as GitHubRunnerError {
            clearData()
            switch error {
            case .timeout:
                emptyStateMessage = "GitHub CLI timed out. Try again."
            case .couldNotStart:
                emptyStateMessage = "GitHub CLI is not available. Install `gh` and authenticate with `gh auth login`."
            }
        } catch {
            clearData()
            errorMessage = error.localizedDescription
        }
    }

    private func run(_ arguments: [String], in directory: URL? = nil) async throws -> GitHubCommandResult {
        try await runner.run(arguments: arguments, workingDirectory: directory, timeout: timeout, maxOutputBytes: maxOutputBytes)
    }

    private func clearData() {
        repositoryName = ""
        currentBranch = "Unknown"
        openPullRequests = []
        recentIssues = []
        checkStatus = "No checks found"
    }

    private func clearErrors() {
        errorMessage = nil
        emptyStateMessage = nil
    }

    private func unavailableMessage(from stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("not logged in") || lower.contains("authenticate") {
            return "GitHub panel requires GitHub CLI authentication (`gh auth login`)."
        }
        if lower.contains("not a git repository") {
            return "The selected folder is not a Git repository."
        }
        return "GitHub CLI could not load repository details for this folder."
    }

    private func applyStatusJSON(_ raw: String) {
        struct StatusResponse: Decodable {
            struct PullRequest: Decodable {
                struct CheckRollup: Decodable {
                    let conclusion: String?
                    let status: String?
                }
                let number: Int
                let title: String
                let headRefName: String
                let url: URL
                let updatedAt: Date?
                let statusCheckRollup: [CheckRollup]?
            }
            let currentBranch: [PullRequest]?
            let createdBy: [PullRequest]?
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = raw.data(using: .utf8),
              let status = try? decoder.decode(StatusResponse.self, from: data)
        else {
            openPullRequests = []
            currentBranch = "Unknown"
            checkStatus = "No checks found"
            return
        }

        if let branchPR = status.currentBranch?.first {
            currentBranch = branchPR.headRefName
            checkStatus = checksSummary(for: (branchPR.statusCheckRollup ?? []).map { ($0.conclusion, $0.status) })
        } else {
            currentBranch = "Unknown"
            checkStatus = "No pull request on current branch"
        }

        openPullRequests = (status.createdBy ?? []).prefix(8).map { pr in
            GitHubPRSummary(
                id: pr.number,
                number: pr.number,
                title: pr.title,
                branch: pr.headRefName,
                url: pr.url,
                checksSummary: checksSummary(for: (pr.statusCheckRollup ?? []).map { ($0.conclusion, $0.status) }),
                updatedAt: pr.updatedAt
            )
        }
    }

    private func checksSummary(for checks: [(String?, String?)]) -> String {
        if checks.isEmpty { return "No checks found" }
        var failed = 0
        var passed = 0
        var pending = 0
        for check in checks {
            let conclusion = check.0
            let status = check.1
            if conclusion == "FAILURE" { failed += 1 }
            else if conclusion == "SUCCESS" { passed += 1 }
            else if status == "IN_PROGRESS" || status == "QUEUED" || conclusion == nil { pending += 1 }
        }
        if failed > 0 { return "\(failed) failing · \(passed) passing · \(pending) pending" }
        if pending > 0 { return "\(passed) passing · \(pending) pending" }
        return "\(passed) passing"
    }

    private func decodeIssues(_ raw: String) -> [GitHubIssueSummary] {
        struct IssueDTO: Decodable {
            let number: Int
            let title: String
            let url: URL
            let updatedAt: Date?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = raw.data(using: .utf8),
              let issues = try? decoder.decode([IssueDTO].self, from: data)
        else { return [] }
        return issues.map { issue in
            GitHubIssueSummary(id: issue.number, number: issue.number, title: issue.title, url: issue.url, updatedAt: issue.updatedAt)
        }
    }
}

public struct GitHubPanel: View {
    @Bindable private var model: GitHubPanelModel

    public init(model: GitHubPanelModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            PanelSection("Repo") {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(DS.Color.accentInk)
                    Text(model.repositoryName.isEmpty ? "Repo ikke lastet" : model.repositoryName)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if model.isLoading { ProgressView().controlSize(.small) }
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Oppdater", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.lbGhost)
                }
                if model.projectRoots.count > 1 {
                    FormField("Prosjektmappe") {
                        Picker("Prosjektmappe", selection: Binding(
                            get: { model.selectedRoot },
                            set: { root in
                                if let root {
                                    model.selectRoot(root)
                                    Task { await model.refresh() }
                                }
                            }
                        )) {
                            ForEach(model.projectRoots, id: \.path) { root in
                                Text(root.lastPathComponent).tag(Optional(root))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                if model.emptyStateMessage == nil {
                    HStack(spacing: DS.Space.xs) {
                        Label(model.currentBranch, systemImage: "arrow.triangle.branch")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryInk)
                            .lineLimit(1)
                        Spacer()
                        StatusPill(kind: ciKind, label: "CI: \(model.checkStatus)")
                    }
                }
            }

            if let message = model.emptyStateMessage {
                EmptyStateView(symbol: "tray", title: "GitHub er ikke tilgjengelig", message: message, identifier: "github.unavailable")
            } else {
                PanelSection("Åpne pull requests") {
                    if model.openPullRequests.isEmpty {
                        emptyLine("Ingen åpne pull requests.")
                    } else {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            ForEach(model.openPullRequests) { pr in
                                Link(destination: pr.url) {
                                    PanelRow {
                                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                            Text("#\(pr.number)  \(pr.title)")
                                                .font(DS.Font.bodyEmphasis)
                                                .foregroundStyle(DS.Color.ink)
                                                .lineLimit(2)
                                            Text("\(pr.branch) · \(pr.checksSummary)")
                                                .font(DS.Font.caption)
                                                .foregroundStyle(DS.Color.secondaryInk)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .help(pr.url.absoluteString)
                            }
                        }
                    }
                }

                PanelSection("Siste issues") {
                    if model.recentIssues.isEmpty {
                        emptyLine("Ingen nye issues.")
                    } else {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            ForEach(model.recentIssues) { issue in
                                Link(destination: issue.url) {
                                    PanelRow {
                                        HStack(spacing: DS.Space.xs) {
                                            Text("#\(issue.number)")
                                                .font(DS.Font.mono)
                                                .foregroundStyle(DS.Color.mutedInk)
                                            Text(issue.title)
                                                .font(DS.Font.body)
                                                .foregroundStyle(DS.Color.ink)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .help(issue.url.absoluteString)
                            }
                        }
                    }
                }
            }

            if let error = model.errorMessage {
                FormStatus(error, tone: .error)
            }
            PanelFootnote("Kun lesing · bruker lokal gh · lagrer ingen token")
        }
        .padding(DS.Space.sm)
        }
        .task { await model.refresh() }
    }

    private var ciKind: StatusKind {
        let status = model.checkStatus.lowercased()
        if status.contains("fail") || status.contains("error") { return .error }
        if status.contains("pend") || status.contains("progress") || status.contains("running") { return .running }
        if status.contains("pass") || status.contains("success") || status.contains("ok") { return .done }
        return .stopped
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.mutedInk)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
