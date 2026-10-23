import Foundation
import LanebayCore
import Security
import SwiftUI
import Darwin

public struct PlannerCommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}

public protocol PlannerProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], workingDirectory: URL?, timeout: Duration, maxOutputBytes: Int) async throws -> PlannerCommandResult
}

public enum PlannerRunnerError: LocalizedError {
    case timeout
    case couldNotStart(String)

    public var errorDescription: String? {
        switch self {
        case .timeout: "Planner command timed out."
        case let .couldNotStart(reason): "Could not start planner command: \(reason)"
        }
    }
}

public struct PlannerCLIRunner: PlannerProcessRunning {
    private let killGracePeriod: Duration

    public init(killGracePeriod: Duration = .milliseconds(300)) {
        self.killGracePeriod = killGracePeriod
    }

    public func run(executable: URL, arguments: [String], workingDirectory: URL?, timeout: Duration, maxOutputBytes: Int) async throws -> PlannerCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutCollector = PlannerOutputCollector(maxBytes: maxOutputBytes)
        let stderrCollector = PlannerOutputCollector(maxBytes: maxOutputBytes)
        stdoutPipe.fileHandleForReading.readabilityHandler = { stdoutCollector.append($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { stderrCollector.append($0.availableData) }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw PlannerRunnerError.couldNotStart(error.localizedDescription)
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { await waitForExit(process) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    await terminate(process, gracePeriod: killGracePeriod)
                    throw PlannerRunnerError.timeout
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            await terminate(process, gracePeriod: .zero)
            _ = await waitForExit(process)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutCollector.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrCollector.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        return PlannerCommandResult(exitCode: process.terminationStatus, stdout: stdoutCollector.string, stderr: stderrCollector.string)
    }

    private func waitForExit(_ process: Process) async {
        if !process.isRunning { return }
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
    }

    private func terminate(_ process: Process, gracePeriod: Duration) async {
        guard process.isRunning else { return }
        process.terminate()
        if gracePeriod > .zero { try? await Task.sleep(for: gracePeriod) }
        guard process.isRunning else { return }
        if process.processIdentifier > 0 {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}

private final class PlannerOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var storage = Data()

    init(maxBytes: Int) { self.maxBytes = max(0, maxBytes) }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !chunk.isEmpty, storage.count < maxBytes else { return }
        storage.append(chunk.prefix(maxBytes - storage.count))
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }
}

public struct PlannerCLIOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let executablePath: String
    public let defaultArguments: [String]
    public init(id: String, title: String, executablePath: String, defaultArguments: [String]) {
        self.id = id
        self.title = title
        self.executablePath = executablePath
        self.defaultArguments = defaultArguments
    }
}

public protocol PlannerAPIKeyReading: Sendable {
    func readPlannerAPIKey() throws -> String
}

public enum PlannerKeychainError: LocalizedError {
    case missing
    case unreadable(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missing: "Planner API key was not found in Keychain."
        case let .unreadable(status): "Planner API key could not be read from Keychain (status \(status))."
        }
    }
}

public struct PlannerKeychainReader: PlannerAPIKeyReading {
    public let service: String
    public let account: String
    public init(service: String = "com.lanebay.planner", account: String = "api-key") {
        self.service = service
        self.account = account
    }

    public func readPlannerAPIKey() throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            throw PlannerKeychainError.missing
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw PlannerKeychainError.unreadable(status)
        }
        return key
    }
}

public enum PlannerBackendKind: String, CaseIterable, Identifiable {
    case cli
    case http
    public var id: String { rawValue }
}

public enum PlannerExecutionOutcome: Equatable {
    case success(String)
    case failure(String)
}

public struct PlannerActionState: Equatable {
    public var approved = false
    public var executed = false
    public var outcome: PlannerExecutionOutcome?
}

@MainActor
@Observable
public final class PlannerPanelModel {
    public var backendKind: PlannerBackendKind = .cli
    public var plannerPrompt = ""
    public var selectedCLIOptionID: String
    public var allowHTTPBackend = false

