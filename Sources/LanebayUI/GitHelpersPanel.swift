import AppKit
import Foundation
import LanebayCore
import SwiftUI
import Darwin

public struct GitCommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}

public protocol GitCommandRunning: Sendable {
    func run(arguments: [String], workingDirectory: URL?, timeout: Duration, maxOutputBytes: Int) async throws -> GitCommandResult
}

public enum GitRunnerError: LocalizedError {
    case timeout
    case couldNotStart(String)

    public var errorDescription: String? {
        switch self {
        case .timeout: "The git command timed out."
        case .couldNotStart(let reason): "Could not start git: \(reason)"
        }
    }
}

public struct GitCLIRunner: GitCommandRunning {
    private let executableCandidates: [URL]
    private let killGracePeriod: Duration

    public init(
        executableCandidates: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin/git"),
            URL(fileURLWithPath: "/usr/local/bin/git"),
            URL(fileURLWithPath: "/usr/bin/git"),
        ],
        killGracePeriod: Duration = .milliseconds(300)
    ) {
        self.executableCandidates = executableCandidates
        self.killGracePeriod = killGracePeriod
    }

    public func run(arguments: [String], workingDirectory: URL?, timeout: Duration, maxOutputBytes: Int) async throws -> GitCommandResult {
        guard let executableURL = resolveExecutable() else {
            throw GitRunnerError.couldNotStart("git executable not found in known locations")
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = GitOutputCollector(maxBytes: maxOutputBytes)
        let stderrCollector = GitOutputCollector(maxBytes: maxOutputBytes)
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
            throw GitRunnerError.couldNotStart(error.localizedDescription)
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    await waitForExit(process)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    await terminateWithEscalation(process, gracePeriod: killGracePeriod)
                    throw GitRunnerError.timeout
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

        return GitCommandResult(
            exitCode: process.terminationStatus,
            stdout: stdoutCollector.string,
            stderr: stderrCollector.string
        )
    }

    private func resolveExecutable() -> URL? {
        let manager = FileManager.default
        for candidate in executableCandidates {
            guard manager.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate
        }
        return nil
    }

    private func waitForExit(_ process: Process) async {
        if !process.isRunning { return }
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
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

public struct GitDraftTarget: Identifiable, Equatable {
    public let id: UUID
    public let title: String
}

private final class GitOutputCollector: @unchecked Sendable {
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

@MainActor
@Observable
public final class GitHelpersPanelModel {
    public private(set) var projectRoots: [URL]
    public private(set) var selectedRoot: URL?
    public private(set) var draftTargets: [GitDraftTarget]
    public var selectedDraftTargetID: UUID?

    public var cloneURL = ""
    public var cloneParentDirectory: URL?
    public var cloneFolderName = ""
    public private(set) var cloneStatusMessage: String?
    public private(set) var cloneErrorMessage: String?
    public private(set) var isCloning = false

    public private(set) var stagedDiffSummary = ""
    public var commitMessageDraft = ""
    public private(set) var commitStatusMessage: String?
    public private(set) var commitErrorMessage: String?
    public private(set) var isRefreshingSummary = false
    public private(set) var isCommitting = false
    public var awaitingCommitApproval = false

    private let runner: GitCommandRunning
    private let timeout: Duration
    private let maxOutputBytes: Int
    private let openWorkspace: @MainActor @Sendable (URL) -> Void
    private let sendDraftPrompt: @MainActor @Sendable (UUID, String) -> Bool

    public init(
        workspace: Workspace?,
        draftTargets: [GitDraftTarget] = [],
        runner: GitCommandRunning = GitCLIRunner(),
        timeout: Duration = .seconds(8),
        maxOutputBytes: Int = 131_072,
        openWorkspace: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
        sendDraftPrompt: @escaping @MainActor @Sendable (UUID, String) -> Bool = { _, _ in false }
    ) {
        self.runner = runner
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.openWorkspace = openWorkspace
        self.sendDraftPrompt = sendDraftPrompt
        var seen = Set<String>()
        let roots = (workspace?.repos ?? []).sorted { $0.path < $1.path }
            .filter { seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
        self.projectRoots = roots
        self.draftTargets = draftTargets
        self.selectedRoot = roots.first
        self.selectedDraftTargetID = draftTargets.first?.id
    }

    public func update(workspace: Workspace?, draftTargets: [GitDraftTarget]) {
        var seen = Set<String>()
        let nextRoots = (workspace?.repos ?? []).sorted { $0.path < $1.path }
            .filter { seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
        if nextRoots != projectRoots {
            let previous = selectedRoot
            projectRoots = nextRoots
            selectedRoot = nextRoots.first(where: { $0 == previous }) ?? nextRoots.first
            stagedDiffSummary = ""
        }
        self.draftTargets = draftTargets
        if let selectedDraftTargetID, draftTargets.contains(where: { $0.id == selectedDraftTargetID }) {
            self.selectedDraftTargetID = selectedDraftTargetID
        } else {
            self.selectedDraftTargetID = draftTargets.first?.id
        }
    }

    public func selectRoot(_ root: URL) {
        guard projectRoots.contains(root) else { return }
        selectedRoot = root
        stagedDiffSummary = ""
        commitStatusMessage = nil
        commitErrorMessage = nil
    }

    public func chooseCloneParentDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        if panel.runModal() == .OK {
            cloneParentDirectory = panel.url
        }
    }

    public func refreshStagedDiffSummary() async {
        commitStatusMessage = nil
        commitErrorMessage = nil
        guard let root = selectedRoot else {
            stagedDiffSummary = ""
            commitErrorMessage = "Select a repository folder in this workspace first."
            return
        }
        isRefreshingSummary = true
        defer { isRefreshingSummary = false }
        do {
            let response = try await run(["diff", "--staged", "--stat", "--summary"], in: root)
            if response.exitCode != 0 {
                stagedDiffSummary = ""
                commitErrorMessage = displayError(from: response.stderr, fallback: "Could not load staged diff summary.")
                return
            }
            let summary = response.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            stagedDiffSummary = summary.isEmpty ? "No staged changes found." : summary
        } catch let error as GitRunnerError {
            stagedDiffSummary = ""
            commitErrorMessage = error.localizedDescription
        } catch {
            stagedDiffSummary = ""
            commitErrorMessage = error.localizedDescription
        }
    }

    public func sendDraftRequestToSelectedConsole() {
        commitStatusMessage = nil
        commitErrorMessage = nil
        guard let root = selectedRoot else {
            commitErrorMessage = "Select a repository folder before requesting a draft."
            return
        }
        guard let targetID = selectedDraftTargetID else {
            commitErrorMessage = "Select a running console to request a draft."
            return
        }
        let summary = stagedDiffSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        Draft a concise git commit message for this staged diff.
        Use conventional style when appropriate.
        Respond with only the commit message text.

        Repo: \(root.path)
        Staged diff summary:
        \(summary.isEmpty ? "(empty)" : summary)
        """
        if sendDraftPrompt(targetID, prompt) {
            commitStatusMessage = "Draft request sent to selected console."
        } else {
            commitErrorMessage = "Could not send draft request. Ensure the selected console is running and idle."
        }
    }

    public func cloneRepository() async {
        cloneStatusMessage = nil
        cloneErrorMessage = nil
        guard let parent = cloneParentDirectory else {
            cloneErrorMessage = "Choose a parent directory for the clone destination."
            return
        }
        let trimmedURL = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let validatedURL = try Self.validateRemoteURL(trimmedURL)
            let destination = try validatedCloneDestination(parent: parent, remote: validatedURL, folderName: cloneFolderName)
            isCloning = true
            defer { isCloning = false }
            let response = try await run(["clone", validatedURL, destination.path])
            guard response.exitCode == 0 else {
                cloneErrorMessage = displayError(from: response.stderr, fallback: "git clone failed.")
                return
            }
            openWorkspace(destination)
            cloneStatusMessage = "Cloned into \(destination.path) and opened as a workspace."
        } catch {
            cloneErrorMessage = error.localizedDescription
        }
    }

    public func requestCommitApproval() {
        commitStatusMessage = nil
        commitErrorMessage = nil
        guard selectedRoot != nil else {
            commitErrorMessage = "Select a repository folder before committing."
            return
        }
        let message = commitMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            commitErrorMessage = "Draft or write a commit message before committing."
            return
        }
        awaitingCommitApproval = true
    }

    public func commitAfterApproval() async {
        awaitingCommitApproval = false
        commitStatusMessage = nil
        commitErrorMessage = nil
        guard let root = selectedRoot else {
            commitErrorMessage = "Select a repository folder before committing."
            return
        }
        let message = commitMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            commitErrorMessage = "Commit message cannot be empty."
            return
        }
        isCommitting = true
        defer { isCommitting = false }
        do {
            let response = try await run(["commit", "-m", message], in: root)
            if response.exitCode == 0 {
                await refreshStagedDiffSummary()
                commitStatusMessage = "Commit created locally. No push was performed."
            } else {
                commitErrorMessage = displayError(from: response.stderr, fallback: "git commit failed.")
            }
        } catch {
            commitErrorMessage = error.localizedDescription
        }
    }

    private func run(_ arguments: [String], in directory: URL? = nil) async throws -> GitCommandResult {
        try await runner.run(arguments: arguments, workingDirectory: directory, timeout: timeout, maxOutputBytes: maxOutputBytes)
    }

    private func validatedCloneDestination(parent: URL, remote: String, folderName: String) throws -> URL {
        let fm = FileManager.default
        let standardizedParent = parent.standardizedFileURL.resolvingSymlinksInPath()
        let suggestedName = Self.defaultDirectoryName(for: remote)
        let requested = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = requested.isEmpty ? suggestedName : requested
        guard !finalName.isEmpty, finalName != ".", finalName != "..", !finalName.contains("/") else {
            throw ValidationError.invalidDestinationName
        }
        let destination = standardizedParent.appendingPathComponent(finalName, isDirectory: true).standardizedFileURL
        guard destination.path.hasPrefix(standardizedParent.path + "/") else {
            throw ValidationError.destinationOutsideParent
        }
        guard !fm.fileExists(atPath: destination.path) else {
            throw ValidationError.destinationExists
        }
        return destination
    }

    private func displayError(from stderr: String, fallback: String) -> String {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? fallback : message
    }

    private enum ValidationError: LocalizedError {
        case invalidRemoteURL
        case invalidDestinationName
        case destinationOutsideParent
        case destinationExists

        var errorDescription: String? {
            switch self {
            case .invalidRemoteURL:
                "Only https://, ssh://, and git@ remote URLs are allowed. Local/file/ext transport is blocked."
            case .invalidDestinationName:
                "Destination folder name is invalid."
            case .destinationOutsideParent:
                "Clone destination must stay inside the chosen parent directory."
            case .destinationExists:
                "Destination folder already exists."
            }
        }
    }

    static func validateRemoteURL(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.invalidRemoteURL }
        let lower = trimmed.lowercased()
        guard !trimmed.hasPrefix("-"),
              !lower.contains("ext::"),
              !lower.contains("file::"),
              !lower.hasPrefix("file://")
        else {
            throw ValidationError.invalidRemoteURL
        }
        if lower.hasPrefix("https://") || lower.hasPrefix("ssh://") {
            guard let components = URLComponents(string: trimmed),
                  let host = components.host,
                  !host.hasPrefix("-") else {
                throw ValidationError.invalidRemoteURL
            }
            return trimmed
        }
        if trimmed.hasPrefix("git@"), trimmed.contains(":") {
            let host = String(trimmed.dropFirst(4).split(separator: ":", maxSplits: 1).first ?? "")
            guard !host.isEmpty, !host.hasPrefix("-") else {
                throw ValidationError.invalidRemoteURL
            }
            return trimmed
        }
        throw ValidationError.invalidRemoteURL
    }

    static func defaultDirectoryName(for remote: String) -> String {
        var candidate = remote
        if let slash = candidate.lastIndex(of: "/") {
            candidate = String(candidate[candidate.index(after: slash)...])
        } else if let colon = candidate.lastIndex(of: ":") {
            candidate = String(candidate[candidate.index(after: colon)...])
        }
        if candidate.hasSuffix(".git") {
            candidate.removeLast(4)
        }
        let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "repository" : cleaned
    }
}

public struct GitHelpersPanel: View {
    @Bindable private var model: GitHelpersPanelModel

    public init(model: GitHelpersPanelModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                GroupBox("Clone repository") {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        TextField("Repository URL (https:// / ssh:// / git@...)", text: $model.cloneURL)
                        HStack {
                            Text(model.cloneParentDirectory?.path ?? "No parent directory selected")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.secondaryInk)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Choose parent…") { model.chooseCloneParentDirectory() }
                        }
                        TextField("Destination folder name (optional)", text: $model.cloneFolderName)
                        Button("Clone and open workspace") {
                            Task { await model.cloneRepository() }
                        }
                        .disabled(model.isCloning)
                    }
                }

                GroupBox("Commit message with approval") {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        if model.projectRoots.count > 1 {
                            Picker("Repository folder", selection: Binding(
                                get: { model.selectedRoot },
                                set: { root in if let root { model.selectRoot(root) } }
                            )) {
                                ForEach(model.projectRoots, id: \.path) { root in
                                    Text(root.lastPathComponent).tag(Optional(root))
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        HStack {
                            if model.isRefreshingSummary { ProgressView().controlSize(.small) }
                            Button("Refresh staged diff summary") {
                                Task { await model.refreshStagedDiffSummary() }
                            }
                        }
                        Text(model.stagedDiffSummary.isEmpty ? "No summary loaded yet." : model.stagedDiffSummary)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(Palette.secondaryInk)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !model.draftTargets.isEmpty {
                            Picker("Draft with console", selection: Binding(
                                get: { model.selectedDraftTargetID },
                                set: { model.selectedDraftTargetID = $0 }
                            )) {
                                ForEach(model.draftTargets) { target in
                                    Text(target.title).tag(Optional(target.id))
                                }
                            }
                            .pickerStyle(.menu)
                            Button("Ask selected console to draft") { model.sendDraftRequestToSelectedConsole() }
                        }

                        TextEditor(text: $model.commitMessageDraft)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .frame(minHeight: 88)
                            .overlay(RoundedRectangle(cornerRadius: Spacing.radiusSmall).stroke(Palette.border))

                        HStack {
                            if model.isCommitting { ProgressView().controlSize(.small) }
                            Button("Approve and commit staged changes") {
                                model.requestCommitApproval()
                            }
                            .disabled(model.isCommitting)
                        }
                    }
                }

                if let message = model.cloneStatusMessage ?? model.commitStatusMessage {
                    Text(message).font(Typography.caption).foregroundStyle(Palette.accent)
                }
                if let error = model.cloneErrorMessage ?? model.commitErrorMessage {
                    Text(error).font(Typography.caption).foregroundStyle(Palette.status(.error)).textSelection(.enabled)
                }
                Text("Never auto-commit. Never push. Commit only happens after explicit approval.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.mutedInk)
            }
            .padding(Spacing.sm)
        }
        .alert("Approve git commit", isPresented: $model.awaitingCommitApproval) {
            Button("Cancel", role: .cancel) {}
            Button("Commit") { Task { await model.commitAfterApproval() } }
        } message: {
            Text("This commits staged changes in the selected repository. No push will be performed.")
        }
    }
}
