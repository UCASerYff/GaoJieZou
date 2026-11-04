import Foundation

// Compiled with the production core files and INTEGRATION_PATH_TEST only.
// The defaults provider is in-memory; no user preference domain is accessed.
final class FixtureDefaults {
    var domain: [String: Any] = [:]
    func persistentDomain(forName: String) -> [String: Any]? { domain }
    func string(forKey key: String) -> String? { domain[key] as? String }
    func set(_ value: Any?, forKey key: String) { domain[key] = value }
    func setPersistentDomain(_ value: [String: Any], forName: String) { domain = value }
    func removePersistentDomain(forName: String) { domain = [:] }
}
enum FootprintsBundle {
    static var bundle = Bundle.main
    static let defaults = FixtureDefaults()
}
@MainActor enum FootprintsRuntime { static var hasOpenedStore = false }
func tF(_ zh: String, _ en: String) -> String { zh }

@main @MainActor struct IntegrationCoreRegression {
    static var cases: [String] = []
    static func require(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw AppFailure("FAIL: " + name) }
        cases.append(name)
    }
    static func refuses(_ name: String, _ operation: () throws -> Void) throws {
        var refused = false
        do { try operation() } catch { refused = true }
        try require(refused, name)
    }
    static func plist(_ value: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: url)
    }
    static func xattr(_ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr"); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppFailure("Synthetic xattr operation failed") }
        return String(decoding: bytes, as: UTF8.self)
    }
    static func current(_ root: URL) throws -> Journal { try Repository(root: root, readOnly: true).load() }
    static func save(_ value: Journal, root: URL) throws {
        try RhythmIntegrationPaths.withWriterLease {
            try Repository(root: root, requiresIntegrationAuthority: true).save(value)
        }
    }

    @MainActor static func main() throws {
        let fm = FileManager.default
        guard let path = ProcessInfo.processInfo.environment["RHYTHM_INTEGRATION_TEST_GROUP"],
              path.hasPrefix("/private/tmp/"), path.contains(".noindex/") else { throw AppFailure("Isolated canonical test group required") }
        let group = URL(fileURLWithPath: path, isDirectory: true)
        try fm.createDirectory(at: group, withIntermediateDirectories: true)
        let integration = group.appendingPathComponent("Integration", isDirectory: true)
        let root = integration.appendingPathComponent("Modules/Footprints", isDirectory: true)
        try fm.createDirectory(at: integration.appendingPathComponent("Modules/Health"), withIntermediateDirectories: true)
        let city = City(id: "fixture-city", name: "测试城市", english: "Fixture", aliases: "", countryID: "CHN", provinceID: "test", province: "测试", continent: "亚洲", longitude: 116, latitude: 39, isCustom: false)
        let geography = Geography(countries: [Country(id: "CHN", name: "中国", english: "China", continent: "亚洲")], cities: [city], world: [], china: [])
        let bundleRoot = group.appendingPathComponent("Fixture.bundle", isDirectory: true)
        let resources = bundleRoot.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try plist(["CFBundleIdentifier": "com.gaojiezou.rhythm.footprints.fixture", "CFBundlePackageType": "BNDL", "CFBundleVersion": "11", "CFBundleShortVersionString": "4.10"], to: bundleRoot.appendingPathComponent("Contents/Info.plist"))
        try JSONEncoder().encode(geography).write(to: resources.appendingPathComponent("Geography.json"))
        guard let bundle = Bundle(url: bundleRoot) else { throw AppFailure("Fixture resource bundle unavailable") }
        FootprintsBundle.bundle = bundle
        let fixtureDate = Date(timeIntervalSince1970: 1_700_000_000)
        var original = Journal(); original.modifiedAt = fixtureDate
        original.residentCityID = city.id
        original.visits = [Visit(id: "original-visit", cityID: city.id, note: "original fixture", createdAt: fixtureDate, modifiedAt: fixtureDate)]
        original.train.materials = 15; original.train.lifetimeMaterials = 30
        original.train.claimedVisitIDs = ["original-visit"]; original.train.claimedCityIDs = [city.id]
        do { let repo = try Repository(root: root); try repo.save(original) }
        try fm.createDirectory(at: root.appendingPathComponent("WidgetData"), withIntermediateDirectories: true)
        let prefs = root.appendingPathComponent("Preferences.plist")
        let sourcePreferences: [String: Any] = ["schema": 1, "transactionID": "footprints-fixture",
            "standard": ["gqns.language": "en", "gqns.train.autoTour": true, "gqns.home.compact": false],
            "module": ["animationEnabled": false, "soundEnabled": true, "ownerName": "source owner"]]
        try plist(sourcePreferences, to: prefs)
        let authority: [String: Any] = ["schemaVersion": 1, "state": "active", "transactionID": "footprints-fixture",
            "modulePaths": ["health": "Modules/Health", "footprints": "Modules/Footprints"],
            "sharedSleepPath": "SharedSleep", "sourceRevisions": ["footprints": String(repeating: "a", count: 64)]]
        try JSONSerialization.data(withJSONObject: authority, options: [.sortedKeys]).write(to: integration.appendingPathComponent("authority.json"))

        FootprintsBundle.defaults.set("new owner", forKey: "ownerName")
        try FootprintsPreferences.prepare()
        try require(FootprintsBundle.defaults.string(forKey: "ownerName") == "new owner", "new-host choice wins first import")
        try require(FootprintsBundle.defaults.domain["animationEnabled"] as? Bool == false, "original boolean preserved")
        FootprintsBundle.defaults.set(true, forKey: "animationEnabled")
        try FootprintsPreferences.prepare()
        try require(FootprintsBundle.defaults.domain["animationEnabled"] as? Bool == true, "same source import idempotent")
        let goodPreferences = try Data(contentsOf: prefs)
        try fm.removeItem(at: prefs)
        try refuses("missing preference receipt refused") { try FootprintsPreferences.prepare() }
        try goodPreferences.write(to: prefs)
        try plist(["schema": 1, "standard": [:], "module": ["animationEnabled": false, "soundEnabled": "yes"]], to: prefs)
        let beforeBad = FootprintsBundle.defaults.string(forKey: "ownerName")
        try refuses("wrong preference type refused") { try FootprintsPreferences.prepare() }
        try require(FootprintsBundle.defaults.string(forKey: "ownerName") == beforeBad && FootprintsBundle.defaults.domain["animationEnabled"] as? Bool == true, "bad import has no partial update")
        try goodPreferences.write(to: prefs)

        let missingDatabase = root.appendingPathComponent("footprints.sqlite")
        let heldDatabase = group.appendingPathComponent("missing-database-held.sqlite")
        try fm.moveItem(at: missingDatabase, to: heldDatabase)
        try refuses("production missing database cannot initialize empty library") {
            _ = try RhythmIntegrationPaths.withWriterLease { try Repository(root: root, requiresIntegrationAuthority: true) }
        }
        try require(!fm.fileExists(atPath: missingDatabase.path), "missing production database was not recreated")
        try fm.moveItem(at: heldDatabase, to: missingDatabase)

        var stale: Repository? = try RhythmIntegrationPaths.withWriterLease { try Repository(root: root, requiresIntegrationAuthority: true) }
        let database = root.appendingPathComponent("footprints.sqlite")
        let predecessor = group.appendingPathComponent("inode-predecessor.sqlite")
        try fm.moveItem(at: database, to: predecessor)
        try fm.copyItem(at: predecessor, to: database)
        try refuses("old SQLite connection refuses replaced inode") { try stale!.save(original) }
        try fm.removeItem(at: database); try fm.moveItem(at: predecessor, to: database); stale = nil
        try require(try current(root).train == original.train, "inode refusal retained game state")

        // Historical objects with SQLite-looking names are byte evidence, not
        // additional live stores. Include binary xattrs and an empty directory.
        let opaque = root.appendingPathComponent("Snapshots/opaque.sqlite")
        let opaqueBytes = Data([0, 255, 1, 2, 0])
        try opaqueBytes.write(to: opaque)
        try Data([255, 254]).write(to: root.appendingPathComponent("Snapshots/opaque.sqlite-wal"))
        try fm.createDirectory(at: root.appendingPathComponent("Historical.noindex/nested/empty"), withIntermediateDirectories: true)
        _ = try xattr(["-wx", "com.rhythm.fixture.raw", "0001ff", opaque.path])
        let archive = group.appendingPathComponent("full-module.zip")
        _ = try AppBackupExport.export(appSupport: root, group: root.appendingPathComponent("WidgetData"), destination: archive)
        var edited = original; edited.visits[0].note = "newer current fixture"
        try save(edited, root: root)
        let (staged, _) = try AppBackupRestore.prepare(archive)
        let stagedSupport = staged.appendingPathComponent("ApplicationSupport-Footprints")
        try require(try Data(contentsOf: stagedSupport.appendingPathComponent("Snapshots/opaque.sqlite")) == opaqueBytes, "historical malformed SQLite preserved without reinterpretation")
        try require(try Data(contentsOf: stagedSupport.appendingPathComponent("Snapshots/opaque.sqlite-wal")) == Data([255, 254]), "historical WAL retained raw")
        try require(fm.fileExists(atPath: stagedSupport.appendingPathComponent("Historical.noindex/nested/empty").path), "empty historical directory retained")
        let copiedXattr = try xattr(["-px", "com.rhythm.fixture.raw", stagedSupport.appendingPathComponent("Snapshots/opaque.sqlite").path]).lowercased().filter { "0123456789abcdef".contains($0) }
        try require(copiedXattr == "0001ff", "binary xattr retained through full ZIP")
        try AppBackupRestore.schedule(staged)
        let jobs = group.appendingPathComponent("TestApplicationSupport/GaoSeries/Rhythm/IntegratedRecovery/Footprints")
        let pending = jobs.appendingPathComponent("pending.json")
        let job = try JSONDecoder().decode(AppBackupRestore.Job.self, from: Data(contentsOf: pending))
        let marker = group.appendingPathComponent(".rhythm-integration-maintenance.json")
        let stagedPrefs = job.prepared.appendingPathComponent("Preferences.plist")
        let intact = try Data(contentsOf: stagedPrefs)
        try Data("corrupt".utf8).write(to: stagedPrefs)
        try refuses("changed prepared payload refused") { try AppBackupRestore.applyPending() }
        try require(fm.fileExists(atPath: pending.path) && fm.fileExists(atPath: marker.path), "failure retains pending and maintenance marker")
        try require(try current(root).visits[0].note == edited.visits[0].note, "failed restore retained current business data")
        try intact.write(to: stagedPrefs)
        try AppBackupRestore.applyPending()
        try require(!fm.fileExists(atPath: pending.path) && !fm.fileExists(atPath: marker.path), "same-owner safe retry completes and clears marker")
        try require(try current(root).train == original.train && current(root).visits == original.visits, "restore preserves original game and IDs")

        // Model a crash after durable completion but before the helper's marker
        // clear/final pending archive. A completed job must not replace newer data.
        try save(edited, root: root)
        var completed = job; completed.phase = "completed"; completed.applying = false
        try JSONEncoder().encode(completed).write(to: pending, options: .atomic)
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "owner": "footprints"]).write(to: marker, options: .atomic)
        try AppBackupRestore.applyPending()
        try require(try current(root).visits[0].note == edited.visits[0].note, "durable completed recovery never replays over newer data")
        try require(!fm.fileExists(atPath: pending.path) && !fm.fileExists(atPath: marker.path), "completed marker recovery archives pending safely")

        let (stagedAgain, _) = try AppBackupRestore.prepare(archive)
        try AppBackupRestore.schedule(stagedAgain)
        var interrupted = try JSONDecoder().decode(AppBackupRestore.Job.self, from: Data(contentsOf: pending))
        interrupted.applying = true; interrupted.hadPrevious = true
        interrupted.previousPreferences = try PropertyListSerialization.data(fromPropertyList: FootprintsBundle.defaults.domain, format: .binary, options: 0)
        try fm.createDirectory(at: interrupted.safety, withIntermediateDirectories: true)
        try fm.moveItem(at: root, to: interrupted.safety.appendingPathComponent("PreviousModule"))
        try JSONEncoder().encode(interrupted).write(to: pending, options: .atomic)
        try require(!fm.fileExists(atPath: root.path), "fault fixture models crash with missing main directory")
        try AppBackupRestore.applyPending()
        try require(try current(root).visits[0].note == edited.visits[0].note, "crash before replacement safely rolls back predecessor")
        try require(!fm.fileExists(atPath: pending.path) && !fm.fileExists(atPath: marker.path), "recovery clears pending only with successful maintenance completion")
        try require(fm.fileExists(atPath: interrupted.safety.appendingPathComponent("restore-result.json").path), "recovery receipt retained")
        print("PASS Footprints integration core \(cases.count) cases; only synthetic files and in-memory preferences")
    }
}
