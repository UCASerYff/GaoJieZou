import AppKit
import Foundation
import Darwin

/// Full-host restore runs before any store opens. The group-root maintenance
/// lock and the original SourceArchives remain at stable paths throughout.
enum AppBackupRestore {
    struct Job: Codable {
        var id: String
        var staged: URL
        var safety: URL
        var applying = false
        var completed = false
        var outcome: String?
        var operations: [Operation] = []
        var originalPreferences: URL?
        var originalPreferencesSHA256: String?

        init(staged: URL, safety: URL) {
            id = UUID().uuidString; self.staged = staged; self.safety = safety
        }
        private enum CodingKeys: String, CodingKey {
            case id, staged, safety, applying, completed, outcome, operations
            case originalPreferences, originalPreferencesSHA256
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            staged = try c.decode(URL.self, forKey: .staged)
            safety = try c.decode(URL.self, forKey: .safety)
            // Old queued jobs decode, but paths and any started rollback still
            // have to pass the current safety contract before being executed.
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? Self.legacyID(safety)
            applying = try c.decodeIfPresent(Bool.self, forKey: .applying) ?? false
            completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
            outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
            operations = try c.decodeIfPresent([Operation].self, forKey: .operations) ?? []
            originalPreferences = try c.decodeIfPresent(URL.self, forKey: .originalPreferences)
            originalPreferencesSHA256 = try c.decodeIfPresent(String.self, forKey: .originalPreferencesSHA256)
        }
        private static func legacyID(_ safety: URL) -> String {
            let suffix = safety.lastPathComponent.replacingOccurrences(of: "恢复前原始数据-", with: "")
                .replacingOccurrences(of: ".noindex", with: "")
            return UUID(uuidString: suffix)?.uuidString ?? "invalid-legacy-job"
        }
    }
    struct Operation: Codable {
        var source: URL
        var destination: URL
        var previous: URL
        var hadPrevious: Bool
        var previousHashes: [String: String]?
        var incomingHashes: [String: String]?
        init(source: URL, destination: URL, previous: URL, hadPrevious: Bool) throws {
            self.source = source; self.destination = destination; self.previous = previous
            self.hadPrevious = hadPrevious
            previousHashes = hadPrevious ? try AppBackupRestore.itemHashes(destination) : nil
            incomingHashes = try AppBackupRestore.exists(source) ? AppBackupRestore.itemHashes(source) : nil
        }
    }

    static var jobs: URL {
        if let test = ProcessInfo.processInfo.environment["GQNS_RESTORE_ROOT"] { return URL(fileURLWithPath: test) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GaoSeriesRestore/Rhythm", isDirectory: true)
    }
    static var pending: URL { jobs.appendingPathComponent("pending.json") }
    private static let domains = ["standard": "com.gaojiezou.rhythm", "module": "com.gaojiezou.rhythm.Rhythm",
                                  "integratedFootprints": "com.gaojiezou.rhythm.integrated.footprints",
                                  "integratedHealth": "com.gaojiezou.rhythm.integrated.health"]
    private static let coordination = Set([".rhythm-integration-writers.lock", ".rhythm-integration-maintenance.json"])

    static func prepare(_ archive: URL) throws -> (URL, BackupIntegrity.Manifest) {
        let fm = FileManager.default
        try validateNoSymlinks(jobs)
        try fm.createDirectory(at: jobs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = jobs.appendingPathComponent(UUID().uuidString + ".noindex", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let attributes = try run("/usr/bin/zipinfo", ["-l", archive.path])
            guard !attributes.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else { throw corrupt() }
            let listing = try run("/usr/bin/unzip", ["-Z1", archive.path])
            guard listing.split(separator: "\n").allSatisfy({ line in
                let path = String(line)
                return !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
            }) else { throw corrupt() }
            _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, root.path])
            let manifest = try BackupIntegrity.verify(root)
            try requireDirectory(root.appendingPathComponent("ApplicationSupport-Rhythm"))
            try requireDirectory(root.appendingPathComponent("AppGroupContainer"))
            try requireCompatibleIntegration(root)
            _ = try incomingPreferences(root)
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.10"
            guard manifest.version.compare(current, options: .numeric) != .orderedDescending,
                  try exists(root.appendingPathComponent("ApplicationSupport-Rhythm")),
                  try exists(root.appendingPathComponent("AppGroupContainer")) else { throw corrupt() }
            return (root, manifest)
        } catch { try? fm.removeItem(at: root); throw error }
    }

