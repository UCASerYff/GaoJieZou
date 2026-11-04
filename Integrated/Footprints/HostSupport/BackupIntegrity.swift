import Foundation
import CryptoKit
import Darwin

/// Streaming checksums keep large PDFs and Word attachments out of resident memory.
enum BackupIntegrity {
    struct Manifest: Codable { var appID="com.gaojiezou.rhythm.footprints"; var format=1; var version:String; var createdAt=Date(); var files:[String:String] }
    static func hash(_ file:URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:file);defer { try? handle.close() }
        var digest=SHA256()
        while let data=try handle.read(upToCount:1_048_576),!data.isEmpty { digest.update(data:data) }
        return digest.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func files(_ root:URL) throws -> [URL] {
        let root=root.resolvingSymlinksInPath()
        let fm=FileManager.default
        guard let e=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else { throw CocoaError(.fileReadUnknown) }
        var result:[URL]=[]
        for case let file as URL in e {
            let v=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard v.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            if v.isRegularFile == true { result.append(file.resolvingSymlinksInPath()) }
        }
        return result
    }
    static func manifest(_ root:URL) throws -> [String:String] {
        let root=root.resolvingSymlinksInPath()
        var result:[String:String]=[:]
        for file in try files(root) where file.path != root.appendingPathComponent("gqns-manifest.json").path {
            result[String(file.path.dropFirst(root.path.count+1))]=try hash(file)
        }
        return result
    }
    static func verify(_ root:URL) throws -> Manifest {
        let m=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:root.appendingPathComponent("gqns-manifest.json")))
        let actual=try manifest(root)
        guard ["com.gaojiezou.rhythm.footprints", "com.gaoseries.GaoZuJi"].contains(m.appID),m.format == 1,!m.files.isEmpty,actual==m.files else {
            let differences=Set(actual.keys).union(m.files.keys).filter { actual[$0] != m.files[$0] }.sorted().prefix(5).joined(separator:", ")
            throw NSError(domain:"GQNS.Backup",code:1,userInfo:[NSLocalizedDescriptionKey:"备份文件校验不一致："+differences])
        }
        // Only this precise live database belongs to the archive protocol.
        // A .sqlite in Snapshots/recovery/old archives is immutable byte evidence.
        let canonical = root.appendingPathComponent("ApplicationSupport-Footprints/footprints.sqlite")
        guard FileManager.default.fileExists(atPath: canonical.path), DailyBackup.integrityCheck(canonical) == "ok" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return m
    }
    static func copySnapshot(from source: URL, to target: URL, canonicalDatabase: String? = nil) throws {
        let source = source.resolvingSymlinksInPath()
        let fm = FileManager.default
        guard canonicalDatabase == nil || canonicalDatabase == "footprints.sqlite" else { throw CocoaError(.fileReadCorruptFile) }
        let canonicalNames = Set(canonicalDatabase.map { [$0, $0 + "-wal", $0 + "-shm"] } ?? [])
        func rawManifest(_ root: URL) throws -> [String: String] {
            var values: [String: String] = [:]
            for file in try files(root) {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                if !canonicalNames.contains(relative) { values[relative] = try hash(file) }
            }
            return values
        }
        let before = try rawManifest(source)
        // ditto preserves empty directories, xattrs, resource forks and ACLs.
        // No recursive filename-extension rule may reinterpret old archives.
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["--rsrc", "--extattr", "--acl", source.path, target.path]
        process.standardError = errors
        try process.run(); let errorData = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Rhythm.Footprints.Backup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(data: errorData, encoding: .utf8) ?? "Raw copy failed"])
        }
        if let canonicalDatabase {
            let origin = source.appendingPathComponent(canonicalDatabase)
            let destination = target.appendingPathComponent(canonicalDatabase)
            for name in canonicalNames {
                let copied = target.appendingPathComponent(name)
                if fm.fileExists(atPath: copied.path) { try fm.removeItem(at: copied) }
            }
            try DailyBackup.vacuumInto(source: origin, destination: destination)
            guard DailyBackup.integrityCheck(destination) == "ok" else { throw CocoaError(.fileReadCorruptFile) }
            guard Darwin.copyfile(origin.path, destination.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
            }
        }
        let after = try rawManifest(source)
        let copied = try rawManifest(target.resolvingSymlinksInPath())
        guard before == after, after == copied else { throw CocoaError(.fileReadCorruptFile) }
    }
}