    public private(set) var isRunning = false
    public private(set) var availableCLIOptions: [PlannerCLIOption]
    public private(set) var generatedPlan: PlannerPlan?
    public private(set) var actionStates: [PlannerActionState] = []
    public private(set) var rawPlannerOutput = ""
    public private(set) var statusMessage: String?
    public private(set) var errorMessage: String?

    private var workspace: Workspace?
    private var runningConsoleIDs: Set<UUID> = []
    private let runner: PlannerProcessRunning
    private let keychainReader: PlannerAPIKeyReading
    private let timeout: Duration
    private let maxOutputBytes: Int
    private let jevladderSearchDirectories: [URL]
    private let executeAction: @MainActor @Sendable (PlannerAction) async -> PlannerExecutionOutcome

    public init(
        workspace: Workspace?,
        runningConsoleIDs: Set<UUID>,
        cliOptions: [PlannerCLIOption],
        runner: PlannerProcessRunning = PlannerCLIRunner(),
        keychainReader: PlannerAPIKeyReading = PlannerKeychainReader(),
        timeout: Duration = .seconds(15),
        maxOutputBytes: Int = 262_144,
        jevladderSearchDirectories: [URL] = AgentCatalog.defaultExecutableSearchDirectories,
        executeAction: @escaping @MainActor @Sendable (PlannerAction) async -> PlannerExecutionOutcome = { _ in .failure("No executor configured.") }
    ) {
        self.workspace = workspace
        self.runningConsoleIDs = runningConsoleIDs
        self.availableCLIOptions = cliOptions
        self.selectedCLIOptionID = cliOptions.first?.id ?? ""
        self.runner = runner
        self.keychainReader = keychainReader
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.jevladderSearchDirectories = jevladderSearchDirectories
        self.executeAction = executeAction
    }

    public func update(workspace: Workspace?, runningConsoleIDs: Set<UUID>, cliOptions: [PlannerCLIOption]) {
        self.workspace = workspace
        self.runningConsoleIDs = runningConsoleIDs
        availableCLIOptions = cliOptions
        if !cliOptions.contains(where: { $0.id == selectedCLIOptionID }) {
            selectedCLIOptionID = cliOptions.first?.id ?? ""
        }
    }

