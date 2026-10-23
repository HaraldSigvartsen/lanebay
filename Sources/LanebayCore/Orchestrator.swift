import Foundation

/// Built-in console that treats the other consoles as subagents.
/// Tool calls stay inside the app. Nothing here opens a socket or leaves the machine.
public enum OrchestratorKind {
    public static let agentID = "orchestrator"
    public static let title = "Orchestrator"
    public static let greeting = """
    Orchestrator ready. The other consoles are its subagents.
    list — names and status
    send <console> <text> — ask, then write that text
    read <console> — recent output
    wait <console> — hook stop, or idle
    summarize <console> — status and recent output
    """

    public static let maxSendUTF8 = 4_096
    public static let maxPendingApprovals = 8
}

public struct OrchestratorConsoleInfo: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var agentID: String
    public var status: String
    public var running: Bool

    public init(id: UUID, title: String, agentID: String, status: String, running: Bool) {
        self.id = id
        self.title = title
        self.agentID = agentID
        self.status = status
        self.running = running
    }
}

public enum OrchestratorCommand: Equatable, Sendable {
    case list
    case send(rest: String)
    case read(target: String)
    case wait(target: String)
    case summarize(target: String)
}

public enum OrchestratorCommandError: Equatable, Sendable, Error {
    case empty
    case unknown(String)
    case missingTarget
    case missingText
    case textTooLong
    case invalidText
    case ambiguousTarget

    public var message: String {
        switch self {
        case .empty:
            "Type list, send, read, wait, or summarize."
        case let .unknown(verb):
            "Unknown command \(verb)."
        case .missingTarget:
            "Name the console."
        case .missingText:
            "Include the text to send."
        case .textTooLong:
            "That text is too long."
        case .invalidText:
            "The text has to be a single line."
        case .ambiguousTarget:
            "That name matches more than one console."
        }
    }
}

public enum OrchestratorCommands {
    public static func parse(_ raw: String) -> Result<OrchestratorCommand, OrchestratorCommandError> {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .failure(.empty) }
        guard !line.contains("\0") else { return .failure(.invalidText) }
        let verbEnd = line.firstIndex(where: { $0 == " " || $0 == "\t" }) ?? line.endIndex
        let verb = String(line[..<verbEnd]).lowercased()
        let rest = line[verbEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        switch verb {
        case "list":
            guard rest.isEmpty else { return .failure(.unknown(verb)) }
            return .success(.list)
        case "send":
            guard !rest.isEmpty else { return .failure(.missingTarget) }
            return .success(.send(rest: rest))
        case "read":
            guard !rest.isEmpty else { return .failure(.missingTarget) }
            return .success(.read(target: rest))
        case "wait":
            guard !rest.isEmpty else { return .failure(.missingTarget) }
            return .success(.wait(target: rest))
        case "summarize":
            guard !rest.isEmpty else { return .failure(.missingTarget) }
            return .success(.summarize(target: rest))
        default:
            return .failure(.unknown(verb))
        }
    }

