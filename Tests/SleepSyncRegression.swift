import AppKit
import Foundation

enum RhythmBundle {
    static let bundle = Bundle.main
    static let defaults = UserDefaults(suiteName: "com.gaojiezou.rhythm.sleep-sync-regression")!
}

@main
struct SleepSyncRegression {
    @MainActor
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("rhythm-sleep-sync-" + UUID().uuidString)
        let library = root.appendingPathComponent("Rhythm")
        let shared = root.appendingPathComponent("SharedSleep")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        setenv("GAOJIEZOU_DATA_DIR", library.path, 1)
        setenv("GAOSERIES_SLEEP_TEST_DIRECTORY", shared.path, 1)

        let now = Date()
        let animal = RhythmCatalog.animals[0]
        let legacyEnd = now.addingTimeInterval(-4 * 86400)
        let legacy = SleepRecord(id: "legacy-timer", startedAt: legacyEnd.addingTimeInterval(-8 * 3600),
                                 endedAt: legacyEnd, durationSeconds: 8 * 3600, score: 100, pastureYield: 2)
        var fixture = RhythmLibrary.starter()
        fixture.sleepRecords = [legacy]
        fixture.coins = 123
        fixture.pastureAnimals = [PastureAnimal(id: "resident", animalID: animal.id,
                                               growthHours: animal.maturitySleepHours, pendingProducts: 7, acquiredAt: now)]
        try RhythmPersistence().write(fixture)

        var store: RhythmStore? = RhythmStore()
        let healthConnection = try SharedSleepStore()
        require(try healthConnection.records().map(\.id) == [legacy.id], "startup must migrate legacy sleep")
        require(store!.pastureAnimals[0].pendingProducts == 7, "legacy timer rewards must not replay")

        let healthEnd = now.addingTimeInterval(-3600)
        let health = entry(id: "health-record", end: healthEnd)
        try healthConnection.upsert(health)
        // App activation is observed by the persistent store, with no SwiftUI window.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        pumpRunLoop(for: 0.15)
        require(store!.sleepRecords.count == 2, "Health record must appear without a content view")
        require(store!.sleepRecords.first?.healthSource == "搞健康", "import must show its source")
        require(store!.pastureAnimals[0].pendingProducts == 9, "Health sleep must settle pasture once")
        require(store!.coins == 123, "sleep synchronization must preserve unrelated progress")
        let sharedHealth = try healthConnection.records().first { $0.id == health.id }!
        require(sharedHealth.manualProductionCreditedCycles == 2 && sharedHealth.pastureYield == 2,
                "shared receipt must preserve credited pasture production")
        store!.synchronizeSleepRecords()
        store!.synchronizeSleepRecords()
        require(store!.pastureAnimals[0].pendingProducts == 9, "repeated imports must not repeat rewards")

        let rhythmEnd = now.addingTimeInterval(-2 * 86400)
        require(store!.addManualSleep(start: rhythmEnd.addingTimeInterval(-8 * 3600), end: rhythmEnd) == .added(score: 100),
                "Rhythm manual record must save")
        let rhythmRecord = store!.sleepRecords.first { $0.id != health.id && $0.id != legacy.id }!
        require(try healthConnection.records().contains { $0.id == rhythmRecord.id && $0.origin == "rhythm" },
                "Rhythm record must be available from the Health connection immediately")
        require(store!.pastureAnimals[0].pendingProducts == 11, "manual record must earn only its own pasture credit")
        require(store!.addManualSleep(start: health.startedAt, end: health.endedAt) == .duplicate,
                "a Health record cannot be recorded again in Rhythm")
        require(store!.pastureAnimals[0].pendingProducts == 11, "duplicate must not grant rewards")

