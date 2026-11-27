import Foundation

/// A read-only Monday–Sunday report. Planned counts in past weeks are unknown
/// because the library stores current schedules, not snapshots of those weeks.
struct WeeklyReview {
    struct FocusEntry: Identifiable {
        let record: FocusRecord
        let seconds: TimeInterval
        let estimated: Bool
        var id: String { record.id }
    }

    struct CheckIn: Identifiable {
        let id: String
        let title: String?
        let completionKey: String
    }

    struct Day: Identifiable {
        let date: Date
        var focus: [FocusEntry] = []
        var habits: [CheckIn] = []
        var sleep: [SleepRecord] = []
        var actions: [ShortAction] = []
        var goals: [LongGoal] = []
        var habitPlan: Int?

        var id: Date { date }
        var focusSeconds: TimeInterval { focus.reduce(0) { $0 + $1.seconds } }
        var focusEstimated: Bool { focus.contains(where: \.estimated) }
        var sleepSeconds: TimeInterval? {
            sleep.isEmpty ? nil : sleep.reduce(0) { $0 + $1.durationSeconds }
        }
    }

    struct PlannedAction: Identifiable {
        let action: ShortAction
        let startDate: Date
        let endDate: Date
        let goalTitle: String?
        var id: String { action.id }
    }

    struct Plan {
        let focusMinutes: Int?
        let habitCount: Int
        let sleepTargetHours: Double?
        let items: [PlannedAction]
        let goals: [LongGoal]
    }

    let weekStart: Date
    let weekEnd: Date
    let currentWeekStart: Date
    let today: Date
    let days: [Day]
    let plan: Plan?
    let sleepUnavailable: Bool
    let undatedActionCount: Int
    let undatedGoalCount: Int

    var focusSeconds: TimeInterval { days.reduce(0) { $0 + $1.focusSeconds } }
    var focusEstimated: Bool { days.contains(where: \.focusEstimated) }
    var habitDone: Int { days.reduce(0) { $0 + $1.habits.count } }
    var actionDone: Int { days.reduce(0) { $0 + $1.actions.count } }
    var goalDone: Int { days.reduce(0) { $0 + $1.goals.count } }
    var sleepSeconds: TimeInterval? {
        let durations = days.compactMap(\.sleepSeconds)
        return durations.isEmpty ? nil : durations.reduce(0, +)
    }
    var sleepNights: Int? {
        sleepUnavailable ? nil : days.filter { !$0.sleep.isEmpty }.count
    }

