import AppKit
import LanebayCore
import XCTest

@testable import LanebayUI

final class BoardLayoutTests: XCTestCase {
  private func stacked(_ count: Int) -> [BoardLayout.Item] {
    (0..<count).map { _ in BoardLayout.Item(id: UUID(), frame: NodeFrame(x: 40, y: 40, w: 420, h: 300)) }
  }

  func testTidyRemovesOverlapAndKeepsSizes() {
    let items = stacked(5)
    XCTAssertTrue(BoardLayout.overlaps(items.map(\.frame)))
    let result = BoardLayout.tidy(items, viewportWidth: 1400)
    let frames = items.compactMap { result[$0.id] }
    XCTAssertEqual(frames.count, 5)
    XCTAssertFalse(BoardLayout.overlaps(frames))
    XCTAssertTrue(frames.allSatisfy { $0.w == 420 && $0.h == 300 })
    XCTAssertTrue(frames.allSatisfy { $0.x >= 0 && $0.y >= 0 })
  }

  func testConsoleCardsKeepATerminalFriendlyMinimumWidth() {
    XCTAssertGreaterThanOrEqual(BoardLayout.minimumConsoleWidth, 420)
    XCTAssertGreaterThan(BoardLayout.minimumConsoleHeight, BoardLayout.compactHeight)
  }

  func testColumnCountFollowsViewport() {
    XCTAssertEqual(BoardLayout.columnCount(widths: [420, 420, 420], viewportWidth: 1400), 3)
    XCTAssertEqual(BoardLayout.columnCount(widths: [420, 420, 420], viewportWidth: 500), 1)
  }

  func testTidyIsStableForTheSameOrder() {
    let items = stacked(4)
    let first = BoardLayout.tidy(items, viewportWidth: 1200)
    XCTAssertEqual(first, BoardLayout.tidy(items, viewportWidth: 1200))
    // First item lands top-left.
    XCTAssertEqual(first[items[0].id]?.x, 24)
    XCTAssertEqual(first[items[0].id]?.y, 24)
  }

  func testCompactLayoutHeightPacksTighter() {
    let id = UUID()
    let below = UUID()
    let items = [
      BoardLayout.Item(id: id, frame: NodeFrame(x: 0, y: 0, w: 420, h: 300), layoutHeight: BoardLayout.compactHeight),
      BoardLayout.Item(id: below, frame: NodeFrame(x: 0, y: 0, w: 420, h: 300)),
    ]
    let result = BoardLayout.tidy(items, viewportWidth: 480)
    XCTAssertEqual(result[below]?.y ?? 0, 24 + BoardLayout.compactHeight + 24, accuracy: 0.5)
  }

  func testLooseLayoutIsDetectedAndTopMarginLeavesRoomForGroupHeaders() {
    let a = UUID(), b = UUID()
    let items = [
      BoardLayout.Item(id: a, frame: NodeFrame(x: 24, y: 24, w: 420, h: 300), layoutHeight: BoardLayout.compactHeight),
      BoardLayout.Item(id: b, frame: NodeFrame(x: 24, y: 600, w: 420, h: 300), layoutHeight: BoardLayout.compactHeight),
    ]
    let tidied = BoardLayout.tidy(items, viewportWidth: 480, topMargin: 64)
    XCTAssertEqual(tidied[a]?.y, 64)
    let shown = { (y: Double) in NodeFrame(x: 24, y: y, w: 420, h: BoardLayout.compactHeight) }
    XCTAssertTrue(BoardLayout.isLoose(current: [shown(24), shown(600)], tidied: [shown(64), shown(tidied[b]!.y)]))
    XCTAssertFalse(BoardLayout.isLoose(current: [shown(64), shown(tidied[b]!.y)], tidied: [shown(64), shown(tidied[b]!.y)]))
  }

  @MainActor
  func testSidebarRowCellInsetsTheIconAndLeavesAGapBeforeTheTitle() {
    let cell = RailRowButtonCell(textCell: "Agenter")
    cell.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
    cell.rowLayout = true
    let bounds = NSRect(x: 0, y: 0, width: 200, height: 34)
    let image = cell.imageRect(forBounds: bounds)
    let title = cell.titleRect(forBounds: bounds)
    XCTAssertGreaterThanOrEqual(image.minX, 12)
    XCTAssertEqual(image.width, 18)
    XCTAssertGreaterThanOrEqual(title.minX, image.maxX + 10)
    XCTAssertEqual(title.midY, bounds.midY, accuracy: 1)
    let button = AXActionButtonView(title: "x", target: nil, action: nil)
    XCTAssertTrue(button.cell is RailRowButtonCell)
    button.rowStyle = true
    XCTAssertEqual((button.cell as? RailRowButtonCell)?.rowLayout, true)
  }

  func testOnlyIdleCardsAreCompact() {
    XCTAssertTrue(BoardLayout.isCompact(idle: true))
    XCTAssertFalse(BoardLayout.isCompact(idle: false))
  }

  func testAppearanceDefaultsToDark() throws {
    XCTAssertEqual(AppPreferences().appearance, .dark)
    let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
    XCTAssertEqual(decoded.appearance, .dark)
    XCTAssertEqual(AppearanceMode.dark.appearanceName, "NSAppearanceNameDarkAqua")
    XCTAssertEqual(AppearanceMode.light.appearanceName, "NSAppearanceNameAqua")
    XCTAssertNil(AppearanceMode.system.appearanceName)
    var prefs = AppPreferences()
    prefs.appearance = .light
    let roundTrip = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs))
    XCTAssertEqual(roundTrip.appearance, .light)
  }

  func testDialogIsCenteredSizeClampedToWindow() {
    let roomy = DialogLayout.size(preferredWidth: 460, in: CGSize(width: 1600, height: 1000))
    XCTAssertEqual(roomy.width, 720)
    XCTAssertEqual(roomy.height, 800)
    let wide = DialogLayout.size(preferredWidth: 1200, in: CGSize(width: 1600, height: 1000))
    XCTAssertEqual(wide.width, 860)
    let small = DialogLayout.size(preferredWidth: 860, in: CGSize(width: 700, height: 500))
    XCTAssertEqual(small.width, 636)
    XCTAssertEqual(small.height, 400)
  }
}
