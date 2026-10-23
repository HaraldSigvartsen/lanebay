import XCTest
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import LanebayCore
@testable import LanebayUI

private struct FakeGitHubRunner: GitHubCommandRunning {
    let responses: [String: GitHubCommandResult]

    func run(arguments: [String], workingDirectory: URL?, timeout: Duration, maxOutputBytes: Int) async throws -> GitHubCommandResult {
        responses[arguments.joined(separator: " ")] ?? GitHubCommandResult(exitCode: 1, stdout: "", stderr: "missing fake response")
    }
}

private actor FakeGitRunnerStore {
    var invocations: [[String]] = []
    func record(_ arguments: [String]) { invocations.append(arguments) }
    func all() -> [[String]] { invocations }
}

private struct FakeGitRunner: GitCommandRunning {
    let responses: [String: GitCommandResult]
    let store: FakeGitRunnerStore

    func run(arguments: [String], workingDirectory: URL?, timeout: Duration, maxOutputBytes: Int) async throws -> GitCommandResult {
        await store.record(arguments)
        return responses[arguments.joined(separator: " ")] ?? GitCommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private actor FakePlannerRunnerStore {
    var calls: [(String, [String])] = []
    func record(executable: String, arguments: [String]) { calls.append((executable, arguments)) }
    func all() -> [(String, [String])] { calls }
}

private struct FakePlannerRunner: PlannerProcessRunning {
    let responses: [String: PlannerCommandResult]
    let store: FakePlannerRunnerStore

    func run(executable: URL, arguments: [String], workingDirectory: URL?, timeout: Duration, maxOutputBytes: Int) async throws -> PlannerCommandResult {
        await store.record(executable: executable.lastPathComponent, arguments: arguments)
        let fullKey = ([executable.lastPathComponent] + arguments).joined(separator: " ")
        if let exact = responses[fullKey] { return exact }
        let executableKey = executable.lastPathComponent
        if let byExecutable = responses[executableKey] { return byExecutable }
        if let first = arguments.first, let byFirstArg = responses["\(executableKey) \(first)"] { return byFirstArg }
        return PlannerCommandResult(exitCode: 1, stdout: "", stderr: "missing fake planner response")
    }
}

private struct FakePlannerKeychainReader: PlannerAPIKeyReading {
    let value: String
    func readPlannerAPIKey() throws -> String { value }
}

@MainActor
private final class FakeVoiceRecognizer: PushToTalkRecognizing {
    var isRecording = false
    var transcriptToReturn = ""
    var startError: Error?
    var stopError: Error?
    var startCalls = 0
    var stopCalls = 0

    func startRecognition() async throws {
        startCalls += 1
        if let startError { throw startError }
        isRecording = true
    }

    func stopRecognition() async throws -> String {
        stopCalls += 1
        if let stopError { throw stopError }
        isRecording = false
        return transcriptToReturn
    }
}

@MainActor
final class LanebayUITests: XCTestCase {
    func testVoiceCommandModelAddsTranscriptOnlyAfterRelease() async {
        let recognizer = FakeVoiceRecognizer()
        recognizer.transcriptToReturn = "run tests"
        let model = VoiceCommandModel(recognizer: recognizer)

        await model.setPressed(true)
        XCTAssertTrue(model.isRecording)
        XCTAssertEqual(recognizer.startCalls, 1)
        XCTAssertNil(model.latestTranscript)

        await model.setPressed(false)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(recognizer.stopCalls, 1)
        XCTAssertEqual(model.consumeTranscript(), "run tests")
        XCTAssertTrue((model.statusMessage ?? "").contains("ready"))
    }

    func testVoiceCommandModelSurfacesOnDeviceErrorsAndDoesNotAutoSend() async {
        let recognizer = FakeVoiceRecognizer()
        recognizer.startError = VoiceRecognitionError.onDeviceRecognitionUnavailable
        let model = VoiceCommandModel(recognizer: recognizer)
        await model.begin()
        XCTAssertFalse(model.isRecording)
        XCTAssertNil(model.latestTranscript)
        XCTAssertTrue((model.errorMessage ?? "").contains("On-device"))
    }

    func testGitHubPanelShowsAuthenticationEmptyStateWhenGhIsUnavailableOrUnauthenticated() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Test", repos: [root])
        let model = GitHubPanelModel(
            workspace: workspace,
            runner: FakeGitHubRunner(
                responses: [
                    "auth status": GitHubCommandResult(exitCode: 1, stdout: "", stderr: "not logged in")
                ]
            )
        )

        await model.refresh()

        XCTAssertTrue((model.emptyStateMessage ?? "").contains("auth"), "Missing auth should present a clear empty state")
        XCTAssertTrue(model.repositoryName.isEmpty)
        XCTAssertEqual(model.currentBranch, "Unknown")
    }

    func testGitHubPanelParsesBranchPullRequestsIssuesAndChecksFromGhJSON() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Test", repos: [root])
        let statusJSON = """
        {
          "currentBranch": [
            {
              "number": 12,
              "title": "Feature branch PR",
              "headRefName": "feature/github-panel",
              "url": "https://github.com/acme/lanebay/pull/12",
              "updatedAt": "2026-10-21T04:00:00Z",
              "statusCheckRollup": [
                { "conclusion": "SUCCESS", "status": "COMPLETED" },
                { "conclusion": null, "status": "IN_PROGRESS" }
              ]
            }
          ],
          "createdBy": [
            {
              "number": 12,
              "title": "Feature branch PR",
              "headRefName": "feature/github-panel",
              "url": "https://github.com/acme/lanebay/pull/12",
              "updatedAt": "2026-10-21T04:00:00Z",
              "statusCheckRollup": [{ "conclusion": "SUCCESS", "status": "COMPLETED" }]
            }
          ]
        }
        """
        let issuesJSON = """
        [
          { "number": 101, "title": "Fix timeout handling", "url": "https://github.com/acme/lanebay/issues/101", "updatedAt": "2026-10-20T12:00:00Z" }
        ]
        """
        let model = GitHubPanelModel(
            workspace: workspace,
            runner: FakeGitHubRunner(
                responses: [
                    "auth status": GitHubCommandResult(exitCode: 0, stdout: "ok", stderr: ""),
                    "repo view --json nameWithOwner --jq .nameWithOwner": GitHubCommandResult(exitCode: 0, stdout: "acme/lanebay\n", stderr: ""),
                    "pr status --json number,title,headRefName,url,statusCheckRollup,updatedAt": GitHubCommandResult(exitCode: 0, stdout: statusJSON, stderr: ""),
                    "issue list --state open --limit 8 --json number,title,url,updatedAt": GitHubCommandResult(exitCode: 0, stdout: issuesJSON, stderr: ""),
                ]
            )
        )

        await model.refresh()

        XCTAssertEqual(model.repositoryName, "acme/lanebay")
        XCTAssertEqual(model.currentBranch, "feature/github-panel")
        XCTAssertEqual(model.openPullRequests.count, 1)
        XCTAssertEqual(model.openPullRequests.first?.number, 12)
        XCTAssertEqual(model.recentIssues.count, 1)
        XCTAssertTrue(model.checkStatus.contains("passing"))
        XCTAssertNil(model.emptyStateMessage)
    }

