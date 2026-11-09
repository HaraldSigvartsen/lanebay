import LanebayCore
import XCTest

@testable import LanebayUI

/// The pure helpers behind the primary panels: Cron cards, the Aktivitet timeline and plan step pills.
final class PrimaryPanelPresentationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  func testCronNextRunCountsDownFromTheLastRun() {
    let loop = Loop(
      targetNodeID: UUID(), prompt: "run", trigger: .schedule(intervalSeconds: 120),
      lastRunAt: now.addingTimeInterval(-90))
    XCTAssertEqual(CronPresentation.nextRunLabel(loop: loop, now: now), "om 30 s")
  }

  func testCronRelativeSteps() {
    XCTAssertEqual(CronPresentation.relative(-5), "nå")
    XCTAssertEqual(CronPresentation.relative(59), "om 59 s")
    XCTAssertEqual(CronPresentation.relative(120), "om 2 min")
    XCTAssertEqual(CronPresentation.relative(7_200), "om 2 t")
    XCTAssertEqual(CronPresentation.relative(3 * 86_400), "om 3 d")
  }

  func testCronPanelsShowStoppedFinishedAndActiveStates() {
    let stopped = Loop(targetNodeID: UUID(), prompt: "run", trigger: .idle, isEnabled: false, iterations: 1)
    XCTAssertEqual(CronPresentation.lastResult(stopped).kind, .stopped)
    XCTAssertEqual(CronPresentation.nextRunLabel(loop: stopped, now: now), "Stoppet")

    let finished = Loop(
      targetNodeID: UUID(), prompt: "run", trigger: .schedule(intervalSeconds: 10),
      isEnabled: false, iterations: 10)
    XCTAssertEqual(CronPresentation.lastResult(finished).kind, .done)
    XCTAssertEqual(CronPresentation.lastResult(finished).label, "Fullført")

    let active = Loop(targetNodeID: UUID(), prompt: "run", trigger: .idle)
    XCTAssertEqual(CronPresentation.lastResult(active).kind, .running)
    XCTAssertEqual(CronPresentation.nextRunLabel(loop: active, now: now), "ved tomgang")
  }

  func testCronNeedsReviewAndScheduleLabels() {
    let review = Loop(
      targetNodeID: UUID(), prompt: "run", trigger: .outputMatch(pattern: "a.b"), needsReview: true)
    XCTAssertEqual(CronPresentation.lastResult(review).kind, .error)
    XCTAssertEqual(CronPresentation.nextRunLabel(loop: review, now: now), "Kjører ikke")

    XCTAssertEqual(CronPresentation.schedule(.schedule(intervalSeconds: 60)), "hvert 60s")
    XCTAssertEqual(CronPresentation.schedule(.outputMatch(pattern: "done")), "når output inneholder \"done\"")
  }

  func testEveryActivityKindHasATimelineTone() {
    XCTAssertEqual(Set(ActivityKind.allCases.map(\.rowTone)), Set([.accent, .accentInk, .accentHot, .handoff, .neutral]))
    XCTAssertEqual(ActivityKind.status.rowTone, .accent)
    XCTAssertEqual(ActivityKind.spawn.rowTone, .accentHot)
    XCTAssertEqual(ActivityKind.handoff.rowTone, .handoff)
    XCTAssertEqual(ActivityKind.start.rowTone, .neutral)
  }

  func testPlanStepPillFollowsApprovalAndOutcome() {
    var state = PlannerActionState()
    XCTAssertEqual(PlannerStepPresentation.status(for: state).label, "Til godkjenning")

    state.approved = true
    XCTAssertEqual(PlannerStepPresentation.status(for: state).kind, .running)

    state.executed = true
    XCTAssertEqual(PlannerStepPresentation.status(for: state).kind, .done)

    state.outcome = .failure("Dispatch gate rejected sendToConsole.")
    XCTAssertEqual(PlannerStepPresentation.status(for: state).kind, .error)
    XCTAssertEqual(PlannerStepPresentation.status(for: state).label, "Feilet")
  }
}
