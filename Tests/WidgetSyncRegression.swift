import Foundation

// A command-line unit runner: temporary stores only, no application/UI launch,
// WidgetCenter calls, workspace observers, notifications or real SharedSleep.
enum RhythmBundle {
    static let bundle = Bundle.main
    static let defaults = UserDefaults(suiteName: "com.gaojiezou.rhythm.widget-sync-regression")!
}

@main
struct WidgetSyncRegression {
    static let fm = FileManager.default
    static let encoder = JSONEncoder()

    @MainActor
    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("rhythm-widget-sync-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("GAOJIEZOU_DATA_DIR", root.appendingPathComponent("unused").path, 1)
        unsetenv("GAOSERIES_SLEEP_TEST_DIRECTORY")
        defer {
            try? fm.removeItem(at: root)
            RhythmBundle.defaults.removePersistentDomain(forName: "com.gaojiezou.rhythm.widget-sync-regression")
        }
        try publication(root: root)
        try businessTimeStability(root: root)
        try readerFailures(root: root)
        try timelineAndTimers()
        try businessEvents(root: root)
        try storeRetries(root: root)
        try protectedLoad(root: root)
        print("PASS Widget sync: atomic envelope; strict schema/hash reading; previous valid fallback; failed mirror retry; unchanged business timestamps; real Store habit/goal/action/chore/focus/sleep events; 32-day DST/month boundaries; bounded dynamic timers. No application, UI or smoke test was started.")
    }

    static func fixture() -> RhythmLibrary {
        var library = RhythmLibrary.starter()
        library.habits = []
        library.habitCompletionKeys = []
        library.habitRewardKeys = []
        library.focusRecords = []
        library.sleepRecords = []
        library.longGoals = []
        library.shortActions = []
        library.chores = []
        library.rewardEvents = []
        library.farmPlots = []
        library.pastureAnimals = []
        library.aquariumFish = []
        return library
    }

    static func paths(_ root: URL, _ name: String) -> (RhythmPersistence, URL) {
        let base = root.appendingPathComponent(name)
        let group = base.appendingPathComponent("group")
        return (RhythmPersistence(libraryDirectory: base.appendingPathComponent("main"),
                                  widgetSnapshotURL: group.appendingPathComponent("library.json")), group)
    }

    static func envelope(_ group: URL) throws -> RhythmWidgetSnapshotEnvelope {
        try RhythmWidgetSnapshotEnvelope.decodeValidated(Data(contentsOf: group.appendingPathComponent("widget-snapshot.json")))
    }

    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func publication(root: URL) throws {
        let (p, group) = paths(root, "publication")
        var library = fixture()
        let result = try p.write(library)
        require(result.widgetPublished && !p.widgetPublicationPending, "a successful publication must acknowledge the mirror")
        let first = try envelope(group)
        try require(first.libraryData == Data(contentsOf: p.libraryURL), "envelope must carry the committed main bytes")
        try require(first.libraryData == Data(contentsOf: group.appendingPathComponent("library.json")), "legacy mirror must equal main data")
        let sourceMtime = try fm.attributesOfItem(atPath: p.libraryURL.path)[.modificationDate] as! Date
        require(p.publishCurrentLibrary(), "retrying an existing valid main archive must succeed")
        let sourceMtimeAfter = try fm.attributesOfItem(atPath: p.libraryURL.path)[.modificationDate] as! Date
        require(sourceMtime == sourceMtimeAfter, "publication retries must not rewrite main-file timestamps")
        require(try envelope(group).contentUpdatedAt == first.contentUpdatedAt, "no business change must retain its real content time")

        library.coins += 17
        _ = try p.write(library)
        let gameOnly = try envelope(group)
        require(gameOnly.librarySHA256 != first.librarySHA256, "game changes must still publish the full latest archive")
        require(gameOnly.businessSHA256 == first.businessSHA256 && gameOnly.contentUpdatedAt == first.contentUpdatedAt,
                "game-only save must not pretend widget business content changed")

        let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
        library.habits = [Habit(id: "fixture-habit", title: "Original", symbol: "star", weekdays: Set(1...7), rewardCoins: 5, createdAt: created)]
        _ = try p.write(library)
        let business = try envelope(group)
        require(business.businessSHA256 != gameOnly.businessSHA256, "a real habit mutation must advance the business revision")
        require(business.contentUpdatedAt >= gameOnly.contentUpdatedAt, "business time must be monotonic after actual changes")
        require(fm.fileExists(atPath: group.appendingPathComponent("widget-snapshot.previous.json").path), "keep one previous valid atomic publication")

        let mainBytes = try Data(contentsOf: p.libraryURL)
        let previousBytes = try Data(contentsOf: group.appendingPathComponent("widget-snapshot.json"))
        try fm.removeItem(at: p.libraryURL)
        require(!p.publishCurrentLibrary(), "a missing main archive must not create an empty publication")
        try require(Data(contentsOf: group.appendingPathComponent("widget-snapshot.json")) == previousBytes, "missing source must retain last valid widget bytes")
        try mainBytes.write(to: p.libraryURL, options: .atomic)

        let base = root.appendingPathComponent("blocked-publication")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let blockedGroup = base.appendingPathComponent("group")
        try Data("an existing file blocks the directory".utf8).write(to: blockedGroup)
        let failed = RhythmPersistence(libraryDirectory: base.appendingPathComponent("main"),
                                       widgetSnapshotURL: blockedGroup.appendingPathComponent("library.json"))
        let failure = try failed.write(library)
        require(!failure.widgetPublished && failed.widgetPublicationPending, "mirror failure must retain pending state while main save succeeds")
        try require(JSONDecoder().decode(RhythmLibrary.self, from: Data(contentsOf: failed.libraryURL)).habits.count == 1,
                    "mirror failure must preserve committed business state")
        try fm.removeItem(at: blockedGroup)
        let restarted = RhythmPersistence(libraryDirectory: base.appendingPathComponent("main"),
                                          widgetSnapshotURL: blockedGroup.appendingPathComponent("library.json"))
        require(restarted.widgetPublicationPending, "pending publication must survive a persistence instance restart")
        require(restarted.publishCurrentLibrary() && !restarted.widgetPublicationPending, "retry must recover without another business mutation")
        try require(envelope(blockedGroup).libraryData == Data(contentsOf: failed.libraryURL), "retry must publish latest committed state")
    }