    public func generatePlan() async {
        statusMessage = nil
        errorMessage = nil
        generatedPlan = nil
        actionStates = []
        rawPlannerOutput = ""
        guard !plannerPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter a planner request first."
            return
        }
        isRunning = true
        defer { isRunning = false }
        do {
            let output = try await callBackend()
            rawPlannerOutput = output
            let plan = try PlannerPlanValidator.decodeStrict(from: output)
            generatedPlan = plan
            actionStates = Array(repeating: PlannerActionState(), count: plan.actions.count)
            statusMessage = "Plan generated. Approve each action before execution."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func approveAction(at index: Int) {
        guard index >= 0, index < actionStates.count else { return }
        actionStates[index].approved = true
    }

    public func executeApprovedAction(at index: Int) async {
        guard let plan = generatedPlan, index >= 0, index < actionStates.count, index < plan.actions.count else { return }
        guard actionStates[index].approved else {
            errorMessage = "Approve the action before executing it."
            return
        }
        guard !actionStates[index].executed else { return }
        let outcome = await executeAction(plan.actions[index])
        actionStates[index].executed = true
        actionStates[index].outcome = outcome
    }

    private func callBackend() async throws -> String {
        switch backendKind {
        case .cli:
            guard let option = availableCLIOptions.first(where: { $0.id == selectedCLIOptionID }) else {
                throw PlannerRunnerError.couldNotStart("No planner CLI option selected.")
            }
            let executable = URL(fileURLWithPath: option.executablePath)
            guard AgentCatalog.isExecutableFile(executable) else {
                throw PlannerRunnerError.couldNotStart("Selected planner executable is not available.")
            }
            let tier = try await resolveTier()
            let prompt = plannerSystemPrompt(userPrompt: plannerPrompt, tier: tier)
            let arguments = plannerArguments(for: option, prompt: prompt)
            let response = try await runner.run(
                executable: executable,
                arguments: arguments,
                workingDirectory: workspace?.repos.first,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes
            )
            guard response.exitCode == 0 else {
                throw PlannerRunnerError.couldNotStart(response.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Planner CLI exited with code \(response.exitCode)." : response.stderr)
            }
            return response.stdout
        case .http:
            guard allowHTTPBackend else {
                throw PlannerRunnerError.couldNotStart("HTTP planner backend is disabled by default.")
            }
            _ = try keychainReader.readPlannerAPIKey()
            throw PlannerRunnerError.couldNotStart("HTTP planner backend is not implemented yet.")
        }
    }

    private func resolveTier() async throws -> String {
        let jevladder = AgentCatalog.resolve(executableName: "jevladder", searchDirectories: jevladderSearchDirectories)
        guard let jevladder else { return "cheapest" }
        let routed = try await runner.run(
            executable: jevladder,
            arguments: ["route", "planner", plannerPrompt],
            workingDirectory: workspace?.repos.first,
            timeout: .seconds(4),
            maxOutputBytes: 4_096
        )
        guard routed.exitCode == 0 else { return "cheapest" }
        let candidate = routed.stdout
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (candidate?.isEmpty == false) ? candidate! : "cheapest"
    }

    private func plannerArguments(for option: PlannerCLIOption, prompt: String) -> [String] {
        switch option.id {
        case "codex":
            return option.defaultArguments + ["exec", prompt]
        case "claude":
            return option.defaultArguments + ["-p", prompt]
        default:
            return option.defaultArguments + [prompt]
        }
    }

    private func plannerSystemPrompt(userPrompt: String, tier: String) -> String {
        let workspaceSummary = plannerWorkspaceSummary()
        return """
        You are a local planner. Use model tier: \(tier).
        Return only strict JSON with this exact shape:
        {"actions":[
          {"type":"sendToConsole","nodeID":"<uuid>","text":"..."},
          {"type":"broadcastToGroup","groupID":"<uuid>","text":"..."},
          {"type":"createLoop","name":"...","targetNodeID":"<uuid>","prompt":"...","trigger":{"type":"idle|outputMatch|schedule|goalCheck", "...": "..."},"maxIterations":10},
          {"type":"startConsole","nodeID":"<uuid>"},
          {"type":"note","text":"..."}
        ]}
        No markdown, no prose.

        Workspace snapshot:
        \(workspaceSummary)

        User request:
        \(userPrompt)
        """
    }

    private func plannerWorkspaceSummary() -> String {
        guard let workspace else { return "No active workspace." }
        let nodes = workspace.nodes.filter { $0.kind == .console }.map { node in
            let running = runningConsoleIDs.contains(node.id) ? "running" : "not started"
            return "- console \(node.id.uuidString) '\(node.title)' (\(running))"
        }.joined(separator: "\n")
        let groups = workspace.groups.map { group in
            "- group \(group.id.uuidString) '\(group.name)' members: \(group.nodeIDs.count)"
        }.joined(separator: "\n")
        return """
        workspace id: \(workspace.id.uuidString)
        consoles:
        \(nodes.isEmpty ? "- none" : nodes)
        groups:
        \(groups.isEmpty ? "- none" : groups)
        """
    }
}

public struct PlannerPanel: View {
    @Bindable private var model: PlannerPanelModel
    public init(model: PlannerPanelModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                GroupBox("Planner backend") {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Picker("Backend", selection: $model.backendKind) {
                            Text("CLI").tag(PlannerBackendKind.cli)
                            Text("HTTP (disabled by default)").tag(PlannerBackendKind.http)
                        }.pickerStyle(.menu)
                        if model.backendKind == .cli {
                            Picker("Planner CLI", selection: $model.selectedCLIOptionID) {
                                ForEach(model.availableCLIOptions) { option in
                                    Text(option.title).tag(option.id)
                                }
                            }
                            .pickerStyle(.menu)
                        } else {
                            Toggle("Allow HTTP backend", isOn: $model.allowHTTPBackend)
                            Text("HTTP backend never reads API keys from files/preferences; it only reads Keychain.")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.mutedInk)
                        }
                    }
                }

                GroupBox("Request") {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        TextEditor(text: $model.plannerPrompt)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .frame(minHeight: 96)
                            .overlay(RoundedRectangle(cornerRadius: Spacing.radiusSmall).stroke(Palette.border))
                        Button("Generate plan") {
                            Task { await model.generatePlan() }
                        }
                        .disabled(model.isRunning)
                    }
                }

