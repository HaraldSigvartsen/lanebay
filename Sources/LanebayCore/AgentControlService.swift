import Foundation

/// What the control service needs from the board. The app's BoardViewModel conforms; tests use a fake.
@MainActor public protocol AgentConsoleDriving: AnyObject {
  func agentProviderStatus(_ provider: String) -> AgentProviderStatus
  func spawnAgentConsole(provider: String, cwd: URL, title: String) -> UUID
  func agentConsoleIsRunning(_ id: UUID) -> Bool
  @discardableResult func writeToAgentConsole(_ text: String, id: UUID) -> Bool
  func agentConsoleOutput(_ id: UUID, maxBytes: Int) -> String?
  func stopAgentConsole(_ id: UUID) async
  func agentTasksChanged(_ tasks: [UUID: AgentTaskRecord])
}

/// Lets the control API add, list and remove wires between board cards.
@MainActor public protocol WireControlling: AnyObject {
  /// A card by exact title (case-insensitive) or the start of its UUID.
  func resolveCard(_ reference: String) -> UUID?
  func controlAddWire(from: UUID, to: UUID, direction: WireDirection, mode: WireMode, instruction: String) -> Result<Wire, WireRules.AddError>
  func controlRemoveWire(_ reference: String) -> Bool
  func controlWireLines() -> [String]
  /// Sends text to a card by name, the same way the chat does (starts it if stopped).
  func controlSendToCard(_ id: UUID, text: String) -> Bool
  /// `lanebay cron …`: add/list/rm/run scheduled messages. Returns the text to print or an error.
  func controlCron(_ args: [String: String]) -> Result<String, CronControlError>
}

public struct CronControlError: Error, LocalizedError, Equatable {
  public var message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

extension WireControlling {
  public func controlSendToCard(_ id: UUID, text: String) -> Bool { false }
  public func controlCron(_ args: [String: String]) -> Result<String, CronControlError> { .failure(CronControlError("Cron is not available.")) }
}

public enum AgentProviderStatus: Sendable, Equatable { case ready, unknown, notInstalled }

/// Spawns short, time-boxed agent tasks in board consoles and tracks them until a handoff note exists.
@MainActor public final class AgentControlService {
  public struct Timing: Sendable {
    public var startupTimeout: Duration
    public var promptDelay: Duration
    public var submitDelay: Duration
    public var tickInterval: Duration
    public init(startupTimeout: Duration = .seconds(20), promptDelay: Duration = .seconds(8),
                submitDelay: Duration = .milliseconds(400), tickInterval: Duration = .seconds(1)) {
      self.startupTimeout = startupTimeout
      self.promptDelay = promptDelay
      self.submitDelay = submitDelay
      self.tickInterval = tickInterval
    }
  }

  public private(set) var records: [String: AgentTaskRecord] = [:]
  /// Called when a task reaches a final state, with the finished record and its outcome.
  public var onFinish: ((AgentTaskRecord, AgentTaskState) -> Void)?
  /// The board, for `lanebay link`.
  public weak var wireControl: WireControlling?
  private weak var driver: (any AgentConsoleDriving)?
  private let files = AgentTaskFiles()
  private let clock: @Sendable () -> Date
  private let sleep: @MainActor @Sendable (Duration) async -> Void
  private let timing: Timing
  /// zsh consoles get an invisible precmd hook, so the card shows the command without a printf marker.
  private let shellHooks: Bool
  private var ticker: Task<Void, Never>?

  public init(driver: any AgentConsoleDriving, timing: Timing = Timing(), clock: @escaping @Sendable () -> Date = { .now },
              sleep: @escaping @MainActor @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
              shellHooks: Bool = false) {
    self.driver = driver
    self.shellHooks = shellHooks
    self.timing = timing
    self.clock = clock
    self.sleep = sleep
  }

