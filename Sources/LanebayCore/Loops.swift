import Foundation

public enum LoopTrigger: Codable, Sendable, Equatable {
    case idle
    case outputMatch(pattern: String)
    case schedule(intervalSeconds: Int)
    case goalCheck(intervalSeconds: Int, goal: String)
}

public struct Loop: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var targetNodeID: UUID
    public var prompt: String
    public var trigger: LoopTrigger
    public var maxIterations: Int
    public var isEnabled: Bool
    public var iterations: Int
    public var lastRunAt: Date?
    public var needsReview: Bool

    public init(id: UUID = UUID(), name: String = "Loop", targetNodeID: UUID, prompt: String, trigger: LoopTrigger, maxIterations: Int = 10, isEnabled: Bool = true, iterations: Int = 0, lastRunAt: Date? = nil, needsReview: Bool = false) {
        self.id = id; self.name = name; self.targetNodeID = targetNodeID; self.prompt = prompt
        self.trigger = trigger; self.maxIterations = max(1, min(1000, maxIterations))
        self.isEnabled = isEnabled; self.iterations = max(0, iterations); self.lastRunAt = lastRunAt; self.needsReview = needsReview
    }

    private enum CodingKeys: String, CodingKey { case id, name, targetNodeID, prompt, trigger, maxIterations, isEnabled, iterations, lastRunAt, needsReview }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Loop"
        targetNodeID = try values.decodeIfPresent(UUID.self, forKey: .targetNodeID) ?? UUID()
        prompt = try values.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        trigger = try values.decodeIfPresent(LoopTrigger.self, forKey: .trigger) ?? .idle
        maxIterations = try values.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 10
        iterations = try values.decodeIfPresent(Int.self, forKey: .iterations) ?? 0
        lastRunAt = try values.decodeIfPresent(Date.self, forKey: .lastRunAt)
        let requestedEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        let existingReview = try values.decodeIfPresent(Bool.self, forKey: .needsReview) ?? false
        let legacyRegex = Self.legacyRegexLookingPattern(trigger)
        needsReview = existingReview || legacyRegex
        isEnabled = requestedEnabled && !legacyRegex
        if requestedEnabled && LoopValidator.validate(self) != nil { isEnabled = false }
    }

    private static func legacyRegexLookingPattern(_ trigger: LoopTrigger) -> Bool {
        guard case let .outputMatch(pattern) = trigger else { return false }
        return pattern.rangeOfCharacter(from: CharacterSet(charactersIn: ".^$*+?{}[]()|\\")) != nil
    }
}

public enum LoopValidator {
    public static let maxPatternLength = 256
    public static let maxOutputBytes = 16_384
    public static let maxPromptLength = 8_192

    public static func validate(_ loop: Loop) -> String? {
        guard !loop.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Prompt is required." }
        guard loop.prompt.utf8.count <= maxPromptLength else { return "Prompt is too long." }
        guard (1...1000).contains(loop.maxIterations) else { return "Maximum iterations must be between 1 and 1000." }
        guard (0...loop.maxIterations).contains(loop.iterations) else { return "Iteration count is outside the configured limit." }
        switch loop.trigger {
        case .idle: return nil
        case let .outputMatch(pattern):
            guard !pattern.isEmpty, pattern.utf8.count <= maxPatternLength else { return "Output pattern must contain 1–256 bytes." }
            return nil
        case let .schedule(interval): return (1...2_592_000).contains(interval) ? nil : "Schedule interval must be between 1 second and 30 days."
        case let .goalCheck(interval, goal): return (1...2_592_000).contains(interval) && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "Goal checks need a goal and an interval between 1 second and 30 days."
        }
    }

    public static func matches(_ pattern: String, output: String) -> Bool {
        hasMatch(pattern, output: output, afterByteCount: 0)
    }

    /// Finds a literal match ending after the previously observed byte count.
    public static func hasNewMatch(_ pattern: String, output: String, previousByteCount: Int) -> Bool {
        hasMatch(pattern, output: output, afterByteCount: previousByteCount)
    }

    private static func hasMatch(_ pattern: String, output: String, afterByteCount: Int) -> Bool {
        guard pattern.utf8.count <= maxPatternLength else { return false }
        let outputBytes = Array(output.utf8.suffix(maxOutputBytes))
        let patternBytes = Array(pattern.utf8)
        guard !patternBytes.isEmpty, patternBytes.count <= outputBytes.count else { return false }
        let previousCount = min(max(0, afterByteCount), outputBytes.count)
        var prefix = Array(repeating: 0, count: patternBytes.count)
        if patternBytes.count > 1 {
            var matched = 0
            for index in 1..<patternBytes.count {
                while matched > 0 && patternBytes[index] != patternBytes[matched] { matched = prefix[matched - 1] }
                if patternBytes[index] == patternBytes[matched] { matched += 1 }
                prefix[index] = matched
            }
        }
        var matched = 0
        for (index, byte) in outputBytes.enumerated() {
            while matched > 0 && byte != patternBytes[matched] { matched = prefix[matched - 1] }
            if byte == patternBytes[matched] { matched += 1 }
            if matched == patternBytes.count {
                if index + 1 > previousCount { return true }
                matched = prefix[matched - 1]
            }
        }
        return false
    }

    public static func boundedUTF8Suffix(_ value: String, limit: Int) -> String {
        var bytes = Array(value.utf8.suffix(max(0, limit)))
        while !bytes.isEmpty {
            if let decoded = String(bytes: bytes, encoding: .utf8) { return decoded }
            bytes.removeFirst()
        }
        return ""
    }
}
