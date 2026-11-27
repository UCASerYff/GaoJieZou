import Darwin
import Foundation

// Compile the live review, store and persistence. Use a private directory and
// leave shared sleep and normal widget publication disabled in this process.
enum RhythmBundle {
    static let bundle = Bundle.main
    static let defaults = UserDefaults(suiteName: "com.gaojiezou.rhythm.weekly-review-regression")!
}

@main
struct WeeklyReviewRegression {
    @MainActor
    static func main() throws {
        checkLocalWeekAndHistoricalRecords()
        try checkGoalDatesAndReadOnlyStore()
        print("Weekly review regression passed")
    }

    private static func checkLocalWeekAndHistoricalRecords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 1
        func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        func focus(_ id: String, _ start: Date, _ end: Date, elapsed: TimeInterval? = nil) -> FocusRecord {
            FocusRecord(id: id, title: id, linkedActionID: nil, startedAt: start, endedAt: end,
                        durationSeconds: elapsed ?? end.timeIntervalSince(start), earnedCoins: 0)
        }
        let now = date(11, 2, 10)
        let habit = Habit(id: "Habit-ONE", title: "Current name", symbol: "circle", weekdays: [2],
                          rewardCoins: 1, createdAt: now)
        let sleep = SleepRecord(id: "canonical-sleep", startedAt: date(11, 1, 22), endedAt: date(11, 2, 6),
                                durationSeconds: 8 * 3600, score: 100, pastureYield: 0)
        let dated = ShortAction(id: "dated", goalID: "goal", title: "Dated work", notes: "",
                                dueDate: date(11, 4), startDate: date(11, 2), endDate: date(11, 4),
                                estimatedMinutes: 40, focusedSeconds: 0, isCompleted: true, rewardClaimed: true,
                                createdAt: date(10, 29), completedAt: now)
        var carried = dated
        carried.id = "carried"
        carried.startDate = date(10, 31)
        carried.isCompleted = false
        carried.completedAt = nil
        var unscheduled = carried
        unscheduled.id = "unscheduled"
        unscheduled.startDate = nil
        unscheduled.endDate = nil
        unscheduled.dueDate = unscheduled.createdAt
        var oldDueDate = unscheduled
        oldDueDate.id = "legacy"
        oldDueDate.dueDate = date(11, 6)
        oldDueDate.estimatedMinutes = 15
        let goal = LongGoal(id: "goal", title: "Project", reason: "", outcome: "", targetValue: 0, currentValue: 0,
                            unit: "", startDate: date(10, 31), targetDate: date(11, 15),
                            status: .completed, rewardClaimed: true, createdAt: date(10, 31))
        let focusRecords = [
            focus("DST fallback", date(11, 1, 0, 30), date(11, 1, 3, 30)),
            focus("Paused across weeks", date(11, 1, 23, 30), date(11, 2, 0, 30), elapsed: 1800),
            focus("Finished at midnight", date(10, 31, 23), date(11, 1), elapsed: 1500),
        ]
        let keys: Set<String> = [
            "Habit-ONE-2026-11-1", "habit-one-2026-11-01", "deleted-habit-2026-11-1",
            "bad-2026-2-30", "habit-one-2026-11-4"
        ]
        func report(_ day: Date, sleepRecords: [SleepRecord]? = [sleep]) -> WeeklyReview {
            WeeklyReview.make(
                containing: day, now: now, calendar: calendar, habits: [habit], habitCompletionKeys: keys,
                focusRecords: focusRecords, sleepRecords: sleepRecords,
                shortActions: [dated, carried, unscheduled, oldDueDate], longGoals: [goal], sleepTargetHours: 8
            )!
        }

