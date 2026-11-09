import Foundation
import XCTest

@testable import LanebayCore

final class ActivityFeedTests: XCTestCase {
  private func event(
    _ kind: ActivityKind, title: String = "Shell", detail: String = "detail",
    at seconds: TimeInterval
  ) -> ActivityEvent {
    ActivityEvent(date: Date(timeIntervalSince1970: seconds), kind: kind, title: title, detail: detail)
  }

  func testAppendKeepsNewestFirst() {
    var feed = ActivityFeed()
    feed.append(event(.start, detail: "first", at: 1))
    feed.append(event(.send, detail: "second", at: 2))
    feed.append(event(.stop, detail: "third", at: 3))
    XCTAssertEqual(feed.events.map(\.detail), ["third", "second", "first"])
  }

  func testAppendTrimsToLimit() {
    var feed = ActivityFeed(limit: 3)
    for index in 1...6 {
      feed.append(event(.send, detail: "event \(index)", at: TimeInterval(index)))
    }
    XCTAssertEqual(feed.events.count, 3)
    XCTAssertEqual(feed.events.map(\.detail), ["event 6", "event 5", "event 4"])
  }

  func testDropsExactDuplicateOfNewestWithinOneSecond() {
    var feed = ActivityFeed()
    feed.append(event(.send, detail: "same", at: 100))
    feed.append(event(.send, detail: "same", at: 100.5))
    XCTAssertEqual(feed.events.count, 1)

    feed.append(event(.send, detail: "different", at: 101))
    XCTAssertEqual(feed.events.count, 2)

    feed.append(event(.send, detail: "different", at: 103))
    XCTAssertEqual(feed.events.count, 3, "A repeat older than one second is kept")

    feed.append(event(.send, detail: "same", at: 103.2))
    XCTAssertEqual(feed.events.count, 4, "A duplicate that is not the newest event is kept")
  }

  func testFilterByKindTreatsAnEmptySetAsAll() {
    var feed = ActivityFeed()
    feed.append(event(.status, detail: "a", at: 1))
    feed.append(event(.send, detail: "b", at: 2))
    feed.append(event(.handoff, detail: "c", at: 3))
    XCTAssertEqual(feed.filtered([.send]).map(\.detail), ["b"])
    XCTAssertEqual(feed.filtered([.status, .handoff]).map(\.detail), ["c", "a"])
    XCTAssertEqual(feed.filtered([]).map(\.detail), ["c", "b", "a"])
    XCTAssertTrue(feed.filtered([.spawn]).isEmpty)
  }

  func testTimestampUsesTwentyFourHourClockInAFixedTimeZone() {
    let utc = TimeZone(secondsFromGMT: 0)!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let midnight = Date(timeIntervalSince1970: 0)
    XCTAssertEqual(ActivityFeed.timestamp(midnight, calendar: calendar, timeZone: utc), "00:00:00")

    let evening = Date(timeIntervalSince1970: 23 * 3600 + 5 * 60 + 9)
    XCTAssertEqual(ActivityFeed.timestamp(evening, calendar: calendar, timeZone: utc), "23:05:09")

    let shifted = TimeZone(secondsFromGMT: 2 * 3600)!
    XCTAssertEqual(
      ActivityFeed.timestamp(evening, calendar: calendar, timeZone: shifted), "01:05:09")
  }

  func testClearRemovesEveryEvent() {
    var feed = ActivityFeed()
    feed.append(event(.start, at: 1))
    feed.clear()
    XCTAssertTrue(feed.events.isEmpty)
  }
}
