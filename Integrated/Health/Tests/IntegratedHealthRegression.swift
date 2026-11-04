import Foundation
import CryptoKit
import Darwin

// Same-module test double shadows Foundation.UserDefaults only in this
// isolated executable. No real preferences domain is read or written.
final class UserDefaults {
    static let standard = UserDefaults()
    private var domains: [String: [String: Any]] = [:]
    func persistentDomain(forName name: String) -> [String: Any]? { domains[name] }
    func setPersistentDomain(_ value: [String: Any], forName name: String) { domains[name] = value }
    func removePersistentDomain(forName name: String) { domains.removeValue(forKey: name) }
    func synchronize() -> Bool { true }
}

@main enum IntegratedHealthRegression {
    static func must(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NSError(domain: "IntegratedHealthRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        var failed = false
        do { try operation() } catch { failed = true }
        try must(failed, message)
    }
    static func main() throws {
        setbuf(stdout, nil)
        print("stage: isolated fixture")
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/rhythm-health-regression-\(UUID().uuidString).noindex", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: RestorePreferences.moduleDomain)
            try? fm.removeItem(at: root)
        }
        let group = root.appendingPathComponent("group", isDirectory: true)
        let integration = group.appendingPathComponent("Integration", isDirectory: true)
        for relative in ["Modules/Health", "Modules/Footprints", "SharedSleep", "SourceArchives/Health/AppGroup/Health/Empty"] {
            try fm.createDirectory(at: integration.appendingPathComponent(relative, isDirectory: true), withIntermediateDirectories: true)
        }
        setenv("RHYTHM_INTEGRATION_TEST_GROUP", group.path, 1)
        let date = Date().addingTimeInterval(-30)
        let fixtureHealth = root.appendingPathComponent("FixtureHealth", isDirectory: true)
        let fixture = try HealthDatabase(directory: fixtureHealth)
        var saved = HealthState()
        var record = HealthRecord(kind: .water); record.amount = 250; record.occurredAt = date; record.rewardEligible = false
        saved.records = [record]; saved.requests = ["existing-request"]
        saved.island.rewardedSleepIDs = ["credited-sleep"]
        saved.ledgers[Engine.day(date, saved)] = DailyLedger(sleepEnergy: 24)
        try fixture.transaction(now: date) { $0 = saved }
        try BackupIntegrity.copySnapshot(from: fixtureHealth, to: integration.appendingPathComponent("Modules/Health"))
        let fixtureSleep = root.appendingPathComponent("FixtureSleep", isDirectory: true)
        let sleepFixture = try SharedSleepStore(directory: fixtureSleep)
        let first = SharedSleepEntry(id: "credited-sleep", startedAt: date.addingTimeInterval(-3600), endedAt: date, durationSeconds: 3600, score: 80, pastureYield: 3, healthGrowthCreditedSeconds: 3600, healthProductionCreditedCycles: 1, origin: "rhythm")
        try sleepFixture.upsert(first); try sleepFixture.remove("deleted-sleep")
        try sleepFixture.seedLegacyOnce([], key: SharedSleepStore.legacyMigrationKey)
        try BackupIntegrity.copySnapshot(from: fixtureSleep, to: integration.appendingPathComponent("SharedSleep"))
        let opaque = Data([0, 255, 1, 3, 0, 14])
        let sourceRaw = integration.appendingPathComponent("SourceArchives/Health/AppGroup/Health/old.sqlite")
        try opaque.write(to: sourceRaw)
        try Data("opaque WAL".utf8).write(to: URL(fileURLWithPath: sourceRaw.path + "-wal"))
        let footprint = integration.appendingPathComponent("Modules/Footprints/unchanged")
        try Data("footprints sentinel".utf8).write(to: footprint)
        let before = try BackupIntegrity.hash(integration.appendingPathComponent("Modules/Health/health.sqlite"))
        try rejects("No authority must reject opening a default database") { _ = try HealthDatabase() }
        try must(try BackupIntegrity.hash(integration.appendingPathComponent("Modules/Health/health.sqlite")) == before, "No-authority failure changed health data")
        let authority: [String: Any] = [
            "schemaVersion": 1, "state": "active", "transactionID": "synthetic-health-transaction",
            "modulePaths": ["health": "Modules/Health", "footprints": "Modules/Footprints"],
            "sharedSleepPath": "SharedSleep", "sourceRevisions": ["health": String(repeating: "a", count: 64)]
        ]
        try JSONSerialization.data(withJSONObject: authority, options: [.sortedKeys]).write(to: integration.appendingPathComponent("authority.json"), options: .atomic)
        let mappedPreferences: [String: Any] = ["schema": 1, "transactionID": "synthetic-health-transaction", "standard": ["gqns.home.compact": false], "module": [:]]
        try PropertyListSerialization.data(fromPropertyList: mappedPreferences, format: .binary, options: 0).write(to: integration.appendingPathComponent("Modules/Health/Preferences.plist"))
        print("stage: open active health and sleep")
        let live = try HealthDatabase(), sleeps = try SharedSleepStore()
        try must(try live.read().records.map(\.id) == [record.id], "Original health IDs lost")
        try must(try sleeps.records() == [first], "Original shared sleep payload changed")
        try must(try sleeps.hasLegacyMigration(SharedSleepStore.legacyMigrationKey), "Seed marker lost")
        var replayed = false
        try live.transaction(request: "existing-request") { _ in replayed = true }
        try must(!replayed, "Existing request replayed")
        let noReward = try HealthSleepRewardSync.synchronize(directory: live.directory)
        try must(!noReward, "Already credited shared sleep rewarded again")
        let archive = root.appendingPathComponent("health.zip")
        print("stage: export scoped ZIP")
        _ = try AppBackupExport.export(destination: archive)
        print("stage: prepare scoped ZIP")
        let (staged, _) = try AppBackupRestore.prepare(archive)
        try must(try Data(contentsOf: staged.appendingPathComponent("SourceArchive/AppGroup/Health/old.sqlite")) == opaque, "Opaque archived sqlite was reinterpreted")
        try must(fm.fileExists(atPath: staged.appendingPathComponent("SourceArchive/AppGroup/Health/Empty").path), "Empty source directory lost")
        print("stage: schedule scoped restore")
        try AppBackupRestore.schedule(staged)
        let later = SharedSleepEntry(id: "post-backup-sleep", startedAt: date.addingTimeInterval(-10800), endedAt: date.addingTimeInterval(-7200), durationSeconds: 3600, score: 80, pastureYield: 2, origin: "rhythm")
        try sleeps.upsert(later)
        try live.transaction(request: "post-backup-request") { state in state.island.rewardedSleepIDs.insert(later.id) }
        let sleepSHA = try BackupIntegrity.hash(integration.appendingPathComponent("SharedSleep/sleep-records.sqlite"))
        let immutableSHA = try BackupIntegrity.hash(sourceRaw)
        print("stage: apply or resume scoped restore")
        try AppBackupRestore.applyPending()
        try must(!fm.fileExists(atPath: AppBackupRestore.pending.path), "Successful restore left a replayable job")
        print("stage: inspect restored health")
        let restored = try HealthDatabase()
        try must(try restored.read().requests.contains("post-backup-request"), "Restore lost request deduplication")
        try must(try restored.read().island.rewardedSleepIDs.contains(later.id), "Restore reopened credited sleep identity")
        try must(try restored.read().ledgers[Engine.day(date, saved)]?.sleepEnergy == 24, "Restore lost daily reward budget")
        try must(try BackupIntegrity.hash(integration.appendingPathComponent("SharedSleep/sleep-records.sqlite")) == sleepSHA, "Health restore replaced shared sleep")
        try must(try BackupIntegrity.hash(sourceRaw) == immutableSHA, "Health restore replaced immutable source archive")
        try must(try String(contentsOf: footprint) == "footprints sentinel", "Health restore touched Footprints")
        try rejects("Old database connection must refuse the replaced inode") { _ = try live.read() }
        print("stage: apply or resume scoped restore")
        try AppBackupRestore.applyPending()
        let beforeFault = try BackupIntegrity.hash(integration.appendingPathComponent("Modules/Health/health.sqlite"))
        let (faultStaged, _) = try AppBackupRestore.prepare(archive)
        try AppBackupRestore.schedule(faultStaged)
        setenv("RHYTHM_HEALTH_RESTORE_FAIL", "after-replace", 1)
        try rejects("Injected post-replacement failure must throw") { try AppBackupRestore.applyPending() }
        unsetenv("RHYTHM_HEALTH_RESTORE_FAIL")
        try must(try BackupIntegrity.hash(integration.appendingPathComponent("Modules/Health/health.sqlite")) == beforeFault, "Failed restore did not recover prior health")
        try must(fm.fileExists(atPath: AppBackupRestore.pending.path) && !RhythmIntegrationPaths.isActive, "Failed restore lost its retry job/maintenance marker")
        print("stage: apply or resume scoped restore")
        try AppBackupRestore.applyPending()
        let unchanged = try BackupIntegrity.hash(integration.appendingPathComponent("Modules/Health/health.sqlite"))
        try Data("{\"staged\":\"file:///arbitrary-old-source\"}".utf8).write(to: AppBackupRestore.pending)
        try rejects("Old or malformed pending jobs must not replay") { try AppBackupRestore.applyPending() }
        try must(fm.fileExists(atPath: AppBackupRestore.pending.path), "Rejected pending evidence was deleted")
        try must(!RhythmIntegrationPaths.isActive, "Failure did not retain maintenance marker")
        try must(try BackupIntegrity.hash(integration.appendingPathComponent("Modules/Health/health.sqlite")) == unchanged, "Rejected restore changed data")
        try RhythmIntegrationPaths.withMaintenanceLease(owner: "health") { try fm.removeItem(at: AppBackupRestore.pending) }
        // Root may retire this pure source copy after acceptance. The active
        // island, deduplication state and shared sleep remain mandatory.
        try fm.removeItem(at: integration.appendingPathComponent("SourceArchives/Health"))
        let afterRetirement = root.appendingPathComponent("health-after-retirement.zip")
        _ = try AppBackupExport.export(destination: afterRetirement)
        let (retiredStage, _) = try AppBackupRestore.prepare(afterRetirement)
        try must(!fm.fileExists(atPath: retiredStage.appendingPathComponent("SourceArchive").path), "Retired source recovery copy was recreated")
        try AppBackupRestore.schedule(retiredStage)
        try AppBackupRestore.applyPending()
        try must(!fm.fileExists(atPath: integration.appendingPathComponent("SourceArchives/Health").path), "Restore recreated retired source bytes")
        let afterRetirementDB = try HealthDatabase()
        try must(try afterRetirementDB.read().island.rewardedSleepIDs.contains(later.id), "Source retirement lost island reward identities")
        try must(try BackupIntegrity.hash(integration.appendingPathComponent("SharedSleep/sleep-records.sqlite")) == sleepSHA, "Source retirement changed shared sleep")
        try must(try String(contentsOf: footprint) == "footprints sentinel", "Source retirement changed current Footprints")
        let reopened = try HealthDatabase()
        try fm.removeItem(at: integration.appendingPathComponent("authority.json"))
        try rejects("Cached connection wrote after authority was removed") { try reopened.transaction { $0.requests.insert("should-not-write") } }
        print("PASS: health authority, original IDs/tombstone/seed, request and sleep reward dedupe, raw source ZIP, scoped restore, stale inode and rejected pending recovery")
    }
}
