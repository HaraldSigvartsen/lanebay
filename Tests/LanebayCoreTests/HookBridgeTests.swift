import Foundation
import XCTest
@testable import LanebayCore

final class HookBridgeTests: XCTestCase {
    func testConfigInstallIsIdempotentAndUninstallPreservesThirdPartyHooks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude")
        let codex = root.appendingPathComponent("codex")
        let hooks = root.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let claudeURL = claude.appendingPathComponent("settings.json")
        let codexURL = codex.appendingPathComponent("hooks.json")
        try Data("{\n  \"theme\": \"dark\", \"hooks\": {\"PreToolUse\": [{\"matcher\": \"Bash\", \"hooks\": [{\"type\": \"command\", \"command\": \"third-party\"}]}]}\n}".utf8).write(to: claudeURL)
        try Data("{\"other\":true,\"hooks\":{\"PreToolUse\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"third-party\"}]}]}}".utf8).write(to: codexURL)
        let merger = ConfigMerger(claudeRoot: claude, codexRoot: codex, hooksRoot: hooks)
        try merger.install()
        let installedCodex = try JSONSerialization.jsonObject(with: Data(contentsOf: codexURL)) as! [String: Any]
        let codexHooks = installedCodex["hooks"] as! [String: Any]
        let preToolGroups = codexHooks["PreToolUse"] as! [[String: Any]]
        XCTAssertTrue(preToolGroups.allSatisfy { $0["matcher"] != nil && $0["hooks"] is [[String: Any]] })
        XCTAssertEqual((preToolGroups[0]["hooks"] as! [[String: Any]])[0]["command"] as? String, "third-party")
        let firstClaude = try Data(contentsOf: claudeURL)
        let firstCodex = try Data(contentsOf: codexURL)
        try merger.install()
        XCTAssertEqual(try Data(contentsOf: claudeURL), firstClaude)
        XCTAssertEqual(try Data(contentsOf: codexURL), firstCodex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeURL.appendingPathExtension("lanebay.bak").path))
        try merger.uninstall()
        let restoredClaude = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as! [String: Any]
        let restoredCodex = try JSONSerialization.jsonObject(with: Data(contentsOf: codexURL)) as! [String: Any]
        XCTAssertEqual(restoredClaude["theme"] as? String, "dark")
        XCTAssertEqual(restoredCodex["other"] as? Bool, true)
        XCTAssertFalse(String(decoding: try Data(contentsOf: claudeURL), as: UTF8.self).contains(ConfigMerger.marker))
        XCTAssertFalse(String(decoding: try Data(contentsOf: codexURL), as: UTF8.self).contains(ConfigMerger.marker))
        XCTAssertTrue(String(decoding: try Data(contentsOf: claudeURL), as: UTF8.self).contains("third-party"))
        XCTAssertTrue(String(decoding: try Data(contentsOf: codexURL), as: UTF8.self).contains("third-party"))
    }

    func testMalformedConfigIsRefusedAndReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude")
        let codex = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let file = claude.appendingPathComponent("settings.json")
        try Data("{oops".utf8).write(to: file)
        XCTAssertThrowsError(try ConfigMerger(claudeRoot: claude, codexRoot: codex, hooksRoot: root.appendingPathComponent("hooks")).install()) { error in
            guard case HookConfigError.malformed = error else { return XCTFail("Expected malformed config error, got \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("{oops".utf8))
    }

    func testEmptyConfigsInstallTwiceAndUninstallToEquivalentJSON() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude config", isDirectory: true)
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        let merger = ConfigMerger(claudeRoot: claude, codexRoot: codex, hooksRoot: root.appendingPathComponent("hooks"))
        try merger.install(); let onceClaude = try Data(contentsOf: claude.appendingPathComponent("settings.json")); let onceCodex = try Data(contentsOf: codex.appendingPathComponent("hooks.json"))
        try merger.install()
        XCTAssertEqual(try Data(contentsOf: claude.appendingPathComponent("settings.json")), onceClaude)
        XCTAssertEqual(try Data(contentsOf: codex.appendingPathComponent("hooks.json")), onceCodex)
        try merger.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.appendingPathComponent("settings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codex.appendingPathComponent("hooks.json").path))
    }

    func testHookScriptIsPrivateAndFailOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try HookScriptInstaller().install(to: root)
        let url = root.appendingPathComponent("lanebay-hook.sh")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("--max-time 1"))
    }

    func testRuntimeTokenFileIsPrivateBeforeAndAfterAtomicInstall() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try HookRuntimeFile.write(port: 50_000, token: "temporary-test-token", to: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("runtime.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testHookRequestParserAuthenticatesAndParsesTypedEvent() throws {
        let headers = "POST /hook/claude HTTP/1.1\r\nAuthorization: Bearer correct-token\r\nContent-Length: 91"
        let body = Data("{\"event\":\"preToolUse\",\"session_id\":\"s-1\",\"cwd\":\"/tmp\",\"tool_name\":\"Bash\"}".utf8)
        XCTAssertThrowsError(try HookRequestParser.parse(headers: headers, body: body, token: "wrong"))
        let parsed = try HookRequestParser.parse(headers: headers, body: body, token: "correct-token")
        XCTAssertEqual(parsed.agent, "claude")
        XCTAssertEqual(parsed.event, .preToolUse)
        XCTAssertEqual(parsed.sessionID, "s-1")
        XCTAssertEqual(parsed.cwd, "/tmp")
        XCTAssertEqual(parsed.payload["tool_name"], .string("Bash"))
        XCTAssertThrowsError(try HookRequestParser.parse(headers: "GET /hook/claude HTTP/1.1\r\nAuthorization: Bearer correct-token", body: body, token: "correct-token"))
        XCTAssertThrowsError(try HookRequestParser.parse(headers: headers, body: Data(repeating: 0, count: HookRequestParser.maximumBodySize + 1), token: "correct-token"))
        let negativeLength = "POST /hook/claude HTTP/1.1\r\nAuthorization: Bearer correct-token\r\nContent-Length: -1"
        XCTAssertThrowsError(try HookRequestParser.validateContentLength(negativeLength))
        XCTAssertTrue(ConstantTimeTokenComparison.matches("correct-token", token: "correct-token"))
        XCTAssertFalse(ConstantTimeTokenComparison.matches("incorrect-token", token: "correct-token"))
    }

    func testUninstallPreservesUntouchedEmptyCodexAndClaudeContainers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude"), codex = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let c = claude.appendingPathComponent("settings.json"), x = codex.appendingPathComponent("hooks.json")
        try Data("{\"hooks\":{\"Untouched\":[],\"PreToolUse\":[]}}".utf8).write(to: c)
        try Data("{\"hooks\":{\"Untouched\":{},\"PreToolUse\":[]}}".utf8).write(to: x)
        let merger = ConfigMerger(claudeRoot: claude, codexRoot: codex, hooksRoot: root.appendingPathComponent("hooks"))
        try merger.uninstall()
        let claudeResult = try JSONSerialization.jsonObject(with: Data(contentsOf: c)) as! [String: Any]
        let codexResult = try JSONSerialization.jsonObject(with: Data(contentsOf: x)) as! [String: Any]
        XCTAssertNotNil((claudeResult["hooks"] as! [String: Any])["Untouched"])
        XCTAssertNotNil((codexResult["hooks"] as! [String: Any])["Untouched"])
    }

    func testThirdPartyCommandContainingMarkerIsNotOwned() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let url = codex.appendingPathComponent("hooks.json")
        try Data("{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"third-party --label lanebay-managed-hook\"}]}]}}".utf8).write(to: url)
        try ConfigMerger(claudeRoot: root.appendingPathComponent("claude"), codexRoot: codex, hooksRoot: root.appendingPathComponent("hooks")).uninstall()
        let result = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(result.contains("third-party --label lanebay-managed-hook"))
    }

}