        // A local write failure cannot leave game mutations in memory for the next retry.
        let badRoot = root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: badRoot)
        let retry = entry(id: "retry-record", end: now.addingTimeInterval(-8 * 86400))
        try healthConnection.upsert(retry)
        setenv("GAOJIEZOU_DATA_DIR", badRoot.path, 1)
        store!.synchronizeSleepRecords()
        require(store!.sleepSyncError != nil, "failed persistence must report deferred sync")
        require(store!.sleepRecords.count == 3 && store!.pastureAnimals[0].pendingProducts == 11,
                "failed save must roll back imported record and pasture reward together")
        setenv("GAOJIEZOU_DATA_DIR", library.path, 1)
        store!.synchronizeSleepRecords()
        require(store!.sleepRecords.count == 4 && store!.pastureAnimals[0].pendingProducts == 13,
                "retry must import once after persistence recovers")

        try healthConnection.remove(health.id)
        store!.synchronizeSleepRecords()
        require(!store!.sleepRecords.contains { $0.id == health.id }, "Health deletion must remove local mirrored row")
        require(store!.pastureAnimals[0].pendingProducts == 13, "deleting history must not rewrite earned progress")
        store = nil
        store = RhythmStore()
        require(store!.sleepRecords.count == 3, "relaunch must keep deletion and all other sleep records")
        require(store!.pastureAnimals[0].pendingProducts == 13, "relaunch must not repeat any pasture credit")
        try healthConnection.seed([health])
        store!.synchronizeSleepRecords()
        require(!store!.sleepRecords.contains { $0.id == health.id }, "a stale archive cannot resurrect a tombstone")
        require(store!.coins == 123, "all sync operations must leave unrelated currency intact")
        store = nil

        // Simulate a record durably saved while shared storage was offline. A
        // Health copy entered meanwhile wins its identity, with one local reward.
        let conflict = entry(id: "health-offline-conflict", end: now.addingTimeInterval(-10 * 86400))
        try healthConnection.upsert(conflict)
        guard case .loaded(var offline) = RhythmPersistence().load() else { fatalError("fixture lost") }
        var queued = SleepRecord(shared: conflict)
        queued.id = "rhythm-offline-copy"
        queued.healthSource = nil
        queued.manualGrowthCreditedSeconds = 8 * 3600
        queued.manualProductionCreditedCycles = 2
        queued.pastureYield = 2
        offline.sleepRecords.append(queued)
        offline.pastureAnimals![0].pendingProducts += 2
        try RhythmPersistence().write(offline)
        store = RhythmStore()
        require(store!.sleepRecords.count == 4 && !store!.sleepRecords.contains { $0.id == queued.id },
                "queued duplicate must merge into the canonical interval instead of bypassing duplicate checks")
        require(store!.pastureAnimals[0].pendingProducts == 15,
                "merging an offline duplicate must preserve, not replay, its local reward")
        let conflictReceipt = try healthConnection.records().first { $0.id == conflict.id }!
        require(conflictReceipt.manualProductionCreditedCycles == 2,
                "duplicate alias must retain the existing local settlement receipt")
        store = nil
        store = RhythmStore()
        require(store!.sleepRecords.count == 4 && store!.pastureAnimals[0].pendingProducts == 15,
                "offline duplicate reconciliation must remain idempotent after relaunch")
        try healthConnection.remove(conflict.id)
        store!.sleepRecords.append(queued)
        require(store!.save(), "stale offline archive fixture must save")
        store!.synchronizeSleepRecords()
        require(store!.sleepRecords.count == 3 && !store!.sleepRecords.contains { $0.id == queued.id },
                "a deleted canonical interval cannot return under its old duplicate alias")
        require(try !healthConnection.records().contains { $0.id == queued.id || $0.id == conflict.id },
                "canonical and duplicate alias identities must both remain tombstoned")
        store = nil

        // A damaged shared journal is not an empty authoritative list.
        let corruptShared = root.appendingPathComponent("CorruptShared")
        try fm.createDirectory(at: corruptShared, withIntermediateDirectories: true)
        let corruptURL = corruptShared.appendingPathComponent(SharedSleepStore.fileName)
        let corruptData = Data("unreadable shared database".utf8)
        try corruptData.write(to: corruptURL)
        setenv("GAOSERIES_SLEEP_TEST_DIRECTORY", corruptShared.path, 1)
        store = RhythmStore()
        require(store!.sleepRecords.count == 3 && store!.sleepSyncError != nil,
                "corrupt shared data must preserve local sleep history and surface failure")
        require(try Data(contentsOf: corruptURL) == corruptData, "corrupt shared bytes must remain unchanged")
        require(store!.pastureAnimals[0].pendingProducts == 15, "corrupt source must not modify game progress")
        store = nil
        print("PASS Sleep sync: legacy migration; both app origins; window-independent refresh; once-only pasture rewards; save-failure rollback/retry; deletion and tombstones after relaunch; offline duplicate reconciliation; corrupted source preservation")
    }

    private static func entry(id: String, end: Date) -> SharedSleepEntry {
        SharedSleepEntry(id: id, startedAt: end.addingTimeInterval(-8 * 3600), endedAt: end,
                         durationSeconds: 8 * 3600, score: 100, pastureYield: 0,
                         manualEntry: true, manualGrowthCreditedSeconds: 0,
                         manualProductionCreditedCycles: 0, origin: "health")
    }

    @MainActor
    private static func pumpRunLoop(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: min(until, Date().addingTimeInterval(0.02))) }
    }

    private static func require(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }
}
