import Foundation
import OSLog

/// A deliberately small, read-only projection of library.json for widgets.
/// The widget target does not link the application target, so keeping this model
/// independent also makes older backups safe to decode.
struct RhythmWidgetData: Decodable {
    /// Must match the application-group entitlement on both targets.
    static let appGroupID = "5G96498KGJ.com.gaojiezou.rhythm"
    struct Habit: Decodable {
        let id: String
        let title: String
        let weekdays: Set<Int>
        let createdAt: Date
    }

    struct FocusRecord: Decodable {
        let startedAt: Date
        let endedAt: Date
        let durationSeconds: TimeInterval
    }

    struct ActiveFocus: Decodable {
        let startedAt: Date
        let accumulatedSeconds: TimeInterval
        let segmentStartedAt: Date?
    }

    struct ActiveSleep: Decodable {
        let startedAt: Date
    }

    struct SleepRecord: Decodable {
        let healthSource: String?
        let startedAt: Date
        let endedAt: Date
        let durationSeconds: TimeInterval
    }

    struct LongGoal: Decodable {
        let id: String
        let title: String
        let status: String
        let createdAt: Date?
    }

    struct ShortAction: Decodable {
        let id: String
        let goalID: String?
        let title: String
        let dueDate: Date
        let startDate: Date?
        let endDate: Date?
        let isCompleted: Bool
        let createdAt: Date?
    }

    struct Chore: Decodable {
        let id: String
        let title: String
        let startDate: Date
        let endDate: Date
        let isCompleted: Bool
        let createdAt: Date?
        let colorHex: String?
    }

    let habits: [Habit]
    let habitCompletionKeys: [String]
    let activeFocus: ActiveFocus?
    let activeSleep: ActiveSleep?
    let focusRecords: [FocusRecord]
    let sleepRecords: [SleepRecord]
    let longGoals: [LongGoal]
    let shortActions: [ShortAction]
    let chores: [Chore]

    private enum CodingKeys: String, CodingKey {
        case habits, habitCompletionKeys, activeFocus, activeSleep, focusRecords, sleepRecords
        case longGoals, shortActions, chores
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        habits = try container.decode([Habit].self, forKey: .habits)
        habitCompletionKeys = try container.decode([String].self, forKey: .habitCompletionKeys)
        activeFocus = try container.decodeIfPresent(ActiveFocus.self, forKey: .activeFocus)
        activeSleep = try container.decodeIfPresent(ActiveSleep.self, forKey: .activeSleep)
        focusRecords = try container.decode([FocusRecord].self, forKey: .focusRecords)
        sleepRecords = try container.decode([SleepRecord].self, forKey: .sleepRecords)
        longGoals = try container.decode([LongGoal].self, forKey: .longGoals)
        shortActions = try container.decode([ShortAction].self, forKey: .shortActions)
        // Chores was optional in existing archives; do not change that protocol.
        chores = try container.decodeIfPresent([Chore].self, forKey: .chores) ?? []
        try validateValues()
    }

    static let empty = RhythmWidgetData(
        habits: [], habitCompletionKeys: [], activeFocus: nil, activeSleep: nil, focusRecords: [],
        sleepRecords: [], longGoals: [], shortActions: [], chores: []
    )

    private init(
        habits: [Habit], habitCompletionKeys: [String], activeFocus: ActiveFocus?, activeSleep: ActiveSleep?,
        focusRecords: [FocusRecord], sleepRecords: [SleepRecord],
        longGoals: [LongGoal], shortActions: [ShortAction], chores: [Chore]
    ) {
        self.habits = habits
        self.habitCompletionKeys = habitCompletionKeys
        self.activeFocus = activeFocus
        self.activeSleep = activeSleep
        self.focusRecords = focusRecords
        self.sleepRecords = sleepRecords
        self.longGoals = longGoals
        self.shortActions = shortActions
        self.chores = chores
    }

