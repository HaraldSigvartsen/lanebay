import Foundation

/// When a scheduled job fires. Times are wall-clock times in the calendar passed to
/// `CronPlanner.nextRun`, so a fixed-TimeZone calendar can be used in tests.
public enum CronSchedule: Codable, Sendable, Equatable {
    /// Every N minutes, 1...10080 (one week).
    case every(minutes: Int)
    /// Once a day, local time.
    case daily(hour: Int, minute: Int)
    /// Monday to Friday, local time.
    case weekdays(hour: Int, minute: Int)
}

public struct CronJob: Codable, Identifiable, Sendable, Equatable {
    /// Longest prompt we send to a card.
    public static let maxPromptLength = 1500
    /// Shortest and longest interval for `.every`.
    public static let minuteRange = 1...10080

    public var id: UUID
    public var name: String
    /// Card name or @handle the prompt goes to.
    public var card: String
    public var prompt: String
    public var schedule: CronSchedule
    public var enabled: Bool
    /// First-run baseline; nil for jobs saved before this field existed.
    public var createdAt: Date?
    public var lastRun: Date?
    /// Short note about the last run, e.g. "Sendt til Utvikler" / "Fant ikke kortet".
    public var lastResult: String?

    public init(id: UUID = UUID(), name: String, card: String, prompt: String,
                schedule: CronSchedule, enabled: Bool = true,
                lastRun: Date? = nil, lastResult: String? = nil, createdAt: Date? = Date()) {
        self.id = id
        self.name = name
        self.card = card
        self.prompt = prompt
        self.schedule = schedule
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastRun = lastRun
        self.lastResult = lastResult
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, card, prompt, schedule, enabled, createdAt, lastRun, lastResult
    }

    /// Tolerant decoding: a missing name becomes "Jobb", a missing job is enabled,
    /// ids and text default to something usable instead of failing the whole load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Jobb"
        self.card = (try? c.decodeIfPresent(String.self, forKey: .card)) ?? ""
        self.prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? ""
        self.schedule = (try? c.decodeIfPresent(CronSchedule.self, forKey: .schedule))
            ?? .every(minutes: 60)
        self.enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        self.createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.lastRun = try? c.decodeIfPresent(Date.self, forKey: .lastRun)
        self.lastResult = try? c.decodeIfPresent(String.self, forKey: .lastResult)
    }
}

public enum CronPlanner {
    /// Next fire time strictly after `after`, using `calendar` for wall-clock times.
    public static func nextRun(_ schedule: CronSchedule, after: Date,
                              calendar: Calendar = .current) -> Date {
        switch schedule {
        case .every(let minutes):
            return after.addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        case .daily(let hour, let minute):
            return nextDaily(hour: hour, minute: minute, after: after, calendar: calendar)
        case .weekdays(let hour, let minute):
            var candidate = nextDaily(hour: hour, minute: minute, after: after, calendar: calendar)
            // 1 = Sunday, 7 = Saturday.
            var guardCount = 0
            while guardCount < 7 {
                let weekday = calendar.component(.weekday, from: candidate)
                if weekday != 1 && weekday != 7 { break }
                candidate = nextDaily(hour: hour, minute: minute, after: candidate, calendar: calendar)
                guardCount += 1
            }
            return candidate
        }
    }

    /// Due when the job is enabled and its next fire time is at or before `now`.
    /// A job that has never run is measured from creation; legacy jobs use app start (`reference`).
    public static func isDue(_ job: CronJob, now: Date, reference: Date,
                             calendar: Calendar = .current) -> Bool {
        guard job.enabled else { return false }
        let base = job.lastRun ?? job.createdAt ?? reference
        return nextRun(job.schedule, after: base, calendar: calendar) <= now
    }

    /// Parse user text: "30m", "2t"/"2h", "every 15m", "07:30",
    /// "hverdager 08:00" / "weekdays 08:00". Returns nil when the text is not a schedule.
    public static func parse(_ text: String) -> CronSchedule? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !body.isEmpty else { return nil }

