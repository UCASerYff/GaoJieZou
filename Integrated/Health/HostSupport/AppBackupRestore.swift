import Foundation

/// Health-only recovery. Shared sleep and immutable source archives are never replaced.
enum AppBackupRestore {
    struct Job: Codable {
        var format = "RhythmHealthRestore-v1"
        var id: String
        var staged: URL
        var authoritySHA256: String
        var applying = false
        var completed = false
        var operations: [Operation] = []
        var originalPreferences: URL?
    }
    struct Operation: Codable { var incoming: URL; var destination: URL; var previous: URL; var incomingHashes: [String: String] }
    static var jobs: URL {
        #if INTEGRATION_PATH_TEST
        return (try! RhythmIntegrationPaths.groupDirectory()).deletingLastPathComponent().appendingPathComponent("TestSupport/GaoSeries/Rhythm/IntegratedRecovery/Health", isDirectory: true)
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GaoSeries/Rhythm/IntegratedRecovery/Health", isDirectory: true)
        #endif
    }
    static var pending: URL { jobs.appendingPathComponent("pending.json") }
    private static func authorityHash() throws -> String { try BackupIntegrity.hash(AppDataLocations.integrationRoot().appendingPathComponent("authority.json")) }
    static func prepare(_ archive: URL) throws -> (URL, BackupIntegrity.Manifest) {
        _ = try RhythmIntegrationPaths.moduleDirectory("health")
        let fm = FileManager.default
        try fm.createDirectory(at: jobs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = jobs.appendingPathComponent("\(UUID().uuidString).noindex", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let attributes = try AppBackupExport.run("/usr/bin/zipinfo", ["-l", archive.path])
            guard !attributes.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else { throw CocoaError(.fileReadCorruptFile) }
            let listing = try AppBackupExport.run("/usr/bin/unzip", ["-Z1", archive.path])
            guard listing.split(separator: "\n").allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else { throw CocoaError(.fileReadCorruptFile) }
            _ = try AppBackupExport.run("/usr/bin/ditto", ["-x", "-k", archive.path, staged.path])
            let manifest = try BackupIntegrity.verify(staged)
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.10"
            guard manifest.version.compare(current, options: .numeric) != .orderedDescending else { throw CocoaError(.fileReadCorruptFile) }
            let roots = try incomingRoots(staged, manifest)
            try HealthArchiveValidation.validate(directory: roots.health)
            if let sleep = roots.sleep { try AppBackupExport.validateSharedSleep(sleep) }
            _ = try RestorePreferences.incoming(staged)
            return (staged, manifest)
        } catch { try? fm.removeItem(at: staged); throw error }
    }
    private static func incomingRoots(_ staged: URL, _ manifest: BackupIntegrity.Manifest) throws -> (health: URL, sleep: URL?) {
        let fm = FileManager.default
        if manifest.format == 2 {
            let health = staged.appendingPathComponent("Health", isDirectory: true), sleep = staged.appendingPathComponent("SharedSleep", isDirectory: true)
            guard fm.fileExists(atPath: health.path), fm.fileExists(atPath: sleep.path) else { throw CocoaError(.fileReadCorruptFile) }
            return (health, sleep)
        }
        let group = staged.appendingPathComponent("AppGroupContainer", isDirectory: true)
        let health = group.appendingPathComponent("Health", isDirectory: true), sleep = group.appendingPathComponent("SharedSleep", isDirectory: true)
        guard fm.fileExists(atPath: health.path), fm.fileExists(atPath: staged.appendingPathComponent("ApplicationSupport-Health").path) else { throw CocoaError(.fileReadCorruptFile) }
        return (health, fm.fileExists(atPath: sleep.path) ? sleep : nil)
    }
    private static func validStaged(_ url: URL) -> Bool {
        guard url.isFileURL, url.deletingLastPathComponent().path == jobs.path,
              url.lastPathComponent.hasSuffix(".noindex"),
              UUID(uuidString: String(url.lastPathComponent.dropLast(8))) != nil else { return false }
        do { try RhythmIntegrationPaths.requireExisting(url, directory: true); return true }
        catch { return false }
    }
    static func schedule(_ staged: URL) throws {
        guard validStaged(staged), !FileManager.default.fileExists(atPath: pending.path) else { throw CocoaError(.fileWriteFileExists) }
        _ = try BackupIntegrity.verify(staged)
        try save(Job(id: UUID().uuidString, staged: staged, authoritySHA256: try authorityHash()))
    }
    private static func save(_ job: Job) throws {
        try JSONEncoder().encode(job).write(to: pending, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
    }
    /// Host calls before ANY store. No pending means no singleton or path initialization.
    static func applyPending() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pending.path) else { return }
        let completed = try RhythmIntegrationPaths.withMaintenanceLease(owner: "health") {
            try applyPendingLocked()
        }
        // The durable completed flag precedes maintenance-marker removal. A crash
        // here leaves an idempotent finalize-only job, never an orphaned marker.
        guard completed.completed else { throw CocoaError(.fileWriteUnknown) }
        try fm.moveItem(at: pending, to: jobs.appendingPathComponent("completed-\(completed.id).json"))
    }
    private static func applyPendingLocked() throws -> Job {
        let fm = FileManager.default
        guard try pending.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        var job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: pending))
        guard job.format == "RhythmHealthRestore-v1", UUID(uuidString: job.id) != nil, validStaged(job.staged), job.authoritySHA256 == (try authorityHash()) else { throw CocoaError(.fileReadCorruptFile) }
        let integration = try AppDataLocations.integrationRoot()
        let health = integration.appendingPathComponent("Modules/Health", isDirectory: true)
        var transaction = integration.appendingPathComponent("HealthRecovery.noindex/\(job.id)", isDirectory: true)
        if job.completed { return job }
        if job.applying {
            try validateOperations(job, health: health, transaction: transaction)
            try rollback(job)
            job.applying = false; job.operations = []; job.originalPreferences = nil
            try save(job)
            throw CocoaError(.fileWriteUnknown)
        }
        let manifest = try BackupIntegrity.verify(job.staged), roots = try incomingRoots(job.staged, manifest)
        try HealthArchiveValidation.validate(directory: roots.health)
        if let source = roots.sleep { try AppBackupExport.validateSharedSleep(source) }
        let preferences = try RestorePreferences.incoming(job.staged)
        // A damaged current save cannot be interpreted as no reward history.
        let current = try HealthDatabase(directory: health, access: .readOnlyMaintenance).read()
        if fm.fileExists(atPath: transaction.path) {
            job.id = UUID().uuidString
            transaction = integration.appendingPathComponent("HealthRecovery.noindex/\(job.id)", isDirectory: true)
            try save(job)
        }
        try fm.createDirectory(at: transaction, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let incoming = transaction.appendingPathComponent("Incoming-Health", isDirectory: true)
        try BackupIntegrity.copySnapshot(from: roots.health, to: incoming)
        // Activation provenance belongs to this transaction, not the imported backup.
        let currentProvenance = health.appendingPathComponent("Preferences.plist")
        try RhythmIntegrationPaths.requireExisting(currentProvenance, directory: false)
        let incomingProvenance = incoming.appendingPathComponent("Preferences.plist")
        if fm.fileExists(atPath: incomingProvenance.path) {
            try fm.moveItem(at: incomingProvenance, to: transaction.appendingPathComponent("Imported-Preferences.plist"))
        }
        try fm.copyItem(at: currentProvenance, to: incomingProvenance)
        let stagedDatabase = try HealthDatabase(directory: incoming, access: .application)
        try stagedDatabase.transaction { state in state = HealthRestoreSafety.retainingReceipts(incoming: state, current: current) }
        try stagedDatabase.closeStagedConnection()
        try HealthArchiveValidation.validate(directory: incoming)
        job.operations = [Operation(incoming: incoming, destination: health, previous: transaction.appendingPathComponent("Previous-Health", isDirectory: true), incomingHashes: try BackupIntegrity.manifest(incoming))]
        let preferencesFile = transaction.appendingPathComponent("original-preferences.json")
        try RestorePreferences.capture(to: preferencesFile); job.originalPreferences = preferencesFile
        job.applying = true; try save(job)
        do {
            for op in job.operations {
                try fm.moveItem(at: op.destination, to: op.previous)
                try fm.moveItem(at: op.incoming, to: op.destination)
            }
            #if INTEGRATION_PATH_TEST
            if ProcessInfo.processInfo.environment["RHYTHM_HEALTH_RESTORE_FAIL"] == "after-replace" { throw CocoaError(.fileWriteUnknown) }
            #endif
            try HealthArchiveValidation.validate(directory: health, maintenance: true)
            try RestorePreferences.apply(preferences)
            job.completed = true; try save(job)
            // SharedSleep and SourceArchives never occur in replacement operations.
            // Incoming archives (including their sleep/source trees), previous
            // health data and all receipts remain available for recovery/audit.
            return job
        } catch {
            try rollback(job)
            job.applying = false; job.operations = []; job.originalPreferences = nil
            try save(job)
            throw error
        }
    }
    private static func validateOperations(_ job: Job, health: URL, transaction: URL) throws {
        guard let receipt = job.originalPreferences, receipt == transaction.appendingPathComponent("original-preferences.json"), job.operations.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
        let op = job.operations[0]
        guard op.destination == health, op.incoming == transaction.appendingPathComponent("Incoming-Health", isDirectory: true), op.previous == transaction.appendingPathComponent("Previous-Health", isDirectory: true) else { throw CocoaError(.fileReadCorruptFile) }
    }
    private static func rollback(_ job: Job) throws {
        let fm = FileManager.default
        guard let receipt = job.originalPreferences else { throw CocoaError(.fileReadCorruptFile) }
        try RestorePreferences.restore(from: receipt)
        for op in job.operations.reversed() where fm.fileExists(atPath: op.previous.path) {
            if fm.fileExists(atPath: op.destination.path) {
                guard try BackupIntegrity.manifest(op.destination) == op.incomingHashes else { throw CocoaError(.fileWriteNoPermission) }
                try fm.moveItem(at: op.destination, to: op.incoming)
            }
            try fm.moveItem(at: op.previous, to: op.destination)
        }
    }
}