    private func validateValues() throws {
        func valid(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isFinite }
        func validDuration(_ value: TimeInterval) -> Bool { value.isFinite && value >= 0 && value < Double(Int.max) }
        guard habits.allSatisfy({ valid($0.createdAt) && $0.weekdays.allSatisfy { (1...7).contains($0) } }),
              focusRecords.allSatisfy({ valid($0.startedAt) && valid($0.endedAt) && $0.startedAt <= $0.endedAt && validDuration($0.durationSeconds) }),
              sleepRecords.allSatisfy({ valid($0.startedAt) && valid($0.endedAt) && $0.startedAt <= $0.endedAt && validDuration($0.durationSeconds) }),
              longGoals.allSatisfy({ $0.createdAt.map(valid) ?? true }),
              shortActions.allSatisfy({ valid($0.dueDate) && ($0.startDate.map(valid) ?? true) && ($0.endDate.map(valid) ?? true) && ($0.createdAt.map(valid) ?? true) }),
              chores.allSatisfy({ valid($0.startDate) && valid($0.endDate) && ($0.createdAt.map(valid) ?? true) }) else {
            throw RhythmWidgetSnapshotEnvelope.ValidationError.invalidLibrary
        }
        if let activeFocus {
            guard valid(activeFocus.startedAt), validDuration(activeFocus.accumulatedSeconds),
                  activeFocus.segmentStartedAt.map(valid) ?? true else {
                throw RhythmWidgetSnapshotEnvelope.ValidationError.invalidLibrary
            }
        }
        if let activeSleep, !valid(activeSleep.startedAt) {
            throw RhythmWidgetSnapshotEnvelope.ValidationError.invalidLibrary
        }
    }

    func scheduledHabits(on date: Date) -> [Habit] {
        habits.filter {
            RhythmShared.habitIsScheduled(weekdays: $0.weekdays, createdAt: $0.createdAt, on: date)
        }
    }

    func isHabitCompleted(_ habit: Habit, on date: Date) -> Bool {
        habitCompletionKeys.contains(RhythmShared.habitKey(habitID: habit.id, date: date))
    }

    func habitStats(on date: Date) -> (completed: Int, total: Int) {
        let scheduled = scheduledHabits(on: date)
        return (scheduled.filter { isHabitCompleted($0, on: date) }.count, scheduled.count)
    }

    func focusSeconds(on date: Date, now: Date) -> TimeInterval {
        RhythmShared.focusSecondsOn(
            records: focusRecords.map { (endedAt: $0.endedAt, durationSeconds: $0.durationSeconds) },
            active: activeFocus.map { (startedAt: $0.startedAt, accumulatedSeconds: $0.accumulatedSeconds, segmentStartedAt: $0.segmentStartedAt) },
            day: date,
            now: now
        )
    }

    /// WidgetKit's system timer advances from the real session anchors without
    /// requesting a new timeline every second. Its upper bound is this day's end.
    func focusTimerInterval(on date: Date, referenceDate: Date, calendar: Calendar = .current) -> ClosedRange<Date>? {
        guard let segment = activeFocus?.segmentStartedAt, segment <= referenceDate,
              calendar.isDate(date, inSameDayAs: referenceDate),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)),
              referenceDate < dayEnd else { return nil }
        let seconds = RhythmShared.focusSecondsOn(
            records: focusRecords.map { (endedAt: $0.endedAt, durationSeconds: $0.durationSeconds) },
            active: activeFocus.map { (startedAt: $0.startedAt, accumulatedSeconds: $0.accumulatedSeconds, segmentStartedAt: $0.segmentStartedAt) },
            day: date, now: referenceDate, calendar: calendar
        )
        let start = referenceDate.addingTimeInterval(-max(0, seconds))
        guard start < dayEnd else { return nil }
        return start...dayEnd
    }

    /// The sleep tile is intentionally tied to the sleep session that ended this morning.
    func lastNightSleepDuration(on date: Date) -> TimeInterval? {
        RhythmShared.lastNightSleepDuration(
            records: sleepRecords.map {
                (startedAt: $0.startedAt, endedAt: $0.endedAt,
                 durationSeconds: $0.durationSeconds, isHealthSource: $0.healthSource != nil)
            },
            on: date
        )
    }
}

enum RhythmWidgetReadSource: String {
    case current, previous, legacy, unavailable, placeholder
}

struct RhythmWidgetReadResult {
    let data: RhythmWidgetData?
    let source: RhythmWidgetReadSource
    let sourceModifiedAt: Date?
    let contentUpdatedAt: Date?
    let generatedAt: Date?
    let readAt: Date
    let librarySHA256: String?
    let sourceVersion: String?
    let sourceBuild: String?

    static func unavailable(at date: Date) -> Self {
        Self(data: nil, source: .unavailable, sourceModifiedAt: nil, contentUpdatedAt: nil,
             generatedAt: nil, readAt: date, librarySHA256: nil, sourceVersion: nil, sourceBuild: nil)
    }

