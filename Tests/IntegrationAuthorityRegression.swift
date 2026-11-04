import Foundation
import Darwin

private enum FixtureFailure: Error { case interrupted }

@main struct IntegrationAuthorityRegression {
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/rhythm-integration-authority-\(UUID().uuidString).noindex", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let group = base.appendingPathComponent("Group", isDirectory: true)
        let integration = group.appendingPathComponent("Integration", isDirectory: true)
        try fm.createDirectory(at: integration, withIntermediateDirectories: true)
        setenv("RHYTHM_INTEGRATION_TEST_GROUP", group.path, 1)
        unsetenv("GAOSERIES_SLEEP_TEST_DIRECTORY")
        try refuses { _ = try RhythmIntegrationPaths.authority() }
        precondition(!fm.fileExists(atPath: integration.appendingPathComponent("Modules").path))

        let authority: [String: Any] = ["schemaVersion": 1, "state": "active", "transactionID": "synthetic-transaction",
            "modulePaths": ["health": "Modules/Health", "footprints": "Modules/Footprints"],
            "sharedSleepPath": "SharedSleep", "sourceRevisions": ["health": String(repeating: "a", count: 64), "footprints": String(repeating: "b", count: 64)]]
        let file = integration.appendingPathComponent("authority.json")
        let bytes = try JSONSerialization.data(withJSONObject: authority)
        try bytes.write(to: file, options: .atomic)
        try refuses { _ = try RhythmIntegrationPaths.sharedSleepDirectory() }
        precondition(!fm.fileExists(atPath: integration.appendingPathComponent("SharedSleep").path))
        for module in ["Health", "Footprints"] {
            try fm.createDirectory(at: integration.appendingPathComponent("Modules/" + module), withIntermediateDirectories: true)
        }
        try expect(try RhythmIntegrationPaths.moduleDirectory("health").lastPathComponent == "Health")
        try refuses { _ = try RhythmIntegrationPaths.moduleDirectory("unknown") }
        let canonical = integration.appendingPathComponent("SharedSleep", isDirectory: true)
        try seedFixture(canonical)
        let original = try SharedSleepStore()
        try expect(try original.records().map(\.id) == ["sleep-original"])

        let lock = group.appendingPathComponent(".rhythm-integration-writers.lock")
        try RhythmIntegrationPaths.withWriterLease {
            let fd = Darwin.open(lock.path, O_RDWR | O_NOFOLLOW)
            precondition(fd >= 0)
            defer { _ = Darwin.close(fd) }
            precondition(flock(fd, LOCK_EX | LOCK_NB) != 0)
        }
        let marker = group.appendingPathComponent(".rhythm-integration-maintenance.json")
        try RhythmIntegrationPaths.withMaintenanceLease(owner: "health") {
            precondition(fm.fileExists(atPath: marker.path))
            try refuses { _ = try RhythmIntegrationPaths.authority() }
            try expect(try RhythmIntegrationPaths.authority(allowMaintenanceOwner: "health").transactionID == "synthetic-transaction")
        }
        precondition(!fm.fileExists(atPath: marker.path))
        do {
            try RhythmIntegrationPaths.withMaintenanceLease(owner: "footprints") { throw FixtureFailure.interrupted }
            preconditionFailure("Expected simulated interruption")
        } catch FixtureFailure.interrupted {}
        precondition(fm.fileExists(atPath: marker.path))
        try refuses { _ = try RhythmIntegrationPaths.moduleDirectory("health") }
        try refuses { try RhythmIntegrationPaths.withMaintenanceLease(owner: "health") {} }
        try RhythmIntegrationPaths.withMaintenanceLease(owner: "footprints") {}
        precondition(!fm.fileExists(atPath: marker.path))

        try RhythmIntegrationPaths.withMaintenanceLease(owner: "host") {
            try fm.moveItem(at: canonical, to: integration.appendingPathComponent("previous-sleep.noindex"))
            try seedFixture(canonical)
        }
        try refuses { _ = try original.records() }
        let reopened = try SharedSleepStore()
        try expect(try reopened.records().count == 1)
        try expect(try reopened.hasLegacyMigration(SharedSleepStore.legacyMigrationKey))

        try RhythmIntegrationPaths.withMaintenanceLease(owner: "host") {
            try fm.moveItem(at: canonical, to: integration.appendingPathComponent("second-sleep.noindex"))
        }
        try refuses { _ = try SharedSleepStore() }
        precondition(!fm.fileExists(atPath: canonical.path), "Production constructor must not create a missing DB or folder")

        let health = integration.appendingPathComponent("Modules/Health")
        try fm.removeItem(at: health)
        try fm.createSymbolicLink(at: health, withDestinationURL: base)
        try refuses { _ = try RhythmIntegrationPaths.moduleDirectory("health") }
        try fm.removeItem(at: health)
        var newer = authority; newer["schemaVersion"] = 2
        try JSONSerialization.data(withJSONObject: newer).write(to: file, options: .atomic)
        try refuses { _ = try RhythmIntegrationPaths.authority() }
        print("PASS: isolated authority, no-default, SH/EX, marker recovery, inode replacement and schema/path boundaries")
    }

    private static func seedFixture(_ directory: URL) throws {
        let fixture = try SharedSleepStore(directory: directory)
        let entry = SharedSleepEntry(id: "sleep-original", startedAt: Date(timeIntervalSince1970: 1000), endedAt: Date(timeIntervalSince1970: 2000), durationSeconds: 1000, score: 80, pastureYield: 0, origin: "rhythm")
        try fixture.seedLegacyOnce([entry], key: SharedSleepStore.legacyMigrationKey)
    }
    private static func expect(_ predicate: @autoclosure () throws -> Bool) throws {
        let value = try predicate()
        precondition(value)
    }
    private static func refuses(_ body: () throws -> Void) throws {
        var denied = false
        do { try body() } catch { denied = true }
        precondition(denied, "Expected a refusal, not a default or side effect")
    }
}
