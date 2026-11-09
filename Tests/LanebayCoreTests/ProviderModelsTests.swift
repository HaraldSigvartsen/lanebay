import Foundation
import XCTest
@testable import LanebayCore

final class ProviderModelsTests: XCTestCase {
    func testModelFlagMappingAndSupport() {
        XCTAssertEqual(ProviderModels.modelFlag(for: "opencode"), "-m")
        XCTAssertEqual(ProviderModels.modelFlag(for: "codex"), "-m")
        XCTAssertEqual(ProviderModels.modelFlag(for: "claude"), "--model")
        XCTAssertEqual(ProviderModels.modelFlag(for: "cursor-agent"), "--model")
        XCTAssertNil(ProviderModels.modelFlag(for: "freebuff"))
        XCTAssertNil(ProviderModels.modelFlag(for: "shell"))
        XCTAssertTrue(ProviderModels.supportsModel("opencode"))
        XCTAssertTrue(ProviderModels.supportsModel("codex"))
        XCTAssertTrue(ProviderModels.supportsModel("claude"))
        XCTAssertTrue(ProviderModels.supportsModel("cursor-agent"))
        XCTAssertFalse(ProviderModels.supportsModel("freebuff"))
        XCTAssertFalse(ProviderModels.supportsModel("shell"))
    }

    func testSuggestions() {
        XCTAssertEqual(
            ProviderModels.suggestions(for: "opencode"),
            ["opencode/big-pickle", "opencode/deepseek-v4.1-flash-free", "opencode/flint-40b-free", "opencode/beam-free"])
        let codex = ProviderModels.suggestions(for: "codex")
        XCTAssertFalse(codex.isEmpty)
        XCTAssertTrue(codex.allSatisfy(ProviderModels.isAcceptableModel))
        if !FileManager.default.fileExists(atPath: ProviderModels.codexModelsCacheURL.path) {
            XCTAssertEqual(codex, ProviderModels.codexFallbackModels)
        }
        XCTAssertEqual(ProviderModels.suggestions(for: "claude"), ["sonnet", "opus", "haiku"])
        XCTAssertEqual(ProviderModels.suggestions(for: "cursor-agent"), ["auto"])
        XCTAssertTrue(ProviderModels.suggestions(for: "freebuff").isEmpty)
        XCTAssertTrue(ProviderModels.suggestions(for: "shell").isEmpty)
    }

