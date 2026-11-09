import XCTest
@testable import LanebayCore

final class ReplyCompletionTests: XCTestCase {
    func testShellFinishesAfterShortQuiet() {
        XCTAssertTrue(ReplyCompletion.isDone(agentID: "shell", processRunning: true, working: false, quietFor: 3, newBytes: 10, tail: "ok"))
        XCTAssertFalse(ReplyCompletion.isDone(agentID: "shell", processRunning: true, working: false, quietFor: 1, newBytes: 10, tail: "ok"))
    }

    func testProviderWaitsLongerWithoutPrompt() {
        XCTAssertFalse(ReplyCompletion.isDone(agentID: "codex", processRunning: true, working: false, quietFor: 6, newBytes: 10, tail: "thinking about it"))
        XCTAssertTrue(ReplyCompletion.isDone(agentID: "codex", processRunning: true, working: false, quietFor: 10.5, newBytes: 10, tail: "thinking about it"))
    }

    func testProviderPromptShortensWindow() {
        XCTAssertTrue(ReplyCompletion.isDone(agentID: "freebuff", processRunning: true, working: false, quietFor: 4.5, newBytes: 10, tail: "Done.\nuser@mac lanebay %"))
    }

    func testNeverDoneWhileWorking() {
        XCTAssertFalse(ReplyCompletion.isDone(agentID: "shell", processRunning: true, working: true, quietFor: 600, newBytes: 10, tail: "$"))
        XCTAssertFalse(ReplyCompletion.isDone(agentID: "codex", processRunning: true, working: true, quietFor: 600, newBytes: 10, tail: "›"))
    }

    func testExitedProcessAlwaysDone() {
        XCTAssertTrue(ReplyCompletion.isDone(agentID: "codex", processRunning: false, working: true, quietFor: 0, newBytes: 0, tail: ""))
    }

    func testNoNewOutputIsNotDone() {
        XCTAssertFalse(ReplyCompletion.isDone(agentID: "shell", processRunning: true, working: false, quietFor: 60, newBytes: 0, tail: "%"))
    }

    func testPromptDetection() {
        XCTAssertTrue(ReplyCompletion.promptVisible(tail: "\u{1B}[32mharald@mac\u{1B}[0m ~ %"))
        XCTAssertFalse(ReplyCompletion.promptVisible(tail: "Working (12s • esc to interrupt)"))
        XCTAssertFalse(ReplyCompletion.promptVisible(tail: "Reading files"))
    }

    func testProviderBusyFollowsTheLatestHint() {
        XCTAssertTrue(ReplyCompletion.providerBusy(tail: "PONG\n• Working (3s • esc to interrupt)"))
        XCTAssertFalse(ReplyCompletion.providerBusy(tail: "thinking… ■ Esc\nPONG\n× End session\n❯ Enter a coding task"))
        XCTAssertFalse(ReplyCompletion.providerBusy(tail: "plain output"))
        XCTAssertTrue(ReplyCompletion.isWorking(agentID: "shell", statusRunning: true, tail: "× End session"))
        XCTAssertFalse(ReplyCompletion.isWorking(agentID: "freebuff", statusRunning: true, tail: "× End session"))
    }

    func testRightPromptRedrawIsNoise() {
        XCTAssertTrue(OutputDigest.isNoise("❯ m6=❯ m6❯ m6"))
        XCTAssertFalse(OutputDigest.isNoise("ferdig etter pause"))
    }

    func testReadyAiToolFinishesSoonerEvenWithoutSilence() {
        let tail = "PONG\n✕ End session\n❯ Enter a coding task\nAd: Get $20"
        XCTAssertTrue(ReplyCompletion.providerReady(tail: tail))
        XCTAssertTrue(ReplyCompletion.isDone(agentID: "freebuff", processRunning: true, working: false, quietFor: 4.2, newBytes: 50, tail: tail))
    }

    func testScreenReplyKeepsOnlyTheAnswer() {
        let screen = """
        ┌──────────────┐
        │ [07:20 AM]   │
        svar bare med ordet PONG3
        PONG3
        Get $20 to try Exa              Ad [Report 1]
        25.6K (3%)                 ✕ End session
        ❯ Enter a coding task
        GPT-6 Luna • high · ~/m6 · /model to change
        """
        XCTAssertEqual(ReplyCompletion.screenReply(screen: screen, sent: "svar bare med ordet PONG3"), "PONG3")
    }

  func testScreenReplySkipsFooterEcho() {
    let screen = "[07:37 AM]\n> svar bare med ordet PONG5\nPONG5\n25.8K (3%)   × End session\n> Enter a coding task\nChat: svar bare med ordet PONG5\n← for history · ? for help"
    XCTAssertEqual(ReplyCompletion.screenReply(screen: screen, sent: "svar bare med ordet PONG5"), "PONG5")
  }

  func testScreenReplyWaitsForTheEcho() {
    let screen = "msvar bare med ordet PONG7\nSession active\n19/21 hours remaining\nChat: svar bare med ordet PONG7"
    XCTAssertEqual(ReplyCompletion.screenReply(screen: screen, sent: "svar bare med ordet PONG7"), "")
  }

  func testPreferredAnswerPicksShortFinalLine() {
    let raw = "The user says answer only with PONG9\nthinking…\nPONG9"
    XCTAssertEqual(ReplyCompletion.preferredAnswer(raw), "PONG9")
  }

  func testScreenReplyDropsChatFooter() {
    let screen = "> svar bare med ordet PONGX\nPONGX\nchange · Chat: svar bare med ordet PONGX"
    XCTAssertEqual(ReplyCompletion.screenReply(screen: screen, sent: "svar bare med ordet PONGX"), "PONGX")
  }
}
