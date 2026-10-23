import Foundation

public struct PlannerPlan: Sendable, Equatable {
    public var actions: [PlannerAction]
    public init(actions: [PlannerAction]) {
        self.actions = actions
    }
}

public enum PlannerAction: Sendable, Equatable {
    case sendToConsole(nodeID: UUID, text: String)
    case broadcastToGroup(groupID: UUID, text: String)
    case createLoop(name: String, targetNodeID: UUID, prompt: String, trigger: LoopTrigger, maxIterations: Int)
    case startConsole(nodeID: UUID)
    case note(text: String)
}

public enum PlannerPlanValidationError: LocalizedError {
    case invalidJSON
    case topLevelObjectRequired
    case missingActions
    case invalidAction(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "Planner output is not valid JSON."
        case .topLevelObjectRequired:
            "Planner output must be a JSON object."
        case .missingActions:
            "Planner output must include an 'actions' array."
        case let .invalidAction(index, reason):
            "Action \(index + 1) is invalid: \(reason)"
        }
    }
}

public enum PlannerPlanValidator {
    public static func decodeStrict(from raw: String) throws -> PlannerPlan {
        guard let data = raw.data(using: .utf8) else {
            throw PlannerPlanValidationError.invalidJSON
        }
        return try decodeStrict(from: data)
    }

