import Foundation

/// The short-task contract for agents spawned through the control API.
/// Small-context agents (FreeBuff) work about an hour per session, so a task is short,
/// time-boxed, and ends with a handoff note the next session can pick up.
public enum AgentTaskContract {
  public static let maximumTaskCharacters = 1_500
  public static let maximumContextBytes = 32_768
  public static let maximumHandoffLines = 20
  public static let defaultTimeout: TimeInterval = 55 * 60
  public static let maximumTimeout: TimeInterval = 3 * 60 * 60
  public static let handoffDirectoryName = ".lanebay/handoffs"

  /// Parses `55m`, `90s`, `1h`, `1h30m` or a bare number of minutes.
  public static func parseDuration(_ text: String) -> TimeInterval? {
    let text = text.trimmingCharacters(in: .whitespaces).lowercased()
    guard !text.isEmpty else { return nil }
    if let minutes = Double(text) { return minutes > 0 ? minutes * 60 : nil }
    var total: TimeInterval = 0
    var number = ""
    var sawUnit = false
    for character in text {
      if character.isNumber || character == "." {
        number.append(character)
        continue
      }
      guard let value = Double(number) else { return nil }
      switch character {
      case "h": total += value * 3_600
      case "m": total += value * 60
      case "s": total += value
      default: return nil
      }
      number = ""
      sawUnit = true
    }
    guard number.isEmpty, sawUnit, total > 0 else { return nil }
    return total
  }

  public static func handoffDirectory(cwd: URL) -> URL {
    cwd.appendingPathComponent(handoffDirectoryName, isDirectory: true)
  }

  public static func taskFile(cwd: URL, id: String) -> URL {
    handoffDirectory(cwd: cwd).appendingPathComponent("\(id).task.md")
  }

  public static func handoffFile(cwd: URL, id: String) -> URL {
    handoffDirectory(cwd: cwd).appendingPathComponent("\(id).md")
  }

  /// The single line typed into the agent. It points at the task file so the prompt stays short.
  public static func prompt(task: String, taskFile: URL, handoffFile: URL, timeout: TimeInterval) -> String {
    let minutes = Int((timeout / 60).rounded(.up))
    let oneLine = task.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    return "\(oneLine) — Full task and context: \(taskFile.path). You have \(minutes) min. "
      + "When finished, write a RESULT/HANDOFF note of at most \(maximumHandoffLines) lines to \(handoffFile.path) "
      + "(first line `RESULT: done|partial|blocked`, then what you did, files touched, and what the next session should do)."
  }

  // MARK: Plain shell tasks

  /// Shell consoles run the task as a command; only AI providers get the contract prompt.
  public static func isShellProvider(_ provider: String) -> Bool { provider == "shell" }

  /// Marker printed after the command. The typed line holds `%s:%d`, so only the printed line matches.
  static func shellMarker(id: String) -> String { "__LANEBAY_DONE_\(id):" }

  /// The command line typed into zsh: the task itself, then a marker carrying `$?`.
  public static func shellCommand(task: String, id: String) -> String {
    let oneLine = task.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      .joined(separator: "; ")
    // A task console is non-interactive: a pager (git log, man) would block the exit marker forever.
    return "export PAGER=cat GIT_PAGER=cat; \(oneLine); printf '\\n__LANEBAY_DONE_%s:%d\\n' \(id) $?"
  }

  /// Invisible OSC 777 markers a zsh hook prints around a hooked task (terminals ignore unknown OSC).
  static func shellStartOSC(id: String) -> String { "\u{1B}]777;lanebay-start;\(id)\u{07}" }
  static func shellDoneOSCPrefix(id: String) -> String { "\u{1B}]777;lanebay-done;\(id);" }

  /// True when the console shell is zsh, so a task can use the invisible precmd hook.
  public static func shellSupportsHook(_ shell: String? = ProcessInfo.processInfo.environment["SHELL"]) -> Bool {
    (shell ?? "/bin/zsh").hasSuffix("/zsh") || shell == "zsh"
  }

