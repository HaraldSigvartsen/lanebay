import Foundation
import XCTest
@testable import LanebayCore

@MainActor
final class ActivityLogStoreTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  private func event(_ seconds: Double, _ title: String = "freebuff") -> ActivityEvent {
    ActivityEvent(date: Date(timeIntervalSince1970: 1_800_000_000 + seconds), kind: .send, title: title, detail: "d\(seconds)")
  }

  func testRoundTripKeepsEventsAndReadThroughAcrossReload() {
    let store = ActivityLogStore(fileURL: dir.appendingPathComponent("activity.json"))
    let log = ActivityLog()
    log.attach(store: store)
    log.append(event(1))
    log.append(event(2))
    log.markRead()
    log.append(event(3))
    log.flush()

    let reloaded = ActivityLog()
    reloaded.attach(store: store)
    XCTAssertEqual(reloaded.feed.events.map(\.detail), ["d3.0", "d2.0", "d1.0"])
    XCTAssertEqual(reloaded.unreadCount, 1)
    let attrs = try? FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    XCTAssertEqual((attrs?[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testSaveIsBoundedToTheNewestFiveHundred() {
    let store = ActivityLogStore(fileURL: dir.appendingPathComponent("activity.json"))
    let events = (0..<650).reversed().map { event(Double($0)) }
    store.save(ActivityLogSnapshot(readThrough: nil, events: events))
    let loaded = store.load()
    XCTAssertEqual(loaded.events.count, ActivityLogStore.maxEvents)
    XCTAssertEqual(loaded.events.first?.detail, "d649.0")
  }

  func testCorruptFileLoadsEmptyAndIsMovedAside() throws {
    let url = dir.appendingPathComponent("activity.json")
    try Data("not json".utf8).write(to: url)
    let store = ActivityLogStore(fileURL: url)
    XCTAssertTrue(store.load().events.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("activity.corrupt.json").path))
  }

  func testMissingFileLoadsEmpty() {
    XCTAssertTrue(ActivityLogStore(fileURL: dir.appendingPathComponent("none.json")).load().events.isEmpty)
  }

  func testClearPersistsAnEmptyLog() {
    let store = ActivityLogStore(fileURL: dir.appendingPathComponent("activity.json"))
    let log = ActivityLog()
    log.attach(store: store)
    log.append(event(1))
    log.flush()
    log.clear()
    log.flush()
    XCTAssertTrue(store.load().events.isEmpty)
    XCTAssertNil(store.load().readThrough)
  }
}
