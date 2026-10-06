import Foundation

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
    let focusRecords: [FocusRecord]
    let sleepRecords: [SleepRecord]
    let longGoals: [LongGoal]
    let shortActions: [ShortAction]
    let chores: [Chore]

    private enum CodingKeys: String, CodingKey {
        case habits, habitCompletionKeys, activeFocus, focusRecords, sleepRecords
        case longGoals, shortActions, chores
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        habits = try container.decodeIfPresent([Habit].self, forKey: .habits) ?? []
        habitCompletionKeys = try container.decodeIfPresent([String].self, forKey: .habitCompletionKeys) ?? []
        activeFocus = try container.decodeIfPresent(ActiveFocus.self, forKey: .activeFocus)
        focusRecords = try container.decodeIfPresent([FocusRecord].self, forKey: .focusRecords) ?? []
        sleepRecords = try container.decodeIfPresent([SleepRecord].self, forKey: .sleepRecords) ?? []
        longGoals = try container.decodeIfPresent([LongGoal].self, forKey: .longGoals) ?? []
        shortActions = try container.decodeIfPresent([ShortAction].self, forKey: .shortActions) ?? []
        chores = try container.decodeIfPresent([Chore].self, forKey: .chores) ?? []
    }

    static let empty = RhythmWidgetData(
        habits: [], habitCompletionKeys: [], activeFocus: nil, focusRecords: [],
        sleepRecords: [], longGoals: [], shortActions: [], chores: []
    )

    private init(
        habits: [Habit], habitCompletionKeys: [String], activeFocus: ActiveFocus?,
        focusRecords: [FocusRecord], sleepRecords: [SleepRecord],
        longGoals: [LongGoal], shortActions: [ShortAction], chores: [Chore]
    ) {
        self.habits = habits
        self.habitCompletionKeys = habitCompletionKeys
        self.activeFocus = activeFocus
        self.focusRecords = focusRecords
        self.sleepRecords = sleepRecords
        self.longGoals = longGoals
        self.shortActions = shortActions
        self.chores = chores
    }

    static func load() -> RhythmWidgetData {
        // WidgetKit runs this extension in a sandbox, so the main app publishes
        // the latest library snapshot into the shared application-group
        // container whenever it saves. Keep the direct file as a fallback for
        // local previews and older installs.
        if let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("library.json"),
           let data = try? Data(contentsOf: groupURL),
           let library = try? JSONDecoder().decode(RhythmWidgetData.self, from: data) {
            return library
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("GaoSeries/Rhythm", isDirectory: true)
            .appendingPathComponent("library.json")
        guard let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(RhythmWidgetData.self, from: data) else {
            return .empty
        }
        return library
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
