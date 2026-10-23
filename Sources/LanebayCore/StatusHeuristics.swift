import Foundation

public enum InferredAgentStatus: Sendable, Equatable {
    case running, waitingForInput, idle
}

/// Fallback status inference for agents that do not provide hook events.
public struct StatusHeuristics: Sendable {
    public struct Rules: Sendable {
        public var quietPeriod: Duration
        public var promptPatterns: [String]
        public var permissionPatterns: [String]

        public init(
            quietPeriod: Duration = .seconds(2),
            promptPatterns: [String] = [
                #"(?:\$|❯|›|>|➜|▶|→|»|λ)\s*$"#,
                #"(?:^|\s)[#%]\s*$"#,
            ],
            permissionPatterns: [String] = [
                #"(?i)\b(?:allow|approve|permit)\b.{0,48}\b(?:tool|command|action|access)\b"#,
                #"(?i)\b(?:yes|no)\s*\(\s*(?:allow|deny)\s*\)"#,
                #"(?i)\bpermission required\b"#,
                #"(?i)\bwaiting for your approval\b"#,
                #"(?i)\b(?:press|type)\s+(?:enter|return)\s+to\s+(?:continue|proceed)\b"#,
                #"(?i)\b(?:password|passphrase)\s*:\s*$"#,
                #"(?i)\b(?:enter|type|input)\b[^:\n]{0,48}:\s*$"#,
                #"(?i)[\[(]\s*y\s*/\s*n\s*[\])]"#,
                #"(?i)[\[(]\s*yes\s*/\s*no\s*[\])]"#,
            ]
        ) {
            self.quietPeriod = quietPeriod
            self.promptPatterns = promptPatterns
            self.permissionPatterns = permissionPatterns
        }
    }

    private let rules: Rules
    private var lastOutputAt: ContinuousClock.Instant?
    /// Glyphs that end a shell prompt. `%` and `#` are handled separately so `100%` stays running.
    private static let promptGlyphs: Set<Character> = ["$", ">", "❯", "›", "➜", "▶", "→", "»", "λ", "❱", "\u{E0B0}"]

    public init(rules: Rules = Rules()) { self.rules = rules }

    /// Returns `.waitingForInput` for an input or permission prompt, `.idle` for a quiet
    /// shell prompt, and `.running` otherwise.
    ///
    /// `blockingCommand` is the line or command submitted with Enter. A quiet prompt that
    /// still shows that command is the shell running it, not an idle prompt. A blank Enter
    /// passes the prompt line itself; seeing that same line again means the shell came back.
    public mutating func infer(
        from text: String,
        now: ContinuousClock.Instant = .now,
        blockingCommand: String? = nil
    ) -> InferredAgentStatus {
        let line = Self.visibleTailLine(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .running }
        if matches(line, patterns: rules.permissionPatterns) { return .waitingForInput }
        guard let lastOutputAt, lastOutputAt.duration(to: now) >= rules.quietPeriod else { return .running }
        guard isIdlePrompt(line, blockingCommand: blockingCommand) else { return .running }
        return .idle
    }

    public mutating func receivedOutput(at instant: ContinuousClock.Instant = .now) {
        lastOutputAt = instant
    }

    /// Last visible row after control sequences and carriage-return rewrites. Capped so a burst cannot feed an unbounded match.
    public static func visibleTailLine(_ text: String) -> String {
        let stripped = stripControls(String(text.suffix(8_192)))
        let lines = stripped.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            let segment = String(line.split(separator: "\r", omittingEmptySubsequences: false).last ?? Substring())
            if !segment.trimmingCharacters(in: .whitespaces).isEmpty {
                return String(segment.suffix(512))
            }
        }
        return ""
    }

    private func isIdlePrompt(_ line: String, blockingCommand: String?) -> Bool {
        let shaped = Self.endsWithTerminator(line) || Self.startsWithGlyph(line) || matches(line, patterns: rules.promptPatterns)
        guard shaped else { return false }
        guard let blockingCommand else { return true }
        let command = blockingCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return Self.endsWithTerminator(line) }
        guard line.contains(command) else { return true }
        return Self.endsWithTerminator(command) && line == command
    }

    private func matches(_ text: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func endsWithTerminator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        if last == "%" || last == "#" {
            if trimmed.count == 1 { return true }
            let previous = trimmed[trimmed.index(trimmed.endIndex, offsetBy: -2)]
            return previous.isWhitespace
        }
        return promptGlyphs.contains(last)
    }

    private static func startsWithGlyph(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        if first == "%" || first == "#" {
            return trimmed.dropFirst().allSatisfy(\.isWhitespace)
        }
        return promptGlyphs.contains(first)
    }

    /// Terminal text with control sequences removed, for a transcript that a person can read.
    public static func readable(_ text: String) -> String {
        stripControls(text)
    }

    /// Ignore retained history and terminal controls. Only the current row can describe the prompt.
    private static func stripControls(_ text: String) -> String {
        let csiPattern = #"\x{001B}\[[0-?]*[ -/]*[@-~]"#
        let oscPattern = #"\x{001B}\][^\x{0007}]*(?:\x{0007}|\x{001B}\\)"#
        let withoutCSI = text.replacingOccurrences(of: csiPattern, with: "", options: .regularExpression)
        let withoutOSC = withoutCSI.replacingOccurrences(of: oscPattern, with: "", options: .regularExpression)
        return String(withoutOSC.unicodeScalars.filter { scalar in
            scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D || scalar.value >= 0x20
        }.map(Character.init))
    }
}