    static func monday(containing date: Date, calendar: Calendar) -> Date? {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        return calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: day).map {
            calendar.startOfDay(for: $0)
        }
    }

    static func make(
        containing date: Date,
        now: Date,
        calendar: Calendar,
        habits: [Habit],
        habitCompletionKeys: Set<String>,
        focusRecords: [FocusRecord],
        sleepRecords: [SleepRecord]?,
        shortActions: [ShortAction],
        longGoals: [LongGoal],
        sleepTargetHours: Double
    ) -> WeeklyReview? {
        guard let first = monday(containing: date, calendar: calendar),
              let currentWeek = monday(containing: now, calendar: calendar) else { return nil }
        let boundaries = (0...7).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
            .map { calendar.startOfDay(for: $0) }
        guard boundaries.count == 8, let last = boundaries.last,
              Set(boundaries).count == boundaries.count else { return nil }
        var days = boundaries.dropLast().map { Day(date: $0) }
        let indices = Dictionary(uniqueKeysWithValues: days.indices.map { (days[$0].date, $0) })
        let today = calendar.startOfDay(for: now)
        let goalsByID = Dictionary(longGoals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for record in focusRecords where record.endedAt <= now && record.endedAt >= first
            && record.startedAt < last && record.durationSeconds.isFinite && record.durationSeconds >= 0 {
            let duration = record.durationSeconds
            let span = record.endedAt.timeIntervalSince(record.startedAt)
            if span <= 0 || duration == 0 {
                if let day = indices[calendar.startOfDay(for: record.endedAt)] {
                    days[day].focus.append(FocusEntry(record: record, seconds: duration, estimated: duration > 0))
                }
                continue
            }
            // Records retain total elapsed time, but do not retain past pause segments.
            // Use absolute overlap with each local day, including shortened/extended DST days.
            let lastElapsedInstant = record.endedAt.addingTimeInterval(-min(0.001, span / 2))
            let estimated = abs(span - duration) > 1
                && !calendar.isDate(record.startedAt, inSameDayAs: lastElapsedInstant)
            for index in days.indices {
                let start = max(record.startedAt, boundaries[index])
                let end = min(record.endedAt, boundaries[index + 1])
                if end > start {
                    let portion = duration * (end.timeIntervalSince(start) / span)
                    days[index].focus.append(FocusEntry(record: record, seconds: portion, estimated: estimated))
                }
            }
        }
        appendCheckIns(habitCompletionKeys, habits: habits, today: today, calendar: calendar, days: &days)
        for record in sleepRecords ?? [] where record.endedAt <= now && record.durationSeconds.isFinite && record.durationSeconds >= 0 {
            if let day = indices[calendar.startOfDay(for: record.endedAt)] { days[day].sleep.append(record) }
        }

        var undatedActions = 0
        for action in shortActions where action.isCompleted {
            if let completed = action.completedAt, completed <= now, completed.timeIntervalSinceReferenceDate.isFinite {
                if let index = indices[calendar.startOfDay(for: completed)] { days[index].actions.append(action) }
            } else {
                undatedActions += 1
            }
        }
        var undatedGoals = 0
        for goal in longGoals where goal.status == .completed {
            if let completed = goal.completedAt, completed <= now, completed.timeIntervalSinceReferenceDate.isFinite {
                if let index = indices[calendar.startOfDay(for: completed)] { days[index].goals.append(goal) }
            } else {
                undatedGoals += 1
            }
        }

        let plan = first < currentWeek ? nil : makePlan(
            from: first, until: last, calendar: calendar, habits: habits, actions: shortActions,
            goalsByID: goalsByID, sleepTargetHours: sleepTargetHours, days: &days
        )
        return WeeklyReview(weekStart: first, weekEnd: boundaries[6], currentWeekStart: currentWeek,
                            today: today, days: days, plan: plan, sleepUnavailable: sleepRecords == nil,
                            undatedActionCount: undatedActions, undatedGoalCount: undatedGoals)
    }

    private static func appendCheckIns(
        _ keys: Set<String>, habits: [Habit], today: Date, calendar: Calendar, days: inout [Day]
    ) {
        let names = Dictionary(habits.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let dateSuffixes = Dictionary(uniqueKeysWithValues: days.indices.map {
            (RhythmShared.habitKey(habitID: "", date: days[$0].date, calendar: calendar), $0)
        })
        var seen: Set<String> = []
        for key in keys.sorted() {
            let pieces = key.split(separator: "-", omittingEmptySubsequences: false)
            let numbers = pieces.suffix(3).compactMap { Int($0) }
            guard pieces.count > 3, numbers.count == 3 else { continue }
            let suffix = "-\(numbers[0])-\(numbers[1])-\(numbers[2])"
            let id = pieces.dropLast(3).joined(separator: "-")
            let lookup = id.lowercased()
            guard !id.isEmpty, let index = dateSuffixes[suffix], days[index].date <= today,
                  seen.insert(lookup + suffix).inserted else { continue }
            days[index].habits.append(CheckIn(id: names[lookup]?.id ?? id, title: names[lookup]?.title, completionKey: key))
        }
    }

    private static func makePlan(
        from first: Date, until last: Date, calendar: Calendar, habits: [Habit], actions: [ShortAction],
        goalsByID: [String: LongGoal], sleepTargetHours: Double, days: inout [Day]
    ) -> Plan {
        var habitCount = 0
        for index in days.indices {
            let date = days[index].date
            let count = habits.filter { $0.isScheduled(on: date, calendar: calendar) }.count
            days[index].habitPlan = count
            habitCount += count
        }
        let items = actions.compactMap { row -> PlannedAction? in
            // The action editor and calendar both use startDate as the schedule.
            // An old dueDate can also remain after a user clears that schedule.
            let start = row.startDate
            guard let start else { return nil }
            let localStart = calendar.startOfDay(for: start)
            let localEnd = calendar.startOfDay(for: max(start, row.normalizedEndDate ?? start))
            guard localStart < last, localEnd >= first else { return nil }
            return PlannedAction(action: row, startDate: localStart, endDate: localEnd,
                                 goalTitle: row.goalID.flatMap { goalsByID[$0]?.title })
        }.sorted { ($0.startDate, $0.endDate, $0.id) < ($1.startDate, $1.endDate, $1.id) }
        let goals = goalsByID.values.filter {
            calendar.startOfDay(for: $0.startDate) < last && calendar.startOfDay(for: $0.targetDate) >= first
        }.sorted { ($0.targetDate, $0.id) < ($1.targetDate, $1.id) }
        let focusMinutes = items.filter { $0.startDate >= first }.reduce(Optional(0)) { total, item -> Int? in
            guard let total, item.action.estimatedMinutes > 0 else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(item.action.estimatedMinutes)
            return overflow ? nil : sum
        }
        let target = sleepTargetHours.isFinite && sleepTargetHours > 0 ? sleepTargetHours : nil
        return Plan(focusMinutes: focusMinutes, habitCount: habitCount, sleepTargetHours: target, items: items, goals: goals)
    }
}

extension RhythmStore {
    /// Use the store's already synchronized journal; opening a review must not
    /// seed, settle rewards, retry failed sync, or write storage.
    func weeklyReview(
        containing date: Date, sleepTargetHours: Double, now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> WeeklyReview? {
        guard !loadFailed else { return nil }
        return WeeklyReview.make(
            containing: date, now: now, calendar: calendar, habits: habits, habitCompletionKeys: habitCompletionKeys,
            focusRecords: focusRecords, sleepRecords: sleepSyncError == nil ? sleepRecords : nil,
            shortActions: shortActions, longGoals: longGoals, sleepTargetHours: sleepTargetHours
        )
    }
}