    static func businessTimeStability(root: URL) throws {
        let (p, group) = paths(root, "business-time")
        var library = fixture()
        let anchor = Date(timeIntervalSinceReferenceDate: 800_000_000)
        library.habits = [Habit(id: "stable-set", title: "Synthetic", symbol: "star", weekdays: [1, 3, 5], rewardCoins: 5, createdAt: anchor)]
        library.habitCompletionKeys = ["stable-set-2026-1-1", "stable-set-2026-1-2"]
        library.activeFocus = ActiveFocus(id: "stable-focus", title: "Synthetic", linkedActionID: nil,
                                          startedAt: anchor, accumulatedSeconds: 30, segmentStartedAt: anchor,
                                          pausedForSystem: false, growthCreditedSeconds: 0)
        _ = try p.write(library)
        let initial = try envelope(group)
        var json = try JSONSerialization.jsonObject(with: initial.libraryData) as! [String: Any]
        json["habitCompletionKeys"] = ["stable-set-2026-1-2", "stable-set-2026-1-1"]
        var habits = json["habits"] as! [[String: Any]]
        habits[0]["weekdays"] = [5, 1, 3]
        json["habits"] = habits
        let reordered = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        require(try RhythmWidgetSnapshotEnvelope.businessDigest(reordered) == initial.businessSHA256,
                "Set serialization order must not create a false business revision")

        library.activeFocus?.growthCreditedSeconds = 27
        library.coins += 1
        _ = try p.write(library)
        let settled = try envelope(group)
        require(settled.businessSHA256 == initial.businessSHA256 && settled.contentUpdatedAt == initial.contentUpdatedAt,
                "growth receipts and game settlement must retain actual business time and timer anchors")
        library.activeFocus?.segmentStartedAt = nil
        library.activeFocus?.accumulatedSeconds = 57
        _ = try p.write(library)
        let paused = try envelope(group)
        require(paused.businessSHA256 != settled.businessSHA256, "a real focus pause must be a new business revision")

        library.activeFocus = nil
        library.activeSleep = ActiveSleep(id: "stable-sleep", startedAt: anchor, targetHours: 8,
                                         growthCreditedSeconds: 0, productionCyclesCredited: 0, pastureYieldCredited: 0)
        _ = try p.write(library)
        let sleepStarted = try envelope(group)
        library.activeSleep?.growthCreditedSeconds = 100
        library.activeSleep?.productionCyclesCredited = 1
        library.activeSleep?.pastureYieldCredited = 2
        _ = try p.write(library)
        let sleepSettled = try envelope(group)
        require(sleepSettled.businessSHA256 == sleepStarted.businessSHA256 && sleepSettled.contentUpdatedAt == sleepStarted.contentUpdatedAt,
                "unchanged active sleep anchors must retain business time during estate settlement")
    }