  /// One-time zsh setup typed before a hooked task, then cleared from the screen. A precmd hook prints an
  /// invisible start marker at the next prompt and an invisible done marker with `$?` after the task,
  /// so the card shows only the command and its output.
  public static func shellHookSetup(id: String) -> String {
    " export PAGER=cat GIT_PAGER=cat; __lb_hook(){ local c=$?; if [[ -n $__lb_armed ]]; then "
      + "printf '\\033]777;lanebay-done;%s;%d\\007' \(id) $c; precmd_functions=(${precmd_functions:#__lb_hook}); "
      + "else __lb_armed=1; printf '\\033]777;lanebay-start;%s\\007' \(id); fi; }; "
      + "precmd_functions=(__lb_hook $precmd_functions); clear"
  }

  /// The command typed after `shellHookSetup`: just the task on one line.
  public static func hookedShellCommand(task: String) -> String {
    task.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      .joined(separator: "; ")
  }

  /// The command's exit code once the marker has been printed, else nil.
  public static func shellExitCode(in output: String, id: String) -> Int? {
    let osc = shellDoneOSCPrefix(id: id)
    if let range = output.range(of: osc, options: .backwards) {
      let digits = output[range.upperBound...].prefix { $0.isNumber || $0 == "-" }
      if output[range.upperBound...].dropFirst(digits.count).first == "\u{07}" { return Int(digits) }
    }
    let marker = shellMarker(id: id)
    for line in plainText(output).components(separatedBy: "\n").reversed() {
      let line = line.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix(marker) else { continue }
      return Int(line.dropFirst(marker.count).prefix { $0.isNumber || $0 == "-" })
    }
    return nil
  }

  /// Handoff note LaneBay writes for a shell task: exit code plus the command's last output lines.
  public static func shellNote(task: String, id: String, exitCode: Int, output: String) -> String {
    if let done = output.range(of: shellDoneOSCPrefix(id: id), options: .backwards) {
      let start = output.range(of: shellStartOSC(id: id), options: .backwards, range: output.startIndex..<done.lowerBound)
      var lines = plainText(String(output[(start?.upperBound ?? output.startIndex)..<done.lowerBound]))
        .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      // Drop the prompt and the echoed command.
      let typed = String(hookedShellCommand(task: task).prefix(24))
      if !typed.isEmpty, let echoed = lines.firstIndex(where: { $0.contains(typed) }) { lines = Array(lines[(echoed + 1)...]) }
      return shellNoteBody(task: task, exitCode: exitCode, lines: lines)
    }
    let marker = shellMarker(id: id)
    var lines = plainText(output).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    if let end = lines.lastIndex(where: { $0.hasPrefix(marker) }) { lines = Array(lines[..<end]) }
    // Drop the echoed command line and everything before it.
    if let start = lines.lastIndex(where: { $0.contains("__LANEBAY_DONE_%s") }) { lines = Array(lines[(start + 1)...]) }
    return shellNoteBody(task: task, exitCode: exitCode, lines: lines)
  }

  private static func shellNoteBody(task: String, exitCode: Int, lines: [String]) -> String {
    // `%` alone is zsh's PROMPT_SP mark for output without a trailing newline.
    let tail = lines.filter { !$0.isEmpty && $0 != "%" }.suffix(maximumHandoffLines - 5).map { "  \($0.prefix(160))" }
    let result = exitCode == 0 ? "RESULT: done" : "RESULT: blocked (exit \(exitCode))"
    return clampNote(([
      result, "TASK: \(task.prefix(200))", "EXIT: \(exitCode)",
      "HANDOFF: written by LaneBay (shell). Last output:",
    ] + (tail.isEmpty ? ["  (no output)"] : tail)).joined(separator: "\n"))
  }

  /// Keeps a note within the handoff line budget.
  public static func clampNote(_ text: String) -> String {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var trimmed = Array(lines.prefix(maximumHandoffLines))
    while let last = trimmed.last, last.trimmingCharacters(in: .whitespaces).isEmpty { trimmed.removeLast() }
    return trimmed.joined(separator: "\n") + "\n"
  }