        let historic = report(date(11, 1))
        require(historic.weekStart == date(10, 26) && historic.weekEnd == date(11, 1), "Monday–Sunday local week")
        require(historic.currentWeekStart == date(11, 2) && historic.days.count == 7, "seven dates, independent of firstWeekday")
        require(historic.plan == nil && historic.days.allSatisfy { $0.habitPlan == nil }, "historical plan is unknown")
        require(historic.days[5].focusSeconds == 1500 && !historic.days[5].focusEstimated,
                "exact midnight ends in the earlier day")
        require(historic.days[6].focusSeconds == 15300 && historic.days[6].focusEstimated,
                "DST real elapsed plus the correctly apportioned paused focus segment")
        require(historic.days[6].habits.count == 2 && historic.habitDone == 2, "obsolete schedules do not erase check-ins")
        require(historic.days[6].habits.contains { $0.id == "deleted-habit" && $0.title == nil },
                "deleted check-in evidence has no fabricated title")
        require(historic.sleepSeconds == nil, "overnight sleep belongs to its wake date")
        require(historic.goalDone == 0 && historic.undatedGoalCount == 1, "legacy completion remains undated")

        let current = report(now)
        require(current.days[0].focusSeconds == 900 && current.focusEstimated, "the other half belongs to Monday")
        require(current.focusSeconds + historic.focusSeconds == 4 * 3600 + 1800 + 1500,
                "cross-week splits preserve all saved elapsed seconds")
        require(current.days[0].sleep.map(\.id) == [sleep.id] && current.sleepNights == 1 && current.sleepSeconds == 28800,
                "one canonical sleep record")
        require(current.days[1].sleepSeconds == nil && current.habitDone == 0, "missing sleep and future check-ins are distinct")
        require(current.plan?.habitCount == 1 && current.plan?.focusMinutes == 40 && current.plan?.items.count == 2,
                "timed actions count on their start week, empty dates do not manufacture plans")
        require(current.plan?.items.first(where: { $0.id == dated.id })?.goalTitle == goal.title,
                "plan keeps real action and goal identifiers")
        require(current.days[0].actions.map(\.id) == [dated.id], "completion follows the recorded date")
        let unavailable = report(now, sleepRecords: nil)
        require(unavailable.sleepUnavailable && unavailable.sleepSeconds == nil && unavailable.sleepNights == nil,
                "protected sleep authority does not look like an empty journal")
    }

    @MainActor
    private static func checkGoalDatesAndReadOnlyStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rhythm-weekly-review-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("GAOJIEZOU_DATA_DIR", root.path, 1)
        defer { unsetenv("GAOJIEZOU_DATA_DIR") }
        let store = RhythmStore(startServices: false)
        store.longGoals = []
        let today = Date()
        func saveGoal(existing: String? = nil, status: GoalStatus = .completed) {
            store.saveGoal(existingID: existing, title: "Fixture goal", reason: "", outcome: "", targetValue: 0,
                           currentValue: 0, unit: "", startDate: today, targetDate: today, status: status)
        }
        saveGoal()
        let newGoal = store.longGoals[0]
        require(newGoal.completedAt != nil, "a newly completed goal has a date")
        let coins = store.coins
        saveGoal(existing: newGoal.id)
        require(store.longGoals[0].completedAt == newGoal.completedAt, "editing preserves the known completion date")
        store.setGoalStatus(newGoal, status: .active)
        require(store.longGoals[0].completedAt == nil, "reopening clears the completed status and date")
        store.setGoalStatus(newGoal, status: .completed)
        require(store.longGoals[0].completedAt != nil && store.coins == coins, "recompletion never reissues the reward")
        let path = root.appendingPathComponent("library.json")
        let saved = try Data(contentsOf: path)
        let report = store.weeklyReview(containing: today, sleepTargetHours: 8)
        require(report?.days.contains { $0.goals.contains { $0.id == newGoal.id } } == true,
                "real store routes the completed goal to a date")
        let afterReview = try Data(contentsOf: path)
        require(saved == afterReview, "opening a review does not change the archive")

        var legacy = newGoal
        legacy.completedAt = nil
        let encoded = try JSONEncoder().encode(legacy)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        require(object?["completedAt"] == nil, "absent completion remains absent on disk")
        let decoded = try JSONDecoder().decode(LongGoal.self, from: encoded)
        require(decoded.status == .completed && decoded.completedAt == nil, "decode schema 11 without a completion date")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ description: String) {
        precondition(condition(), description)
    }
}
