import Foundation
import Darwin

/// Complete scoped archive; no other merged module is exported or replaced.
enum AppBackupExport {
    struct Summary { var fileCount: Int; var totalBytes: Int64; var zipBytes: Int64 }
    @discardableResult static func validateSharedSleep(_ directory: URL) throws -> Bool {
        _ = try HealthSleepRewardSync.readRewards(directory: directory)
        return true
    }
    static func export(destination: URL) throws -> Summary {
        return try RhythmIntegrationPaths.withWriterLease {
        let fm = FileManager.default
        let health = try RhythmIntegrationPaths.moduleDirectory("health")
        let sleep = try RhythmIntegrationPaths.sharedSleepDirectory()
        let archive = try AppDataLocations.sourceArchive()
        try HealthArchiveValidation.validate(directory: health)
        try validateSharedSleep(sleep)
        // This is a temporary source recovery copy, never the active health
        // store. Root may remove it after acceptance under the retirement policy.
        let hasSourceArchive = fm.fileExists(atPath: archive.path)
        if hasSourceArchive {
            try RhythmIntegrationPaths.requireExisting(archive, directory: true)
        }
        #if INTEGRATION_PATH_TEST
        print("stage: health export validated")
        #endif
        let work = fm.temporaryDirectory.appendingPathComponent("rhythm-health-export-\(UUID().uuidString).noindex", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let payload = work.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        #if INTEGRATION_PATH_TEST
        print("stage: health export snapshots")
        #endif
        for (source, name) in [(health, "Health"), (sleep, "SharedSleep")] {
            try BackupIntegrity.copySnapshot(from: source, to: payload.appendingPathComponent(name, isDirectory: true))
        }
        #if INTEGRATION_PATH_TEST
        print("stage: health export raw archive")
        #endif
        if hasSourceArchive {
            try copyRawArchive(archive, to: payload.appendingPathComponent("SourceArchive", isDirectory: true))
        }
        #if INTEGRATION_PATH_TEST
        print("stage: health export preferences")
        #endif
        let preferences = ["module": UserDefaults.standard.persistentDomain(forName: RestorePreferences.moduleDomain) ?? [:]]
        try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0).write(to: payload.appendingPathComponent("preferences.plist"), options: .atomic)
        #if INTEGRATION_PATH_TEST
        print("stage: health export hash manifest")
        #endif
        let hashes = try BackupIntegrity.manifest(payload)
        let manifest = BackupIntegrity.Manifest(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.10", files: hashes)
        try JSONEncoder().encode(manifest).write(to: payload.appendingPathComponent("gqns-manifest.json"), options: .atomic)
        let zip = work.appendingPathComponent("backup.zip")
        #if INTEGRATION_PATH_TEST
        print("stage: health export ZIP create")
        #endif
        _ = try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", payload.path, zip.path])
        let verify = work.appendingPathComponent("verify", isDirectory: true)
        _ = try run("/usr/bin/ditto", ["-x", "-k", zip.path, verify.path])
        #if INTEGRATION_PATH_TEST
        print("stage: health export ZIP verify")
        #endif
        _ = try BackupIntegrity.verify(verify)
        let sibling = destination.deletingLastPathComponent().appendingPathComponent(".rhythm-health-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: sibling) }
        try fm.copyItem(at: zip, to: sibling)
        guard try BackupIntegrity.hash(zip) == BackupIntegrity.hash(sibling) else { throw CocoaError(.fileReadCorruptFile) }
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: sibling) }
        else { try fm.moveItem(at: sibling, to: destination) }
        let bytes = try BackupIntegrity.files(payload).reduce(Int64(0)) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        return Summary(fileCount: hashes.count, totalBytes: bytes, zipBytes: Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
    
        }
    }
    private static func copyRawArchive(_ source: URL, to target: URL) throws {
        func physical(_ url: URL) throws -> String {
            guard let pointer = realpath(url.path, nil) else { throw CocoaError(.fileReadUnknown) }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        func relative(_ url: URL, rootPath: String) throws -> String {
            let path = try physical(url)
            guard path.hasPrefix(rootPath + "/") else { throw CocoaError(.fileReadCorruptFile) }
            return String(path.dropFirst(rootPath.count + 1))
        }
        func index(_ root: URL) throws -> [String: String] {
            let rootPath = try physical(root)
            var hashes: [String: String] = [:]
            for file in try BackupIntegrity.files(root) {
                hashes[try relative(file, rootPath: rootPath)] = try BackupIntegrity.hash(file)
            }
            return hashes
        }
        func directories(_ root: URL) throws -> Set<String> {
            let rootPath = try physical(root)
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { throw CocoaError(.fileReadUnknown) }
            var result = Set<String>()
            for case let entry as URL in entries {
                let value = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard value.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
                if value.isDirectory == true { result.insert(try relative(entry, rootPath: rootPath)) }
            }
            return result
        }
        let before = try index(source), beforeDirectories = try directories(source)
        _ = try run("/usr/bin/ditto", ["--rsrc", "--extattr", "--acl", source.path, target.path])
        let afterSource = try index(source), targetIndex = try index(target)
        let afterDirectories = try directories(source), targetDirectories = try directories(target)
        #if INTEGRATION_PATH_TEST
        print("stage: raw source/copy file maps equal \(before == afterSource)/\(before == targetIndex), empty directory maps equal \(beforeDirectories == afterDirectories)/\(beforeDirectories == targetDirectories)")
        #endif
        guard before == afterSource, before == targetIndex, beforeDirectories == afterDirectories, beforeDirectories == targetDirectories else { throw CocoaError(.fileReadCorruptFile) }
    }
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments; p.standardOutput = pipe; p.standardError = pipe
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
