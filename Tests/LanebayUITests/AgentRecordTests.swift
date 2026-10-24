import XCTest

/// LOOP.md "Mandatory verification": every `agent/screens/<timestamp>` cited in the
/// agent notes must resolve against the working tree (snapshots are local, git-ignored evidence).
final class AgentRecordTests: XCTestCase {
    func testCitedScreenDirectoriesExist() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: "agent/screens/[0-9]{8}-[0-9]{6}")
        var cited: Set<String> = []
        for note in ["agent/BACKLOG.md", "agent/PROGRESS.md"] {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(note), encoding: .utf8)
            pattern.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
                if let match, let range = Range(match.range, in: text) {
                    cited.insert(String(text[range]))
                }
            }
        }
        XCTAssertFalse(cited.isEmpty, "agent notes must keep citing self-test evidence")
        for path in cited.sorted() {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: repoRoot.appendingPathComponent(path).path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue,
                "\(path) is cited in agent/BACKLOG.md or agent/PROGRESS.md but is missing on disk"
            )
        }
    }
}
