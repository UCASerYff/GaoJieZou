import Foundation
import CryptoKit
import Darwin

/// Streaming checksums keep large PDFs and Word attachments out of resident memory.
enum BackupIntegrity {
    struct Manifest: Codable { var appID="com.gaojiezou.rhythm"; var format=1; var version:String; var createdAt=Date(); var files:[String:String] }
    static func hash(_ file:URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:file);defer { try? handle.close() }
        var digest=SHA256()
        while let data=try handle.read(upToCount:1_048_576),!data.isEmpty { digest.update(data:data) }
        return digest.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func files(_ root:URL) throws -> [URL] {
        let root=root.resolvingSymlinksInPath()
        let fm=FileManager.default
        guard let e=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.isDirectoryKey]) else { throw CocoaError(.fileReadUnknown) }
        var result:[URL]=[]
        for case let file as URL in e {
            let v=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.isDirectoryKey])
            guard v.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            guard v.isRegularFile == true || v.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
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
    static func verify(_ originalRoot:URL) throws -> Manifest {
        let root = originalRoot.resolvingSymlinksInPath()
        let m=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:root.appendingPathComponent("gqns-manifest.json")))
        let actual=try manifest(root)
        guard m.appID == "com.gaojiezou.rhythm",m.format == 1,!m.files.isEmpty,actual==m.files else {
            let differences=Set(actual.keys).union(m.files.keys).filter { actual[$0] != m.files[$0] }.sorted().prefix(5).joined(separator:", ")
            throw NSError(domain:"GQNS.Backup",code:1,userInfo:[NSLocalizedDescriptionKey:"备份文件校验不一致："+differences])
        }
        let archivedDatabases = Set(canonicalDatabases.map { "AppGroupContainer/" + $0 })
        let authority = "AppGroupContainer/Integration/authority.json"
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(authority).path) {
            // An integrated archive is complete only with all three active
            // authorities. A self-consistent manifest must not turn a missing
            // canonical DB into a successful partial backup.
            guard m.files[authority] != nil,
                  archivedDatabases.isSubset(of: Set(m.files.keys)) else { throw CocoaError(.fileReadCorruptFile) }
            for relative in archivedDatabases {
                let type = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative).path)[.type] as? FileAttributeType
                guard type == .typeRegular else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        for file in try files(root) where archivedDatabases.contains(String(file.path.dropFirst(root.path.count + 1))) {
            guard DailyBackup.integrityCheck(file)=="ok" else { throw CocoaError(.fileReadCorruptFile) }
        }
        return m
    }
    private static let canonicalDatabases: Set<String> = [
        "Integration/Modules/Health/health.sqlite",
        "Integration/Modules/Footprints/footprints.sqlite",
        "Integration/SharedSleep/sleep-records.sqlite"
    ]
    private static let rawDirectories: Set<String> = ["SourceArchives", "SourceArchive", "ImportedSupport", "PendingRestore", "IntegratedRecovery", "Snapshots", "Backups", "AutoBackups", "ReconciliationBackups", "恢复前备份"]

    static func copySnapshot(from source:URL,to target:URL) throws {
        guard try source.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        _ = try files(source) // Reject every non-regular/symlink node before copying.
        let basePath = try physicalPath(source)
        try copyTree(source:source,to:target,basePath:basePath)
    }
    private static func copyTree(source:URL,to target:URL,basePath:String) throws {
        let fm=FileManager.default
        if rawDirectories.contains(source.lastPathComponent) || source.lastPathComponent.hasSuffix(".noindex") {
            try copyImmutableArchive(from:source,to:target)
            return
        }
        try fm.createDirectory(at:target,withIntermediateDirectories:true)
        for entry in try fm.contentsOfDirectory(at:source,includingPropertiesForKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey]) {
            let values=try entry.resourceValues(forKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
            // URL enumeration may use the /var or /tmp alias while the caller
            // supplied /private/var or /private/tmp. Classify only a physical
            // descendant of this fixed source root, never a sliced alias.
            let physical = try physicalPath(entry)
            guard physical.hasPrefix(basePath + "/") else { throw CocoaError(.fileReadCorruptFile) }
            let relative=String(physical.dropFirst(basePath.count+1))
            if relative.hasPrefix(".com.apple.") { continue }
            let dest=target.appendingPathComponent(entry.lastPathComponent)
            if values.isDirectory == true {
                try copyTree(source:entry,to:dest,basePath:basePath)
            } else if values.isRegularFile == true {
                if canonicalDatabases.contains(where:{relative == $0+"-wal" || relative == $0+"-shm" || relative == $0+"-journal"}) { continue }
                if canonicalDatabases.contains(relative) {
                    try DailyBackup.vacuumInto(source:entry,destination:dest)
                    guard DailyBackup.integrityCheck(dest)=="ok" else { throw CocoaError(.fileReadCorruptFile) }
                } else {
                    try fm.copyItem(at:entry,to:dest)
                    guard try hash(entry)==hash(dest) else { throw CocoaError(.fileReadCorruptFile) }
                }
                try copyMetadata(from:entry,to:dest)
            } else { throw CocoaError(.fileReadUnsupportedScheme) }
        }
        // Applying metadata last keeps directory mtimes after child creation.
        try copyMetadata(from:source,to:target)
    }
    private static func physicalPath(_ url:URL) throws -> String {
        guard let pointer = realpath(url.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(pointer) }
        return String(cString:pointer)
    }
    private static func copyMetadata(from source:URL,to target:URL) throws {
        let flags=copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR)
        guard Darwin.copyfile(source.path,target.path,nil,flags)==0 else { throw CocoaError(.fileWriteUnknown) }
    }
    private static func copyImmutableArchive(from source:URL,to target:URL) throws {
        let before=try manifest(source)
        let process=Process()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto")
        process.arguments=["--rsrc","--extattr","--acl",source.path,target.path]
        try process.run();process.waitUntilExit()
        guard process.terminationStatus==0,try manifest(source)==before,try manifest(target)==before else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Originals never enter restore operations; ordinary ZIP is not used to
        // reconstruct a missing immutable archive's nanosecond/ACL metadata.
    }
}