    public static func decodeStrict(from data: Data) throws -> PlannerPlan {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw PlannerPlanValidationError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw PlannerPlanValidationError.topLevelObjectRequired
        }
        guard Set(root.keys) == ["actions"] else {
            throw PlannerPlanValidationError.missingActions
        }
        guard let rawActions = root["actions"] as? [Any] else {
            throw PlannerPlanValidationError.missingActions
        }
        let actions = try rawActions.enumerated().map { index, raw in
            try parseAction(raw, index: index)
        }
        return PlannerPlan(actions: actions)
    }

    private static func parseAction(_ raw: Any, index: Int) throws -> PlannerAction {
        guard let payload = raw as? [String: Any] else {
            throw PlannerPlanValidationError.invalidAction(index, "Action must be an object.")
        }
        guard let type = payload["type"] as? String else {
            throw PlannerPlanValidationError.invalidAction(index, "Missing 'type'.")
        }
        switch type {
        case "sendToConsole":
            try ensureKeys(payload, allowed: ["type", "nodeID", "text"], index: index)
            guard let nodeID = parseUUID(payload["nodeID"]) else {
                throw PlannerPlanValidationError.invalidAction(index, "Invalid nodeID.")
            }
            guard let text = parseNonEmptyString(payload["text"]) else {
                throw PlannerPlanValidationError.invalidAction(index, "Text is required.")
            }
            return .sendToConsole(nodeID: nodeID, text: text)

        case "broadcastToGroup":
            try ensureKeys(payload, allowed: ["type", "groupID", "text"], index: index)
            guard let groupID = parseUUID(payload["groupID"]) else {
                throw PlannerPlanValidationError.invalidAction(index, "Invalid groupID.")
            }
            guard let text = parseNonEmptyString(payload["text"]) else {
                throw PlannerPlanValidationError.invalidAction(index, "Text is required.")
            }
            return .broadcastToGroup(groupID: groupID, text: text)

        case "createLoop":
            try ensureKeys(payload, allowed: ["type", "name", "targetNodeID", "prompt", "trigger", "maxIterations"], index: index)
            guard let name = parseNonEmptyString(payload["name"]) else {
                throw PlannerPlanValidationError.invalidAction(index, "Loop name is required.")
            }
            guard let targetNodeID = parseUUID(payload["targetNodeID"]) else {
                throw PlannerPlanValidationError.invalidAction(index, "Invalid targetNodeID.")
            }
            guard let prompt = parseNonEmptyString(payload["prompt"]) else {
                throw PlannerPlanValidationError.invalidAction(index, "Prompt is required.")
            }
            guard let triggerPayload = payload["trigger"] as? [String: Any] else {
                throw PlannerPlanValidationError.invalidAction(index, "Trigger object is required.")
            }
            let trigger = try parseTrigger(triggerPayload, actionIndex: index)
            let maxIterations = parseInt(payload["maxIterations"]) ?? 10
            guard (1...1000).contains(maxIterations) else {
                throw PlannerPlanValidationError.invalidAction(index, "maxIterations must be 1...1000.")
            }
            return .createLoop(
                name: name,
                targetNodeID: targetNodeID,
                prompt: prompt,
                trigger: trigger,
                maxIterations: maxIterations
            )

        case "startConsole":
            try ensureKeys(payload, allowed: ["type", "nodeID"], index: index)
            guard let nodeID = parseUUID(payload["nodeID"]) else {
                throw PlannerPlanValidationError.invalidAction(index, "Invalid nodeID.")
            }
            return .startConsole(nodeID: nodeID)

        case "note":
            try ensureKeys(payload, allowed: ["type", "text"], index: index)
            guard let text = parseNonEmptyString(payload["text"]) else {
                throw PlannerPlanValidationError.invalidAction(index, "Text is required.")
            }
            return .note(text: text)

        default:
            throw PlannerPlanValidationError.invalidAction(index, "Unsupported action type '\(type)'.")
        }
    }

    private static func parseTrigger(_ payload: [String: Any], actionIndex: Int) throws -> LoopTrigger {
        guard let type = payload["type"] as? String else {
            throw PlannerPlanValidationError.invalidAction(actionIndex, "Trigger missing type.")
        }
        switch type {
        case "idle":
            try ensureKeys(payload, allowed: ["type"], index: actionIndex)
            return .idle
        case "outputMatch":
            try ensureKeys(payload, allowed: ["type", "pattern"], index: actionIndex)
            guard let pattern = parseNonEmptyString(payload["pattern"]) else {
                throw PlannerPlanValidationError.invalidAction(actionIndex, "Output-match pattern is required.")
            }
            return .outputMatch(pattern: pattern)
        case "schedule":
            try ensureKeys(payload, allowed: ["type", "intervalSeconds"], index: actionIndex)
            guard let interval = parseInt(payload["intervalSeconds"]), (1...2_592_000).contains(interval) else {
                throw PlannerPlanValidationError.invalidAction(actionIndex, "Schedule interval must be 1...2592000.")
            }
            return .schedule(intervalSeconds: interval)
        case "goalCheck":
            try ensureKeys(payload, allowed: ["type", "intervalSeconds", "goal"], index: actionIndex)
            guard let interval = parseInt(payload["intervalSeconds"]), (1...2_592_000).contains(interval),
                  let goal = parseNonEmptyString(payload["goal"]) else {
                throw PlannerPlanValidationError.invalidAction(actionIndex, "Goal-check trigger requires goal and valid interval.")
            }
            return .goalCheck(intervalSeconds: interval, goal: goal)
        default:
            throw PlannerPlanValidationError.invalidAction(actionIndex, "Unsupported trigger type '\(type)'.")
        }
    }

    private static func ensureKeys(_ payload: [String: Any], allowed: Set<String>, index: Int) throws {
        let keys = Set(payload.keys)
        guard keys == allowed else {
            let unknown = keys.subtracting(allowed)
            let missing = allowed.subtracting(keys)
            let parts = [
                unknown.isEmpty ? nil : "unknown keys: \(unknown.sorted().joined(separator: ", "))",
                missing.isEmpty ? nil : "missing keys: \(missing.sorted().joined(separator: ", "))",
            ].compactMap { $0 }
            throw PlannerPlanValidationError.invalidAction(index, parts.joined(separator: "; "))
        }
    }

    private static func parseUUID(_ value: Any?) -> UUID? {
        guard let string = value as? String else { return nil }
        return UUID(uuidString: string)
    }

    private static func parseNonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : string
    }

    private static func parseInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let int = Int(string) { return int }
        return nil
    }
}
