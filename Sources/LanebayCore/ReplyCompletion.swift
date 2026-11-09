import Foundation

/// Decides when a chat reply from a card is finished.
/// AI tools pause while they think, so they get a longer quiet window than a plain shell,
/// and a reply is never closed while the card still reports that it is working.
public enum ReplyCompletion {
    public static let shellQuiet: TimeInterval = 2.5
    public static let providerQuiet: TimeInterval = 10
    /// With a ready prompt visible, an AI card may finish a bit sooner.
    public static let providerQuietWithPrompt: TimeInterval = 4

    public static func isShell(_ agentID: String?) -> Bool {
        agentID == nil || agentID == "shell" || agentID == ""
    }

    public static func quietWindow(agentID: String?, promptVisible: Bool) -> TimeInterval {
        if isShell(agentID) { return shellQuiet }
        return promptVisible ? providerQuietWithPrompt : providerQuiet
    }

    /// True when the last visible line looks like an idle prompt (zsh/bash `%`/`$`/`#`, or an AI tool's input box).
    public static func promptVisible(tail: String) -> Bool {
        let cleaned = AgentTaskContract.plainText(tail)
        let lines = cleaned.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return false }
        if let end = last.last, "%$#❯›>".contains(end), last.count <= 120 { return true }
        let lower = last.lowercased()
        let readyHints = ["send a message", "ask anything", "type your message", "esc to interrupt"]
        // "esc to interrupt" means the tool is busy, never ready.
        if lower.contains("esc to interrupt") { return false }
        return readyHints.contains { lower.contains($0) } || lower.hasPrefix("›") || lower.hasPrefix("> ")
    }

    /// Text AI tools show while they work, and text they show when they wait for you.
    static let busyHints = ["esc to interrupt", "■ esc", "esc to cancel", "working (", "thinking…", "starting your model session", "esc: back to draft"]
    static let readyHints = [
        "end session", "new chat", "enter a coding task", "for help", "? for shortcuts", "ask codex",
        "send a message", "type your message", "ask anything",
    ]

    /// For full-screen AI tools the terminal status heuristic never sees a shell prompt, so it says
    /// "running" forever. Instead, compare where the latest busy hint and the latest ready hint appear.
    public static func providerBusy(tail: String) -> Bool {
        let text = AgentTaskContract.plainText(tail).lowercased()
        func lastIndex(_ hints: [String]) -> String.Index? {
            hints.compactMap { text.range(of: $0, options: .backwards)?.lowerBound }.max()
        }
        guard let busy = lastIndex(busyHints) else { return false }
        guard let ready = lastIndex(readyHints) else { return true }
        return busy > ready
    }

    /// An AI tool shows its "waiting for you" text (and nothing busy after it).
    /// Some tools rotate ads or timers while idle, so this lets them finish without a long silence.
    public static func providerReady(tail: String) -> Bool {
        let text = AgentTaskContract.plainText(tail).lowercased()
        return readyHints.contains { text.contains($0) } && !providerBusy(tail: tail)
    }

    /// Whether the card is still working: a shell uses its prompt status, an AI tool its own hints.
    public static func isWorking(agentID: String?, statusRunning: Bool, tail: String) -> Bool {
        isShell(agentID) ? statusRunning : providerBusy(tail: tail)
    }

    /// - Parameters:
    ///   - working: the card shows "Jobber" (status running).
    ///   - quietFor: seconds since the last output byte.
    ///   - newBytes: bytes printed since the message was sent.
    public static func isDone(agentID: String?, processRunning: Bool, working: Bool,
                              quietFor: TimeInterval, newBytes: Int, tail: String) -> Bool {
        if !processRunning { return true }
        if working { return false }
        guard newBytes > 0 else { return false }
        let ready = promptVisible(tail: tail) || (!isShell(agentID) && providerReady(tail: tail))
        return quietFor >= quietWindow(agentID: agentID, promptVisible: ready)
    }

    /// The answer an AI tool shows on screen: the lines after the last echo of what was sent,
    /// without the tool's footer, hints, ads and box borders. Empty when nothing is found.
    public static func screenReply(screen: String, sent: String?, maxLines: Int = 40) -> String {
        let lines = screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let sent = sent?.trimmingCharacters(in: .whitespacesAndNewlines), !sent.isEmpty else {
            return cleanReply(lines, maxLines: maxLines, sentEcho: nil)
        }
        // The prompt can echo the message in a footer too, so try each echo from the bottom up.
        let probe = String(sent.prefix(30)).lowercased()
        // Only a line that starts with the message counts as its echo (not "Chat: …" footers or a half-typed input row).
        let echoes = lines.indices.filter {
            var line = lines[$0]
            line = String(line.drop(while: { "❯›>│⏺●▌┃ ".contains($0) }))
            return line.lowercased().hasPrefix(probe)
        }
        for index in echoes.reversed() {
            let answer = cleanReply(Array(lines[(index + 1)...]), maxLines: maxLines, sentEcho: probe)
            if !answer.isEmpty { return answer }
        }
        return ""
    }

    /// Prefer a short final line when the screen still holds thinking / streak / ad chrome above the answer.
    public static func preferredAnswer(_ raw: String) -> String? {
        let lines = raw.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let noise = ["thinking", "streak", "hours remaining", "session active", "refer friends",
                     "starting your model", "suggest_followups", "trivial request", "the user says",
                     "so just reply", "i shouldn't", "just answer", "chat:", "change ·"]
        let clean = lines.filter { line in
            let lower = line.lowercased()
            return !noise.contains { lower.contains($0) }
        }
        if let last = clean.last, last.count <= 80 { return last }
        if let last = lines.last, last.count <= 40, !noise.contains(where: { last.lowercased().contains($0) }) {
            return last
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
    }

    static func cleanReply(_ lines: [String], maxLines: Int, sentEcho: String? = nil) -> String {
        let border = CharacterSet(charactersIn: "─│┌┐└┘├┤┬┴┼╭╮╯╰═║▀▄█▌▐░▒▓■□▪▫•·…-_=|+ ")
        let footer = readyHints + busyHints + ["/model", "for history", "ad [", "learn more", "context left", "tokens used", "hours remaining", "day streak", "session active", "refer friends", "get $"]
        let echo = sentEcho?.lowercased()
        var kept: [String] = []
        for raw in lines {
            var line = raw
            for prefix in ["❯ ", "› ", "> ", "│ ", "⏺ ", "● "] where line.hasPrefix(prefix) { line = String(line.dropFirst(prefix.count)) }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "│█▌▐┃ "))
            if line.contains("△▽") || line.hasPrefix("⎘") { continue }
            guard !line.isEmpty, !line.unicodeScalars.allSatisfy({ border.contains($0) }) else { continue }
            let lower = line.lowercased()
            if footer.contains(where: { lower.contains($0) }) { continue }
            if lower.hasPrefix("[") && lower.hasSuffix("]") && lower.count <= 12 { continue }  // [07:20 AM]
            if lower.contains("chat:") { continue }
            if let echo, lower.contains(echo) { continue }
            if lower.range(of: #"^[0-9.]+k \([0-9]+%\)"#, options: .regularExpression) != nil { continue }
            kept.append(line)
        }
        return kept.suffix(maxLines).joined(separator: "\n")
    }
}
