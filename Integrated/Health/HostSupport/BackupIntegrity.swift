import Foundation
import CryptoKit

/// Streaming checksums keep large PDFs and Word attachments out of resident memory.
enum BackupIntegrity {
    struct Manifest: Codable { var appID="com.gaojiezou.rhythm.health"; var format=2; var version:String; var createdAt=Date(); var files:[String:String] }
    static func hash(_ file:URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:file);defer { try? handle.close() }
        var digest=SHA256()
        while let data=try handle.read(upToCount:1_048_576),!data.isEmpty { digest.update(data:data) }
        return digest.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func files(_ root:URL) throws -> [URL] {
        guard try root.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
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
        guard ((m.appID == "com.gaojiezou.rhythm.health" && m.format == 2) || (m.appID == "com.gaoseries.GaoJianKang" && m.format == 1)),!m.files.isEmpty,actual==m.files else {
            let differences=Set(actual.keys).union(m.files.keys).filter { actual[$0] != m.files[$0] }.sorted().prefix(5).joined(separator:", ")
            throw NSError(domain:"GQNS.Backup",code:1,userInfo:[NSLocalizedDescriptionKey:"备份文件校验不一致："+differences])
        }
        let databases = m.format == 2
            ? ["Health/health.sqlite", "SharedSleep/sleep-records.sqlite"]
            : ["AppGroupContainer/Health/health.sqlite", "AppGroupContainer/SharedSleep/sleep-records.sqlite"]
        for relative in databases where FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) {
            guard DailyBackup.integrityCheck(root.appendingPathComponent(relative)) == "ok" else { throw CocoaError(.fileReadCorruptFile) }
        }
        // Other archived .sqlite files may be intentionally retained failed/recovery
        // objects. Their bytes are verified, not reinterpreted or rewritten.
        return m
    }
    static func copySnapshot(from source:URL,to target:URL, consistentSQLite: Set<String> = ["health.sqlite", "sleep-records.sqlite"]) throws {
        let source=source.resolvingSymlinksInPath()
        let fm=FileManager.default
        try fm.createDirectory(at:target,withIntermediateDirectories:true)
        // Preserve empty directories and reject directory symlinks as well as file symlinks.
        if let entries = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for case let entry as URL in entries {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
                if values.isDirectory == true {
                    try fm.createDirectory(at: target.appendingPathComponent(String(entry.path.dropFirst(source.path.count + 1)), isDirectory: true), withIntermediateDirectories: true)
                }
            }
        }
        for file in try files(source) {
            let relative=String(file.path.dropFirst(source.path.count+1))
            // Container metadata belongs to macOS; journals are folded into SQLite snapshots.
            if relative.hasPrefix(".com.apple.") || consistentSQLite.contains(where: { relative == $0 + "-wal" || relative == $0 + "-shm" }) { continue }
            let dest=target.appendingPathComponent(relative)
            try fm.createDirectory(at:dest.deletingLastPathComponent(),withIntermediateDirectories:true)
            if consistentSQLite.contains(relative) {
                try DailyBackup.vacuumInto(source:file,destination:dest)
                guard DailyBackup.integrityCheck(dest)=="ok" else { throw CocoaError(.fileReadCorruptFile) }
            } else {
                // Atomic writers are safe; concurrent non-atomic attachment changes are detected.
                try fm.copyItem(at:file,to:dest)
                guard try hash(file)==hash(dest) else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
    }
}
