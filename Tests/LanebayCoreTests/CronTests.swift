import XCTest
@testable import LanebayCore

final class CronTests: XCTestCase {
    /// Fixed UTC calendar so wall-clock assertions do not depend on the machine time zone.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        let components = DateComponents(year: year, month: month, day: day,
                                        hour: hour, minute: minute, second: second)
        return utc.date(from: components)!
    }

    // MARK: - parse

    func testParseAcceptsUserFormsAndRejectsInvalidText() {
        XCTAssertEqual(CronPlanner.parse("30m"), .every(minutes: 30))
        XCTAssertEqual(CronPlanner.parse("2t"), .every(minutes: 120))
        XCTAssertEqual(CronPlanner.parse("2h"), .every(minutes: 120))
        XCTAssertEqual(CronPlanner.parse("every 15m"), .every(minutes: 15))
        XCTAssertEqual(CronPlanner.parse("07:30"), .daily(hour: 7, minute: 30))
        XCTAssertEqual(CronPlanner.parse("hverdager 08:00"), .weekdays(hour: 8, minute: 0))
        XCTAssertEqual(CronPlanner.parse("weekdays 08:00"), .weekdays(hour: 8, minute: 0))

        XCTAssertNil(CronPlanner.parse("abc"))
        XCTAssertNil(CronPlanner.parse("25:00"))
        XCTAssertNil(CronPlanner.parse("07:60"))
        XCTAssertNil(CronPlanner.parse("0m"))
        XCTAssertNil(CronPlanner.parse(""))
        XCTAssertNil(CronPlanner.parse("m"))
    }

    func testParseBoundsIntervalsBeforeConvertingHoursToMinutes() {
        for suffix in ["timer", "hours", "hour", "hrs", "hr", "t", "h"] {
            XCTAssertEqual(CronPlanner.parse("1\(suffix)"), .every(minutes: 60))
            XCTAssertEqual(CronPlanner.parse("168\(suffix)"), .every(minutes: 10080))
            for hours in [0, -1, 169, Int.max / 60, Int.max / 60 + 1, Int.max] {
                XCTAssertNil(CronPlanner.parse("\(hours)\(suffix)"))
            }
        }
        XCTAssertEqual(CronPlanner.parse("10080m"), .every(minutes: 10080))
        XCTAssertNil(CronPlanner.parse("10081m"))
        XCTAssertNil(CronPlanner.parse("\(Int.max)m"))
        XCTAssertNil(CronPlanner.parse("\(Int.max)0h"))
    }

    // MARK: - describe

    func testDescribe() {
        XCTAssertEqual(CronPlanner.describe(.every(minutes: 30)), "hvert 30. minutt")
        XCTAssertEqual(CronPlanner.describe(.daily(hour: 7, minute: 30)), "hver dag kl. 07:30")
        XCTAssertEqual(CronPlanner.describe(.weekdays(hour: 8, minute: 0)), "hverdager kl. 08:00")
    }

    // MARK: - nextRun

    func testNextRunEveryIsStrictlyAfterBase() {
        let base = date(2026, 3, 2, 12, 0)
        XCTAssertEqual(CronPlanner.nextRun(.every(minutes: 30), after: base, calendar: utc),
                       base.addingTimeInterval(30 * 60))
    }

    func testInvalidSchedulesHaveNoNextRunAndNeverBecomeDue() throws {
        let base = date(2026, 3, 2, 12, 0)
        let schedules: [CronSchedule] = [
            .every(minutes: Int.max), .every(minutes: Int.min),
            .every(minutes: 0), .every(minutes: 10081),
            .daily(hour: 24, minute: 0), .daily(hour: 8, minute: -1),
            .weekdays(hour: -1, minute: 0), .weekdays(hour: 8, minute: 60),
        ]
        for schedule in schedules {
            let job = CronJob(name: "Invalid", card: "Builder", prompt: "echo scheduled",
                              schedule: schedule, createdAt: base)
            let restored = try JSONDecoder().decode(CronJob.self, from: JSONEncoder().encode(job))
            XCTAssertEqual(restored.schedule, schedule, "Keep the saved job available for inspection/removal")
            XCTAssertEqual(CronPlanner.nextRun(restored.schedule, after: base, calendar: utc), .distantFuture)
            for now in [base.addingTimeInterval(8 * 24 * 60 * 60), .distantFuture] {
                XCTAssertFalse(CronPlanner.isDue(restored, now: now, reference: base, calendar: utc))
            }
        }
        for minutes in [1, 10080] {
            XCTAssertEqual(CronPlanner.nextRun(.every(minutes: minutes), after: base, calendar: utc),
                           base.addingTimeInterval(TimeInterval(minutes * 60)))
        }
    }

    func testNextRunDailyCrossesMidnight() {
        let evening = date(2026, 3, 2, 22, 15) // Monday
        XCTAssertEqual(CronPlanner.nextRun(.daily(hour: 7, minute: 30), after: evening, calendar: utc),
                       date(2026, 3, 3, 7, 30))

        let exactly = date(2026, 3, 2, 7, 30)
        XCTAssertEqual(CronPlanner.nextRun(.daily(hour: 7, minute: 30), after: exactly, calendar: utc),
                       date(2026, 3, 3, 7, 30))
    }

    func testNextRunWeekdaysSkipsWeekend() {
        let friday = date(2026, 3, 6, 9, 0)
        XCTAssertEqual(CronPlanner.nextRun(.weekdays(hour: 8, minute: 0), after: friday, calendar: utc),
                       date(2026, 3, 9, 8, 0)) // Monday

        let monday = date(2026, 3, 2, 7, 0)
        XCTAssertEqual(CronPlanner.nextRun(.weekdays(hour: 8, minute: 0), after: monday, calendar: utc),
                       date(2026, 3, 2, 8, 0))
    }

    // MARK: - isDue

    func testIsDueEveryWithAndWithoutLastRun() {
        let reference = date(2026, 3, 2, 12, 0)
        let job = CronJob(name: "Sjekk", card: "Utvikler", prompt: "Status?",
                          schedule: .every(minutes: 30), createdAt: reference)

        XCTAssertFalse(CronPlanner.isDue(job, now: reference.addingTimeInterval(29 * 60),
                                         reference: reference, calendar: utc))
        XCTAssertTrue(CronPlanner.isDue(job, now: reference.addingTimeInterval(30 * 60),
                                        reference: reference, calendar: utc))

        var ran = job
        ran.lastRun = reference
        XCTAssertFalse(CronPlanner.isDue(ran, now: reference.addingTimeInterval(20 * 60),
                                         reference: reference.addingTimeInterval(-3600), calendar: utc),
                       "lastRun wins over the reference date")
        XCTAssertTrue(CronPlanner.isDue(ran, now: reference.addingTimeInterval(31 * 60),
                                        reference: reference, calendar: utc))

        var disabled = job
        disabled.enabled = false
        XCTAssertFalse(CronPlanner.isDue(disabled, now: reference.addingTimeInterval(600 * 60),
                                         reference: reference, calendar: utc))
    }

    func testIsDueDailyWaitsForTheClockTime() {
        let reference = date(2026, 3, 2, 6, 0)
        let job = CronJob(name: "Morgen", card: "@planlegger", prompt: "Dagplan?",
                          schedule: .daily(hour: 7, minute: 30), createdAt: reference)
        XCTAssertFalse(CronPlanner.isDue(job, now: date(2026, 3, 2, 7, 29), reference: reference, calendar: utc))
        XCTAssertTrue(CronPlanner.isDue(job, now: date(2026, 3, 2, 7, 30), reference: reference, calendar: utc))
    }

    func testFirstRunUsesPersistedCreationTimeAcrossAppRestarts() throws {
        let created = date(2026, 3, 2, 12, 0)
        let job = CronJob(name: "Sjekk", card: "Utvikler", prompt: "Status?",
                          schedule: .every(minutes: 30), createdAt: created)
        let restored = try JSONDecoder().decode(CronJob.self, from: JSONEncoder().encode(job))
        XCTAssertFalse(CronPlanner.isDue(restored, now: created.addingTimeInterval(29 * 60),
                                         reference: created.addingTimeInterval(-3600), calendar: utc))
        XCTAssertTrue(CronPlanner.isDue(restored, now: created.addingTimeInterval(30 * 60),
                                        reference: created.addingTimeInterval(20 * 60), calendar: utc))

        var ran = restored
        ran.lastRun = created.addingTimeInterval(30 * 60)
        XCTAssertFalse(CronPlanner.isDue(ran, now: created.addingTimeInterval(59 * 60),
                                         reference: created, calendar: utc))
        XCTAssertTrue(CronPlanner.isDue(ran, now: created.addingTimeInterval(60 * 60),
                                        reference: created, calendar: utc))
    }

    func testNewDailyAndWeekdayJobsSkipClockTimeBeforeCreation() {
        let appStart = date(2026, 3, 6, 6, 0) // Friday
        let created = date(2026, 3, 6, 9, 0)
        for (schedule, due) in [(CronSchedule.daily(hour: 8, minute: 0), date(2026, 3, 7, 8, 0)),
                                (.weekdays(hour: 8, minute: 0), date(2026, 3, 9, 8, 0))] {
            let job = CronJob(name: "Morgen", card: "Utvikler", prompt: "Status?",
                              schedule: schedule, createdAt: created)
            XCTAssertFalse(CronPlanner.isDue(job, now: created, reference: appStart, calendar: utc))
            XCTAssertFalse(CronPlanner.isDue(job, now: due.addingTimeInterval(-1), reference: appStart, calendar: utc))
            XCTAssertTrue(CronPlanner.isDue(job, now: due, reference: appStart, calendar: utc))
        }
    }

    // MARK: - validate

    func testValidateErrors() {
        func job(card: String = "Utvikler", prompt: String = "Hei",
                 schedule: CronSchedule = .every(minutes: 30)) -> CronJob {
            CronJob(name: "Test", card: card, prompt: prompt, schedule: schedule)
        }

        XCTAssertNil(CronPlanner.validate(job()))
        XCTAssertEqual(CronPlanner.validate(job(card: "  ")), "Mangler kort")
        XCTAssertEqual(CronPlanner.validate(job(prompt: "")), "Meldingen er tom")
        XCTAssertEqual(CronPlanner.validate(job(prompt: " ")), "Meldingen er tom")
        XCTAssertEqual(CronPlanner.validate(job(prompt: String(repeating: "a", count: 1501))),
                       "Meldingen er for lang (maks 1500 tegn)")
        XCTAssertNil(CronPlanner.validate(job(prompt: String(repeating: "a", count: 1500))))
        XCTAssertEqual(CronPlanner.validate(job(schedule: .every(minutes: 0))), "Ugyldig tidsplan")
        XCTAssertEqual(CronPlanner.validate(job(schedule: .daily(hour: 24, minute: 0))), "Ugyldig tidsplan")
        XCTAssertEqual(CronPlanner.validate(job(schedule: .weekdays(hour: 8, minute: 75))), "Ugyldig tidsplan")
    }

    // MARK: - Codable

    func testRunHistoryKeepsNewestTwentyAttemptsAndRoundTrips() throws {
        var job = CronJob(name: "History", card: "Builder", prompt: "Status?", schedule: .every(minutes: 5))
        let start = date(2026, 3, 2, 12, 0)
        for index in 0..<25 {
            job.recordRun(at: start.addingTimeInterval(Double(index)), result: "Attempt \(index)")
        }
        XCTAssertEqual(job.history.count, 20)
        XCTAssertEqual(job.history.first?.date, start.addingTimeInterval(24))
        XCTAssertEqual(job.history.first?.result, "Attempt 24")
        XCTAssertEqual(job.history.last?.result, "Attempt 5")
        XCTAssertEqual(job.lastRun, start.addingTimeInterval(24))
        XCTAssertEqual(job.lastResult, "Attempt 24")
        let restored = try JSONDecoder().decode(CronJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(restored, job)
    }

    func testLegacyLastResultSeedsHistoryWithoutChangingScheduleBaseline() throws {
        let last = date(2026, 3, 2, 12, 0)
        let job = CronJob(name: "Legacy", card: "Builder", prompt: "Status?", schedule: .every(minutes: 5),
                          lastRun: last, lastResult: "Sendt til Builder")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        object.removeValue(forKey: "history")
        let restored = try JSONDecoder().decode(CronJob.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.history.count, 1)
        XCTAssertEqual(restored.history.first?.date, last)
        XCTAssertEqual(restored.history.first?.result, "Sendt til Builder")
        XCTAssertEqual(restored.lastRun, last)
        XCTAssertFalse(CronPlanner.isDue(restored, now: last.addingTimeInterval(299), reference: last, calendar: utc))
    }

    func testDecodeBoundsSavedHistory() throws {
        let job = CronJob(name: "History", card: "Builder", prompt: "Status?", schedule: .every(minutes: 5))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        object["history"] = (0..<25).map { ["date": Double(25 - $0), "result": "Attempt \($0)"] as [String: Any] }
        let restored = try JSONDecoder().decode(CronJob.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.history.count, 20)
        XCTAssertEqual(restored.history.first?.result, "Attempt 0")
        XCTAssertEqual(restored.history.last?.result, "Attempt 19")
        object["history"] = "damaged"
        let damaged = try JSONDecoder().decode(CronJob.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(damaged.history.isEmpty)
        XCTAssertEqual(damaged.schedule, .every(minutes: 5))
    }

    func testCodableRoundTrip() throws {
        let job = CronJob(name: "Ukentlig", card: "@planlegger", prompt: "Oppsummer uken",
                          schedule: .weekdays(hour: 16, minute: 5), enabled: false,
                          lastRun: date(2026, 3, 6, 16, 5), lastResult: "Sendt til planlegger")
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(CronJob.self, from: data)
        XCTAssertEqual(decoded, job)
    }

    func testTolerantDecodeFillsDefaults() throws {
        let schedule = try JSONEncoder().encode(CronJob(name: "x", card: "x", prompt: "y",
                                                        schedule: .every(minutes: 15)))
        guard let object = try JSONSerialization.jsonObject(with: schedule) as? [String: Any],
              let scheduleObject = object["schedule"] as? [String: Any] else {
            return XCTFail("could not build fixture")
        }
        let fixture: [String: Any] = [
            "id": UUID().uuidString,
            "card": "Utvikler",
            "prompt": "Status?",
            "schedule": scheduleObject,
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        let decoded = try JSONDecoder().decode(CronJob.self, from: data)

        XCTAssertEqual(decoded.name, "Jobb")
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.card, "Utvikler")
        XCTAssertEqual(decoded.prompt, "Status?")
        XCTAssertEqual(decoded.schedule, .every(minutes: 15))
        XCTAssertNil(decoded.lastRun)
        XCTAssertNil(decoded.lastResult)
        XCTAssertNil(decoded.createdAt)
        XCTAssertTrue(decoded.history.isEmpty)
        let reference = date(2026, 3, 2, 12, 0)
        XCTAssertFalse(CronPlanner.isDue(decoded, now: reference.addingTimeInterval(14 * 60),
                                         reference: reference, calendar: utc))
        XCTAssertTrue(CronPlanner.isDue(decoded, now: reference.addingTimeInterval(15 * 60),
                                        reference: reference, calendar: utc))
    }
}
