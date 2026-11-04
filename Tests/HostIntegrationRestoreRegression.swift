import Foundation
import AppKit
import CryptoKit
import SQLite3
import Darwin

// Storage-transaction fixtures only. No App/NSApplication, production defaults,
// real Application Support, real App Group or actual business/game acceptance.
#if !INTEGRATION_PATH_TEST
#error("Host restore regression requires isolated INTEGRATION_PATH_TEST")
#endif

/// Same-module shim intentionally shadows Foundation.UserDefaults in the real
/// recovery source compiled into this test. Even an incorrect production-domain
/// access aborts instead of reaching CFPreferences or ~/Library/Preferences.
final class UserDefaults {
    static let standard = UserDefaults()
    private var storage: [String: [String: Any]] = [:]
    private func requireIsolated(_ domain: String) {
        let prefix = ProcessInfo.processInfo.environment["RHYTHM_RESTORE_TEST_PREFERENCE_PREFIX"] ?? ""
        let roles = ["standard", "module", "integratedFootprints", "integratedHealth"]
        precondition(prefix.hasPrefix("com.gaojiezou.rhythm.test.restore.") &&
                     roles.contains(where: { domain == prefix + "." + $0 }),
                     "Test attempted a non-isolated preference domain")
    }
    func persistentDomain(forName name: String) -> [String: Any]? {
        requireIsolated(name); return storage[name]
    }
    func setPersistentDomain(_ domain: [String: Any], forName name: String) {
        requireIsolated(name); storage[name] = domain
    }
    func removePersistentDomain(forName name: String) {
        requireIsolated(name); storage.removeValue(forKey: name)
    }
    func synchronize() -> Bool { true }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure(message) }
}
private func mustRefuse(_ message: String, _ body: () throws -> Void) throws {
    var refused = false
    do { try body() } catch { refused = true }
    try check(refused, message)
}

private enum FixtureContext { static var current: RestoreFixture? }

/// This stub replaces Host/Settings.swift. Never compile that file into this test.
enum AppDataLocations {
    static var appSupport: URL? { FixtureContext.current?.support }
    static var groupContainer: URL? { FixtureContext.current?.group }
    static var sharedSleepContainer: URL? { FixtureContext.current?.group.appendingPathComponent("Integration/SharedSleep", isDirectory: true) }
}

private final class RestoreFixture {
    static let roles = ["standard", "module", "integratedFootprints", "integratedHealth"]
    let root: URL
    let support: URL
    let group: URL
    let jobs: URL
    let prefix: String
    let fm = FileManager.default
    var marker: URL { group.appendingPathComponent(".rhythm-integration-maintenance.json") }
    var writerLock: URL { group.appendingPathComponent(".rhythm-integration-writers.lock") }
    var sourceArchive: URL { group.appendingPathComponent("Integration/SourceArchives", isDirectory: true) }