  /// Strips ANSI escape sequences and control characters from terminal output.
  public static func plainText(_ text: String) -> String {
    let pattern = "\u{1B}\\[[0-?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]"
    let stripped = (try? NSRegularExpression(pattern: pattern)).map {
      $0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    } ?? text
    return String(stripped.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.value >= 0x20 && $0.value != 0x7F }
      .map(Character.init))
  }

  /// The note LaneBay writes when the agent did not write one (timeout, exit or stop).
  /// TUI frames are box art and cursor jumps, not lines. Keep the runs of words.
  static func readableLines(_ text: String) -> [String] {
    let flattened = String(text.unicodeScalars.map { scalar -> Character in
      let art = (0x2500...0x259F).contains(scalar.value) || scalar.value == 0xFFFD
      return art ? " " : Character(scalar)
    })
    return flattened.components(separatedBy: "\n")
      .flatMap { $0.components(separatedBy: "   ") }
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { line in line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 2 }
  }

  public static func fallbackNote(outcome: AgentTaskState, task: String, output: String?) -> String {
    let lines = readableLines(plainText(output ?? ""))
    let tail = lines.suffix(maximumHandoffLines - 4).map { "  \($0.prefix(160))" }
    let result: String = switch outcome {
    case .timedOut: "RESULT: timed out"
    case .stopped: "RESULT: stopped"
    case .exited: "RESULT: agent exited without a note"
    default: "RESULT: \(outcome.rawValue)"
    }
    return clampNote(([result, "TASK: \(task.prefix(200))", "HANDOFF: written by LaneBay. Last output:"] + tail).joined(separator: "\n"))
  }
}

public enum AgentTaskState: String, Codable, Sendable, Equatable {
  case starting, running, done, timedOut, stopped, exited, failed

  public var isFinal: Bool { ![.starting, .running].contains(self) }

  public var title: String {
    switch self {
    case .starting: "Starting"
    case .running: "Running"
    case .done: "Done"
    case .timedOut: "TimedOut"
    case .stopped: "Stopped"
    case .exited: "Exited"
    case .failed: "Failed"
    }
  }
}

public struct AgentSpawnRequest: Sendable, Equatable {
  public var provider: String
  public var cwd: URL
  public var task: String
  public var timeout: TimeInterval
  public var contextFile: URL?

  public init(provider: String, cwd: URL, task: String, timeout: TimeInterval = AgentTaskContract.defaultTimeout, contextFile: URL? = nil) {
    self.provider = provider
    self.cwd = cwd
    self.task = task
    self.timeout = timeout
    self.contextFile = contextFile
  }
}

public enum AgentSpawnError: Error, LocalizedError, Equatable {
  case emptyTask
  case taskTooLong(Int)
  case invalidTimeout
  case directoryMissing(String)
  case contextUnreadable(String)
  case contextTooLarge(Int)
  case unknownProvider(String)
  case providerNotInstalled(String)

  public var errorDescription: String? {
    switch self {
    case .emptyTask: "Task is empty."
    case let .taskTooLong(count):
      "Task is \(count) characters; the limit is \(AgentTaskContract.maximumTaskCharacters). Split it into shorter tasks or move detail into --context."
    case .invalidTimeout: "Timeout must be between 1 second and 3 hours."
    case let .directoryMissing(path): "Working directory does not exist: \(path)"
    case let .contextUnreadable(path): "Context file cannot be read: \(path)"
    case let .contextTooLarge(limit): "Context file exceeds \(limit) bytes."
    case let .unknownProvider(id): "Unknown provider '\(id)'."
    case let .providerNotInstalled(id): "Provider '\(id)' is not installed on this Mac."
    }
  }
}

public struct AgentTaskRecord: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var nodeID: UUID
  public var provider: String
  public var cwd: String
  public var task: String
  public var startedAt: Date
  public var deadline: Date
  public var state: AgentTaskState
  public var taskFile: String
  public var handoffFile: String
  public var finishedAt: Date?

  public init(id: String, nodeID: UUID, provider: String, cwd: String, task: String, startedAt: Date, deadline: Date,
              state: AgentTaskState, taskFile: String, handoffFile: String, finishedAt: Date? = nil) {
    self.id = id
    self.nodeID = nodeID
    self.provider = provider
    self.cwd = cwd
    self.task = task
    self.startedAt = startedAt
    self.deadline = deadline
    self.state = state
    self.taskFile = taskFile
    self.handoffFile = handoffFile
    self.finishedAt = finishedAt
  }

  public func remaining(now: Date) -> TimeInterval { max(0, deadline.timeIntervalSince(now)) }

  /// `mm:ss` or `h:mm:ss` until the deadline.
  public static func countdown(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded(.down))
    let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
  }
}

