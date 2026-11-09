import Foundation
import Observation

/// What a board activity describes. Used for filtering the panel and for the row chip.
public enum ActivityKind: String, Codable, Sendable, CaseIterable {
  case status, send, spawn, handoff, stop, start, wire
}

public struct ActivityEvent: Identifiable, Equatable, Sendable, Codable {
  public let id: UUID
  public let date: Date
  public let kind: ActivityKind
  /// The console or agent title the event belongs to.
  public let title: String
  public let detail: String

  public init(id: UUID = UUID(), date: Date, kind: ActivityKind, title: String, detail: String) {
    self.id = id
    self.date = date
    self.kind = kind
    self.title = title
    self.detail = detail
  }
}

/// Observes a feed without widening the board's own observation surface.
@MainActor @Observable public final class ActivityLog {
  public private(set) var feed = ActivityFeed()
  /// The newest event date seen when the Aktivitet panel was last opened. A nil marker makes every event unread.
  public private(set) var readThrough: Date?

  @ObservationIgnored private var store: ActivityLogStore?
  @ObservationIgnored private var pendingSave: Task<Void, Never>?
  @ObservationIgnored public var saveDelay: Duration = .seconds(1)

  public init() {}

  /// Loads persisted events from `store` and saves every later change there (debounced).
  public func attach(store: ActivityLogStore) {
    self.store = store
    let snapshot = store.load()
    var restored = ActivityFeed(limit: feed.limit)
    for event in snapshot.events.reversed() { restored.append(event) }
    for event in feed.events.reversed() { restored.append(event) }
    feed = restored
    readThrough = snapshot.readThrough ?? readThrough
  }

  public func append(_ event: ActivityEvent) {
    feed.append(event)
    scheduleSave()
  }

  public func clear() {
    feed.clear()
    readThrough = nil
    scheduleSave()
  }

  public func markRead() {
    readThrough = feed.events.first?.date
    scheduleSave()
  }

  /// Writes pending changes now. Called on app termination and from tests.
  public func flush() {
    pendingSave?.cancel()
    pendingSave = nil
    store?.save(ActivityLogSnapshot(readThrough: readThrough, events: feed.events))
  }

  private func scheduleSave() {
    guard store != nil else { return }
    pendingSave?.cancel()
    let delay = saveDelay
    pendingSave = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }

  /// Events recorded since the panel was last opened; the sidebar badge shows this.
  public var unreadCount: Int {
    guard let readThrough else { return feed.events.count }
    return feed.events.filter { $0.date > readThrough }.count
  }
}

/// A bounded, newest-first log of board activity.
public struct ActivityFeed: Sendable {
  public private(set) var events: [ActivityEvent]
  public let limit: Int

  public init(limit: Int = 500) {
    self.events = []
    self.limit = max(0, limit)
  }

  /// Newest first, trimmed to `limit`. An exact repeat of the newest event within one second is dropped.
  public mutating func append(_ event: ActivityEvent) {
    if let newest = events.first,
      newest.kind == event.kind,
      newest.title == event.title,
      newest.detail == event.detail,
      abs(event.date.timeIntervalSince(newest.date)) <= 1
    {
      return
    }
    events.insert(event, at: 0)
    if events.count > limit {
      events.removeLast(events.count - limit)
    }
  }

  public mutating func clear() {
    events.removeAll()
  }

  /// An empty set means no filter: every event is shown.
  public func filtered(_ kinds: Set<ActivityKind>) -> [ActivityEvent] {
    guard !kinds.isEmpty else { return events }
    return events.filter { kinds.contains($0.kind) }
  }

  /// `HH:mm:ss` in 24-hour time, resolved through `calendar` with `timeZone`.
  public static func timestamp(
    _ date: Date, calendar: Calendar = .current, timeZone: TimeZone = .current
  ) -> String {
    var calendar = calendar
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
    return String(
      format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
  }
}

/// What `ActivityLogStore` keeps on disk.
public struct ActivityLogSnapshot: Codable, Equatable, Sendable {
  public var version: Int
  public var readThrough: Date?
  public var events: [ActivityEvent]

  public init(version: Int = 1, readThrough: Date?, events: [ActivityEvent]) {
    self.version = version
    self.readThrough = readThrough
    self.events = events
  }
}

/// Persists the newest activity events as JSON (0600). Missing or unreadable files load as empty;
/// an unreadable file is moved aside to `activity.corrupt.json`.
public struct ActivityLogStore: Sendable {
  public static let maxEvents = 500
  public let fileURL: URL

  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Lanebay/activity.json")
  }

  public func load() -> ActivityLogSnapshot {
    let fm = FileManager.default
    guard let data = try? Data(contentsOf: fileURL) else {
      return ActivityLogSnapshot(readThrough: nil, events: [])
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard var snapshot = try? decoder.decode(ActivityLogSnapshot.self, from: data) else {
      let aside = fileURL.deletingLastPathComponent().appendingPathComponent("activity.corrupt.json")
      try? fm.removeItem(at: aside)
      try? fm.moveItem(at: fileURL, to: aside)
      return ActivityLogSnapshot(readThrough: nil, events: [])
    }
    snapshot.events = Array(snapshot.events.sorted { $0.date > $1.date }.prefix(Self.maxEvents))
    return snapshot
  }

  public func save(_ snapshot: ActivityLogSnapshot) {
    var bounded = snapshot
    bounded.events = Array(snapshot.events.prefix(Self.maxEvents))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(bounded) else { return }
    try? FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? AtomicPrivateFileWriter.write(data, to: fileURL, temporaryPrefix: "activity")
  }
}