    static func schedule(_ staged: URL) throws {
        try validateStaged(staged)
        guard try !exists(pending) else { throw failure("已有未完成的完整恢复任务，未覆盖。") }
        try requireCompatibleIntegration(staged)
        _ = try BackupIntegrity.verify(staged)
        _ = try incomingPreferences(staged)
        let job = Job(staged: staged, safety: jobs.appendingPathComponent("恢复前原始数据-" + UUID().uuidString + ".noindex", isDirectory: true))
        try save(job)
    }

    static func applyPending() throws {
        guard try exists(pending) else { return }
        // The completed record remains pending until the persistent marker has
        // been cleared. Restarting in that window only finalizes this record.
        let completed = try RhythmIntegrationPaths.withMaintenanceLease(owner: "host") {
            try applyPendingLocked()
        }
        guard completed.completed else { throw corrupt() }
        try syncDirectory(RhythmIntegrationPaths.groupDirectory())
        try archiveCompleted(completed)
        if completed.outcome != "applied" {
            throw failure("上次完整恢复未完成，已恢复原资料和原偏好；恢复中内容及备份已保留。")
        }
    }

    private static func applyPendingLocked() throws -> Job {
        let fm = FileManager.default
        try requireRegular(pending)
        var job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: pending))
        try validateJob(job)
        if job.completed {
            guard job.outcome == "applied" || job.outcome == "rolledBack" else { throw corrupt() }
            return job
        }
        // Never compare a partially copied Integration with an incoming backup.
        // First recover the recorded originals under EX, including preferences.
        if job.applying {
            try requireRollbackEvidence(job)
            try rollback(job)
            job.completed = true; job.outcome = "rolledBack"
            try save(job)
            return job
        }
        guard job.operations.isEmpty else { throw failure("未开始的旧恢复任务含未知操作，需离线核对。") }
        try requireCompatibleIntegration(job.staged)
        let queuedManifest = try BackupIntegrity.verify(job.staged)
        let currentVersion = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "4.10"
        guard queuedManifest.version.compare(currentVersion,options:.numeric) != .orderedDescending else { throw corrupt() }
        let preferences = try incomingPreferences(job.staged)
        guard let app = AppDataLocations.appSupport, let group = AppDataLocations.groupContainer else { throw corrupt() }
        try validateNoSymlinks(app); try validateNoSymlinks(group)
        if try !exists(job.safety) {
            try fm.createDirectory(at: job.safety, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let preferencesFile = job.safety.appendingPathComponent("original-preferences.plist")
        let original = try capturePreferences(jobID: job.id)
        if try exists(preferencesFile) {
            try requireRegular(preferencesFile)
            let retained = try preferenceSnapshot(preferencesFile, jobID: job.id)
            guard NSDictionary(dictionary: retained).isEqual(to: original) else {
                throw failure("恢复准备后的原偏好已变化，保留快照并停止，未覆盖新偏好。")
            }
        } else { try writeDurable(try plistData(original), to: preferencesFile) }
        job.originalPreferences = preferencesFile
        job.originalPreferencesSHA256 = try BackupIntegrity.hash(preferencesFile)
        job.operations = try makeOperations(job, app: app, group: group)
        try validateJob(job)
        for op in job.operations {
            guard try !exists(op.previous) else { throw failure("恢复安全目标已存在，未覆盖未知现物。") }
        }
        job.applying = true
        try save(job) // original preferences and all rollback identities precede any mutation
        do {
            for op in job.operations {
                if op.hadPrevious {
                    guard try exists(op.destination), try itemHashes(op.destination) == op.previousHashes else { throw corrupt() }
                    try fm.moveItem(at: op.destination, to: op.previous)
                }
                if let incoming = op.incomingHashes {
                    guard try itemHashes(op.source) == incoming else { throw corrupt() }
                    try fm.copyItem(at: op.source, to: op.destination)
                    guard try itemHashes(op.destination) == incoming else { throw corrupt() }
                }
            }
            // Jobs inside a restored Support tree describe historical requests.
            // Preserve their bytes, but never let module startup execute them.
            try quarantineImportedPending(in: app, jobID: job.id)
            try applyPreferences(preferences)
            try syncRestoredState(job)
            job.completed = true; job.outcome = "applied"
            try save(job)
            return job
        } catch {
            // Any failed rollback leaves applying+pending+maintenance intact.
            try rollback(job)
            job.completed = true; job.outcome = "rolledBack"
            try save(job)
            return job
        }
    }

    private static func makeOperations(_ job: Job, app: URL, group: URL) throws -> [Operation] {
        let fm = FileManager.default
        var result = [try Operation(source: job.staged.appendingPathComponent("ApplicationSupport-Rhythm"), destination: app,
                                    previous: job.safety.appendingPathComponent("ApplicationSupport"), hadPrevious: exists(app))]
        try requireDirectory(job.staged.appendingPathComponent("ApplicationSupport-Rhythm"))
        let groupSource = job.staged.appendingPathComponent("AppGroupContainer", isDirectory: true)
        try requireDirectory(groupSource)
        let incoming = try fm.contentsOfDirectory(at: groupSource, includingPropertiesForKeys: nil).filter { allowedGroupName($0.lastPathComponent) }
        let existing = try fm.contentsOfDirectory(at: group, includingPropertiesForKeys: nil).filter { allowedGroupName($0.lastPathComponent) }
        for name in Set(incoming.map(\.lastPathComponent) + existing.map(\.lastPathComponent)).sorted() {
            if name == "Integration" {
                let from = groupSource.appendingPathComponent(name, isDirectory: true)
                let to = group.appendingPathComponent(name, isDirectory: true)
                try requireDirectory(from); try requireDirectory(to)
                let old = try fm.contentsOfDirectory(at: to, includingPropertiesForKeys: nil)
                let new = try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)
                for child in Set(old.map(\.lastPathComponent) + new.map(\.lastPathComponent)).sorted() where allowedIntegrationName(child) {
                    let destination = to.appendingPathComponent(child)
                    result.append(try Operation(source: from.appendingPathComponent(child), destination: destination,
                                                previous: job.safety.appendingPathComponent("Integration-" + child), hadPrevious: exists(destination)))
                }
            } else {
                let destination = group.appendingPathComponent(name)
                result.append(try Operation(source: groupSource.appendingPathComponent(name), destination: destination,
                                            previous: job.safety.appendingPathComponent("Group-" + name), hadPrevious: exists(destination)))
            }
        }
        return result
    }

    private static func validateJob(_ job: Job) throws {
        guard UUID(uuidString: job.id) != nil else { throw corrupt() }
        try validateStaged(job.staged)
        try validateDirectJobPath(job.safety, prefix: "恢复前原始数据-")
        guard path(job.safety) != path(job.staged) else { throw corrupt() }
        if let original = job.originalPreferences {
            guard path(original) == path(job.safety.appendingPathComponent("original-preferences.plist")),
                  let digest = job.originalPreferencesSHA256, digest.count == 64,
                  digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw corrupt() }
        } else if job.originalPreferencesSHA256 != nil { throw corrupt() }
        guard let app = AppDataLocations.appSupport, let group = AppDataLocations.groupContainer else { throw corrupt() }
        var seen = Set<String>()
        for op in job.operations {
            try validateNoSymlinks(op.source); try validateNoSymlinks(op.destination); try validateNoSymlinks(op.previous)
            guard seen.insert(path(op.destination)).inserted else { throw corrupt() }
            if path(op.destination) == path(app) {
                guard path(op.source) == path(job.staged.appendingPathComponent("ApplicationSupport-Rhythm")),
                      path(op.previous) == path(job.safety.appendingPathComponent("ApplicationSupport")) else { throw corrupt() }
            } else if path(op.destination.deletingLastPathComponent()) == path(group) {
                let name = op.destination.lastPathComponent
                guard name != "Integration", allowedGroupName(name),
                      path(op.source) == path(job.staged.appendingPathComponent("AppGroupContainer/" + name)),
                      path(op.previous) == path(job.safety.appendingPathComponent("Group-" + name)) else { throw corrupt() }
            } else if path(op.destination.deletingLastPathComponent()) == path(group.appendingPathComponent("Integration")) {
                let name = op.destination.lastPathComponent
                guard allowedIntegrationName(name),
                      path(op.source) == path(job.staged.appendingPathComponent("AppGroupContainer/Integration/" + name)),
                      path(op.previous) == path(job.safety.appendingPathComponent("Integration-" + name)) else { throw corrupt() }
            } else { throw failure("恢复任务包含非本应用的目标路径，已停止重放。") }
            if !op.hadPrevious && op.previousHashes != nil { throw corrupt() }
        }
    }

    private static func requireRollbackEvidence(_ job: Job) throws {
        guard let file = job.originalPreferences, let expected = job.originalPreferencesSHA256,
              try BackupIntegrity.hash(file) == expected,
              job.operations.allSatisfy({ !$0.hadPrevious || $0.previousHashes != nil }) else {
            throw failure("旧的中断任务缺少恢复前偏好或原资料摘要，无法自动确认完整回滚；现物和备份均保留，请离线核对。")
        }
        _ = try preferenceSnapshot(file, jobID: job.id)
    }

    private static func rollback(_ job: Job) throws {
        try validateJob(job)
        try requireRollbackEvidence(job)
        let fm = FileManager.default
        for op in job.operations.reversed() {
            if try exists(op.previous) {
                guard try itemHashes(op.previous) == op.previousHashes else { throw corrupt() }
                if try exists(op.destination) {
                    try fm.moveItem(at: op.destination, to: job.safety.appendingPathComponent("恢复中内容-" + UUID().uuidString + ".noindex"))
                }
                try fm.moveItem(at: op.previous, to: op.destination)
            } else if !op.hadPrevious, try exists(op.destination) {
                try fm.moveItem(at: op.destination, to: job.safety.appendingPathComponent("恢复中内容-" + UUID().uuidString + ".noindex"))
            }
            if op.hadPrevious {
                guard try exists(op.destination), try itemHashes(op.destination) == op.previousHashes else { throw corrupt() }
            } else { guard try !exists(op.destination) else { throw corrupt() } }
        }
        let snapshot = try preferenceSnapshot(job.originalPreferences!, jobID: job.id)
        try restorePreferences(snapshot)
        try syncRestoredState(job)
    }

    private static func quarantineImportedPending(in support: URL, jobID: String) throws {
        let fm = FileManager.default
        for module in ["Health", "Footprints"] {
            let root = support.appendingPathComponent("IntegratedRecovery/" + module, isDirectory: true)
            let imported = root.appendingPathComponent("pending.json")
            if try !exists(imported) { continue }
            try requireRegular(imported)
            let archive = root.appendingPathComponent("ImportedPending.noindex", isDirectory: true)
            try validateNoSymlinks(archive)
            try fm.createDirectory(at: archive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let retained = archive.appendingPathComponent(jobID + "-pending.json")
            guard try !exists(retained) else { throw corrupt() }
            try fm.moveItem(at: imported, to: retained)
            try syncDirectory(root); try syncDirectory(archive)
        }
    }

    private static func effectiveDomain(_ role: String) throws -> String {
        guard let domain = domains[role] else { throw corrupt() }
        #if INTEGRATION_PATH_TEST
        guard let prefix = ProcessInfo.processInfo.environment["RHYTHM_RESTORE_TEST_PREFERENCE_PREFIX"],
              !prefix.isEmpty, prefix.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
            throw failure("Missing isolated restore preference prefix")
        }
        return prefix + "." + role
        #else
        return domain
        #endif
    }

    private static func capturePreferences(jobID: String) throws -> [String: Any] {
        var captured: [String: Any] = [:]
        for role in domains.keys.sorted() {
            let value = UserDefaults.standard.persistentDomain(forName: try effectiveDomain(role))
            captured[role] = ["present": value != nil, "values": value ?? [:]]
        }
        return ["schema": 1, "jobID": jobID, "domains": captured]
    }

    private static func preferenceSnapshot(_ file: URL, jobID: String) throws -> [String: Any] {
        try requireRegular(file)
        guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), options: [], format: nil) as? [String: Any],
              value["schema"] as? Int == 1, value["jobID"] as? String == jobID,
              let entries = value["domains"] as? [String: [String: Any]], Set(entries.keys) == Set(domains.keys),
              entries.values.allSatisfy({ $0["present"] is Bool && $0["values"] is [String: Any] }) else { throw corrupt() }
        return value
    }

    private static func restorePreferences(_ snapshot: [String: Any]) throws {
        guard let entries = snapshot["domains"] as? [String: [String: Any]] else { throw corrupt() }
        for role in domains.keys.sorted() {
            let domain = try effectiveDomain(role)
            guard let entry = entries[role], let present = entry["present"] as? Bool,
                  let values = entry["values"] as? [String: Any] else { throw corrupt() }
            if present { UserDefaults.standard.setPersistentDomain(values, forName: domain) }
            else { UserDefaults.standard.removePersistentDomain(forName: domain) }
        }
        guard UserDefaults.standard.synchronize() else { throw failure("原偏好未能持久保存，恢复任务仍保留。") }
        let current = try capturePreferences(jobID: snapshot["jobID"] as? String ?? "")
        guard NSDictionary(dictionary: current).isEqual(to: snapshot) else { throw corrupt() }
    }

    private static func incomingPreferences(_ staged: URL) throws -> [String: [String: Any]] {
        let file = staged.appendingPathComponent("preferences.plist")
        try requireRegular(file)
        guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), options: [], format: nil) as? [String: [String: Any]],
              Set(domains.keys).isSubset(of: Set(value.keys)) else { throw corrupt() }
        return value
    }

    private static func applyPreferences(_ incoming: [String: [String: Any]]) throws {
        for role in domains.keys.sorted() {
            guard let value = incoming[role] else { throw corrupt() }
            UserDefaults.standard.setPersistentDomain(value, forName: try effectiveDomain(role))
        }
        guard UserDefaults.standard.synchronize() else { throw failure("恢复偏好未能持久保存，正在保留原偏好。") }
        for role in domains.keys.sorted() {
            let actual = UserDefaults.standard.persistentDomain(forName: try effectiveDomain(role))
            guard let actual, let expected = incoming[role], NSDictionary(dictionary: actual).isEqual(to: expected) else { throw corrupt() }
        }
    }

    private static func archiveCompleted(_ job: Job) throws {
        try validateJob(job)
        try requireRegular(pending)
        let saved = try JSONDecoder().decode(Job.self, from: Data(contentsOf: pending))
        guard saved.id == job.id, saved.completed, saved.outcome == job.outcome else { throw corrupt() }
        let directory = jobs.appendingPathComponent("Completed.noindex", isDirectory: true)
        try validateNoSymlinks(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = directory.appendingPathComponent(job.id + ".json")
        if try exists(archive) {
            guard try BackupIntegrity.hash(archive) == BackupIntegrity.hash(pending) else { throw corrupt() }
            try FileManager.default.removeItem(at: pending)
        } else { try FileManager.default.moveItem(at: pending, to: archive) }
        try syncDirectory(jobs); try syncDirectory(directory)
    }

    private static func save(_ job: Job) throws {
        try validateNoSymlinks(jobs)
        try writeDurable(try JSONEncoder().encode(job), to: pending)
    }
    private static func writeDurable(_ bytes: Data, to file: URL) throws {
        try validateNoSymlinks(file)
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
        try syncDirectory(file.deletingLastPathComponent())
    }
    private static func syncRestoredState(_ job: Job) throws {
        for op in job.operations {
            if try exists(op.destination) { try syncItem(op.destination) }
            if try exists(op.previous) { try syncItem(op.previous) }
            try syncDirectory(op.destination.deletingLastPathComponent())
            try syncDirectory(op.previous.deletingLastPathComponent())
        }
    }
    private static func syncItem(_ url: URL) throws {
        try validateNoSymlinks(url)
        let fm = FileManager.default
        let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        if type == .typeDirectory {
            guard let entries = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else { throw corrupt() }
            var directories = [url]
            for case let entry as URL in entries {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw corrupt() }
                if values.isDirectory == true { directories.append(entry) }
                else if values.isRegularFile == true { try syncItem(entry) }
                else { throw corrupt() }
            }
            for directory in directories.reversed() { try syncDirectory(directory) }
        } else {
            try requireRegular(url)
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw corrupt() }
            defer { _ = Darwin.close(fd) }
            guard Darwin.fsync(fd) == 0 else { throw corrupt() }
        }
    }
    private static func syncDirectory(_ directory: URL) throws {
        try validateNoSymlinks(directory)
        let fd = Darwin.open(directory.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw corrupt() }
        defer { _ = Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw corrupt() }
    }

    private static func requireCompatibleIntegration(_ staged: URL) throws {
        let incoming = staged.appendingPathComponent("AppGroupContainer/Integration/authority.json")
        let active = AppDataLocations.groupContainer?.appendingPathComponent("Integration/authority.json")
        if let active, try exists(active), try !exists(incoming) {
            throw failure("此旧备份不含迁入的健康与足迹，不能整库覆盖当前整合资料。请保留备份并离线核对。")
        }
        // Pure source recovery copies can be retired after acceptance. They
        // are excluded from restore operations whether present or absent;
        // authority lineage and the three active databases remain mandatory.
        if try exists(staged.appendingPathComponent("SharedSleep")) {
            throw failure("此备份含旧独立睡眠权威，需先离线核对迁移，不能自动写入新权威。")
        }
        // Keep the actual immutable source tree in place; only an integrated
        // backup with the same authority lineage can restore mutable children.
        if let active, try exists(active), try exists(incoming) {
            try requireRegular(active); try requireRegular(incoming)
            guard let current = try JSONSerialization.jsonObject(with: Data(contentsOf: active)) as? [String: Any],
                  let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: incoming)) as? [String: Any],
                  current["schemaVersion"] as? Int == 1, restored["schemaVersion"] as? Int == 1,
                  current["state"] as? String == "active", restored["state"] as? String == "active",
                  let transaction = current["transactionID"] as? String,
                  restored["transactionID"] as? String == transaction,
                  let currentRevisions = current["sourceRevisions"] as? [String: String],
                  restored["sourceRevisions"] as? [String: String] == currentRevisions,
                  NSDictionary(dictionary: current["modulePaths"] as? [String: String] ?? [:]).isEqual(to: restored["modulePaths"] as? [String: String] ?? [:]),
                  current["sharedSleepPath"] as? String == restored["sharedSleepPath"] as? String else { throw corrupt() }
            for relative in ["Modules/Health/health.sqlite", "Modules/Footprints/footprints.sqlite", "SharedSleep/sleep-records.sqlite"] {
                try requireRegular(incoming.deletingLastPathComponent().appendingPathComponent(relative))
            }
        }
    }

    private static func allowedGroupName(_ name: String) -> Bool {
        safeName(name) && !name.hasPrefix(".com.apple.") && !coordination.contains(name)
    }
    private static func allowedIntegrationName(_ name: String) -> Bool {
        safeName(name) && !["SourceArchives", ".migration.lock", "health-restore-in-progress.json",
                            "footprints-restore-in-progress.json"].contains(name)
    }
    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
    private static func validateStaged(_ staged: URL) throws {
        try validateDirectJobPath(staged, prefix: "")
        try requireDirectory(staged)
    }
    private static func validateDirectJobPath(_ url: URL, prefix: String) throws {
        try validateNoSymlinks(jobs); try validateNoSymlinks(url)
        guard url.isFileURL, path(url.deletingLastPathComponent()) == path(jobs) else { throw corrupt() }
        var name = url.lastPathComponent
        if name.hasSuffix(".noindex") { name = String(name.dropLast(8)) }
        guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { throw corrupt() }
    }
    private static func validateNoSymlinks(_ url: URL) throws {
        guard url.isFileURL, !url.pathComponents.contains("..") && !url.pathComponents.contains(".") else { throw corrupt() }
        var part = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            part.appendPathComponent(component)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: part.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw corrupt() }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            }
        }
    }
    private static func requireRegular(_ url: URL) throws {
        try validateNoSymlinks(url)
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isReadableFile(atPath: url.path) else { throw corrupt() }
    }
    private static func requireDirectory(_ url: URL) throws {
        try validateNoSymlinks(url)
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else { throw corrupt() }
    }
    private static func exists(_ url: URL) throws -> Bool {
        try validateNoSymlinks(url)
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return false }
    }
    private static func itemHashes(_ url: URL) throws -> [String: String] {
        try validateNoSymlinks(url)
        let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        if type == .typeDirectory { return try BackupIntegrity.manifest(url) }
        try requireRegular(url)
        return ["$file": try BackupIntegrity.hash(url)]
    }
    // Paths are validated component by component before comparison. Foundation
    // standardization can change a physical /private path as files appear or
    // move during recovery, so it must not define transaction identity.
    private static func path(_ url: URL) -> String { url.path }
    private static func plistData(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    private static func failure(_ reason: String) -> NSError {
        NSError(domain: "GQNS.Backup", code: 10, userInfo: [NSLocalizedDescriptionKey: reason])
    }
    private static func corrupt() -> CocoaError { CocoaError(.fileReadCorruptFile) }
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments; p.standardOutput = pipe
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw corrupt() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
