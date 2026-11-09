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

    /// The console a typed action targets, so the panel can show its provider badge.
    public func consoleTitle(for nodeID: UUID) -> String? {
        workspace?.nodes.first { $0.id == nodeID }?.title
    }

    public func consoleAgentID(for nodeID: UUID) -> String? {
        workspace?.nodes.first { $0.id == nodeID }?.agentID
    }

    public func groupName(for groupID: UUID) -> String? {
        workspace?.groups.first { $0.id == groupID }?.name
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

/// The Orkestrering panel: request, plan and typed steps. Header and close come from `PanelHost`.
public struct PlannerPanel: View {
    @Bindable private var model: PlannerPanelModel
    @FocusState private var requestFocused: Bool
    private let header: AnyView?

    public init(model: PlannerPanelModel, header: AnyView? = nil) {
        self.model = model
        self.header = header
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                if let header {
                    header
                    Divider().padding(.vertical, DS.Space.xs)
                }
                backendSection
                requestSection
                if let plan = model.generatedPlan {
                    stepsSection(plan)
                } else {
                    EmptyStateView(
                        symbol: "point.3.connected.trianglepath.dotted",
                        title: "Ingen plan ennå",
                        message: "Beskriv en forespørsel og lag en plan. Hvert steg godkjennes før det kjøres.",
                        actionTitle: "Skriv en forespørsel",
                        action: { requestFocused = true },
                        identifier: "planner.empty"
                    )
                    .padding(.vertical, DS.Space.lg)
                }
                if !model.rawPlannerOutput.isEmpty { rawOutputSection }
                statusLines
            }
            .padding(DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Planlegger

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Planlegger").sectionCaptionStyle()
            HStack(spacing: DS.Space.xs) {
                Menu {
                    ForEach(PlannerBackendKind.allCases) { kind in
                        Button(kind.panelTitle) { model.backendKind = kind }
                    }
                } label: {
                    capsuleLabel(model.backendKind.panelTitle, symbol: "cpu")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityIdentifier("planner.backend")
                .accessibilityLabel("Planlegger-backend: \(model.backendKind.panelTitle)")

                if model.backendKind == .cli {
                    Menu {
                        ForEach(model.availableCLIOptions) { option in
                            Button(option.title) { model.selectedCLIOptionID = option.id }
                        }
                    } label: {
                        capsuleLabel(selectedCLITitle, symbol: "terminal")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(model.availableCLIOptions.isEmpty)
                    .accessibilityIdentifier("planner.cli")
                    .accessibilityLabel("Planlegger-CLI: \(selectedCLITitle)")
                }
                Spacer(minLength: 0)
            }
            if model.backendKind == .http {
                Toggle("Tillat HTTP-backend", isOn: $model.allowHTTPBackend)
                    .toggleStyle(.switch)
                Text("HTTP-backenden leser API-nøkler kun fra Keychain, aldri fra filer eller preferanser.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.mutedInk)
            }
        }
    }

    private var selectedCLITitle: String {
        model.availableCLIOptions.first { $0.id == model.selectedCLIOptionID }?.title ?? "Ingen CLI"
    }

    private func capsuleLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: DS.Space.xxs) {
            Image(systemName: symbol).font(DS.Font.caption)
            Text(title).font(DS.Font.headline)
            Image(systemName: "chevron.down").font(DS.Font.caption)
        }
        .foregroundStyle(DS.Color.accentInk)
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs)
        .background(DS.Color.accentSoft, in: Capsule())
        .overlay(Capsule().strokeBorder(DS.Color.accent.opacity(0.35), lineWidth: 1))
    }

    // MARK: - Forespørsel

    private var requestSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Forespørsel").sectionCaptionStyle()
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.plannerPrompt)
                    .font(DS.Font.body)
                    .scrollContentBackground(.hidden)
                    .padding(DS.Space.xs)
                    .focused($requestFocused)
                    .accessibilityIdentifier("planner.request")
                if model.plannerPrompt.isEmpty {
                    Text("Beskriv hva agentene skal gjøre …")
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.mutedInk)
                        .padding(.horizontal, DS.Space.sm + DS.Space.xxs)
                        .padding(.vertical, DS.Space.xs)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: DS.Space.xl * 3)
            .glass(radius: DS.Radius.control)

            HStack(spacing: DS.Space.sm) {
                AXActionButton(
                    title: "Lag plan",
                    systemImage: "wand.and.stars",
                    identifier: "planner.generate",
                    accessibilityLabel: "Lag plan",
                    enabled: !model.isRunning,
                    highlighted: false,
                    primary: true,
                    compact: false
                ) { Task { await model.generatePlan() } }
                .frame(width: DS.Space.xl * 4, height: DS.Space.lg + DS.Space.xxs)
                if model.isRunning {
                    Text("Lager plan …")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryInk)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Steg

    private func stepsSection(_ plan: PlannerPlan) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Steg").sectionCaptionStyle()
            VStack(spacing: DS.Space.xs) {
                ForEach(Array(plan.actions.enumerated()), id: \.offset) { index, action in
                    stepCard(index: index, action: action)
                }
            }
        }
    }

    private func stepCard(index: Int, action: PlannerAction) -> some View {
        let state = model.actionStates[index]
        let presentation = PlannerStepPresentation.status(for: state)
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .top, spacing: DS.Space.xs) {
                Text("\(index + 1)")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.accentInk)
                    .frame(width: DS.Space.lg, height: DS.Space.lg)
                    .background(DS.Color.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(label(for: action))
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Space.xxs) {
                        ProviderBadge(agentID: assigneeAgentID(for: action), size: DS.Space.md + DS.Space.xxs)
                        Text(assigneeTitle(for: action))
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryInk)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DS.Space.xs)
                StatusPill(kind: presentation.kind, label: presentation.label)
            }
            HStack(spacing: DS.Space.xs) {
                if !state.approved {
                    Button("Godkjenn") { model.approveAction(at: index) }
                        .buttonStyle(.lbSecondary)
                        .accessibilityIdentifier("planner.approve.\(index)")
                } else if !state.executed {
                    Button("Kjør") { Task { await model.executeApprovedAction(at: index) } }
                        .buttonStyle(.lbPrimary)
                        .accessibilityIdentifier("planner.execute.\(index)")
                }
                if case let .success(message) = state.outcome {
                    Label(message, systemImage: "checkmark.circle")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.status(.done))
                } else if case let .failure(message) = state.outcome {
                    Text(message)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.status(.error))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(radius: DS.Radius.control)
    }

    // MARK: - Output

    private var rawOutputSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Rå output").sectionCaptionStyle()
            Text(model.rawPlannerOutput)
                .font(DS.Font.mono)
                .foregroundStyle(DS.Color.secondaryInk)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.sm)
                .glass(radius: DS.Radius.control)
        }
    }

    @ViewBuilder private var statusLines: some View {
        if let status = model.statusMessage {
            Text(status).font(DS.Font.caption).foregroundStyle(DS.Color.accentInk)
        }
        if let error = model.errorMessage {
            Text(error)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.status(.error))
                .textSelection(.enabled)
                .accessibilityIdentifier("planner.error")
        }
    }

    // MARK: - Step presentation

    private func assigneeAgentID(for action: PlannerAction) -> String {
        switch action {
        case let .sendToConsole(nodeID, _), let .startConsole(nodeID):
            model.consoleAgentID(for: nodeID) ?? "shell"
        case .broadcastToGroup, .note:
            OrchestratorKind.agentID
        case let .createLoop(_, targetNodeID, _, _, _):
            model.consoleAgentID(for: targetNodeID) ?? "shell"
        }
    }

    private func assigneeTitle(for action: PlannerAction) -> String {
        switch action {
        case let .sendToConsole(nodeID, _), let .startConsole(nodeID):
            model.consoleTitle(for: nodeID) ?? "Ukjent konsoll"
        case let .broadcastToGroup(groupID, _):
            model.groupName(for: groupID) ?? "Ukjent gruppe"
        case .note:
            "Notat"
        case let .createLoop(_, targetNodeID, _, _, _):
            model.consoleTitle(for: targetNodeID) ?? "Ukjent konsoll"
        }
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

extension PlannerBackendKind {
    var panelTitle: String {
        switch self {
        case .cli: "CLI"
        case .http: "HTTP"
        }
    }
}

/// A plan step's pill. Pure so the mapping can be tested without a view.
enum PlannerStepPresentation {
    static func status(for state: PlannerActionState) -> (kind: StatusKind, label: String) {
        switch state.outcome {
        case .success:
            return (.done, "Kjørt")
        case .failure:
            return (.error, "Feilet")
        case .none:
            if state.executed { return (.done, "Kjørt") }
            if state.approved { return (.running, "Klar til kjøring") }
            return (.waiting, "Til godkjenning")
        }
    }
}
