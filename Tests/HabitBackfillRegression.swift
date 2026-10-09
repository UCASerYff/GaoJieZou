import AppKit
import Foundation

// Compile the real store and persistence. The runner never starts an app or
// touches its data directory, App Group snapshot, or notification settings.
enum RhythmBundle {
    static let bundle = Bundle.main
    static let defaults = UserDefaults(suiteName: "com.gaojiezou.rhythm.habit-backfill-regression")!
}

@main
struct HabitBackfillRegression {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhythm-habit-backfill-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            RhythmBundle.defaults.removePersistentDomain(forName: "com.gaojiezou.rhythm.habit-backfill-regression")
        }
        unsetenv("GAOSERIES_SLEEP_TEST_DIRECTORY")

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = day(-1, from: today, calendar: calendar)
        let firstDay = day(-3, from: today, calendar: calendar)
        let secondDay = day(-2, from: today, calendar: calendar)
        let habit = Habit(id: "backfill-daily-reading", title: "Daily reading", symbol: "book.fill",
                          weekdays: Set(1...7), rewardCoins: 7,
                          createdAt: atHour(18, on: firstDay, calendar: calendar))

        let normalDirectory = root.appendingPathComponent("normal", isDirectory: true)
        var fixture = emptyFixture(habits: [habit])
        fixture.habitCompletionKeys = [key(habit, firstDay, calendar), key(habit, secondDay, calendar)]
        fixture.habitRewardKeys = fixture.habitCompletionKeys
        try writeFixture(fixture, to: normalDirectory)
        setenv("GAOJIEZOU_DATA_DIR", normalDirectory.path, 1)
        var store: RhythmStore? = RhythmStore()
        require(!store!.loadFailed, "a valid historical fixture must load")
        require(store!.habitStreaks(today: today).current == 0 && store!.habitStreaks(today: today).longest == 2,
                "the missed yesterday must break the current streak before backfill")
        let before = store!.habitDaySummaries(until: today, calendar: calendar)
        require(summary(before, for: yesterday, calendar: calendar).completed == 0,
                "the historical day must start incomplete")
        require(summary(before, for: today, calendar: calendar).completed == 0,
                "today must start incomplete")

        let operationStarted = Date()
        require(store!.toggleHabit(habit, on: atHour(7, on: yesterday, calendar: calendar)),
                "yesterday's scheduled habit must accept backfill")
        require(store!.isHabitCompleted(habit, on: yesterday), "backfill must belong to yesterday")
        require(!store!.isHabitCompleted(habit, on: today), "backfill must not complete today's habit")
        require(store!.pendingHabitCountToday == 1, "today's reminder count must remain pending")
        require(store!.coins == fixture.coins + 7 && store!.rewardEvents.count == 1,
                "the first backfill must award exactly the habit's daily reward")
        require(store!.rewardEvents[0].title == RhythmLocalization.text("补打日常打卡"),
                "historical check-in must identify its reward as backfill")
        require(store!.rewardEvents[0].date >= operationStarted && calendar.isDateInToday(store!.rewardEvents[0].date),
                "the reward audit event must record actual operation time")
        let after = store!.habitDaySummaries(until: today, calendar: calendar)
        let historicalSummary = summary(after, for: yesterday, calendar: calendar)
        require(historicalSummary.scheduled == 1 && historicalSummary.completed == 1,
                "the statistics data must repair yesterday's completion rate to 100 percent")
        require(summary(after, for: today, calendar: calendar).completed == 0,
                "the statistics data must not add a completion to today")
        require(store!.habitStreaks(today: today).current == 3 && store!.habitStreaks(today: today).longest == 3,
                "backfill must join the earlier two completed days into a three-day streak")

        let dailyCoins = store!.coins
        let dailyEvents = store!.rewardEvents
        require(store!.toggleHabit(habit, on: atHour(20, on: yesterday, calendar: calendar)),
                "another hour of the same selected day must cancel the same completion")
        require(!store!.isHabitCompleted(habit, on: yesterday), "cancellation must remove yesterday's completion")
        require(store!.habitRewardKeys.contains(key(habit, yesterday, calendar)),
                "cancellation must retain the daily reward receipt")
        require(store!.coins == dailyCoins && store!.rewardEvents == dailyEvents,
                "cancellation must not change the already awarded coins or audit events")
        require(store!.toggleHabit(habit, on: atHour(1, on: yesterday, calendar: calendar)),
                "the cancelled date must be completable again")
        require(store!.coins == dailyCoins && store!.rewardEvents == dailyEvents,
                "cancel and backfill again must not award that date twice")
        require(store!.habitCompletionKeys.count == 3 && store!.habitRewardKeys.count == 3,
                "different hours of the same day must share one completion and reward receipt")

        let csv = RhythmCSVExport.habitCompletionsCSV(habits: store!.habits,
                                                    completionKeys: store!.habitCompletionKeys,
                                                    calendar: calendar)
        require(csv.contains("Daily reading," + isoDay(yesterday) + ",7\r\n"),
                "CSV must export the selected historical date")
        require(!csv.contains("Daily reading," + isoDay(today) + ","),
                "CSV must not turn the backfill into a row dated today")
        require(csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count == 4,
                "CSV must have exactly one header and one row per completed date")

        require(store!.toggleHabit(habit, on: today), "today must remain separately completable")
        require(store!.coins == dailyCoins + 7 && store!.rewardEvents.count == dailyEvents.count + 1,
                "different dates must each award their daily reward once")
        require(store!.habitStreaks(today: today).current == 4 && store!.habitStreaks(today: today).longest == 4,
                "completing today must extend the repaired historical streak")
        let saved = try readFixture(from: normalDirectory)
        require(saved.habitCompletionKeys == store!.habitCompletionKeys && saved.habitRewardKeys == store!.habitRewardKeys,
                "completion and reward receipts must both be persisted")
        require(saved.coins == store!.coins && saved.rewardEvents == store!.rewardEvents,
                "reward balance and audit events must be persisted with the completion")
        store = nil
        store = RhythmStore()
        require(store!.habitCompletionKeys == saved.habitCompletionKeys && store!.habitRewardKeys == saved.habitRewardKeys,
                "relaunch must retain historical completion and reward receipts")
        require(store!.coins == saved.coins && store!.rewardEvents == saved.rewardEvents,
                "relaunch must preserve reward balance and event identity")
        require(store!.toggleHabit(habit, on: yesterday) && store!.toggleHabit(habit, on: yesterday),
                "historical completion must remain reversible after relaunch")
        require(store!.coins == saved.coins && store!.rewardEvents == saved.rewardEvents,
                "relaunch must not forget the receipt and grant a second reward")
        store = nil

        try validateEligibility(root: root, today: today, yesterday: yesterday, calendar: calendar)
        try validateSaveFailure(root: root, habit: habit, yesterday: yesterday, today: today, calendar: calendar)
        try validateUnreadableData(root: root, today: today)
        print("PASS Habit backfill: historical attribution; repaired statistics and streaks; one reward per day; eligibility and stale values; durable restart and CSV; failed-write rollback; unreadable-data protection")
    }

    @MainActor
    private static func validateEligibility(root: URL, today: Date, yesterday: Date, calendar: Calendar) throws {
        let directory = root.appendingPathComponent("eligibility", isDirectory: true)
        let original = Habit(id: "eligible-history", title: "Old title", symbol: "star", weekdays: Set(1...7),
                             rewardCoins: 10, createdAt: atHour(18, on: day(-3, from: today, calendar: calendar), calendar: calendar))
        let sparse = Habit(id: "weekday-only", title: "Yesterday only", symbol: "calendar",
                           weekdays: [calendar.component(.weekday, from: yesterday)], rewardCoins: 2,
                           createdAt: original.createdAt)
        try writeFixture(emptyFixture(habits: [original, sparse]), to: directory)
        setenv("GAOJIEZOU_DATA_DIR", directory.path, 1)
        let store = RhythmStore()
        let initialCoins = store.coins
        require(!store.toggleHabit(original, on: day(1, from: today, calendar: calendar)), "future dates must be rejected")
        require(!store.toggleHabit(original, on: Date(timeIntervalSinceReferenceDate: .nan)), "invalid dates must be rejected")
        require(!store.toggleHabit(original, on: day(-4, from: today, calendar: calendar)), "dates before creation must be rejected")
        require(!store.toggleHabit(sparse, on: today), "a weekday absent from the schedule must be rejected")
        require(store.coins == initialCoins && store.habitCompletionKeys.isEmpty && store.habitRewardKeys.isEmpty && store.rewardEvents.isEmpty,
                "rejected dates must not mutate completion or economy")
        require(store.toggleHabit(original, on: atHour(0, on: original.createdAt, calendar: calendar)),
                "the creation date must be eligible from the beginning of that calendar day")

        store.saveHabit(existingID: original.id, title: "Current title", symbol: "book", weekdays: Set(1...7), rewardCoins: 4)
        let beforeBackfill = store.coins
        require(store.toggleHabit(original, on: yesterday), "an old UI value must resolve the habit by identity")
        require(store.coins == beforeBackfill + 4 && store.rewardEvents[0].coins == 4,
                "an old Habit value must use the current reward rather than its old reward")
        require(store.rewardEvents[0].detail.contains("Current title") && !store.rewardEvents[0].detail.contains("Old title"),
                "the reward event must describe the current habit")
        store.saveHabit(existingID: original.id, title: "Current title", symbol: "book",
                        weekdays: sparse.weekdays, rewardCoins: 4)
        let beforeUnscheduled = store.coins
        require(!store.toggleHabit(original, on: today), "an old UI value must respect the current weekday schedule")
        require(store.coins == beforeUnscheduled, "a stale schedule must not grant a reward")
        store.deleteHabit(original)
        let beforeDeleted = try store.backupData()
        let deletedState = try JSONDecoder().decode(RhythmLibrary.self, from: beforeDeleted)
        require(!store.toggleHabit(original, on: yesterday), "a deleted habit must not be toggled by an old UI value")
        require(store.habitCompletionKeys == deletedState.habitCompletionKeys
                    && store.habitRewardKeys == deletedState.habitRewardKeys
                    && store.coins == deletedState.coins && store.rewardEvents == deletedState.rewardEvents,
                "rejecting a deleted habit must preserve its existing history and economy")
    }

    @MainActor
    private static func validateSaveFailure(root: URL, habit: Habit, yesterday: Date, today: Date, calendar: Calendar) throws {
        let directory = root.appendingPathComponent("write-failure", isDirectory: true)
        try writeFixture(emptyFixture(habits: [habit]), to: directory)
        setenv("GAOJIEZOU_DATA_DIR", directory.path, 1)
        let store = RhythmStore()
        let originalData = try Data(contentsOf: directory.appendingPathComponent("library.json"))
        let originalCoins = store.coins
        let obstacle = directory.appendingPathComponent("library.json.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: obstacle, withIntermediateDirectories: false)
        try Data("keep directory nonempty".utf8).write(to: obstacle.appendingPathComponent("sentinel"))
        require(!store.toggleHabit(habit, on: yesterday), "a real filesystem write failure must report failure")
        require(!store.isHabitCompleted(habit, on: yesterday) && store.habitRewardKeys.isEmpty,
                "a failed save must roll back completion and reward receipts")
        require(store.coins == originalCoins && store.rewardEvents.isEmpty,
                "a failed save must roll back coins and audit events")
        try require(try Data(contentsOf: directory.appendingPathComponent("library.json")) == originalData,
                "a failed write must preserve the previous archive bytes")
        try FileManager.default.removeItem(at: obstacle)
        require(store.toggleHabit(habit, on: yesterday), "retry after the write failure is resolved must succeed")
        require(store.coins == originalCoins + habit.rewardCoins && store.rewardEvents.count == 1,
                "the successful retry must award exactly once")

        let completedData = try Data(contentsOf: directory.appendingPathComponent("library.json"))
        let completedState = try readFixture(from: directory)
        try FileManager.default.createDirectory(at: obstacle, withIntermediateDirectories: false)
        try Data("keep directory nonempty".utf8).write(to: obstacle.appendingPathComponent("sentinel"))
        require(!store.toggleHabit(habit, on: yesterday), "cancellation must also fail when it cannot be saved")
        require(store.isHabitCompleted(habit, on: yesterday)
                    && store.habitCompletionKeys == completedState.habitCompletionKeys
                    && store.habitRewardKeys == completedState.habitRewardKeys
                    && store.coins == completedState.coins && store.rewardEvents == completedState.rewardEvents,
                "a failed cancellation must restore the previously completed state")
        require(!store.toggleHabit(habit, on: today), "a different day's new completion must fail while writes are blocked")
        require(!store.isHabitCompleted(habit, on: today) && store.coins == completedState.coins
                    && store.rewardEvents == completedState.rewardEvents,
                "a failed second date must not leak a new completion or reward")
        try require(try Data(contentsOf: directory.appendingPathComponent("library.json")) == completedData,
                "multiple failed changes must preserve the last good archive")
    }

    @MainActor
    private static func validateUnreadableData(root: URL, today: Date) throws {
        let directory = root.appendingPathComponent("read-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let damagedData = Data("{ broken archive and private original bytes".utf8)
        let archive = directory.appendingPathComponent("library.json")
        try damagedData.write(to: archive)
        setenv("GAOJIEZOU_DATA_DIR", directory.path, 1)
        var store: RhythmStore? = RhythmStore()
        require(store!.loadFailed, "invalid existing data must enter read-only protection")
        let initialCoins = store!.coins
        let initialCompletions = store!.habitCompletionKeys
        let initialRewards = store!.habitRewardKeys
        let initialEvents = store!.rewardEvents
        require(!store!.toggleHabit(store!.habits[0], on: today), "read-only protection must prohibit habit changes")
        require(store!.coins == initialCoins && store!.habitCompletionKeys == initialCompletions
                    && store!.habitRewardKeys == initialRewards && store!.rewardEvents == initialEvents,
                "a protected library must not display false completion or rewards")
        try require(try Data(contentsOf: archive) == damagedData, "a protected library must preserve unreadable original data")
        require(FileManager.default.fileExists(atPath: archive.appendingPathExtension("read-only").path),
                "read-only protection must survive application relaunch")
        store = nil
        store = RhythmStore()
        require(store!.loadFailed && !store!.toggleHabit(store!.habits[0], on: today),
                "relaunch must continue to prohibit changes until data is recovered")
        try require(try Data(contentsOf: archive) == damagedData, "relaunch must not replace the protected archive")
    }

    private static func emptyFixture(habits: [Habit]) -> RhythmLibrary {
        var library = RhythmLibrary.starter()
        library.habits = habits
        library.longGoals = []
        library.shortActions = []
        library.farmPlots = []
        library.rewardEvents = []
        return library
    }

    private static func writeFixture(_ library: RhythmLibrary, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
    }

    private static func readFixture(from directory: URL) throws -> RhythmLibrary {
        try JSONDecoder().decode(RhythmLibrary.self, from: Data(contentsOf: directory.appendingPathComponent("library.json")))
    }

    private static func day(_ offset: Int, from date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: offset, to: date)!
    }

    private static func atHour(_ hour: Int, on date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
    }

    private static func key(_ habit: Habit, _ date: Date, _ calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(habit.id)-\(components.year!)-\(components.month!)-\(components.day!)"
    }

    private static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func summary(_ days: [(date: Date, scheduled: Int, completed: Int)], for date: Date,
                                calendar: Calendar) -> (date: Date, scheduled: Int, completed: Int) {
        days.first { calendar.isDate($0.date, inSameDayAs: date) }!
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try condition() else { fatalError(message) }
    }
}