                if let plan = model.generatedPlan {
                    GroupBox("Typed actions (approval required per action)") {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            ForEach(Array(plan.actions.enumerated()), id: \.offset) { index, action in
                                actionRow(index: index, action: action)
                            }
                        }
                    }
                }

                if !model.rawPlannerOutput.isEmpty {
                    GroupBox("Raw planner output") {
                        Text(model.rawPlannerOutput)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let status = model.statusMessage {
                    Text(status).font(Typography.caption).foregroundStyle(Palette.accent)
                }
                if let error = model.errorMessage {
                    Text(error).font(Typography.caption).foregroundStyle(Palette.status(.error)).textSelection(.enabled)
                }
            }
            .padding(Spacing.sm)
        }
    }

    @ViewBuilder
    private func actionRow(index: Int, action: PlannerAction) -> some View {
        let state = model.actionStates[index]
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("\(index + 1). \(label(for: action))").font(Typography.bodyEmphasis)
            HStack(spacing: Spacing.xs) {
                if !state.approved {
                    Button("Approve") { model.approveAction(at: index) }
                } else if !state.executed {
                    Button("Execute") { Task { await model.executeApprovedAction(at: index) } }
                } else {
                    Text("Executed").font(Typography.caption).foregroundStyle(Palette.secondaryInk)
                }
                switch state.outcome {
                case let .success(message):
                    Text(message).font(Typography.caption).foregroundStyle(Palette.accent)
                case let .failure(message):
                    Text(message).font(Typography.caption).foregroundStyle(Palette.status(.error))
                case .none:
                    EmptyView()
                }
            }
        }
        .padding(Spacing.xs)
        .background(Palette.raisedSurface, in: RoundedRectangle(cornerRadius: Spacing.radiusSmall))
    }

    private func label(for action: PlannerAction) -> String {
        switch action {
        case let .sendToConsole(nodeID, text):
            "sendToConsole node=\(nodeID.uuidString.prefix(8)) text='\(text.prefix(40))'"
        case let .broadcastToGroup(groupID, text):
            "broadcastToGroup group=\(groupID.uuidString.prefix(8)) text='\(text.prefix(40))'"
        case let .createLoop(name, targetNodeID, prompt, trigger, maxIterations):
            "createLoop '\(name)' target=\(targetNodeID.uuidString.prefix(8)) trigger=\(triggerLabel(trigger)) max=\(maxIterations) prompt='\(prompt.prefix(24))'"
        case let .startConsole(nodeID):
            "startConsole node=\(nodeID.uuidString.prefix(8))"
        case let .note(text):
            "note '\(text.prefix(60))'"
        }
    }

    private func triggerLabel(_ trigger: LoopTrigger) -> String {
        switch trigger {
        case .idle: return "idle"
        case let .outputMatch(pattern): return "outputMatch(\(pattern))"
        case let .schedule(intervalSeconds): return "schedule(\(intervalSeconds)s)"
        case let .goalCheck(intervalSeconds, goal): return "goalCheck(\(intervalSeconds)s, \(goal))"
        }
    }
}