    func testCodexModelsPrefersTheCacheOrderedByPriority() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-models-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
            {"models":[
              {"slug":"gpt-6.1-sol","visibility":"list","priority":1},
              {"slug":"gpt-6-astra","visibility":"list","priority":3},
              {"slug":"gpt-6.1-terra","visibility":"list","priority":2},
              {"slug":"internal-only","visibility":"hidden","priority":0}
            ]}
            """
        try Data(json.utf8).write(to: url)
        XCTAssertEqual(
            ProviderModels.codexModels(fromCacheAt: url),
            ["gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-astra"])
    }

    func testCodexModelsReturnsNilForUnusableCache() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-models-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(ProviderModels.codexModels(fromCacheAt: url))
        try Data(#"{"models":[]}"#.utf8).write(to: url)
        XCTAssertNil(ProviderModels.codexModels(fromCacheAt: url))
        try Data(#"{"models":[{"slug":"x","visibility":"hidden"}]}"#.utf8).write(to: url)
        XCTAssertNil(ProviderModels.codexModels(fromCacheAt: url))
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(ProviderModels.codexModels(fromCacheAt: url))
    }

    func testIsAcceptableModel() {
        XCTAssertTrue(ProviderModels.isAcceptableModel("sonnet"))
        XCTAssertTrue(ProviderModels.isAcceptableModel("opencode/deepseek-v4.1-flash-free"))
        XCTAssertTrue(ProviderModels.isAcceptableModel("gpt-5.1-codex"))
        XCTAssertTrue(ProviderModels.isAcceptableModel("vendor.model:v2@beta+1_2"))
        XCTAssertFalse(ProviderModels.isAcceptableModel(""))
        XCTAssertFalse(ProviderModels.isAcceptableModel("a b"))
        XCTAssertFalse(ProviderModels.isAcceptableModel("x;rm"))
        XCTAssertFalse(ProviderModels.isAcceptableModel("model\n"))
        XCTAssertFalse(ProviderModels.isAcceptableModel(String(repeating: "a", count: 129)))
        XCTAssertTrue(ProviderModels.isAcceptableModel(String(repeating: "a", count: 128)))
    }

    func testLaunchArguments() {
        XCTAssertEqual(
            ProviderModels.launchArguments(base: [], agentID: "opencode", model: "opencode/big-pickle"),
            ["-m", "opencode/big-pickle"])
        XCTAssertEqual(
            ProviderModels.launchArguments(base: [], agentID: "codex", model: " gpt-5.1 "),
            ["-m", "gpt-5.1"])
        XCTAssertEqual(
            ProviderModels.launchArguments(base: [], agentID: "claude", model: "sonnet"),
            ["--model", "sonnet"])
        XCTAssertEqual(
            ProviderModels.launchArguments(base: ["--resume"], agentID: "cursor-agent", model: "auto"),
            ["--resume", "--model", "auto"])
        XCTAssertEqual(
            ProviderModels.launchArguments(base: ["--flag"], agentID: "freebuff", model: "gpt-5.1"),
            ["--flag"])
        XCTAssertEqual(
            ProviderModels.launchArguments(base: ["--flag"], agentID: "shell", model: "sonnet"),
            ["--flag"])
        XCTAssertEqual(
            ProviderModels.launchArguments(base: ["--flag"], agentID: "opencode", model: nil),
            ["--flag"])
        XCTAssertEqual(
            ProviderModels.launchArguments(base: ["--flag"], agentID: "opencode", model: ""),
            ["--flag"])
        XCTAssertEqual(
            ProviderModels.launchArguments(base: ["--flag"], agentID: "opencode", model: "a b"),
            ["--flag"])
        XCTAssertEqual(
            ProviderModels.launchArguments(base: ["--flag"], agentID: "claude", model: "x;rm"),
            ["--flag"])
    }

    func testNodeDecodesOldJSONWithoutModel() throws {
        let json = """
            {"id":"\(UUID().uuidString)","kind":"console","agentID":"claude","cwd":"file:\\/\\/\\/tmp","frame":{"x":0,"y":0,"w":480,"h":320},"title":"Claude Code","notStarted":true}
            """
        let node = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
        XCTAssertNil(node.model)
    }

    func testNodeRoundTripsModel() throws {
        let node = Node(
            kind: .console, agentID: "codex", cwd: URL(fileURLWithPath: "/tmp"),
            frame: NodeFrame(x: 0, y: 0, w: 480, h: 320), model: "gpt-5.1", title: "Codex")
        let decoded = try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(node))
        XCTAssertEqual(decoded.model, "gpt-5.1")
        let without = Node(
            kind: .console, cwd: URL(fileURLWithPath: "/tmp"),
            frame: NodeFrame(x: 0, y: 0, w: 480, h: 320), title: "Shell")
        XCTAssertNil(try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(without)).model)
    }

    func testDraftRemembersModelPerAgent() {
        let agents = [
            NewTerminalAgent(id: "shell", title: "Shell", isCustom: false),
            NewTerminalAgent(id: "codex", title: "Codex", isCustom: false),
            NewTerminalAgent(id: "claude", title: "Claude Code", isCustom: false),
        ]
        let draft = NewTerminalDraft(
            agents: agents, selectedAgentID: "codex", directories: [], selectedDirectoryPath: "",
            lastModels: ["codex": "gpt-5.1", "claude": "opus"])
        XCTAssertEqual(draft.selectedModel, "")
        let codex = draft.selectingAgent("codex")
        XCTAssertEqual(codex.selectedModel, "gpt-5.1")
        XCTAssertFalse(codex.modelSuggestions.isEmpty)
        XCTAssertTrue(codex.modelSuggestions.allSatisfy(ProviderModels.isAcceptableModel))
        XCTAssertTrue(codex.supportsModel)
        let claude = draft.selectingAgent("claude")
        XCTAssertEqual(claude.selectedModel, "opus")
        XCTAssertEqual(claude.selectingModel(" sonnet ").selectedModel, "sonnet")
        XCTAssertFalse(draft.selectingAgent("shell").supportsModel)
        XCTAssertTrue(draft.selectingAgent("shell").modelSuggestions.isEmpty)
        XCTAssertEqual(draft.selectingAgent("nope").selectedAgentID, "codex")
    }

    func testMakeStartsWithTheRememberedModelForTheSelectedAgent() {
        let draft = NewTerminalDraft.make(
            knownAgents: AgentCatalog.knownCLIs,
            customExecutables: [],
            lastUsedAgentID: "claude",
            recentDirectories: [],
            defaultDirectory: nil,
            homeDirectory: FileManager.default.temporaryDirectory,
            lastModels: ["claude": "opus", "codex": "gpt-5.1"]
        )
        XCTAssertEqual(draft.selectedAgentID, "claude")
        XCTAssertEqual(draft.selectedModel, "opus")
        XCTAssertEqual(draft.selectingAgent("codex").selectedModel, "gpt-5.1")
        XCTAssertEqual(draft.selectingAgent("shell").selectedModel, "")
    }

    func testPreferencesRoundTripsAndSanitizesLastModelByAgent() throws {
        let preferences = AppPreferences(lastModelByAgentID: [
            "codex": "gpt-5.1", "opencode": "opencode/big-pickle",
        ])
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.lastModelByAgentID, ["codex": "gpt-5.1", "opencode": "opencode/big-pickle"])

        let legacy = Data(#"{"version":3,"restoreLastWorkspace":true,"showNotifications":true}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(AppPreferences.self, from: legacy).lastModelByAgentID.isEmpty)

        let dirty = Data(
            #"{"version":3,"lastModelByAgentID":{"codex":"gpt-5.1","bad/key":"opus","claude":"x;rm","opencode":"a b"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: dirty).lastModelByAgentID, ["codex": "gpt-5.1"])
    }
}
