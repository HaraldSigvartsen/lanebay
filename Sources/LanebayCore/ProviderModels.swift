import Foundation

/// Model flags and suggested model names for the CLIs Lanebay can launch.
/// freebuff has no model flag: its model is chosen inside its own TUI with `/model`.
public enum ProviderModels {
    public static let modelArgumentLimit = 128
    private static let allowedModelCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/@-+")

    public static func modelFlag(for agentID: String) -> String? {
        switch agentID {
        case "opencode", "codex": "-m"
        case "claude", "cursor-agent": "--model"
        default: nil
        }
    }

    /// Verified from codex-cli 0.164's `~/.codex/models_cache.json` (`visibility == "list"`).
    public static let codexFallbackModels = [
        "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
    ]

    /// The cache the Codex CLI keeps next to its config.
    public static var codexModelsCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
    }

    /// Parses Codex's model cache (`{"models":[{"slug","visibility","priority"}]}`).
    /// Keeps only `visibility == "list"` entries, ordered by `priority`; nil when nothing is usable.
    public static func codexModels(fromCacheAt url: URL) -> [String]? {
        struct Cache: Decodable {
            struct Model: Decodable {
                let slug: String
                let visibility: String?
                let priority: Int?
            }
            let models: [Model]
        }
        guard let data = try? Data(contentsOf: url),
            let cache = try? JSONDecoder().decode(Cache.self, from: data)
        else { return nil }
        let listed = cache.models.enumerated()
            .filter { $0.element.visibility == "list" }
            .sorted { lhs, rhs in
                let left = lhs.element.priority ?? Int.max
                let right = rhs.element.priority ?? Int.max
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map { $0.element.slug.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isAcceptableModel($0) }
        return listed.isEmpty ? nil : listed
    }

    public static func suggestions(for agentID: String) -> [String] {
        switch agentID {
        case "opencode":
            ["opencode/big-pickle", "opencode/deepseek-v4.1-flash-free", "opencode/flint-40b-free", "opencode/beam-free"]
        case "codex":
            codexModels(fromCacheAt: codexModelsCacheURL) ?? codexFallbackModels
        case "claude":
            ["sonnet", "opus", "haiku"]
        case "cursor-agent":
            ["auto"]
        default:
            []
        }
    }

    public static func supportsModel(_ agentID: String) -> Bool {
        modelFlag(for: agentID) != nil
    }

    /// A literal argument value: 1...128 characters from A-Z a-z 0-9 . _ : / @ - +
    public static func isAcceptableModel(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= modelArgumentLimit else { return false }
        return s.unicodeScalars.allSatisfy { allowedModelCharacters.contains($0) }
    }

    /// Appends `flag model` only when the agent has a model flag and the trimmed model is acceptable.
    public static func launchArguments(base: [String], agentID: String, model: String?) -> [String] {
        guard let flag = modelFlag(for: agentID), let model else { return base }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAcceptableModel(trimmed) else { return base }
        return base + [flag, trimmed]
    }
}