    /// Longest console title wins, so "Claude Code echo hi" stays one target.
    /// The text is kept literally: no quotes, variables, or extra commands are added.
    public static func splitSend(
        _ rest: String, titles: [String]
    ) -> Result<(target: String, text: String), OrchestratorCommandError> {
        let rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return .failure(.missingTarget) }
        let tokens = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if let first = tokens.first, UUID(uuidString: String(first)) != nil {
            guard tokens.count == 2 else { return .failure(.missingText) }
            let text = String(tokens[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            return validated(text).map { (String(first), $0) }
        }
        let ordered = titles.sorted { $0.count > $1.count }
        var matches: [(String, String)] = []
        for title in ordered where !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let prefix = title + " "
            guard rest.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            let text = String(rest.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            matches.append((title, text))
        }
        if let bestLength = matches.map(\.0.count).max() {
            let best = matches.filter { $0.0.count == bestLength }
            let names = Set(best.map { $0.0.lowercased() })
            if names.count > 1 { return .failure(.ambiguousTarget) }
            if names.count == 1, let choice = best.first {
                return validated(choice.1).map { (choice.0, $0) }
            }
        }
        guard tokens.count == 2 else { return .failure(.missingText) }
        let text = String(tokens[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return validated(text).map { (String(tokens[0]), $0) }
    }

    private static func validated(_ text: String) -> Result<String, OrchestratorCommandError> {
        guard !text.isEmpty else { return .failure(.missingText) }
        guard text.utf8.count <= OrchestratorKind.maxSendUTF8 else { return .failure(.textTooLong) }
        guard !text.contains("\0"), !text.contains("\n"), !text.contains("\r") else { return .failure(.invalidText) }
        return .success(text)
    }
}

public struct OrchestratorTargetError: Equatable, Sendable, Error {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public enum OrchestratorTargets {
    public static func resolve(query: String, consoles: [OrchestratorConsoleInfo]) -> Result<OrchestratorConsoleInfo, OrchestratorTargetError> {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .failure(OrchestratorTargetError("Name the console.")) }
        if let id = UUID(uuidString: query), let match = consoles.first(where: { $0.id == id }) {
            return .success(match)
        }
        let matches = consoles.filter {
            $0.title.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if matches.count == 1, let match = matches.first { return .success(match) }
        if matches.count > 1 { return .failure(OrchestratorTargetError("\(query) matches more than one console.")) }
        return .failure(OrchestratorTargetError("No console named \(query)."))
    }
}

public struct OrchestratorApprovalRequest: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var orchestratorID: UUID
    public var targetID: UUID
    public var targetTitle: String
    public var text: String
    public var linkID: UUID

    public init(
        id: UUID = UUID(),
        orchestratorID: UUID,
        targetID: UUID,
        targetTitle: String,
        text: String,
        linkID: UUID
    ) {
        self.id = id
        self.orchestratorID = orchestratorID
        self.targetID = targetID
        self.targetTitle = targetTitle
        self.text = text
        self.linkID = linkID
    }
}

public enum OrchestratorSendDecision: Equatable, Sendable {
    case needsApproval(OrchestratorApprovalRequest)
    case deliver(targetID: UUID, linkID: UUID, text: String)
    case rejected(String)
}

public enum OrchestratorSendGate {
    /// Default is to ask. A permission event is not an input here and cannot take the deliver path.
    public static func decide(
        orchestratorID: UUID,
        target: OrchestratorConsoleInfo,
        text: String,
        linkID: UUID,
        askBeforeSending: Bool
    ) -> OrchestratorSendDecision {
        if target.id == orchestratorID || target.agentID == OrchestratorKind.agentID {
            return .rejected("\(target.title) cannot take a task.")
        }
        guard target.running else { return .rejected("\(target.title) is not running.") }
        guard !text.isEmpty else { return .rejected("Include the text to send.") }
        if askBeforeSending {
            return .needsApproval(OrchestratorApprovalRequest(
                orchestratorID: orchestratorID,
                targetID: target.id,
                targetTitle: target.title,
                text: text,
                linkID: linkID
            ))
        }
        return .deliver(targetID: target.id, linkID: linkID, text: text)
    }
}

public enum OrchestratorLinkStatus: String, Equatable, Sendable {
    case pending, waiting, done, denied, failed

    public var label: String {
        switch self {
        case .pending: "Pending"
        case .waiting: "Waiting"
        case .done: "Finished"
        case .denied: "Denied"
        case .failed: "Failed"
        }
    }
}

public struct OrchestratorLink: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var orchestratorID: UUID
    public var targetID: UUID
    public var targetTitle: String
    public var status: OrchestratorLinkStatus

    public init(
        id: UUID = UUID(),
        orchestratorID: UUID,
        targetID: UUID,
        targetTitle: String,
        status: OrchestratorLinkStatus
    ) {
        self.id = id
        self.orchestratorID = orchestratorID
        self.targetID = targetID
        self.targetTitle = targetTitle
        self.status = status
    }
}

public struct OrchestratorLinkSegment: Equatable, Sendable {
    public var startX: Double
    public var startY: Double
    public var endX: Double
    public var endY: Double
    public var badgeX: Double
    public var badgeY: Double

    public init(startX: Double, startY: Double, endX: Double, endY: Double, badgeX: Double, badgeY: Double) {
        self.startX = startX
        self.startY = startY
        self.endX = endX
        self.endY = endY
        self.badgeX = badgeX
        self.badgeY = badgeY
    }
}

public enum OrchestratorLinkLayout {
    public static func segment(
        from source: NodeFrame,
        to target: NodeFrame,
        zoom: Double,
        panX: Double,
        panY: Double
    ) -> OrchestratorLinkSegment? {
        guard zoom.isFinite, zoom > 0, panX.isFinite, panY.isFinite else { return nil }
        let values = [source.x, source.y, source.w, source.h, target.x, target.y, target.w, target.h]
        guard values.allSatisfy(\.isFinite), source.w > 0, source.h > 0, target.w > 0, target.h > 0 else { return nil }
        let sourceMidY = (source.y + source.h / 2) * zoom + panY
        let targetMidY = (target.y + target.h / 2) * zoom + panY
        let sourceCenterX = (source.x + source.w / 2) * zoom + panX
        let targetCenterX = (target.x + target.w / 2) * zoom + panX
        let leftToRight = sourceCenterX <= targetCenterX
        let startX = (leftToRight ? source.x + source.w : source.x) * zoom + panX
        let endX = (leftToRight ? target.x : target.x + target.w) * zoom + panX
        return OrchestratorLinkSegment(
            startX: startX,
            startY: sourceMidY,
            endX: endX,
            endY: targetMidY,
            badgeX: (startX + endX) / 2,
            badgeY: (sourceMidY + targetMidY) / 2 - 18
        )
    }
}

public enum OrchestratorWaitReason: Equatable, Sendable {
    case hookStop
    case hookSubagentStop
    case idle
    case exited
}

public enum OrchestratorWait {
    /// A permission request never finishes the wait. The caller must not treat it as a yes.
    public static func consider(status: String, outputGrew: Bool, hook: AgentHookEvent?) -> OrchestratorWaitReason? {
        switch hook {
        case .permissionRequest:
            return nil
        case .stop:
            return .hookStop
        case .subagentStop:
            return .hookSubagentStop
        case .sessionEnd:
            return .exited
        default:
            break
        }
        switch status {
        case "finished", "done", "error": // legacy key: done
            return .exited
        case "idle", "resting": // legacy key: resting
            return outputGrew ? .idle : nil
        default:
            return nil
        }
    }
}

public enum OrchestratorSummary {
    public static let maxBytes = 1_200
    public static let maxLines = 12
    public static let readMaxBytes = 4_096
    public static let readMaxLines = 40

    public static func statusWord(_ status: String) -> String {
        switch status {
        case "running", "working": "Running" // legacy key: working
        case "waitingForInput", "needsYou": "Waiting for input" // legacy key: needsYou
        case "idle", "resting": "Idle" // legacy key: resting
        case "stopped", "paused": "Stopped" // legacy key: paused
        case "finished", "done": "Finished" // legacy key: done
        case "error": "Error"
        default: status
        }
    }

    public static func listLine(_ info: OrchestratorConsoleInfo) -> String {
        let motion = info.running ? "running" : "stopped"
        return "\(info.title) — \(statusWord(info.status)) — \(motion)"
    }

    public static func report(title: String, status: String, output: String, reason: OrchestratorWaitReason? = nil) -> String {
        let headline: String
        switch reason {
        case .hookStop:
            headline = "\(title) stopped."
        case .hookSubagentStop:
            headline = "\(title) subagent stopped."
        case .exited:
            headline = "\(title) finished."
        case .idle, nil:
            headline = "\(title) is \(statusWord(status))."
        }
        let tail = boundedTail(output, maxBytes: maxBytes, maxLines: maxLines)
        guard !tail.isEmpty else { return "\(headline) No output yet." }
        return "\(headline)\n\(tail)"
    }

    public static func readReport(title: String, output: String) -> String {
        let tail = boundedTail(output, maxBytes: readMaxBytes, maxLines: readMaxLines)
        guard !tail.isEmpty else { return "\(title) has no output yet." }
        return "\(title) output:\n\(tail)"
    }

    public static func boundedTail(_ output: String, maxBytes: Int, maxLines: Int) -> String {
        let readable = StatusHeuristics.readable(output)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n\r", with: "\n")
        let lines = readable.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let parts = line.split(separator: "\r", omittingEmptySubsequences: false)
            if let last = parts.last, !last.isEmpty { return String(last) }
            return String(parts.dropLast().last ?? Substring())
        }
        let kept = lines.suffix(max(0, maxLines)).joined(separator: "\n")
        return LoopValidator.boundedUTF8Suffix(kept, limit: max(0, maxBytes))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
