import Foundation
import Darwin

/// Shared by the host, each embedded native framework and the new widgets.
/// The migration tool alone creates authority.json as its final atomic step.
/// No initializer in this resolver creates a directory, database or default state.
enum RhythmIntegrationPaths {
    static let groupID = "5G96498KGJ.com.gaojiezou.rhythm"
    private static let paths = ["health": "Modules/Health", "footprints": "Modules/Footprints"]

    struct Authority {
        let root: URL
        let transactionID: String
        let sourceRevisions: [String: String]
    }

    static var isActive: Bool { (try? authority()) != nil }

    static func groupDirectory() throws -> URL {
        let group: URL
        #if INTEGRATION_PATH_TEST
        guard let value = ProcessInfo.processInfo.environment["RHYTHM_INTEGRATION_TEST_GROUP"], !value.isEmpty else {
            throw failure("Missing isolated integration test group")
        }
        group = URL(fileURLWithPath: value, isDirectory: true)
        #else
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw failure("无法读取搞节奏共享容器；原数据未改动。")
        }
        group = container
        #endif
        try requireExisting(group, directory: true)
        return group
    }

    static func authority(allowMaintenanceOwner: String? = nil) throws -> Authority {
        let group = try groupDirectory()
        let marker = group.appendingPathComponent(".rhythm-integration-maintenance.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            try requireExisting(marker, directory: false)
            guard let allowed = allowMaintenanceOwner,
                  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any],
                  value["owner"] as? String == allowed else {
                throw failure("资料正在恢复或恢复尚未完成，已暂停整合读写。")
            }
        }
        let root = group.appendingPathComponent("Integration", isDirectory: true)
        let healthMarker = root.appendingPathComponent("health-restore-in-progress.json")
        if FileManager.default.fileExists(atPath: healthMarker.path), allowMaintenanceOwner != "health" {
            throw failure("健康资料正在恢复，已暂停整合读写。")
        }
        try requireExisting(root, directory: true)
        let file = root.appendingPathComponent("authority.json")
        try requireExisting(file, directory: false)
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 1_048_576,
              let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let version = value["schemaVersion"] as? Int, version == 1,
              value["state"] as? String == "active",
              let transaction = value["transactionID"] as? String,
              !transaction.isEmpty, transaction.count <= 128,
              transaction.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }),
              let modules = value["modulePaths"] as? [String: String], modules == paths,
              value["sharedSleepPath"] as? String == "SharedSleep",
              let revisions = value["sourceRevisions"] as? [String: String], !revisions.isEmpty,
              revisions.values.allSatisfy({ $0.count == 64 && $0.allSatisfy({ "0123456789abcdef".contains($0) }) }) else {
            throw failure("整合尚未完成切换，或权威凭据损坏。不会新建空白资料库。")
        }
        return Authority(root: root, transactionID: transaction, sourceRevisions: revisions)
    }

    static func moduleDirectory(_ module: String) throws -> URL {
        guard let relative = paths[module] else { throw failure("Unknown integrated module") }
        let active = try authority()
        let directory = active.root.appendingPathComponent(relative, isDirectory: true)
        try requireExisting(directory, directory: true)
        return directory
    }

    static func sharedSleepDirectory() throws -> URL {
        let directory = try authority().root.appendingPathComponent("SharedSleep", isDirectory: true)
        try requireExisting(directory, directory: true)
        try requireExisting(directory.appendingPathComponent("sleep-records.sqlite"), directory: false)
        return directory
    }

    /// A persistent group-root lock survives atomic replacement of module trees.
    /// All migrated DB/publisher writers hold SH for the entire operation; restore
    /// holds EX until its verified commit or rollback. No caller acquires a lease
    /// by merely constructing a View or reading a last-valid widget snapshot.
    static func withWriterLease<T>(_ body: () throws -> T) throws -> T {
        try withFileLock(exclusive: false) {
            _ = try authority()
            return try body()
        }
    }

    static func withMaintenanceLease<T>(owner: String, _ body: () throws -> T) throws -> T {
        guard ["host", "health", "footprints"].contains(owner) else { throw failure("Unknown recovery owner") }
        return try withFileLock(exclusive: true) {
            let marker = try groupDirectory().appendingPathComponent(".rhythm-integration-maintenance.json")
            if FileManager.default.fileExists(atPath: marker.path) {
                try requireExisting(marker, directory: false)
                guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any],
                      value["owner"] as? String == owner else { throw failure("另一模块的恢复尚未完成。") }
            } else {
                let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "owner": owner,
                    "startedAt": ISO8601DateFormatter().string(from: Date())])
                try bytes.write(to: marker, options: .atomic)
                let handle = try FileHandle(forUpdating: marker)
                try handle.synchronize(); try handle.close()
                try syncDirectory(marker.deletingLastPathComponent())
            }
            // A thrown body deliberately retains the marker and the caller's
            // pending job. The next launch resumes before any store is opened.
            let value = try body()
            try FileManager.default.removeItem(at: marker)
            try syncDirectory(marker.deletingLastPathComponent())
            return value
        }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Cannot open integration coordination directory") }
        defer { _ = Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw failure("Cannot synchronize integration coordination directory") }
    }

    private static func withFileLock<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        let lock = try groupDirectory().appendingPathComponent(".rhythm-integration-writers.lock")
        let fd = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw failure("Cannot open integration writer lock") }
        defer { _ = Darwin.close(fd) }
        var details = stat()
        guard fstat(fd, &details) == 0, details.st_mode & S_IFMT == S_IFREG,
              details.st_uid == getuid() else { throw failure("Invalid integration writer lock") }
        // Bound contention: do not hang a widget or first launch indefinitely.
        let deadline = Date().addingTimeInterval(5)
        while flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN, Date() < deadline else {
                throw failure("整合资料仍在写入，请稍后重试。")
            }
            usleep(10_000)
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    static func requireExisting(_ url: URL, directory: Bool) throws {
        // Inspect every component: resolving a final symlink alone is insufficient.
        var component = URL(fileURLWithPath: "/", isDirectory: true)
        let fm = FileManager.default
        // Foundation maps an existing /private/tmp path back to the /tmp
        // alias during standardization. Walk the supplied physical components
        // instead, so aliases are still rejected when actually supplied.
        guard !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else {
            throw failure("Invalid relative integration path")
        }
        for part in url.pathComponents.dropFirst() {
            component.appendPathComponent(part)
            let values = try fm.attributesOfItem(atPath: component.path)
            guard values[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw failure("整合路径包含符号链接，已停止读写。")
            }
        }
        let values = try fm.attributesOfItem(atPath: url.path)
        let type = values[.type] as? FileAttributeType
        guard type == (directory ? .typeDirectory : .typeRegular), fm.isReadableFile(atPath: url.path),
              directory || ((values[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
            throw failure("整合资料缺失、不可读或类型不符；不会用空白数据替代。")
        }
    }

    private static func failure(_ reason: String) -> NSError {
        NSError(domain: "com.gaojiezou.rhythm.integration", code: 1,
                userInfo: [NSLocalizedDescriptionKey: reason])
    }
}