    func testUsagePanelModelLoadsWorkspaceDayAggregatesFromInjectedStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = UsageWorkspaceDaySummary(workspaceID: UUID(), workspaceName: "Workspace")
        try UsageStatsStore(rootURL: root).save(
            UsageStatsDocument(days: [UsageDaySummary(day: "2026-10-21", workspaces: [workspace])])
        )
        let model = UsagePanelModel(store: UsageStatsStore(rootURL: root), homeRoot: root)
        let loaded = expectation(description: "usage model refresh")
        Task {
            await model.refresh()
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 2)
        XCTAssertEqual(model.days.count, 1)
        XCTAssertEqual(model.days.first?.workspaces.first?.workspaceName, "Workspace")
        XCTAssertNil(model.errorMessage)
    }

    func testUsagePanelModelOptionallyReadsInjectedLocalLogsOnlyWhenPresent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = UsagePanelModel(store: UsageStatsStore(rootURL: root.appendingPathComponent("app-support")), homeRoot: root)
        XCTAssertNil(model.optionalLogSnapshot)
        let logs = root.appendingPathComponent(".claude/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("usage.jsonl")
        let line = #"{"status":"needs-you","durationSeconds":5,"dispatchedPrompts":1,"loopIterations":2}"#
        try Data((line + "\n").utf8).write(to: file)
        let loaded = expectation(description: "usage snapshot refresh")
        Task {
            await model.refresh()
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 2)
        XCTAssertEqual(model.optionalLogSnapshot?.statusDuration.waitingForInput, 5)
        XCTAssertEqual(model.optionalLogSnapshot?.dispatchedPrompts, 1)
        XCTAssertEqual(model.optionalLogSnapshot?.loopIterations, 2)
    }

    func testGitHubCLIRunnerUsesInjectedExecutableAndCollectsOutputWithoutRealGh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("gh")
        let script = """
        #!/bin/sh
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          echo "AUTH_OK"
          exit 0
        fi
        echo "ARGS:$*"
        echo "ERR:$*" 1>&2
        exit 3
        """
        try Data(script.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)

        let runner = GitHubCLIRunner(executableCandidates: [fake])
        let auth = try await runner.run(arguments: ["auth", "status"], workingDirectory: root, timeout: .seconds(2), maxOutputBytes: 8_192)
        XCTAssertEqual(auth.exitCode, 0)
        XCTAssertTrue(auth.stdout.contains("AUTH_OK"))

        let failed = try await runner.run(arguments: ["repo", "view"], workingDirectory: root, timeout: .seconds(2), maxOutputBytes: 8_192)
        XCTAssertEqual(failed.exitCode, 3)
        XCTAssertTrue(failed.stdout.contains("ARGS:repo view"))
        XCTAssertTrue(failed.stderr.contains("ERR:repo view"))
    }

    func testGitHelpersRemoteValidationAllowsOnlyExpectedSchemes() throws {
        XCTAssertNoThrow(try GitHelpersPanelModel.validateRemoteURL("https://github.com/acme/repo.git"))
        XCTAssertNoThrow(try GitHelpersPanelModel.validateRemoteURL("ssh://git@github.com/acme/repo.git"))
        XCTAssertNoThrow(try GitHelpersPanelModel.validateRemoteURL("git@github.com:acme/repo.git"))
        XCTAssertThrowsError(try GitHelpersPanelModel.validateRemoteURL("-c core.sshCommand=evil"))
        XCTAssertThrowsError(try GitHelpersPanelModel.validateRemoteURL("ssh://-oProxyCommand=evil/repo.git"))
        XCTAssertThrowsError(try GitHelpersPanelModel.validateRemoteURL("git@-oProxyCommand=evil:acme/repo.git"))
        XCTAssertThrowsError(try GitHelpersPanelModel.validateRemoteURL("file:///tmp/repo"))
        XCTAssertThrowsError(try GitHelpersPanelModel.validateRemoteURL("ext::sh -c whoami"))
    }

    func testGitHelpersCloneUsesFakeRunnerAndOpensWorkspaceInsideChosenParent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let store = FakeGitRunnerStore()
        var opened: URL?
        let model = GitHelpersPanelModel(
            workspace: nil,
            runner: FakeGitRunner(
                responses: ["clone https://github.com/acme/lanebay.git \(parent.appendingPathComponent("lanebay").path)": GitCommandResult(exitCode: 0, stdout: "", stderr: "")],
                store: store
            ),
            openWorkspace: { opened = $0 }
        )
        model.cloneURL = "https://github.com/acme/lanebay.git"
        model.cloneParentDirectory = parent
        await model.cloneRepository()

        let calls = await store.all()
        XCTAssertEqual(calls.first, ["clone", "https://github.com/acme/lanebay.git", parent.appendingPathComponent("lanebay").path])
        XCTAssertEqual(opened?.standardizedFileURL.path, parent.appendingPathComponent("lanebay").standardizedFileURL.path)
        XCTAssertTrue((model.cloneStatusMessage ?? "").contains("opened as a workspace"))
    }

    func testGitHelpersCommitRunsOnlyAfterExplicitApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = FakeGitRunnerStore()
        let model = GitHelpersPanelModel(
            workspace: Workspace(name: "Test", repos: [root]),
            runner: FakeGitRunner(
                responses: [
                    "commit -m chore: update docs": GitCommandResult(exitCode: 0, stdout: "[main abc123] chore: update docs\n", stderr: ""),
                    "diff --staged --stat --summary": GitCommandResult(exitCode: 0, stdout: "", stderr: ""),
                ],
                store: store
            )
        )
        model.commitMessageDraft = "chore: update docs"
        model.requestCommitApproval()
        XCTAssertTrue(model.awaitingCommitApproval)
        let beforeCalls = await store.all()
        XCTAssertTrue(beforeCalls.isEmpty)

        await model.commitAfterApproval()
        let calls = await store.all()
        XCTAssertEqual(calls.first, ["commit", "-m", "chore: update docs"])
        XCTAssertEqual(calls.last, ["diff", "--staged", "--stat", "--summary"])
        XCTAssertTrue((model.commitStatusMessage ?? "").contains("No push"))
    }

    func testChatTranscriptPersistsPerWorkspaceAndBoundsHistoryAndMessageSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatTranscriptStore(rootURL: root)
        let first = UUID(), second = UUID()
        let model = ChatPanelModel(workspaceID: first, store: store)
        XCTAssertFalse(model.send(text: "blocked", targetName: "Console", dispatch: { false }, reply: nil))
        for index in 0..<205 {
            XCTAssertTrue(model.send(text: "message \(index)", targetName: "Console", dispatch: { true }, reply: nil))
        }
        XCTAssertEqual(model.messages.count, ChatTranscriptStore.maxMessages)
        model.setWorkspace(second)
        XCTAssertTrue(model.messages.isEmpty)
        model.setWorkspace(first)
        XCTAssertEqual(model.messages.count, ChatTranscriptStore.maxMessages)
        XCTAssertEqual(model.messages.first?.text, "message 5")
        XCTAssertLessThanOrEqual(model.messages.last!.text.utf8.count, ChatTranscriptStore.maxMessageBytes)
    }

    func testChatTranscriptStoreRejectsOversizedFilesAndUsesPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatTranscriptStore(rootURL: root)
        let workspaceID = UUID()
        try store.save([ChatMessage(kind: .sent, target: "Console", text: "ok")], workspaceID: workspaceID)
        let file = root.appendingPathComponent("\(workspaceID.uuidString).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try Data(repeating: 0x61, count: ChatTranscriptStore.maxFileBytes + 1).write(to: file, options: .atomic)
        XCTAssertThrowsError(try store.load(workspaceID: workspaceID)) { error in
            XCTAssertTrue(error.localizedDescription.contains("too large"))
        }
    }

    func testPresetsPanelModelCreatesEditsDeletesAndPersistsWithPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PresetsStore(rootURL: root)
        let model = PresetsPanelModel(store: store)
        model.name = "Review"
        model.text = "Review this diff"
        model.targetAgentKind = "claude"
        XCTAssertTrue(model.save())
        let saved = try XCTUnwrap(model.presets.first)
        XCTAssertEqual(saved.targetAgentKind, "claude")
        XCTAssertEqual(try store.load(), [saved])
        let file = root.appendingPathComponent("presets.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        model.select(saved)
        model.text = "Review the staged diff"
        XCTAssertTrue(model.save())
        XCTAssertEqual(try store.load().first?.text, "Review the staged diff")
        model.deleteSelected()
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testPresetsPanelModelShowsVisibleErrorForOversizedPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PresetsPanelModel(store: PresetsStore(rootURL: root))
        model.name = "Huge"
        model.text = String(repeating: "a", count: PresetsStore.maximumTextBytes + 1)
        XCTAssertFalse(model.save())
        XCTAssertEqual(model.presets.count, 0)
        XCTAssertTrue((model.errorMessage ?? "").contains("too long"))
    }

    func testPresetPanelSendActionUsesCallbackAndOptionalTarget() {
        var received: (String, String?)?
        let view = PresetsPanel(model: PresetsPanelModel(store: PresetsStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))), agentKinds: ["claude"]) {
            received = ($0, $1)
            return true
        }
        XCTAssertEqual(view.agentKinds, ["claude"])
        _ = view.onSend("run checks", "claude")
        XCTAssertEqual(received?.0, "run checks")
        XCTAssertEqual(received?.1, "claude")
    }

    func testBroadcastButtonRequiresTextAndIdleRecipientsOnly() {
        XCTAssertFalse(CommandBar.isBroadcastEnabled(hasIdleRecipients: false, text: "command"))
        XCTAssertFalse(CommandBar.isBroadcastEnabled(hasIdleRecipients: true, text: "  \n"))
        XCTAssertTrue(CommandBar.isBroadcastEnabled(hasIdleRecipients: true, text: "command"))
    }

    func testPaletteDefinesEveryStatusColor() {
        XCTAssertEqual(Set(Palette.statusColors.keys), Set(AgentStatus.allCases))
        for status in AgentStatus.allCases {
            _ = Palette.status(status)
        }
    }

    func testLegacyAgentStatusRawValuesDecodeToRenamedCases() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(AgentStatus.self, from: Data("\"working\"".utf8)), .running)
        XCTAssertEqual(try decoder.decode(AgentStatus.self, from: Data("\"needsYou\"".utf8)), .waitingForInput) // legacy raw value
        XCTAssertEqual(try decoder.decode(AgentStatus.self, from: Data("\"resting\"".utf8)), .idle) // legacy raw value
        XCTAssertEqual(try decoder.decode(AgentStatus.self, from: Data("\"paused\"".utf8)), .stopped)
        XCTAssertEqual(try decoder.decode(AgentStatus.self, from: Data("\"done\"".utf8)), .finished)
        let encoded = try JSONEncoder().encode(AgentStatus.waitingForInput)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"waitingForInput\"")
    }

    func testDesignTokensAreAvailable() {
        XCTAssertGreaterThan(Spacing.xl, Spacing.md)
        XCTAssertEqual(Spacing.radiusSmall, 6)
        XCTAssertEqual(Spacing.radiusMedium, 10)
        XCTAssertEqual(Spacing.radiusLarge, 14)
        XCTAssertFalse(Icon.allCases.isEmpty)
    }

    func testSettingsViewModelPersistsChangesThroughInjectedRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppPreferencesStore(rootURL: root)
        let model = SettingsViewModel(store: store)

        model.setRestoreLastWorkspace(false)
        model.setShowNotifications(false)

        XCTAssertEqual(try store.load().restoreLastWorkspace, false)
        XCTAssertEqual(try store.load().showNotifications, false)
        XCTAssertNil(model.errorMessage)
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertTrue(model.rememberNewTerminal(agentID: "claude", directory: folder))
        let loaded = try store.load()
        XCTAssertEqual(loaded.lastUsedAgentID, "claude")
        XCTAssertEqual(loaded.recentWorkingDirectories.first?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        let draft = model.newTerminalDraft(homeDirectory: root)
        XCTAssertEqual(draft.selectedAgentID, "claude")
        XCTAssertEqual(draft.selectedDirectoryPath, folder.resolvingSymlinksInPath().path)
    }

    func testSettingsViewModelBlocksWritesAfterUnsupportedVersionUntilReset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("preferences.json")
        let original = Data("{\"version\":99,\"restoreLastWorkspace\":false}".utf8)
        try original.write(to: file)
        let model = SettingsViewModel(store: AppPreferencesStore(rootURL: root))
        XCTAssertFalse(model.canWritePreferences)
        model.setShowNotifications(false)
        XCTAssertEqual(try Data(contentsOf: file), original)
        model.resetPreferences()
        XCTAssertTrue(model.canWritePreferences)
        XCTAssertEqual(try AppPreferencesStore(rootURL: root).load(), AppPreferences())
    }

    func testSettingsViewModelCustomExecutableAndProfileValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = SettingsViewModel(
            store: AppPreferencesStore(rootURL: root.appendingPathComponent("settings", isDirectory: true)),
            executableSearchDirectories: [root]
        )
        XCTAssertTrue(model.upsertCustomExecutable(CustomAgentExecutable(
            id: "custom-agent", displayName: "Custom Agent", executablePath: executable.path, arguments: ["--fast"]
        )))
        XCTAssertEqual(model.customExecutables.count, 1)
        XCTAssertFalse(model.upsertAccountProfile(AgentAccountProfile(
            name: "Bad profile", agentID: "custom-agent", environment: ["CLAUDE_CONFIG_DIR": "sk-secret-token-value-12345678901234567890"]
        )))
        XCTAssertTrue((model.profileError ?? "").contains("secret"))
    }

    func testSettingsViewModelCachesInstalledAgentsUntilExplicitRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = SettingsViewModel(
            store: AppPreferencesStore(rootURL: root.appendingPathComponent("preferences", isDirectory: true)),
            executableSearchDirectories: [root]
        )
        XCTAssertFalse(model.installedKnownAgentIDs.contains("codex"))
        let codex = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        XCTAssertFalse(model.installedKnownAgentIDs.contains("codex"))
        model.refreshInstalledKnownAgents()
        XCTAssertTrue(model.installedKnownAgentIDs.contains("codex"))
    }

    func testPanelHostExposesSharedPanelContentAndDismissal() {
        var dismissed = false
        let host = PanelHost(title: "Settings", subtitle: "App preferences", onClose: { dismissed = true }) {
            Text("Preferences")
        }
        XCTAssertEqual(host.title, "Settings")
        XCTAssertEqual(host.subtitle, "App preferences")
        host.onClose()
        XCTAssertTrue(dismissed)
    }

    func testMarkdownPanelReadsWorkspaceMarkdownAndSupportsSourceMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Heading\n\n**Bold** [site](https://example.com) ![remote](https://example.com/a.png)\n\nFirst\nSecond".utf8)
            .write(to: root.appendingPathComponent("README.md"))
        try Data("plain text".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let model = MarkdownPanelModel(workspace: Workspace(name: "Test", repos: [root]))

        XCTAssertEqual(model.documents.map(\.relativePath), ["README.md"])
        let document = try XCTUnwrap(model.documents.first)
        model.select(document)
        XCTAssertEqual(model.source, "# Heading\n\n**Bold** [site](https://example.com) ![remote](https://example.com/a.png)\n\nFirst\nSecond")
        XCTAssertNotNil(model.renderedText)
        let blocks = MarkdownBlocks(markdown: model.source)
        XCTAssertEqual(blocks.blockCount, 3)
        XCTAssertTrue(blocks.plainText.contains("\n"))
        XCTAssertFalse(String(describing: model.renderedText!).contains("attachment"))
        model.mode = .source
        XCTAssertEqual(model.mode, .source)
    }

    func testSkillsLinksOnlyOpenHTTPAndHTTPSWithInjectedOpener() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var opened: [URL] = []
        let model = SkillsPanelModel(workspace: Workspace(name: "Test", repos: []), homeRoot: base, linkOpener: { opened.append($0) })
        for value in ["https://example.com/path", "http://example.com", "file:///tmp/private", "custom://host/action", "javascript:alert(1)"] {
            model.openLink(try XCTUnwrap(URL(string: value)))
        }
        XCTAssertEqual(opened.map(\.scheme), ["https", "http"])
    }

    func testSkillsWithDuplicateRelativePathsHaveDistinctIdentityAndSelection() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for root in [project, home] { try FileManager.default.createDirectory(at: root.appendingPathComponent(".agents/skills/review", isDirectory: true), withIntermediateDirectories: true) }
        try Data("---\nname: Project review\n---\nProject".utf8).write(to: project.appendingPathComponent(".agents/skills/review/SKILL.md"))
        try Data("---\nname: Home review\n---\nHome".utf8).write(to: home.appendingPathComponent(".agents/skills/review/SKILL.md"))
        let model = SkillsPanelModel(workspace: Workspace(name: "Test", repos: [project]), homeRoot: home)
        XCTAssertEqual(model.skills.map(\.relativePath), ["review/SKILL.md", "review/SKILL.md"])
        XCTAssertEqual(Set(model.skills.map(\.id)).count, 2)
        let selected = try XCTUnwrap(model.skills.first(where: { $0.name == "Home review" }))
        model.select(selected)
        XCTAssertEqual(model.source, "---\nname: Home review\n---\nHome")
    }

    func testMarkdownPanelInheritsWorkspaceDocumentSafetyLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.md"), withDestinationURL: outside.appendingPathComponent("secret.md"))
        try Data(repeating: 0x61, count: WorkspaceDocuments.maximumFileSize + 1).write(to: root.appendingPathComponent("large.md"))
        let model = MarkdownPanelModel(workspace: Workspace(name: "Test", repos: [root]))
        XCTAssertTrue(model.documents.isEmpty)
    }

    func testSkillsPanelFindsProjectAndInjectedHomeSkillsAndRendersContent() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        for path in ["project/.codex/skills/review", "home/.agents/skills/notes"] {
            try fm.createDirectory(at: base.appendingPathComponent(path, isDirectory: true), withIntermediateDirectories: true)
        }
        let projectSkill = project.appendingPathComponent(".codex/skills/review/SKILL.md")
        let homeSkill = home.appendingPathComponent(".agents/skills/notes/SKILL.md")
        try Data("---\nname: Code Review\ndescription: Checks changes\n---\n# Review\n\n**Carefully**".utf8).write(to: projectSkill)
        try Data("---\nname: Notes\ndescription: Personal notes\n---\nRead me".utf8).write(to: homeSkill)

        let model = SkillsPanelModel(workspace: Workspace(name: "Test", repos: [project]), homeRoot: home)
        XCTAssertEqual(Set(model.skills.map(\.name)), ["Code Review", "Notes"])
        let selected = try XCTUnwrap(model.skills.first(where: { $0.name == "Code Review" }))
        XCTAssertEqual(selected.description, "Checks changes")
        model.select(selected)
        XCTAssertTrue(model.source.contains("# Review"))
        XCTAssertNotNil(model.renderedText)
        XCTAssertEqual(model.selectedSkill, selected)
    }

    func testSkillsPanelRejectsOversizedAndSymlinkedSkillFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        try fm.createDirectory(at: project.appendingPathComponent(".claude/skills/large", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: project.appendingPathComponent(".agents/skills/linked", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: WorkspaceDocuments.maximumFileSize + 1)
            .write(to: project.appendingPathComponent(".claude/skills/large/SKILL.md"))
        let target = outside.appendingPathComponent("SKILL.md")
        try Data("---\nname: Escaped\n---\nsecret".utf8).write(to: target)
        try fm.createSymbolicLink(at: project.appendingPathComponent(".agents/skills/linked/SKILL.md"), withDestinationURL: target)
        let model = SkillsPanelModel(workspace: Workspace(name: "Test", repos: [project]), homeRoot: base.appendingPathComponent("empty"))
        XCTAssertTrue(model.skills.isEmpty)
    }

    func testMemoryPanelFindsProjectAndInjectedHomeFilesAndRendersMarkdown() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        for folder in [project, home] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let contents: [(URL, String)] = [
            (project.appendingPathComponent("AGENTS.md"), "# Project rules"),
            (project.appendingPathComponent("CLAUDE.md"), "Project Claude"),
            (project.appendingPathComponent(".codex/AGENTS.md"), "Codex project"),
            (project.appendingPathComponent(".claude/CLAUDE.md"), "Claude project"),
            (home.appendingPathComponent(".codex/AGENTS.md"), "# User rules\n\n**Private**"),
            (home.appendingPathComponent(".claude/CLAUDE.md"), "Claude user"),
        ]
        for (url, text) in contents {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try Data("not an instruction file".utf8).write(to: project.appendingPathComponent("README.md"))

        let model = MemoryPanelModel(workspace: Workspace(name: "Test", repos: [project]), homeRoot: home)
        XCTAssertEqual(Set(model.projectDocuments.map(\.relativePath)), ["AGENTS.md", "CLAUDE.md", ".codex/AGENTS.md", ".claude/CLAUDE.md"])
        XCTAssertEqual(Set(model.userDocuments.map(\.relativePath)), [".codex/AGENTS.md", ".claude/CLAUDE.md"])
        let selected = try XCTUnwrap(model.userDocuments.first(where: { $0.relativePath == ".codex/AGENTS.md" }))
        model.select(selected)
        XCTAssertEqual(model.source, "# User rules\n\n**Private**")
        XCTAssertNotNil(model.renderedText)
        XCTAssertEqual(model.selectedDocument, selected)
        XCTAssertNil(model.errorMessage)
    }

    func testMemoryPanelRejectsOversizedAndSymlinkedFilesUsingDocumentProtections() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        for folder in [project, home, outside] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let largeFolder = project.appendingPathComponent(".codex", isDirectory: true)
        let linkedFolder = project.appendingPathComponent(".claude", isDirectory: true)
        try fm.createDirectory(at: largeFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: linkedFolder, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: WorkspaceDocuments.maximumFileSize + 1)
            .write(to: largeFolder.appendingPathComponent("AGENTS.md"))
        let secret = outside.appendingPathComponent("CLAUDE.md")
        try Data("outside".utf8).write(to: secret)
        try fm.createSymbolicLink(at: linkedFolder.appendingPathComponent("CLAUDE.md"), withDestinationURL: secret)

        let model = MemoryPanelModel(workspace: Workspace(name: "Test", repos: [project]), homeRoot: home)
        XCTAssertTrue(model.projectDocuments.isEmpty)
        XCTAssertTrue(model.userDocuments.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testTextSurfaceContrastMeetsWCAGAAInLightAndDarkMode() {
        let pairs: [(String, Color, Color)] = [
            ("ink / surface", Palette.ink, Palette.surface),
            ("ink / raised surface", Palette.ink, Palette.raisedSurface),
            ("secondary ink / surface", Palette.secondaryInk, Palette.surface),
            ("secondary ink / raised surface", Palette.secondaryInk, Palette.raisedSurface),
            ("muted ink / surface", Palette.mutedInk, Palette.surface),
            ("muted ink / raised surface", Palette.mutedInk, Palette.raisedSurface),
            ("accent / accent soft", Palette.accent, Palette.accentSoft),
            ("command destination / accent soft", Palette.accent, Palette.accentSoft),
            ("command text / command surface", Palette.ink, Palette.surface),
            ("card title / raised surface", Palette.ink, Palette.raisedSurface),
            ("card menu / raised surface", Palette.secondaryInk, Palette.raisedSurface),
            ("status label / raised surface", Palette.secondaryInk, Palette.raisedSurface),
        ]

        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let nsAppearance = NSAppearance(named: appearance)!
            for (pair, foreground, background) in pairs {
                let fg = resolvedSRGB(foreground, appearance: nsAppearance)
                let bg = resolvedSRGB(background, appearance: nsAppearance)
                let ratio = contrastRatio(fg, bg)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) \(pair): \(ratio):1")
            }
        }
    }

    func testScreenshotPanelModelImportsAndAttachesPathThroughDispatchGate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let importsDir = root.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: importsDir, withIntermediateDirectories: true)
        let sourceImage = importsDir.appendingPathComponent("sample.png")
        try makePNG(width: 16, height: 10).write(to: sourceImage)
        var dispatched: (UUID, String)?
        let targetID = UUID()
        let model = ScreenshotLibraryPanelModel(
            store: ScreenshotLibraryStore(rootURL: root.appendingPathComponent("app-support")),
            attachTargets: [ScreenshotAttachTarget(id: targetID, title: "Console")],
            attachToConsole: {
                dispatched = ($0, $1)
                return true
            }
        )
        model.importURLs([sourceImage])
        XCTAssertEqual(model.items.count, 1)
        XCTAssertNotNil(model.selectedItem)
        model.attachSelectedToConsole()
        XCTAssertEqual(dispatched?.0, targetID)
        XCTAssertTrue((dispatched?.1 ?? "").hasSuffix(".png"))
        XCTAssertTrue((model.statusMessage ?? "").contains("Attached"))
    }

    func testPlannerPanelUsesJevladderWhenInstalledAndRequiresApprovalBeforeExecution() async throws {
        let workspace = Workspace(name: "Planner", nodes: [Node(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, kind: .console, cwd: URL(fileURLWithPath: "/tmp"), frame: .init(x: 0, y: 0, w: 1, h: 1), title: "Console")])
        let runnerStore = FakePlannerRunnerStore()
        let codexDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let codex = codexDir.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        defer { try? FileManager.default.removeItem(at: codexDir) }
        let jevladder = URL(fileURLWithPath: "/opt/homebrew/bin/jevladder")
        let planJSON = #"{"actions":[{"type":"note","text":"hello"}]}"#
        let model = PlannerPanelModel(
            workspace: workspace,
            runningConsoleIDs: [],
            cliOptions: [PlannerCLIOption(id: "codex", title: "Codex", executablePath: codex.path, defaultArguments: [])],
            runner: FakePlannerRunner(
                responses: [
                    "jevladder": PlannerCommandResult(exitCode: 0, stdout: "cheap\n", stderr: ""),
                    "codex": PlannerCommandResult(exitCode: 0, stdout: planJSON, stderr: ""),
                ],
                store: runnerStore
            ),
            jevladderSearchDirectories: [URL(fileURLWithPath: "/opt/homebrew/bin")],
            executeAction: { action in
                if case .note = action { return .success("ok") }
                return .failure("unexpected")
            }
        )
        model.plannerPrompt = "run planner"
        await model.generatePlan()
        XCTAssertEqual(model.generatedPlan?.actions.count, 1)
        guard model.actionStates.count == 1 else {
            XCTFail("Expected one planner action, got error: \(model.errorMessage ?? "none")")
            return
        }
        XCTAssertFalse(model.actionStates[0].approved)
        await model.executeApprovedAction(at: 0)
        XCTAssertFalse(model.actionStates[0].executed)
        model.approveAction(at: 0)
        await model.executeApprovedAction(at: 0)
        XCTAssertTrue(model.actionStates[0].executed)
        let calls = await runnerStore.all()
        XCTAssertTrue(calls.contains { $0.0 == "jevladder" && $0.1.first == "route" } || !AgentCatalog.isExecutableFile(jevladder))
    }

    func testPlannerPanelSkipsJevladderLookupWhenSearchDirectoriesAreEmpty() async throws {
        let runnerStore = FakePlannerRunnerStore()
        let fakeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fakeDir) }
        try FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        let codex = fakeDir.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        let planJSON = #"{"actions":[{"type":"note","text":"ok"}]}"#
        let model = PlannerPanelModel(
            workspace: nil,
            runningConsoleIDs: [],
            cliOptions: [PlannerCLIOption(id: "codex", title: "Codex", executablePath: codex.path, defaultArguments: [])],
            runner: FakePlannerRunner(
                responses: ["codex": PlannerCommandResult(exitCode: 0, stdout: planJSON, stderr: "")],
                store: runnerStore
            ),
            jevladderSearchDirectories: [],
            executeAction: { _ in .success("unused") }
        )
        model.plannerPrompt = "make a note"
        await model.generatePlan()
        XCTAssertEqual(model.generatedPlan?.actions.count, 1)
        let calls = await runnerStore.all()
        XCTAssertEqual(calls.filter { $0.0 == "jevladder" }.count, 0)
    }

    func testPlannerPanelRejectsInvalidJSONAndDisabledHTTPBackend() async {
        let runnerStore = FakePlannerRunnerStore()
        let fakeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        let fakeCLI = fakeDir.appendingPathComponent("claude")
        try? Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeCLI)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        defer { try? FileManager.default.removeItem(at: fakeDir) }
        let model = PlannerPanelModel(
            workspace: nil,
            runningConsoleIDs: [],
            cliOptions: [PlannerCLIOption(id: "claude", title: "Claude", executablePath: fakeCLI.path, defaultArguments: [])],
            runner: FakePlannerRunner(
                responses: [
                    "jevladder": PlannerCommandResult(exitCode: 1, stdout: "", stderr: "missing"),
                    "claude": PlannerCommandResult(exitCode: 0, stdout: "not json", stderr: ""),
                ],
                store: runnerStore
            ),
            keychainReader: FakePlannerKeychainReader(value: "sk-local"),
            executeAction: { _ in .failure("unused") }
        )
        model.plannerPrompt = "bad json"
        await model.generatePlan()
        XCTAssertNil(model.generatedPlan)
        XCTAssertTrue((model.errorMessage ?? "").contains("JSON"))

        model.backendKind = .http
        model.allowHTTPBackend = false
        await model.generatePlan()
        XCTAssertTrue((model.errorMessage ?? "").contains("disabled"))
    }

    private func resolvedSRGB(_ color: Color, appearance: NSAppearance) -> (CGFloat, CGFloat, CGFloat) {
        var components: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else {
                XCTFail("Unable to resolve color as sRGB")
                return
            }
            components = (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        }
        return components
    }

    private func contrastRatio(_ foreground: (CGFloat, CGFloat, CGFloat), _ background: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        let foregroundLuminance = luminance(foreground)
        let backgroundLuminance = luminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ rgb: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        func linearize(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(rgb.0) + 0.7152 * linearize(rgb.1) + 0.0722 * linearize(rgb.2)
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create CGContext")
            return Data()
        }
        context.setFillColor(CGColor(red: 0.5, green: 0.7, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            XCTFail("Could not create CGImage")
            return Data()
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            XCTFail("Could not create image destination")
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
