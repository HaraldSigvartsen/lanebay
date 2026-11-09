import XCTest
import LanebayUI

final class VerktoyPanelsTests: XCTestCase {
    func testEveryVerktoyPanelDeclaresEmptyStateCopy() {
        let titles = [
            ChatPanel.emptyStateTitle,
            CodePanel.emptyStateTitle,
            DocsPanel.emptyStateTitle,
            MarkdownPanel.emptyStateTitle,
            MemoryPanel.emptyStateTitle,
            SkillsPanel.emptyStateTitle,
            PresetsPanel.emptyStateTitle,
        ]

        XCTAssertEqual(titles.count, 7)
        XCTAssertEqual(Set(titles).count, titles.count, "Every panel needs its own empty-state copy")
        for title in titles {
            XCTAssertFalse(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(title.hasPrefix("Ingen"), "Empty-state copy is Norwegian: \(title)")
        }
        XCTAssertEqual(MemoryPanel.emptyStateTitle, "Ingen minner ennå")
    }
}