    init(base: URL) throws {
        let id = UUID().uuidString
        root = base.appendingPathComponent(id + ".noindex", isDirectory: true)
        support = root.appendingPathComponent("ApplicationSupport/GaoSeries/Rhythm", isDirectory: true)
        group = root.appendingPathComponent("RhythmAppGroup", isDirectory: true)
        jobs = root.appendingPathComponent("RestoreJobs", isDirectory: true)
        prefix = "com.gaojiezou.rhythm.test.restore." + id
        try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: group, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: jobs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        setenv("RHYTHM_INTEGRATION_TEST_GROUP", group.path, 1)
        setenv("GQNS_RESTORE_ROOT", jobs.path, 1)
        setenv("RHYTHM_RESTORE_TEST_PREFERENCE_PREFIX", prefix, 1)
        FixtureContext.current = self
        var initialized = false
        defer { if !initialized { cleanup() } }
        for role in Self.roles { UserDefaults.standard.removePersistentDomain(forName: domain(role)) }
        try seedOriginalPreferences()
        try write(Data("original-rhythm-library".utf8), at: support.appendingPathComponent("library.json"))
        try write(Data("original-widget-mirror".utf8), at: group.appendingPathComponent("library.json"))
        let integration = group.appendingPathComponent("Integration", isDirectory: true)
        try writeJSON(authority(), at: integration.appendingPathComponent("authority.json"))
        for relative in ["Modules/Health/health.sqlite", "Modules/Footprints/footprints.sqlite", "SharedSleep/sleep-records.sqlite"] {
            try makeDatabase(integration.appendingPathComponent(relative), value: "original:" + relative)
        }
        try write(Data("immutable-original-attachment".utf8), at: sourceArchive.appendingPathComponent("Health/ApplicationSupport/document.pdf"))
        // Arbitrary archived SQLite/WAL bytes must never be interpreted here.
        try write(Data("opaque-original-sqlite".utf8), at: sourceArchive.appendingPathComponent("Health/old.sqlite"))
        try write(Data("opaque-original-wal".utf8), at: sourceArchive.appendingPathComponent("Health/old.sqlite-wal"))
        try fm.createDirectory(at: sourceArchive.appendingPathComponent("empty-directory", isDirectory: true), withIntermediateDirectories: true)
        try write(Data("original-transaction-receipt".utf8), at: integration.appendingPathComponent("Transactions.noindex/source-transaction/receipt.json"))
        try RhythmIntegrationPaths.withWriterLease {} // creates only our isolated stable lock
        initialized = true
    }
    func cleanup() {
        for role in Self.roles { UserDefaults.standard.removePersistentDomain(forName: domain(role)) }
        _ = UserDefaults.standard.synchronize()
        if FixtureContext.current === self { FixtureContext.current = nil }
        try? fm.removeItem(at: root)
    }
    func domain(_ role: String) -> String { prefix + "." + role }
    func seedOriginalPreferences() throws {
        for role in Self.roles {
            if role == "integratedHealth" { UserDefaults.standard.removePersistentDomain(forName: domain(role)) }
            else { UserDefaults.standard.setPersistentDomain(["fixtureValue": "original-" + role,
                                                              "opaqueData": Data([0, 255, 17])], forName: domain(role)) }
        }
        try check(UserDefaults.standard.synchronize(), "isolated preference initialization failed")
    }
    func preferences() -> [String: Any] {
        var domains: [String: Any] = [:]
        for role in Self.roles {
            let value = UserDefaults.standard.persistentDomain(forName: domain(role))
            domains[role] = ["present": value != nil, "values": value ?? [:]]
        }
        return domains
    }
    func authority() -> [String: Any] {
        ["schemaVersion": 1, "state": "active", "transactionID": "fixture-source-transaction",
         "modulePaths": ["health": "Modules/Health", "footprints": "Modules/Footprints"],
         "sharedSleepPath": "SharedSleep", "sourceRevisions": ["fixtureSource": String(repeating: "a", count: 64)]]
    }
    func staged(version: String = "4.10", historicalPending: Bool = false) throws -> URL {
        let staged = jobs.appendingPathComponent(UUID().uuidString + ".noindex", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        let app = staged.appendingPathComponent("ApplicationSupport-Rhythm", isDirectory: true)
        let incomingGroup = staged.appendingPathComponent("AppGroupContainer", isDirectory: true)
        try fm.copyItem(at: support, to: app)
        try fm.copyItem(at: group, to: incomingGroup)
        try write(Data("incoming-rhythm-library".utf8), at: app.appendingPathComponent("library.json"))
        try write(Data("incoming-widget-mirror".utf8), at: incomingGroup.appendingPathComponent("library.json"))
        for relative in ["Modules/Health/health.sqlite", "Modules/Footprints/footprints.sqlite", "SharedSleep/sleep-records.sqlite"] {
            let database = incomingGroup.appendingPathComponent("Integration/" + relative)
            try fm.removeItem(at: database)
            try makeDatabase(database, value: "incoming:" + relative)
        }
        // These historical coordination files must not replace the live lock or marker.
        try write(Data("incoming-stale-lock-bytes".utf8), at: incomingGroup.appendingPathComponent(".rhythm-integration-writers.lock"))
        try writeJSON(["owner": "footprints", "schemaVersion": 1], at: incomingGroup.appendingPathComponent(".rhythm-integration-maintenance.json"))
        if historicalPending {
            for module in ["Health", "Footprints"] {
                try write(Data(("historical-request-" + module).utf8),
                          at: app.appendingPathComponent("IntegratedRecovery/" + module + "/pending.json"))
            }
        }
        var incomingPreferences: [String: [String: Any]] = [:]
        for role in Self.roles { incomingPreferences[role] = ["fixtureValue": "incoming-" + role] }
        try write(try PropertyListSerialization.data(fromPropertyList: incomingPreferences, format: .binary, options: 0),
                  at: staged.appendingPathComponent("preferences.plist"))
        let manifest = BackupIntegrity.Manifest(version: version, files: try BackupIntegrity.manifest(staged))
        try write(try JSONEncoder().encode(manifest), at: staged.appendingPathComponent("gqns-manifest.json"))
        return staged
    }
    func makeDatabase(_ url: URL, value: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { throw CheckFailure("cannot create isolated SQLite fixture") }
        defer { sqlite3_close(database) }
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(database, "CREATE TABLE fixture(id INTEGER PRIMARY KEY, value TEXT); INSERT INTO fixture VALUES(1,'\(escaped)');", nil, nil, nil) == SQLITE_OK else {
            throw CheckFailure("cannot populate isolated SQLite fixture")
        }
    }
    func write(_ data: Data, at url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    func writeJSON(_ value: Any, at url: URL) throws {
        try write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), at: url)
    }
    func save(_ job: AppBackupRestore.Job) throws { try write(try JSONEncoder().encode(job), at: AppBackupRestore.pending) }
    func pendingJob() throws -> AppBackupRestore.Job {
        try JSONDecoder().decode(AppBackupRestore.Job.self, from: Data(contentsOf: AppBackupRestore.pending))
    }
    func markerForInterruptedHost() throws { try writeJSON(["schemaVersion": 1, "owner": "host", "startedAt": "synthetic-fixture"], at: marker) }
    func archivedJob() throws -> (URL, AppBackupRestore.Job) {
        let directory = jobs.appendingPathComponent("Completed.noindex", isDirectory: true)
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        try check(files.count == 1, "expected one completed host job")
        return (files[0], try JSONDecoder().decode(AppBackupRestore.Job.self, from: Data(contentsOf: files[0])))
    }
    func itemHashes(_ url: URL) throws -> [String: String] {
        let a = try fm.attributesOfItem(atPath: url.path)
        if a[.type] as? FileAttributeType == .typeDirectory { return try BackupIntegrity.manifest(url) }
        return ["$file": try BackupIntegrity.hash(url)]
    }
    func originalPreferenceReceipt(_ job: inout AppBackupRestore.Job) throws {
        let file = job.safety.appendingPathComponent("original-preferences.plist")
        let snapshot: [String: Any] = ["schema": 1, "jobID": job.id, "domains": preferences()]
        try write(try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0), at: file)
        job.originalPreferences = file; job.originalPreferencesSHA256 = try BackupIntegrity.hash(file)
    }
    func interruptedJob(includeModules: Bool) throws -> AppBackupRestore.Job {
        let stage = try staged()
        var job = AppBackupRestore.Job(staged: stage, safety: jobs.appendingPathComponent("恢复前原始数据-" + UUID().uuidString + ".noindex", isDirectory: true))
        try fm.createDirectory(at: job.safety, withIntermediateDirectories: true)
        try originalPreferenceReceipt(&job)
        job.operations = [try AppBackupRestore.Operation(source: stage.appendingPathComponent("ApplicationSupport-Rhythm"), destination: support,
                                                        previous: job.safety.appendingPathComponent("ApplicationSupport"), hadPrevious: true)]
        if includeModules {
            job.operations.append(try AppBackupRestore.Operation(source: stage.appendingPathComponent("AppGroupContainer/Integration/Modules"),
                                                                  destination: group.appendingPathComponent("Integration/Modules"),
                                                                  previous: job.safety.appendingPathComponent("Integration-Modules"), hadPrevious: true))
        }
        job.applying = true
        try save(job)
        for op in job.operations {
            try fm.moveItem(at: op.destination, to: op.previous)
            try fm.createDirectory(at: op.destination, withIntermediateDirectories: true)
            try write(Data("interrupted-partial-copy".utf8), at: op.destination.appendingPathComponent("partial.bin"))
        }
        try markerForInterruptedHost()
        return job
    }
    struct Stable {
        let archiveIdentity: String
        let fileIdentity: String
        let lockIdentity: String
        let archiveHashes: [String: String]
        let emptyDirectoryIdentity: String
        let modificationDate: Date?
        let permissions: NSNumber?
    }
    func identity(_ url: URL) throws -> String {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard let device = attrs[.systemNumber] as? NSNumber, let inode = attrs[.systemFileNumber] as? NSNumber else { throw CheckFailure("missing fixture identity") }
        return "\(device):\(inode)"
    }
    func stable() throws -> Stable {
        let file = sourceArchive.appendingPathComponent("Health/ApplicationSupport/document.pdf")
        let attrs = try fm.attributesOfItem(atPath: file.path)
        return Stable(archiveIdentity: try identity(sourceArchive), fileIdentity: try identity(file), lockIdentity: try identity(writerLock),
                      archiveHashes: try BackupIntegrity.manifest(sourceArchive),
                      emptyDirectoryIdentity: try identity(sourceArchive.appendingPathComponent("empty-directory")),
                      modificationDate: attrs[.modificationDate] as? Date, permissions: attrs[.posixPermissions] as? NSNumber)
    }
    func assertStable(_ before: Stable) throws {
        let after = try stable()
        try check(after.archiveIdentity == before.archiveIdentity && after.fileIdentity == before.fileIdentity,
                  "immutable SourceArchives or attachment was replaced")
        try check(after.lockIdentity == before.lockIdentity, "stable integration lock inode changed")
        try check(after.archiveHashes == before.archiveHashes && after.emptyDirectoryIdentity == before.emptyDirectoryIdentity,
                  "immutable archive content or empty directory changed")
        try check(after.modificationDate == before.modificationDate && after.permissions == before.permissions,
                  "immutable archive metadata changed")
    }
}