/// Validates spawn requests and writes the handoff files. No process work happens here.
public struct AgentTaskFiles: Sendable {
  public init() {}

  public func validate(_ request: AgentSpawnRequest) throws -> String? {
    let task = request.task.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !task.isEmpty else { throw AgentSpawnError.emptyTask }
    guard task.count <= AgentTaskContract.maximumTaskCharacters else { throw AgentSpawnError.taskTooLong(task.count) }
    guard request.timeout.isFinite, request.timeout >= 1, request.timeout <= AgentTaskContract.maximumTimeout else {
      throw AgentSpawnError.invalidTimeout
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: request.cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw AgentSpawnError.directoryMissing(request.cwd.path)
    }
    guard let contextFile = request.contextFile else { return nil }
    guard let data = try? Data(contentsOf: contextFile) else { throw AgentSpawnError.contextUnreadable(contextFile.path) }
    guard data.count <= AgentTaskContract.maximumContextBytes else {
      throw AgentSpawnError.contextTooLarge(AgentTaskContract.maximumContextBytes)
    }
    return String(decoding: data, as: UTF8.self)
  }

  /// Writes `<cwd>/.lanebay/handoffs/<id>.task.md` with the task, the context and the note contract.
  @discardableResult
  public func writeTask(id: String, request: AgentSpawnRequest, context: String?, startedAt: Date) throws -> URL {
    let directory = AgentTaskContract.handoffDirectory(cwd: request.cwd)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = AgentTaskContract.taskFile(cwd: request.cwd, id: id)
    let handoff = AgentTaskContract.handoffFile(cwd: request.cwd, id: id)
    var body = "# LaneBay task \(id)\n\n"
    body += "- Provider: \(request.provider)\n- Started: \(ISO8601DateFormatter().string(from: startedAt))\n"
    body += "- Timeout: \(Int(request.timeout / 60)) min\n- Handoff note: \(handoff.path)\n\n"
    body += "## Task\n\n\(request.task.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
    if let context, !context.isEmpty { body += "## Context\n\n\(context)\n\n" }
    body += "## When you finish\n\nWrite at most \(AgentTaskContract.maximumHandoffLines) lines to the handoff note: "
    body += "`RESULT: done|partial|blocked`, what you did, files touched, open issues, and the next short task.\n"
    try Data(body.utf8).write(to: url, options: .atomic)
    return url
  }

  /// Writes the fallback note unless the agent already wrote one. Existing notes are clamped to the line budget.
  @discardableResult
  public func finalize(record: AgentTaskRecord, outcome: AgentTaskState, output: String?) throws -> URL {
    let url = URL(fileURLWithPath: record.handoffFile)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let existing = try? String(contentsOf: url, encoding: .utf8), !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let clamped = AgentTaskContract.clampNote(existing)
      if clamped != existing { try Data(clamped.utf8).write(to: url, options: .atomic) }
      return url
    }
    let note = AgentTaskContract.fallbackNote(outcome: outcome, task: record.task, output: output)
    try Data(note.utf8).write(to: url, options: .atomic)
    return url
  }

  public func handoffExists(_ record: AgentTaskRecord) -> Bool {
    guard let text = try? String(contentsOfFile: record.handoffFile, encoding: .utf8) else { return false }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// What a running task should become on a tick.
public enum AgentTaskTransition {
  public static func next(state: AgentTaskState, now: Date, deadline: Date, handoffWritten: Bool, processRunning: Bool) -> AgentTaskState {
    guard !state.isFinal else { return state }
    if handoffWritten { return .done }
    if now >= deadline { return .timedOut }
    if state == .running, !processRunning { return .exited }
    return state
  }
}
