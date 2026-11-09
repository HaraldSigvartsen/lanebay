import XCTest
@testable import LanebayCore

final class TerminalInputModesTests: XCTestCase {
  func testPlainTerminalSendsTextAsIs() {
    let modes = TerminalInputModes()
    XCTAssertEqual(String(decoding: modes.encode("ls"), as: UTF8.self), "ls")
    XCTAssertEqual(String(decoding: modes.encode("\r"), as: UTF8.self), "\r")
  }

  func testFreeBuffStyleModesWrapPasteAndReportFocusBeforeSubmit() {
    var modes = TerminalInputModes()
    modes.scan("\u{1B}[?1049h\u{1B}[?2004h\u{1B}[?1000;1004h hello")
    XCTAssertTrue(modes.bracketedPaste)
    XCTAssertTrue(modes.focusReporting)
    XCTAssertEqual(String(decoding: modes.encode("do it"), as: UTF8.self), "\u{1B}[I\u{1B}[200~do it\u{1B}[201~")
    XCTAssertEqual(String(decoding: modes.encode("\r"), as: UTF8.self), "\u{1B}[I\r")
  }

  func testModeSwitchSplitAcrossChunksAndTurnedOff() {
    var modes = TerminalInputModes()
    modes.scan("output \u{1B}[?20")
    modes.scan("04h more")
    XCTAssertTrue(modes.bracketedPaste)
    modes.scan("\u{1B}[?2004l")
    XCTAssertFalse(modes.bracketedPaste)
  }

  func testFallbackNoteDropsTuiBoxArt() {
    let frame = "\u{FFFD}──┘ ████│ Your first message starts the session.││ 21/21 hours remaining   │╰────╯ say hi"
    let note = AgentTaskContract.fallbackNote(outcome: .timedOut, task: "t", output: frame)
    XCTAssertTrue(note.contains("Your first message starts the session."))
    XCTAssertFalse(note.contains("█"))
    XCTAssertFalse(note.contains("\u{FFFD}"))
  }
}