    static func changedJSON(_ data: Data, key: String, value: Any?) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func readerFailures(root: URL) throws {
        let (p, group) = paths(root, "reader")
        var library = fixture()
        library.habits = [Habit(id: "reader-habit", title: "First revision", symbol: "book", weekdays: Set(1...7), rewardCoins: 5, createdAt: Date())]
        _ = try p.write(library)
        let first = try envelope(group)
        library.habits[0].title = "Second revision"
        _ = try p.write(library)
        let second = try envelope(group)
        let readAt = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let current = RhythmWidgetReader.load(groupURL: group, now: readAt)
        require(current.source == .current && current.data?.habits.first?.title == "Second revision", "current validated revision must be preferred")
        require(current.readAt == readAt && current.generatedAt == second.generatedAt && current.contentUpdatedAt == second.contentUpdatedAt,
                "reader must preserve source/generation time separately from actual read time")
        require(current.librarySHA256 == second.librarySHA256, "reader diagnostic hash must identify loaded bytes")
        let currentURL = group.appendingPathComponent("widget-snapshot.json")
        let currentBytes = try Data(contentsOf: currentURL)
        try Data("broken current".utf8).write(to: currentURL, options: .atomic)
        let previous = RhythmWidgetReader.load(groupURL: group, now: readAt)
        require(previous.source == .previous && previous.librarySHA256 == first.librarySHA256,
                "broken current must retain the last valid publication and must not use a newer unvalidated legacy mirror")
        require(previous.sourceModifiedAt == first.sourceModifiedAt && previous.contentUpdatedAt == first.contentUpdatedAt
                    && previous.generatedAt == first.generatedAt && previous.readAt == readAt,
                "previous fallback must preserve its original three timestamps and the current read time")

        try changedJSON(currentBytes, key: "librarySHA256", value: "wrong").write(to: currentURL, options: .atomic)
        require(RhythmWidgetReader.load(groupURL: group, now: readAt).source == .previous, "mismatched payload hash must reject current")
        try changedJSON(currentBytes, key: "formatVersion", value: 999).write(to: currentURL, options: .atomic)
        require(RhythmWidgetReader.load(groupURL: group, now: readAt).source == .previous, "future envelope format must preserve previous content")
        try fm.removeItem(at: group.appendingPathComponent("widget-snapshot.previous.json"))
        let unavailable = RhythmWidgetReader.load(groupURL: group, now: readAt)
        require(unavailable.source == .unavailable && unavailable.data == nil, "unreadable current with no valid previous must not become fake zero values")
        try fm.removeItem(at: currentURL)
        let legacyResult = RhythmWidgetReader.load(groupURL: group, now: readAt)
        require(legacyResult.source == .legacy, "valid legacy archive remains compatible only before first envelope")

        let legacyURL = group.appendingPathComponent("library.json")
        let legacyMtime = try fm.attributesOfItem(atPath: legacyURL.path)[.modificationDate] as! Date
        require(legacyResult.sourceModifiedAt == legacyMtime && legacyResult.contentUpdatedAt == nil && legacyResult.generatedAt == nil,
                "legacy file mtime must never be represented as a known business modification or snapshot generation time")
        let legacy = try Data(contentsOf: legacyURL)
        for invalid in [try changedJSON(legacy, key: "version", value: 999),
                        try changedJSON(legacy, key: "habits", value: nil),
                        try changedJSON(legacy, key: "habitCompletionKeys", value: [1, 2]),
                        Data("{not json".utf8)] {
            try invalid.write(to: legacyURL, options: .atomic)
            require(RhythmWidgetReader.load(groupURL: group, now: readAt).data == nil, "future schema, missing core arrays and corrupt data must fail closed")
        }
        try fm.removeItem(at: legacyURL)
        try fm.createDirectory(at: legacyURL, withIntermediateDirectories: false)
        require(RhythmWidgetReader.load(groupURL: group, now: readAt).data == nil, "unreadable file type must not become an empty archive")
        require(RhythmWidgetReader.load(groupURL: nil, now: readAt).data == nil, "missing App Group must not read a sandbox-local backup path")
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    static func widgetData(_ library: RhythmLibrary) throws -> RhythmWidgetData {
        try JSONDecoder().decode(RhythmWidgetData.self, from: encoder.encode(library))
    }

    static func timelineAndTimers() throws {
        for zone in ["Asia/Shanghai", "America/Los_Angeles", "Europe/Berlin"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            for now in [date(2026, 10, 18, 15, calendar: calendar), date(2026, 3, 1, 12, calendar: calendar), date(2026, 10, 25, 12, calendar: calendar)] {
                let dates = RhythmWidgetTimelineSchedule.dates(now: now, calendar: calendar)
                require(dates.count == 33 && dates[0] == now, "timeline must include now and 32 calendar midnights")
                for day in 1...32 {
                    require(dates[day] == calendar.date(byAdding: .day, value: day, to: calendar.startOfDay(for: now)),
                            "future entry must use calendar arithmetic across DST and month boundaries")
                    require(dates[day] > dates[day - 1], "timeline dates must remain strictly increasing")
                }
                require(calendar.component(.month, from: dates[32]) != calendar.component(.month, from: now), "32-day horizon must advance across a month")
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = date(2026, 3, 8, 12, calendar: calendar)
        var library = fixture()
        library.focusRecords = [FocusRecord(id: "completed", title: "Synthetic", linkedActionID: nil,
                                             startedAt: now.addingTimeInterval(-3600), endedAt: now.addingTimeInterval(-1800), durationSeconds: 1800, earnedCoins: 0)]
        library.activeFocus = ActiveFocus(id: "active", title: "Synthetic", linkedActionID: nil,
                                          startedAt: now.addingTimeInterval(-900), accumulatedSeconds: 300,
                                          segmentStartedAt: now.addingTimeInterval(-600), pausedForSystem: false, growthCreditedSeconds: 0)
        let data = try widgetData(library)
        let interval = data.focusTimerInterval(on: now, referenceDate: now, calendar: calendar)
        require(interval != nil, "running focus must use a bounded native timer interval")
        require(abs(now.timeIntervalSince(interval!.lowerBound) - 2700) < 0.001, "timer anchor must include completed plus active focus time")
        require(interval!.upperBound == calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)), "dynamic timer must stop at next local midnight")
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        require(data.focusTimerInterval(on: tomorrow, referenceDate: now, calendar: calendar) == nil, "future entry must not use a current-day timer anchor")
        library.activeFocus?.segmentStartedAt = nil
        require(try widgetData(library).focusTimerInterval(on: now, referenceDate: now, calendar: calendar) == nil, "paused focus must show a stable duration")
        library.activeFocus = nil
        require(try widgetData(library).focusTimerInterval(on: now, referenceDate: now, calendar: calendar) == nil, "finished or cancelled focus must stop dynamic timer")
    }

    @MainActor
    static func businessEvents(root: URL) throws {
        let (p, group) = paths(root, "store-events")
        _ = try p.write(fixture())
        let store = RhythmStore(persistence: p, startServices: false)
        let now = Date()
        func latest() throws -> RhythmWidgetData {
            let published = try envelope(group)
            try require(published.libraryData == Data(contentsOf: p.libraryURL), "every business mutation must publish the corresponding committed bytes")
            let value = RhythmWidgetReader.load(groupURL: group, now: now)
            require(value.source == .current && value.librarySHA256 == published.librarySHA256, "widget must read the exact newly committed revision")
            return value.data!
        }
        store.saveHabit(existingID: nil, title: "Synthetic habit", symbol: "star", weekdays: Set(1...7), rewardCoins: 5)
        let habit = store.habits[0]
        require(try latest().habits.count == 1, "new habit must reach widget")
        require(store.toggleHabit(habit), "synthetic habit completion must save")
        require(try latest().habitStats(on: now).completed == 1, "habit check-in must reach widget completion count")
        require(store.toggleHabit(habit), "synthetic habit cancellation must save")
        require(try latest().habitStats(on: now).completed == 0, "habit cancellation must reach widget")
        store.saveHabit(existingID: habit.id, title: "Edited synthetic habit", symbol: "book", weekdays: Set(1...7), rewardCoins: 6)
        require(try latest().habits[0].title == "Edited synthetic habit", "habit edit must reach widget content")
        store.deleteHabit(store.habits[0])
        require(try latest().habits.isEmpty, "habit deletion must reach widget")

        store.saveGoal(existingID: nil, title: "Synthetic goal", reason: "", outcome: "", targetValue: 2,
                       currentValue: 0, unit: "", startDate: now, targetDate: now, status: .active)
        let goal = store.longGoals[0]
        require(try latest().longGoals.count == 1, "new goal must reach widget")
        store.setGoalStatus(goal, status: .completed)
        require(try latest().longGoals[0].status == "completed", "goal completion must reach widget")
        store.saveAction(existingID: nil, goalID: goal.id, title: "Synthetic action", notes: "", startDate: now,
                         endDate: now.addingTimeInterval(3600), estimatedMinutes: 25, isCompleted: false)
        require(try latest().shortActions.count == 1, "new action must reach monthly overview")
        let action = store.shortActions[0]
        store.toggleAction(action)
        require(try latest().shortActions[0].isCompleted, "action completion must reach widget")
        store.deleteAction(action)
        require(try latest().shortActions.isEmpty, "action deletion must reach widget")
        store.deleteGoal(goal)
        require(try latest().longGoals.isEmpty, "goal deletion must reach widget")

        var chore = Chore()
        chore.id = "synthetic-chore"; chore.title = "Synthetic chore"; chore.startDate = now; chore.endDate = now.addingTimeInterval(3600)
        store.saveChore(chore)
        require(try latest().chores.count == 1, "new chore must reach monthly overview")
        store.toggleChore(chore.id)
        require(try latest().chores[0].isCompleted, "chore completion must reach widget")
        store.deleteChore(chore.id)
        require(try latest().chores.isEmpty, "chore deletion must reach widget")

        store.startFocus(linkedActionID: nil)
        require(try latest().activeFocus?.segmentStartedAt != nil, "focus start must publish its real clock anchor")
        store.pauseFocus()
        require(try latest().activeFocus != nil && latest().activeFocus?.segmentStartedAt == nil, "pause must publish stable accumulated focus")
        store.resumeFocus()
        require(try latest().activeFocus?.segmentStartedAt != nil, "resume must publish new running anchor")
        store.finishFocus()
        require(try latest().activeFocus == nil && latest().focusRecords.count == 1, "finish must publish final record without throttle delay")
        store.startFocus(linkedActionID: nil)
        store.cancelFocus()
        require(try latest().activeFocus == nil && latest().focusRecords.count == 1, "cancel must clear session without adding a record")

        store.startSleep(at: now.addingTimeInterval(-3600), targetHours: 8)
        let sleepBytes = try envelope(group).libraryData
        let activeLibrary = try JSONDecoder().decode(RhythmLibrary.self, from: sleepBytes)
        require(activeLibrary.activeSleep != nil, "sleep start must be in the shared publication even before completion")
        store.finishSleep(at: now, targetHours: 8)
        require(try latest().sleepRecords.count == 1, "sleep finish must publish its settled record")
        store.startSleep(at: now, targetHours: 8)
        store.cancelSleep()
        require(try JSONDecoder().decode(RhythmLibrary.self, from: envelope(group).libraryData).activeSleep == nil,
                "sleep cancel must clear active state in publication")
        require(store.prepareForTermination(), "termination must save final pending state without UI")
        _ = try latest()
    }

    @MainActor
    static func storeRetries(root: URL) throws {
        let (p, group) = paths(root, "store-retries")
        _ = try p.write(fixture())
        var reloads = 0
        let store = RhythmStore(persistence: p, startServices: false, widgetReload: { reloads += 1 })
        let initialReloads = reloads
        let legacy = group.appendingPathComponent("library.json")
        let originalPublication = try Data(contentsOf: group.appendingPathComponent("widget-snapshot.json"))
        try fm.removeItem(at: legacy)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: false)
        try Data("block atomic mirror replacement".utf8).write(to: legacy.appendingPathComponent("sentinel"))
        store.saveHabit(existingID: nil, title: "Pending synthetic habit", symbol: "star", weekdays: Set(1...7), rewardCoins: 5)
        require(p.widgetPublicationPending && reloads == initialReloads, "failed mirror must not acknowledge reload or discard pending state")
        try require(Data(contentsOf: group.appendingPathComponent("widget-snapshot.json")) == originalPublication,
                    "mirror write failure must preserve previous canonical publication")
        try fm.removeItem(at: legacy)
        store.maintainWidgetPublication(at: Date().addingTimeInterval(31))
        require(!p.widgetPublicationPending && reloads > initialReloads, "idle maintenance must recover final mirror failure without another event")
        require(RhythmWidgetReader.load(groupURL: group).data?.habits.count == 1, "idle retry must deliver real pending business content")

        func blockMain() throws {
            let temporary = p.libraryURL.appendingPathExtension("tmp")
            try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
            try Data("block atomic main replacement".utf8).write(to: temporary.appendingPathComponent("sentinel"))
        }
        func unblockMain() throws { try fm.removeItem(at: p.libraryURL.appendingPathExtension("tmp")) }
        store.startFocus(linkedActionID: nil)
        try blockMain()
        store.cancelFocus()
        require(store.activeFocus == nil, "failed cancellation save retains final in-memory intent for retry")
        let beforeCancelRetry = try JSONDecoder().decode(RhythmLibrary.self, from: Data(contentsOf: p.libraryURL))
        require(beforeCancelRetry.activeFocus != nil, "failed cancellation must not overwrite prior durable archive")
        try unblockMain()
        store.maintainWidgetPublication(at: Date().addingTimeInterval(62))
        let cancelled = try JSONDecoder().decode(RhythmLibrary.self, from: Data(contentsOf: p.libraryURL))
        require(cancelled.activeFocus == nil && RhythmWidgetReader.load(groupURL: group).data?.activeFocus == nil,
                "idle retry must persist and publish final cancel after session becomes idle")

        store.startFocus(linkedActionID: nil)
        store.activeFocus?.segmentStartedAt = Date().addingTimeInterval(-60)
        try blockMain()
        store.finishFocus()
        require(store.activeFocus == nil && store.focusRecords.count == 1, "failed finish save must retain final record in memory")
        try unblockMain()
        store.maintainWidgetPublication(at: Date().addingTimeInterval(93))
        let finished = try JSONDecoder().decode(RhythmLibrary.self, from: Data(contentsOf: p.libraryURL))
        require(finished.activeFocus == nil && finished.focusRecords.count == 1,
                "idle retry must not lose completed focus when main save failed")
        require(RhythmWidgetReader.load(groupURL: group).data?.focusRecords.count == 1, "final completion retry must reach widgets")

        store.startFocus(linkedActionID: nil)
        try blockMain()
        require(!store.prepareForTermination(), "termination must report main-save failure instead of silently losing state")
        try unblockMain()
        require(store.prepareForTermination(), "termination may succeed after storage recovers")
        let terminated = try JSONDecoder().decode(RhythmLibrary.self, from: Data(contentsOf: p.libraryURL))
        require(terminated.activeFocus != nil && terminated.activeFocus?.segmentStartedAt == nil,
                "successful termination must persist a paused recoverable session")
    }