        var weekdaysOnly = false
        for prefix in ["hverdager", "hverdag", "weekdays", "weekday"] {
            if body.hasPrefix(prefix) {
                weekdaysOnly = true
                body = String(body.dropFirst(prefix.count))
                break
            }
        }
        if !weekdaysOnly {
            for prefix in ["hver dag", "daily", "every day"] {
                if body.hasPrefix(prefix) {
                    body = String(body.dropFirst(prefix.count))
                    break
                }
            }
        }
        for prefix in ["every", "hvert"] where body.hasPrefix(prefix) {
            body = String(body.dropFirst(prefix.count))
            break
        }
        body = body.replacingOccurrences(of: "kl.", with: " ")
            .replacingOccurrences(of: "kl ", with: " ")
            .trimmingCharacters(in: .whitespaces)

        guard !body.isEmpty else { return nil }

        if body.contains(":") {
            guard let time = parseTime(body) else { return nil }
            return weekdaysOnly ? .weekdays(hour: time.hour, minute: time.minute)
                               : .daily(hour: time.hour, minute: time.minute)
        }

        guard let minutes = parseMinutes(body), CronJob.minuteRange.contains(minutes) else { return nil }
        return .every(minutes: minutes)
    }

    /// Norwegian plain description: "hvert 30. minutt", "hver dag kl. 07:30", "hverdager kl. 08:00".
    public static func describe(_ schedule: CronSchedule) -> String {
        switch schedule {
        case .every(let minutes):
            return "hvert \(minutes). minutt"
        case .daily(let hour, let minute):
            return "hver dag kl. \(clock(hour, minute))"
        case .weekdays(let hour, let minute):
            return "hverdager kl. \(clock(hour, minute))"
        }
    }

    /// nil when the job is fine, otherwise a short Norwegian error.
    public static func validate(_ job: CronJob) -> String? {
        if job.card.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Mangler kort"
        }
        let prompt = job.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty { return "Meldingen er tom" }
        if job.prompt.count > CronJob.maxPromptLength {
            return "Meldingen er for lang (maks \(CronJob.maxPromptLength) tegn)"
        }
        if !isValid(schedule: job.schedule) { return "Ugyldig tidsplan" }
        return nil
    }

    // MARK: - Helpers

    private static func isValid(schedule: CronSchedule) -> Bool {
        switch schedule {
        case .every(let minutes):
            return CronJob.minuteRange.contains(minutes)
        case .daily(let hour, let minute), .weekdays(let hour, let minute):
            return (0...23).contains(hour) && (0...59).contains(minute)
        }
    }

    private static func clock(_ hour: Int, _ minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    private static func nextDaily(hour: Int, minute: Int, after: Date,
                                  calendar: Calendar) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        if let next = calendar.nextDate(after: after, matching: components,
                                        matchingPolicy: .nextTime) {
            return next
        }
        return after.addingTimeInterval(24 * 60 * 60)
    }

    private static func parseTime(_ token: String) -> (hour: Int, minute: Int)? {
        let parts = token.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let minute = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    private static func parseMinutes(_ token: String) -> Int? {
        let t = token.replacingOccurrences(of: " ", with: "")
        guard !t.isEmpty else { return nil }
        for suffix in ["minutes", "minute", "mins", "min", "m"] where t.hasSuffix(suffix) {
            guard let n = Int(t.dropLast(suffix.count)), n > 0 else { return nil }
            return n
        }
        for suffix in ["timer", "hours", "hour", "hrs", "hr", "t", "h"] where t.hasSuffix(suffix) {
            guard let n = Int(t.dropLast(suffix.count)),
                  (1...(CronJob.minuteRange.upperBound / 60)).contains(n) else { return nil }
            return n * 60
        }
        return nil
    }
}