    static func placeholder(at date: Date) -> Self {
        Self(data: .empty, source: .placeholder, sourceModifiedAt: nil, contentUpdatedAt: nil,
             generatedAt: nil, readAt: date, librarySHA256: nil, sourceVersion: nil, sourceBuild: nil)
    }
}

enum RhythmWidgetReader {
    private static let log = Logger(subsystem: "com.gaojiezou.rhythm", category: "WidgetRead")

    static func load(groupURL: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: RhythmWidgetData.appGroupID), now: Date = Date()) -> RhythmWidgetReadResult {
        let result = read(groupURL: groupURL, now: now)
        let formatter = ISO8601DateFormatter()
        let sourceTime = result.sourceModifiedAt.map(formatter.string(from:)) ?? "unknown"
        let contentTime = result.contentUpdatedAt.map(formatter.string(from:)) ?? "unknown"
        let generatedTime = result.generatedAt.map(formatter.string(from:)) ?? "unknown"
        let readTime = formatter.string(from: now)
        let digest = String((result.librarySHA256 ?? "none").prefix(12))
        let version = "\(result.sourceVersion ?? "unknown")/\(result.sourceBuild ?? "unknown")"
        log.info("readAt=\(readTime, privacy: .public) source=\(result.source.rawValue, privacy: .public) sourceModifiedAt=\(sourceTime, privacy: .public) contentUpdatedAt=\(contentTime, privacy: .public) generatedAt=\(generatedTime, privacy: .public) sha256=\(digest, privacy: .public) producer=\(version, privacy: .public)")
        return result
    }

    private static func read(groupURL: URL?, now: Date) -> RhythmWidgetReadResult {
        guard let groupURL else { return .unavailable(at: now) }
        let snapshotURL = groupURL.appendingPathComponent("widget-snapshot.json")
        do {
            let bytes = try Data(contentsOf: snapshotURL)
            if let current = try? envelopeResult(bytes, source: .current, now: now) { return current }
            return previous(groupURL: groupURL, now: now)
        } catch {
            // A failed or denied read must never switch to another data source.
            let cocoa = error as NSError
            guard cocoa.domain == NSCocoaErrorDomain,
                  cocoa.code == NSFileReadNoSuchFileError else {
                return previous(groupURL: groupURL, now: now)
            }
        }
        // Only a genuinely absent new-format publication permits this migration
        // path. It remains inside the signed App Group, never Application Support.
        let legacyURL = groupURL.appendingPathComponent("library.json")
        do {
            let bytes = try Data(contentsOf: legacyURL)
            _ = try RhythmWidgetSnapshotEnvelope.validateLibrary(bytes)
            let data = try JSONDecoder().decode(RhythmWidgetData.self, from: bytes)
            let attributes = try FileManager.default.attributesOfItem(atPath: legacyURL.path)
            guard let modifiedAt = attributes[.modificationDate] as? Date else {
                return previous(groupURL: groupURL, now: now)
            }
            return RhythmWidgetReadResult(data: data, source: .legacy, sourceModifiedAt: modifiedAt,
                                          contentUpdatedAt: nil, generatedAt: nil, readAt: now,
                                          librarySHA256: RhythmWidgetSnapshotEnvelope.sha256(bytes), sourceVersion: nil, sourceBuild: nil)
        } catch {
            return previous(groupURL: groupURL, now: now)
        }
    }

    private static func previous(groupURL: URL, now: Date) -> RhythmWidgetReadResult {
        guard let bytes = try? Data(contentsOf: groupURL.appendingPathComponent("widget-snapshot.previous.json")),
              let result = try? envelopeResult(bytes, source: .previous, now: now) else {
            return .unavailable(at: now)
        }
        return result
    }

    private static func envelopeResult(_ bytes: Data, source: RhythmWidgetReadSource, now: Date) throws -> RhythmWidgetReadResult {
        let envelope = try RhythmWidgetSnapshotEnvelope.decodeValidated(bytes)
        let data = try JSONDecoder().decode(RhythmWidgetData.self, from: envelope.libraryData)
        return RhythmWidgetReadResult(data: data, source: source, sourceModifiedAt: envelope.sourceModifiedAt,
                                      contentUpdatedAt: envelope.contentUpdatedAt, generatedAt: envelope.generatedAt,
                                      readAt: now, librarySHA256: envelope.librarySHA256,
                                      sourceVersion: envelope.sourceVersion, sourceBuild: envelope.sourceBuild)
    }
}