    @MainActor
    static func protectedLoad(root: URL) throws {
        for condition in ["missing", "corrupt", "future"] {
            let (p, group) = paths(root, "protected-" + condition)
            _ = try p.write(fixture())
            let validPublication = try Data(contentsOf: group.appendingPathComponent("widget-snapshot.json"))
            if condition == "missing" {
                try fm.removeItem(at: p.libraryURL)
            } else if condition == "corrupt" {
                try Data("unreadable json".utf8).write(to: p.libraryURL, options: .atomic)
            } else {
                try changedJSON(Data(contentsOf: p.libraryURL), key: "version", value: 999).write(to: p.libraryURL, options: .atomic)
            }
            let reopening = RhythmPersistence(libraryDirectory: p.libraryDirectory,
                                               widgetSnapshotURL: group.appendingPathComponent("library.json"))
            let store = RhythmStore(persistence: reopening, startServices: false)
            require(store.loadFailed && !store.save(), "previous archive evidence with missing/corrupt/newer source must stay read-only")
            require(!reopening.publishCurrentLibrary(), "protected source must not overwrite the last valid publication")
            try require(Data(contentsOf: group.appendingPathComponent("widget-snapshot.json")) == validPublication,
                        "protected load must retain last valid widget content without generating starter or zero values")
        }
    }
}
