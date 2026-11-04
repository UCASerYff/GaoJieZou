import AppKit
import Foundation

/// Module-scoped complete restore. Source-app pending jobs are never executed.
/// Staging and recovery objects are under Rhythm support, in .noindex containers.
enum AppBackupRestore {
    struct Job: Codable {
        var format = "Rhythm.Footprints.Restore"
        var schema = 1
        var staged: URL
        var prepared: URL
        var safety: URL
        var applying = false
        var hadPrevious = true
        var previousPreferences: Data? = nil
        var authorityRoot: URL
        var authorityTransactionID: String
        var authoritySHA256: String
        var preparedFiles: [String: String]
        var phase = "prepared"
    }

    private static func jobsDirectory() throws -> URL {
        #if INTEGRATION_PATH_TEST
        let support = try RhythmIntegrationPaths.groupDirectory().appendingPathComponent("TestApplicationSupport", isDirectory: true)
        #else
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AppFailure("无法定位搞节奏的恢复目录。")
        }
        #endif
        return support.appendingPathComponent("GaoSeries/Rhythm/IntegratedRecovery/Footprints", isDirectory: true)
    }
    private static func pendingURL() throws -> URL { try jobsDirectory().appendingPathComponent("pending.json") }
    static func hasPending() throws -> Bool { FileManager.default.fileExists(atPath: try pendingURL().path) }

    static func prepare(_ archive: URL) throws -> (URL, BackupIntegrity.Manifest) {
        _ = try FootprintsIntegratedStorage.dataDirectory()
        let fm = FileManager.default
        let jobs = try jobsDirectory()
        try fm.createDirectory(at: jobs, withIntermediateDirectories: true)
        let root = jobs.appendingPathComponent(UUID().uuidString + ".noindex", isDirectory: true)
        let payload = root.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        do {
            let attributes = try run("/usr/bin/zipinfo", ["-l", archive.path])
            guard !attributes.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else { throw CocoaError(.fileReadCorruptFile) }
            let listing = try run("/usr/bin/unzip", ["-Z1", archive.path])
            guard listing.split(separator: "\n").allSatisfy({ line in
                let path = String(line)
                return !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
            }) else { throw CocoaError(.fileReadCorruptFile) }
            _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, payload.path])
            let manifest = try validatePayload(payload)
            return (payload, manifest)
        } catch { try? fm.removeItem(at: root); throw error }
    }

    static func schedule(_ staged: URL) throws {
        try RhythmIntegrationPaths.withWriterLease { try scheduleUnderLease(staged) }
    }
    private static func scheduleUnderLease(_ staged: URL) throws {
        let fm = FileManager.default
        let pending = try pendingURL()
        guard !fm.fileExists(atPath: pending.path) else { throw AppFailure("已有未完成的足迹恢复任务，未覆盖。") }
        try requireStagedPath(staged)
        _ = try validatePayload(staged)
        let root = staged.deletingLastPathComponent()
        let prepared = root.appendingPathComponent("PreparedModule", isDirectory: true)
        guard !fm.fileExists(atPath: prepared.path) else { throw AppFailure("恢复暂存已经存在，请重新选择备份。") }
        try fm.copyItem(at: staged.appendingPathComponent("ApplicationSupport-Footprints"), to: prepared)
        do {
            // Both legacy full archives and new module archives are accepted.
            // The group payload replaces only this disposable prepared copy.
            let widget = prepared.appendingPathComponent("WidgetData", isDirectory: true)
            if fm.fileExists(atPath: widget.path) { try fm.removeItem(at: widget) }
            try fm.copyItem(at: staged.appendingPathComponent("AppGroupContainer"), to: widget)
            // Activation provenance is not rolled back by a user data restore.
            let current = try FootprintsIntegratedStorage.dataDirectory().appendingPathComponent("Preferences.plist")
            let provenance = prepared.appendingPathComponent("Preferences.plist")
            if fm.fileExists(atPath: provenance.path) {
                let retained = prepared.appendingPathComponent("RestoredArchiveMetadata", isDirectory: true)
                try fm.createDirectory(at: retained, withIntermediateDirectories: true)
                try fm.moveItem(at: provenance, to: retained.appendingPathComponent(UUID().uuidString + "-Preferences.plist"))
            }
            try fm.copyItem(at: current, to: provenance)
            let authority = try RhythmIntegrationPaths.authority()
            let job = Job(staged: staged, prepared: prepared,
                          safety: try jobsDirectory().appendingPathComponent("恢复前原始数据-" + UUID().uuidString + ".noindex", isDirectory: true),
                          authorityRoot: authority.root, authorityTransactionID: authority.transactionID,
                          authoritySHA256: digest(try Data(contentsOf: authority.root.appendingPathComponent("authority.json"))),
                          preparedFiles: try BackupIntegrity.manifest(prepared))
            try JSONEncoder().encode(job).write(to: pending, options: .atomic)
        } catch { try? fm.removeItem(at: prepared); throw error }
    }

    @MainActor static func applyPending() throws {
        let fm = FileManager.default
        let pending = try pendingURL()
        guard fm.fileExists(atPath: pending.path) else { return }
        guard !FootprintsRuntime.hasOpenedStore else { throw AppFailure("足迹恢复已安排，请正常退出并重新打开搞节奏后完成。") }
        // The exclusive helper accepts only our own existing maintenance marker.
        // On failure both that marker and this pending job must remain durable.
        try RhythmIntegrationPaths.withMaintenanceLease(owner: "footprints") {
            var job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: pending))
            guard job.format == "Rhythm.Footprints.Restore", job.schema == 1 else { throw AppFailure("不支持的足迹恢复任务，原资料保持不变。") }
            let authority = try RhythmIntegrationPaths.authority(allowMaintenanceOwner: "footprints")
            guard authority.root.path == job.authorityRoot.path,
                  authority.transactionID == job.authorityTransactionID,
                  digest(try Data(contentsOf: authority.root.appendingPathComponent("authority.json"))) == job.authoritySHA256 else {
                throw AppFailure("足迹恢复绑定的切换凭据已变化，未写入另一批资料。")
            }
            try requireStagedPath(job.staged)
            let jobRoot = job.staged.deletingLastPathComponent()
            #if INTEGRATION_PATH_TEST
            let pathChecks: [String: Any] = [
                "phase": job.phase,
                "preparedExists": fm.fileExists(atPath: job.prepared.path),
                "oldPreparedURLComparison": job.prepared.standardizedFileURL == jobRoot.appendingPathComponent("PreparedModule").standardizedFileURL,
                "prepared": job.prepared.absoluteString,
                "preparedStandardized": job.prepared.standardizedFileURL.absoluteString,
                "expectedPrepared": jobRoot.appendingPathComponent("PreparedModule").absoluteString,
                "expectedPreparedStandardized": jobRoot.appendingPathComponent("PreparedModule").standardizedFileURL.absoluteString,
                "safetyParent": job.safety.deletingLastPathComponent().absoluteString,
                "safetyParentStandardized": job.safety.deletingLastPathComponent().standardizedFileURL.absoluteString,
                "jobs": try jobsDirectory().absoluteString,
                "jobsStandardized": try jobsDirectory().standardizedFileURL.absoluteString,
                "safetyName": job.safety.lastPathComponent,
                "safetyExtension": job.safety.pathExtension
            ]
            try FileHandle.standardError.write(contentsOf: Data(("FOOTPRINTS_RESTORE_PATHS " + String(decoding: try JSONSerialization.data(withJSONObject: pathChecks, options: [.sortedKeys]), as: UTF8.self) + "\n").utf8))
            #endif
            // A completed job has already moved PreparedModule into its target.
            // URL equality would then compare its persisted directory hint with
            // an inferred non-directory URL. Identity is the validated path,
            // independent of whether that directory currently exists.
            guard job.prepared.path == jobRoot.appendingPathComponent("PreparedModule").path,
                  job.safety.deletingLastPathComponent().path == (try jobsDirectory()).path,
                  job.safety.lastPathComponent.hasPrefix("恢复前原始数据-"), job.safety.pathExtension == "noindex" else {
                throw AppFailure("足迹恢复路径不匹配，未执行旧的绝对路径。")
            }
            for directory in [job.prepared, job.safety] where fm.fileExists(atPath: directory.path) {
                try RhythmIntegrationPaths.requireExisting(directory, directory: true)
            }
            // Do not call moduleDirectory/withWriterLease under the EX lease.
            let target = authority.root.appendingPathComponent("Modules/Footprints", isDirectory: true)
            let previous = job.safety.appendingPathComponent("PreviousModule", isDirectory: true)
            if job.phase == "completed" || job.phase == "recovered" {
                // The previous process may have committed the job but died before
                // the helper cleared its marker or this method archived pending.
                try validateExistingLibrary(target)
                return
            }
            if job.applying || job.phase == "rolledBack" {
                if job.phase != "rolledBack" {
                    try rollback(target: target, previous: previous, hadPrevious: job.hadPrevious)
                    try restorePreviousPreferences(job.previousPreferences)
                    job.phase = "rolledBack"
                    try JSONEncoder().encode(job).write(to: pending, options: .atomic)
                }
                try validateExistingLibrary(target)
                try writeRecoveryReceipt(job: job, result: "recovered_original_after_interruption")
                job.phase = "recovered"; job.applying = false
                try JSONEncoder().encode(job).write(to: pending, options: .atomic)
                return
            }
            _ = try validatePayload(job.staged)
            guard try BackupIntegrity.manifest(job.prepared) == job.preparedFiles else { throw AppFailure("恢复暂存内容已变化，未替换原资料。") }
            try validateExistingLibrary(job.prepared)
            let domains = try FootprintsPreferences.validateRestoreDomains(Data(contentsOf: job.staged.appendingPathComponent("preferences.plist")))
            guard !fm.fileExists(atPath: job.safety.path) else { throw AppFailure("恢复安全目录已存在，未覆盖。") }
            try fm.createDirectory(at: job.safety, withIntermediateDirectories: true)
            job.hadPrevious = fm.fileExists(atPath: target.path)
            if let domain = FootprintsBundle.defaults.persistentDomain(forName: FootprintsPreferences.suiteName) {
                job.previousPreferences = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
            }
            job.applying = true
            try JSONEncoder().encode(job).write(to: pending, options: .atomic)
            do {
                if job.hadPrevious { try fm.moveItem(at: target, to: previous) }
                try fm.moveItem(at: job.prepared, to: target)
                try validateExistingLibrary(target)
                try FootprintsPreferences.restoreOwnValues(standard: domains["standard"]!, module: domains["module"]!)
                try writeRecoveryReceipt(job: job, result: "applied")
                job.phase = "completed"; job.applying = false
                try JSONEncoder().encode(job).write(to: pending, options: .atomic)
            } catch {
                try rollback(target: target, previous: previous, hadPrevious: job.hadPrevious)
                try restorePreviousPreferences(job.previousPreferences)
                job.phase = "rolledBack"
                try JSONEncoder().encode(job).write(to: pending, options: .atomic)
                throw error
            }
        }
        // Only after the common helper has successfully removed its marker may
        // pending leave its well-known location. A crash before this move leaves
        // a durable completed phase, never an orphan maintenance marker.
        let finished = try JSONDecoder().decode(Job.self, from: Data(contentsOf: pending))
        guard finished.phase == "completed" || finished.phase == "recovered" else { throw AppFailure("恢复尚未安全完成，pending保持原位。") }
        let history = try jobsDirectory().appendingPathComponent("Completed.noindex", isDirectory: true)
        try fm.createDirectory(at: history, withIntermediateDirectories: true)
        try fm.moveItem(at: pending, to: history.appendingPathComponent(UUID().uuidString + "-" + finished.phase + ".json"))
    }

    static func validateExistingLibrary(_ root: URL) throws {
        guard let geographyURL = FootprintsBundle.bundle.url(forResource: "Geography", withExtension: "json") else { throw AppFailure("足迹离线资源缺失。") }
        let geography = try JSONDecoder().decode(Geography.self, from: Data(contentsOf: geographyURL))
        let repository = try Repository(root: root, readOnly: true)
        let journal = try repository.load()
        try repository.validate(journal, geography: geography)
        for attachment in journal.attachments {
            let bytes = try Data(contentsOf: repository.photoURL(attachment))
            guard bytes.count == attachment.size, digest(bytes) == attachment.sha256 else { throw AppFailure("足迹照片副本缺失或摘要不符。") }
        }
    }

    private static func writeRecoveryReceipt(job: Job, result: String) throws {
        let receipt: [String: Any] = ["schema": 1, "module": "footprints", "result": result,
                                      "transactionID": job.authorityTransactionID,
                                      "at": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            .write(to: job.safety.appendingPathComponent("restore-result.json"), options: .atomic)
    }

    private static func validatePayload(_ root: URL) throws -> BackupIntegrity.Manifest {
        let fm = FileManager.default
        let manifest = try BackupIntegrity.verify(root)
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.10"
        guard manifest.version.compare(current, options: .numeric) != .orderedDescending,
              fm.fileExists(atPath: root.appendingPathComponent("AppGroupContainer").path),
              let geographyURL = FootprintsBundle.bundle.url(forResource: "Geography", withExtension: "json") else {
            throw AppFailure("完整足迹备份版本或目录不兼容。")
        }
        let geography = try JSONDecoder().decode(Geography.self, from: Data(contentsOf: geographyURL))
        let repository = try Repository(root: root.appendingPathComponent("ApplicationSupport-Footprints"), readOnly: true)
        let journal = try repository.load()
        try repository.validate(journal, geography: geography)
        for attachment in journal.attachments {
            let bytes = try Data(contentsOf: repository.photoURL(attachment))
            guard bytes.count == attachment.size, digest(bytes) == attachment.sha256 else { throw AppFailure("完整足迹备份的照片缺失或摘要不符。") }
        }
        _ = try FootprintsPreferences.validateRestoreDomains(Data(contentsOf: root.appendingPathComponent("preferences.plist")))
        return manifest
    }

    private static func requireStagedPath(_ staged: URL) throws {
        let jobs = try jobsDirectory()
        let parent = staged.deletingLastPathComponent()
        try RhythmIntegrationPaths.requireExisting(staged, directory: true)
        guard staged.lastPathComponent == "Archive", parent.pathExtension == "noindex",
              UUID(uuidString: parent.deletingPathExtension().lastPathComponent) != nil,
              parent.deletingLastPathComponent().path == jobs.path else {
            throw AppFailure("足迹恢复暂存路径无效。")
        }
    }

    private static func restorePreviousPreferences(_ bytes: Data?) throws {
        if let bytes {
            guard let domain = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any] else {
                throw AppFailure("恢复前偏好收据不可读，未把它当作空白覆盖。")
            }
            FootprintsBundle.defaults.setPersistentDomain(domain, forName: FootprintsPreferences.suiteName)
        } else {
            FootprintsBundle.defaults.removePersistentDomain(forName: FootprintsPreferences.suiteName)
        }
    }

    private static func rollback(target: URL, previous: URL, hadPrevious: Bool) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: previous.path) {
            if fm.fileExists(atPath: target.path) {
                try fm.moveItem(at: target, to: previous.deletingLastPathComponent().appendingPathComponent("InterruptedModule-" + UUID().uuidString + ".noindex", isDirectory: true))
            }
            try fm.moveItem(at: previous, to: target)
        } else if !hadPrevious, fm.fileExists(atPath: target.path) {
            try fm.moveItem(at: target, to: previous.deletingLastPathComponent().appendingPathComponent("InterruptedModule-" + UUID().uuidString + ".noindex", isDirectory: true))
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.standardOutput = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