private func snapshotCanonicalAndRaw(_ fixture: RestoreFixture) throws {
    let canonical = ["Integration/Modules/Health/health.sqlite", "Integration/Modules/Footprints/footprints.sqlite",
                     "Integration/SharedSleep/sleep-records.sqlite"]
    var connections: [OpaquePointer] = []
    defer { for database in connections { sqlite3_close(database) } }
    // Keep all three original connections open: row 2 exists only in a
    // committed WAL while the production snapshot implementation copies it.
    for (index, relative) in canonical.enumerated() {
        let url = fixture.group.appendingPathComponent(relative)
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database = opened else {
            if let opened { sqlite3_close(opened) }
            throw CheckFailure("cannot open isolated WAL source")
        }
        connections.append(database)
        let sql = "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO fixture VALUES(2,'committed-wal-\(index)');"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CheckFailure("cannot seed committed WAL row") }
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        try check(((try fixture.fm.attributesOfItem(atPath: walURL.path)[.size]) as? NSNumber)?.intValue ?? 0 > 0,
                  "fixture WAL must remain nonempty until snapshot finishes")
    }

    let rawFiles: [String: Data] = [
        "Integration/SourceArchives/Health/old.sqlite": Data("opaque-original-sqlite".utf8),
        "Integration/SourceArchives/Health/old.sqlite-wal": Data("opaque-original-wal".utf8),
        "Integration/Modules/Health/ImportedSupport/opaque.sqlite": Data("opaque-user-sqlite".utf8),
        "Integration/Modules/Health/ImportedSupport/opaque.sqlite-wal": Data("opaque-user-wal".utf8),
        "Integration/Modules/Health/ImportedSupport/opaque.sqlite-shm": Data("opaque-user-shm".utf8),
        "Integration/Modules/Health/ImportedSupport/opaque.sqlite-journal": Data("opaque-user-journal".utf8),
        // A repeated AppGroupContainer component used to be globally stripped
        // by verify(), incorrectly opening this raw nested file as a real DB.
        "AppGroupContainer/Integration/Modules/Health/health.sqlite": Data("opaque-nested-health-sqlite".utf8),
        "AppGroupContainer/Integration/Modules/Health/health.sqlite-wal": Data("opaque-nested-health-wal".utf8)
    ]
    for (relative, bytes) in rawFiles { try fixture.write(bytes, at: fixture.group.appendingPathComponent(relative)) }
    let rawFile = fixture.group.appendingPathComponent("Integration/Modules/Health/ImportedSupport/opaque.sqlite")
    let empty = fixture.group.appendingPathComponent("Integration/Modules/Health/ImportedSupport/empty-directory", isDirectory: true)
    try fixture.fm.createDirectory(at: empty, withIntermediateDirectories: true)
    let metadataDate = Date(timeIntervalSince1970: 1_650_000_123)
    try fixture.fm.setAttributes([.posixPermissions: 0o640, .modificationDate: metadataDate], ofItemAtPath: rawFile.path)
    try fixture.fm.setAttributes([.posixPermissions: 0o750, .modificationDate: metadataDate], ofItemAtPath: empty.path)
    let attribute = "com.gaojiezou.rhythm.test.backup", attributeBytes = Data([0, 255, 19, 7])
    func putAttribute(_ url: URL) throws {
        let result = attributeBytes.withUnsafeBytes { bytes in
            Darwin.setxattr(url.path, attribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        try check(result == 0, "cannot seed isolated extended attribute")
    }
    func readAttribute(_ url: URL) throws -> Data {
        let length = Darwin.getxattr(url.path, attribute, nil, 0, 0, 0)
        guard length >= 0 else { throw CheckFailure("copied extended attribute is missing") }
        var bytes = Data(count: length)
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.getxattr(url.path, attribute, buffer.baseAddress, buffer.count, 0, 0)
        }
        try check(count == length, "copied extended attribute is incomplete")
        return bytes
    }
    try putAttribute(rawFile); try putAttribute(empty)
    let stable = try fixture.stable()
    let snapshot = fixture.root.appendingPathComponent("Snapshot.noindex", isDirectory: true)
    let copiedGroup = snapshot.appendingPathComponent("AppGroupContainer", isDirectory: true)
    try BackupIntegrity.copySnapshot(from: fixture.group, to: copiedGroup)

    for (index, relative) in canonical.enumerated() {
        let copied = copiedGroup.appendingPathComponent(relative)
        for suffix in ["-wal", "-shm", "-journal"] {
            try check(!fixture.fm.fileExists(atPath: copied.path + suffix), "canonical SQLite sidecar was not folded")
        }
        var opened: OpaquePointer?
        guard sqlite3_open_v2(copied.path, &opened, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database = opened else {
            if let opened { sqlite3_close(opened) }
            throw CheckFailure("cannot read isolated snapshot database")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM fixture WHERE id=2", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CheckFailure("snapshot fixture query failed") }
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_step(statement) == SQLITE_ROW, "committed WAL row disappeared from canonical snapshot")
        guard let value = sqlite3_column_text(statement, 0) else { throw CheckFailure("snapshot WAL value missing") }
        try check(String(cString: value) == "committed-wal-\(index)", "canonical snapshot omitted committed WAL data")
    }
    for (relative, bytes) in rawFiles {
        try check(try Data(contentsOf: copiedGroup.appendingPathComponent(relative)) == bytes, "raw SQLite/sidecar bytes changed")
        try check(try Data(contentsOf: fixture.group.appendingPathComponent(relative)) == bytes, "source raw bytes changed")
    }
    for original in [rawFile, empty] {
        let relative = String(original.path.dropFirst(fixture.group.path.count + 1))
        let copied = copiedGroup.appendingPathComponent(relative)
        let before = try fixture.fm.attributesOfItem(atPath: original.path)
        let after = try fixture.fm.attributesOfItem(atPath: copied.path)
        try check(after[.type] as? FileAttributeType == before[.type] as? FileAttributeType, "raw node/empty directory type changed")
        try check(after[.modificationDate] as? Date == before[.modificationDate] as? Date &&
                  after[.posixPermissions] as? NSNumber == before[.posixPermissions] as? NSNumber,
                  "raw node metadata changed")
        let copiedAttribute = try readAttribute(copied), sourceAttribute = try readAttribute(original)
        try check(copiedAttribute == attributeBytes && sourceAttribute == attributeBytes,
                  "raw file/directory extended attribute changed")
    }
    let manifest = BackupIntegrity.Manifest(version: "4.10", files: try BackupIntegrity.manifest(snapshot))
    try fixture.write(try JSONEncoder().encode(manifest), at: snapshot.appendingPathComponent("gqns-manifest.json"))
    _ = try BackupIntegrity.verify(snapshot) // Exactly three real DBs; nested/raw SQLite stays opaque.
    // A newly rewritten matching manifest must not legitimize a missing active
    // authority. Check each canonical DB independently, then retain its bytes.
    for relative in canonical {
        let copied = copiedGroup.appendingPathComponent(relative)
        let retained = try Data(contentsOf: copied)
        try fixture.fm.removeItem(at: copied)
        let incomplete = BackupIntegrity.Manifest(version: "4.10", files: try BackupIntegrity.manifest(snapshot))
        try fixture.write(try JSONEncoder().encode(incomplete), at: snapshot.appendingPathComponent("gqns-manifest.json"))
        try mustRefuse("integrated archive accepted missing canonical DB: " + relative) {
            _ = try BackupIntegrity.verify(snapshot)
        }
        try fixture.write(retained, at: copied)
    }
    let complete = BackupIntegrity.Manifest(version: "4.10", files: try BackupIntegrity.manifest(snapshot))
    try fixture.write(try JSONEncoder().encode(complete), at: snapshot.appendingPathComponent("gqns-manifest.json"))
    _ = try BackupIntegrity.verify(snapshot)
    try fixture.assertStable(stable)
}

private func normalRestore(_ fixture: RestoreFixture) throws {
    let stable = try fixture.stable()
    let staged = try fixture.staged(historicalPending: true)
    try AppBackupRestore.schedule(staged)
    let jobID = try fixture.pendingJob().id
    try AppBackupRestore.applyPending()
    try check(!fixture.fm.fileExists(atPath: AppBackupRestore.pending.path), "committed job stayed pending")
    try check(!fixture.fm.fileExists(atPath: fixture.marker.path), "committed job left maintenance marker")
    let (_, job) = try fixture.archivedJob()
    try check(job.completed && job.outcome == "applied", "committed phase was not durable")
    try check(try Data(contentsOf: fixture.support.appendingPathComponent("library.json")) == Data("incoming-rhythm-library".utf8), "new Root library not applied")
    for module in ["Health", "Footprints"] {
        let root = fixture.support.appendingPathComponent("IntegratedRecovery/" + module, isDirectory: true)
        try check(!fixture.fm.fileExists(atPath: root.appendingPathComponent("pending.json").path), "historical module request remains executable")
        let retained = root.appendingPathComponent("ImportedPending.noindex/" + jobID + "-pending.json")
        try check(try Data(contentsOf: retained) == Data(("historical-request-" + module).utf8), "historical request bytes not retained")
        let original = job.safety.appendingPathComponent("ApplicationSupport/library.json")
        try check(try Data(contentsOf: original) == Data("original-rhythm-library".utf8), "original Root data not retained in safety")
    }
    try fixture.assertStable(stable)
}

private func retiredArchivesAreNotRestoreDependencies(_ fixture: RestoreFixture) throws {
    let staged = try fixture.staged()
    try fixture.fm.removeItem(at: fixture.sourceArchive)
    try AppBackupRestore.schedule(staged)
    try AppBackupRestore.applyPending()
    try check(!fixture.fm.fileExists(atPath: fixture.sourceArchive.path), "restore recreated retired source recovery bytes")
    try check(try Data(contentsOf: fixture.support.appendingPathComponent("library.json")) == Data("incoming-rhythm-library".utf8), "current business restore depended on retired copies")
    for relative in ["Modules/Health/health.sqlite", "Modules/Footprints/footprints.sqlite", "SharedSleep/sleep-records.sqlite"] {
        try check(DailyBackup.integrityCheck(fixture.group.appendingPathComponent("Integration/" + relative)) == "ok", "retired copies weakened active database validation")
    }
}

private func completedCrashWindow(_ fixture: RestoreFixture, markerAlreadyCleared: Bool) throws {
    let staged = try fixture.staged()
    try AppBackupRestore.schedule(staged); try AppBackupRestore.applyPending()
    let (archived, job) = try fixture.archivedJob()
    let completedBytes = try Data(contentsOf: archived)
    try fixture.fm.removeItem(at: archived)
    try fixture.write(completedBytes, at: AppBackupRestore.pending)
    if !markerAlreadyCleared { try fixture.markerForInterruptedHost() }
    // A legitimate post-completion edit must survive finalize-only restart.
    try fixture.write(Data("new-user-data-after-completed".utf8), at: fixture.support.appendingPathComponent("after-completed.txt"))
    UserDefaults.standard.setPersistentDomain(["newPreference": "after-completed"], forName: fixture.domain("integratedFootprints"))
    _ = UserDefaults.standard.synchronize()
    let dataBefore = try BackupIntegrity.manifest(fixture.support), prefsBefore = fixture.preferences(), stable = try fixture.stable()
    try AppBackupRestore.applyPending()
    try check(try BackupIntegrity.manifest(fixture.support) == dataBefore, "completed restart replayed or rolled back data")
    try check(NSDictionary(dictionary: fixture.preferences()).isEqual(to: prefsBefore), "completed restart replayed preferences")
    try check(!fixture.fm.fileExists(atPath: fixture.marker.path) && !fixture.fm.fileExists(atPath: AppBackupRestore.pending.path), "completed restart did not finalize")
    let (_, again) = try fixture.archivedJob()
    try check(again.id == job.id && again.completed && again.outcome == "applied", "completed job identity changed")
    try fixture.assertStable(stable)
}

private func partialPreferencesRollback(_ fixture: RestoreFixture) throws {
    let before = fixture.preferences(), original = try BackupIntegrity.manifest(fixture.support), stable = try fixture.stable()
    _ = try fixture.interruptedJob(includeModules: false)
    UserDefaults.standard.setPersistentDomain(["half": "new-standard"], forName: fixture.domain("standard"))
    UserDefaults.standard.setPersistentDomain(["half": "created-health-domain"], forName: fixture.domain("integratedHealth"))
    _ = UserDefaults.standard.synchronize()
    try mustRefuse("rolled-back recovery should report the interrupted operation") { try AppBackupRestore.applyPending() }
    try check(NSDictionary(dictionary: fixture.preferences()).isEqual(to: before), "all four original preference presences/values not restored")
    try check(UserDefaults.standard.persistentDomain(forName: fixture.domain("integratedHealth")) == nil, "original absent domain became empty/new domain")
    try check(try BackupIntegrity.manifest(fixture.support) == original, "original Root Support did not roll back")
    try check(!fixture.fm.fileExists(atPath: fixture.marker.path) && !fixture.fm.fileExists(atPath: AppBackupRestore.pending.path), "verified rollback left orphan marker")
    let (_, job) = try fixture.archivedJob()
    try check(job.completed && job.outcome == "rolledBack", "rollback completion not retained")
    try fixture.assertStable(stable)
}

private func partialIntegrationRollback(_ fixture: RestoreFixture) throws {
    let modules = fixture.group.appendingPathComponent("Integration/Modules", isDirectory: true)
    let original = try BackupIntegrity.manifest(modules), stable = try fixture.stable()
    let interrupted = try fixture.interruptedJob(includeModules: true)
    // An interrupted restore must recover from its verified safety copy even
    // if its incoming archive is damaged afterwards. Checking compatibility
    // first would reject these changed staged bytes before rollback can run.
    try fixture.write(Data("damaged-incoming-after-interruption".utf8),
                      at: interrupted.staged.appendingPathComponent("AppGroupContainer/Integration/SourceArchives/Health/ApplicationSupport/document.pdf"))
    try mustRefuse("partial restore must surface its rollback result") { try AppBackupRestore.applyPending() }
    try check(try BackupIntegrity.manifest(modules) == original, "partial Integration prevented original rollback")
    let (_, job) = try fixture.archivedJob()
    try check(job.completed && job.outcome == "rolledBack", "partial Integration did not reach durable rollback phase")
    try fixture.assertStable(stable)
}

private func escapedLegacyPaths(_ fixture: RestoreFixture) throws {
    let stable = try fixture.stable(), original = try BackupIntegrity.manifest(fixture.support)
    let staged = try fixture.staged()
    let outside = fixture.root.appendingPathComponent("OutsideJobs/" + UUID().uuidString + ".noindex", isDirectory: true)
    try fixture.fm.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fixture.fm.copyItem(at: staged, to: outside)
    let job = AppBackupRestore.Job(staged: outside, safety: fixture.jobs.appendingPathComponent("恢复前原始数据-" + UUID().uuidString + ".noindex"))
    var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
    value.removeValue(forKey: "id"); value.removeValue(forKey: "completed"); value.removeValue(forKey: "outcome")
    try fixture.writeJSON(value, at: AppBackupRestore.pending)
    try mustRefuse("legacy outside-jobs staged path was accepted") { try AppBackupRestore.applyPending() }
    try check(fixture.fm.fileExists(atPath: AppBackupRestore.pending.path), "unsafe legacy request was discarded")
    try check(try BackupIntegrity.manifest(fixture.support) == original, "unsafe legacy job changed Root Support")
    try fixture.assertStable(stable)
}

private func escapedLegacyOperations(_ fixture: RestoreFixture) throws {
    let stable = try fixture.stable(), original = try BackupIntegrity.manifest(fixture.support)
    let staged = try fixture.staged()
    let outside = fixture.root.appendingPathComponent("NotRootOwned/data.txt")
    try fixture.write(Data("keep-outside".utf8), at: outside)
    var job = AppBackupRestore.Job(staged: staged, safety: fixture.jobs.appendingPathComponent("恢复前原始数据-" + UUID().uuidString + ".noindex", isDirectory: true))
    job.applying = true
    job.operations = [try AppBackupRestore.Operation(source: staged.appendingPathComponent("ApplicationSupport-Rhythm/library.json"), destination: outside,
                                                     previous: job.safety.appendingPathComponent("Outside"), hadPrevious: true)]
    try fixture.save(job)
    try mustRefuse("foreign destination was accepted") { try AppBackupRestore.applyPending() }
    try check(try Data(contentsOf: outside) == Data("keep-outside".utf8), "foreign destination changed")
    // An old operation that swaps the whole Integration must also be rejected.
    job.operations = [try AppBackupRestore.Operation(source: staged.appendingPathComponent("AppGroupContainer/Integration"),
                                                     destination: fixture.group.appendingPathComponent("Integration"),
                                                     previous: job.safety.appendingPathComponent("Group-Integration"), hadPrevious: true)]
    try fixture.save(job)
    try mustRefuse("whole-Integration legacy swap was accepted") { try AppBackupRestore.applyPending() }
    try check(try BackupIntegrity.manifest(fixture.support) == original, "foreign operation changed Root data")
    try fixture.assertStable(stable)
}

private func failedRollbackRemainsPending(_ fixture: RestoreFixture) throws {
    let stable = try fixture.stable()
    let job = try fixture.interruptedJob(includeModules: false)
    try fixture.write(Data("changed-safety-evidence".utf8), at: job.safety.appendingPathComponent("ApplicationSupport/changed.txt"))
    let partial = try BackupIntegrity.manifest(fixture.support)
    try mustRefuse("damaged rollback evidence was accepted") { try AppBackupRestore.applyPending() }
    try check(fixture.fm.fileExists(atPath: fixture.marker.path) && fixture.fm.fileExists(atPath: AppBackupRestore.pending.path), "failed rollback cleared protective marker/pending")
    let current = try fixture.pendingJob()
    try check(current.applying && !current.completed, "failed rollback was marked complete")
    try check(try BackupIntegrity.manifest(fixture.support) == partial, "failed rollback overwrote partial/current evidence")
    try fixture.assertStable(stable)
}

private func futureVersionPending(_ fixture: RestoreFixture) throws {
    let stable = try fixture.stable(), original = try BackupIntegrity.manifest(fixture.support), preferences = fixture.preferences()
    let staged = try fixture.staged(version: "999.0")
    // Deliberately model a request queued by a newer app. Calling prepare again
    // would hide the exact pending-resume version boundary under test.
    let job = AppBackupRestore.Job(staged: staged, safety: fixture.jobs.appendingPathComponent("恢复前原始数据-" + UUID().uuidString + ".noindex"))
    try fixture.save(job)
    try mustRefuse("future-version pending was applied without prepare") { try AppBackupRestore.applyPending() }
    try check(try BackupIntegrity.manifest(fixture.support) == original, "future-version pending changed data")
    try check(NSDictionary(dictionary: fixture.preferences()).isEqual(to: preferences), "future-version pending changed preferences")
    try check(fixture.fm.fileExists(atPath: AppBackupRestore.pending.path), "future-version pending evidence disappeared")
    try fixture.assertStable(stable)
}

@main private struct HostIntegrationRestoreRegression {
    static func main() {
        do {
            guard let value = ProcessInfo.processInfo.environment["RHYTHM_HOST_RESTORE_FIXTURE_ROOT"] else {
                throw CheckFailure("missing explicit isolated fixture root")
            }
            let base = URL(fileURLWithPath: value, isDirectory: true)
            guard base.path.hasPrefix("/private/tmp/rhythm-host-restore-"), base.lastPathComponent.hasSuffix(".noindex"),
                  !base.pathComponents.contains(".."), FileManager.default.fileExists(atPath: base.path) else {
                throw CheckFailure("fixture must be an existing uniquely owned /private/tmp .noindex directory")
            }
            let suffix = base.lastPathComponent.dropFirst("rhythm-host-restore-".count).dropLast(8)
            guard UUID(uuidString: String(suffix)) != nil else { throw CheckFailure("fixture UUID missing") }
            let cases: [(String, (RestoreFixture) throws -> Void)] = [
                ("snapshot_three_canonical_wals_and_raw_opaque_metadata", snapshotCanonicalAndRaw),
                ("normal_restore_quarantines_two_historical_pending_and_keeps_stable_objects", normalRestore),
                ("retired_source_archives_not_required_or_recreated", retiredArchivesAreNotRestoreDependencies),
                ("completed_before_marker_clear_only_finalizes", { try completedCrashWindow($0, markerAlreadyCleared: false) }),
                ("completed_after_marker_clear_only_finalizes", { try completedCrashWindow($0, markerAlreadyCleared: true) }),
                ("partial_preferences_rollback_restores_four_domains_including_absence", partialPreferencesRollback),
                ("partial_integration_rolls_back_before_compatibility", partialIntegrationRollback),
                ("escaped_legacy_stage_is_refused", escapedLegacyPaths),
                ("escaped_and_whole_integration_operations_are_refused", escapedLegacyOperations),
                ("failed_rollback_retains_pending_and_marker", failedRollbackRemainsPending),
                ("future_version_pending_is_refused", futureVersionPending)
            ]
            var passed: [String] = []
            for (name, operation) in cases {
                let fixture = try RestoreFixture(base: base)
                defer { fixture.cleanup() }
                try operation(fixture)
                passed.append(name)
                print("PASS " + name)
            }
            let report: [String: Any] = ["status": "PASS", "cases": passed.count, "passed": passed,
                                         "syntheticOnly": true, "realUserDataRead": false, "guiLaunched": false,
                                         "realPreferenceDomainsRead": false, "smokeTest": false]
            print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
        } catch {
            fputs("FAIL host integration restore regression: \(error)\n", stderr)
            exit(1)
        }
    }
}