  public func startTicking() {
    guard ticker == nil else { return }
    ticker = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.sleep(self.timing.tickInterval)
        self.tick()
      }
    }
  }

  public func stopTicking() { ticker?.cancel(); ticker = nil }

  // MARK: Operations

  public func spawn(_ request: AgentSpawnRequest) throws -> (record: AgentTaskRecord, delivery: Task<Void, Never>) {
    guard let driver else { throw AgentSpawnError.unknownProvider(request.provider) }
    switch driver.agentProviderStatus(request.provider) {
    case .unknown: throw AgentSpawnError.unknownProvider(request.provider)
    case .notInstalled: throw AgentSpawnError.providerNotInstalled(request.provider)
    case .ready: break
    }
    let context = try files.validate(request)
    let now = clock()
    let id = String(UUID().uuidString.lowercased().prefix(8))
    let taskURL = try files.writeTask(id: id, request: request, context: context, startedAt: now)
    let handoffURL = AgentTaskContract.handoffFile(cwd: request.cwd, id: id)
    let task = request.task.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = "\(request.provider) · \(id)"
    let nodeID = driver.spawnAgentConsole(provider: request.provider, cwd: request.cwd, title: title)
    let record = AgentTaskRecord(
      id: id, nodeID: nodeID, provider: request.provider, cwd: request.cwd.path, task: task,
      startedAt: now, deadline: now.addingTimeInterval(request.timeout), state: .starting,
      taskFile: taskURL.path, handoffFile: handoffURL.path)
    records[id] = record
    publish()
    let isShell = AgentTaskContract.isShellProvider(request.provider)
    let setup = isShell && shellHooks ? AgentTaskContract.shellHookSetup(id: id) : nil
    let prompt = isShell
      ? (setup != nil ? AgentTaskContract.hookedShellCommand(task: task) : AgentTaskContract.shellCommand(task: task, id: id))
      : AgentTaskContract.prompt(task: task, taskFile: taskURL, handoffFile: handoffURL, timeout: request.timeout)
    let delivery = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.deliver(prompt: prompt, id: id, setup: setup)
    }
    return (record, delivery)
  }

  private func deliver(prompt: String, id: String, setup: String? = nil) async {
    guard let record = records[id], let driver else { return }
    var waited: Duration = .zero
    let step: Duration = .milliseconds(250)
    while !driver.agentConsoleIsRunning(record.nodeID) {
      if waited >= timing.startupTimeout {
        finish(id, as: .failed)
        return
      }
      await sleep(step)
      waited += step
    }
    await sleep(timing.promptDelay)
    guard records[id]?.state == .starting else { return }
    if let setup {
      // Separate writes: text first, then Return, so a pasted line cannot swallow the Return.
      driver.writeToAgentConsole(setup, id: record.nodeID)
      await sleep(timing.submitDelay)
      driver.writeToAgentConsole("\r", id: record.nodeID)
      await sleep(timing.submitDelay)
      await sleep(timing.submitDelay)
    }
    driver.writeToAgentConsole(prompt, id: record.nodeID)
    await sleep(timing.submitDelay)
    driver.writeToAgentConsole("\r", id: record.nodeID)
    records[id]?.state = .running
    publish()
  }

  public func send(id: String, text: String) -> Bool {
    guard let record = records[id], !record.state.isFinal, let driver else { return false }
    guard driver.writeToAgentConsole(text, id: record.nodeID) else { return false }
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.sleep(self.timing.submitDelay)
      self.driver?.writeToAgentConsole("\r", id: record.nodeID)
    }
    return true
  }

  public func read(id: String, tailLines: Int) -> String? {
    guard let record = records[id] else { return nil }
    let raw = driver?.agentConsoleOutput(record.nodeID, maxBytes: 65_536) ?? ""
    let lines = AgentTaskContract.plainText(raw).split(separator: "\n", omittingEmptySubsequences: false)
    return lines.suffix(max(1, tailLines)).joined(separator: "\n")
  }

  public func stop(id: String) async -> AgentTaskRecord? {
    guard let record = records[id] else { return nil }
    if !record.state.isFinal { finish(id, as: .stopped) }
    await driver?.stopAgentConsole(record.nodeID)
    return records[id]
  }

  public func tick() {
    let now = clock()
    for (id, record) in records where !record.state.isFinal {
      if record.state == .running, AgentTaskContract.isShellProvider(record.provider) { writeShellNoteIfDone(record) }
      let running = driver?.agentConsoleIsRunning(record.nodeID) ?? false
      let next = AgentTaskTransition.next(
        state: record.state, now: now, deadline: record.deadline,
        handoffWritten: files.handoffExists(record), processRunning: running)
      if next != record.state { finish(id, as: next) }
    }
  }

  /// A shell task is done when its marker shows up; the note is written from the exit code and output.
  private func writeShellNoteIfDone(_ record: AgentTaskRecord) {
    guard !files.handoffExists(record),
      let output = driver?.agentConsoleOutput(record.nodeID, maxBytes: 65_536),
      let exitCode = AgentTaskContract.shellExitCode(in: output, id: record.id)
    else { return }
    let note = AgentTaskContract.shellNote(task: record.task, id: record.id, exitCode: exitCode, output: output)
    let url = URL(fileURLWithPath: record.handoffFile)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(note.utf8).write(to: url, options: .atomic)
  }

  private func finish(_ id: String, as state: AgentTaskState) {
    guard var record = records[id] else { return }
    record.state = state
    record.finishedAt = clock()
    records[id] = record
    let output = driver?.agentConsoleOutput(record.nodeID, maxBytes: 16_384)
    _ = try? files.finalize(record: record, outcome: state, output: output)
    publish()
    onFinish?(record, state)
  }

  private func publish() {
    var byNode: [UUID: AgentTaskRecord] = [:]
    for record in records.values { byNode[record.nodeID] = record }
    driver?.agentTasksChanged(byNode)
  }

  // MARK: Control API

  public func handle(_ request: ControlRequest) async -> ControlResponse {
    guard let op = ControlOperation(rawValue: request.op) else { return .failure("Unknown operation '\(request.op)'.") }
    let args = request.args
    switch op {
    case .spawn:
      let provider = args["provider"] ?? "freebuff"
      guard let cwd = args["cwd"], cwd.hasPrefix("/") else { return .failure("--cwd must be an absolute path.") }
      guard let task = args["task"] else { return .failure("--task is required.") }
      let timeout: TimeInterval
      if let text = args["timeout"] {
        guard let parsed = AgentTaskContract.parseDuration(text) else { return .failure("Invalid --timeout '\(text)'.") }
        timeout = parsed
      } else {
        timeout = AgentTaskContract.defaultTimeout
      }
      let context = args["context"].map { URL(fileURLWithPath: $0) }
      do {
        let (record, _) = try spawn(AgentSpawnRequest(
          provider: provider, cwd: URL(fileURLWithPath: cwd, isDirectory: true), task: task, timeout: timeout, contextFile: context))
        return ControlResponse(task: record)
      } catch {
        return .failure(error.localizedDescription)
      }
    case .send:
      guard let id = args["id"], let text = args["text"], !text.isEmpty else { return .failure("send needs an id and text.") }
      guard text.count <= AgentTaskContract.maximumTaskCharacters else { return .failure(AgentSpawnError.taskTooLong(text.count).localizedDescription) }
      if records[id] == nil, let card = wireControl?.resolveCard(id) {
        return wireControl?.controlSendToCard(card, text: text) == true
          ? ControlResponse(output: "Sent to \(id).") : .failure("Could not send to \(id).")
      }
      return send(id: id, text: text) ? ControlResponse(task: records[id]) : .failure("Task \(id) is not running.")
    case .read:
      guard let id = args["id"] else { return .failure("read needs an id.") }
      let tail = Int(args["tail"] ?? "") ?? 40
      guard let output = read(id: id, tailLines: tail) else { return .failure("Unknown task \(id).") }
      return ControlResponse(task: records[id], output: output)
    case .status:
      if let id = args["id"] {
        guard let record = records[id] else { return .failure("Unknown task \(id).") }
        return ControlResponse(task: record)
      }
      return ControlResponse(tasks: sortedRecords())
    case .stop:
      guard let id = args["id"] else { return .failure("stop needs an id.") }
      guard let record = await stop(id: id) else { return .failure("Unknown task \(id).") }
      return ControlResponse(task: record)
    case .list:
      return ControlResponse(tasks: sortedRecords())
    case .link:
      return handleLink(args)
    case .cron:
      guard let wireControl else { return .failure("Cron is not available.") }
      switch wireControl.controlCron(args) {
      case let .success(text): return ControlResponse(output: text)
      case let .failure(error): return .failure(error.message)
      }
    }
  }

  private func cardID(_ reference: String) -> UUID? {
    if let record = records[reference] { return record.nodeID }
    return wireControl?.resolveCard(reference)
  }

  private func handleLink(_ args: [String: String]) -> ControlResponse {
    guard let wireControl else { return .failure("Wires are not available.") }
    switch args["action"] ?? "list" {
    case "add":
      guard let fromRef = args["from"], let toRef = args["to"] else { return .failure("link add needs <from> <to>.") }
      guard let from = cardID(fromRef) else { return .failure("Unknown card '\(fromRef)'.") }
      guard let to = cardID(toRef) else { return .failure("Unknown card '\(toRef)'.") }
      let direction: WireDirection = args["two-way"] == "1" ? .twoWay : .oneWay
      let mode: WireMode
      switch (args["mode"] ?? "handoff").lowercased() {
      case "handoff", "done", "ferdig": mode = .handoff
      case "reply", "every-reply", "everyreply", "svar": mode = .everyReply
      default: return .failure("Unknown --mode \(args["mode"] ?? ""). Use handoff or reply.")
      }
      switch wireControl.controlAddWire(from: from, to: to, direction: direction, mode: mode, instruction: args["instruction"] ?? "") {
      case let .success(wire): return ControlResponse(output: "Added wire \(wire.id.uuidString.prefix(8)).")
      case let .failure(error): return .failure(error.localizedDescription)
      }
    case "rm":
      guard let id = args["id"] else { return .failure("link rm needs a wire id.") }
      return wireControl.controlRemoveWire(id) ? ControlResponse(output: "Removed.") : .failure("Unknown wire '\(id)'.")
    case "list":
      let lines = wireControl.controlWireLines()
      return ControlResponse(output: lines.isEmpty ? "No wires." : lines.joined(separator: "\n"))
    default:
      return .failure("link takes add, list or rm.")
    }
  }

  private func sortedRecords() -> [AgentTaskRecord] { records.values.sorted { $0.startedAt < $1.startedAt } }
}
