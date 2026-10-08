import Foundation
import OSLog

/// Local lifecycle diagnostics contain event identifiers only, never record
/// titles, URLs, document paths, credentials, or other business data.
@MainActor
final class AppLifecycleLog {
    private struct Session: Codable {
        let id: String
        let pid: Int32
        let startedAt: String
    }

    private struct Entry: Encodable {
        let timestamp: String
        let event: String
        let session: String
        let pid: Int32
    }

    private let directory: URL
    private let maximumFileBytes: Int
    private let archiveCount: Int
    private let sessionID = UUID().uuidString
    private let formatter = ISO8601DateFormatter()
    private let encoder = JSONEncoder()
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.gaojiezou.rhythm", category: "lifecycle")
    private var launched = false
    private var terminated = false
    private var reportedWriteFailure = false

    private(set) var previousSessionWasUnclean = false

    init(directory: URL? = nil, maximumFileBytes: Int = 128 * 1024, archiveCount: Int = 3) {
        if let directory {
            self.directory = directory
        } else if let dataPath = ProcessInfo.processInfo.environment["GAOJIEZOU_DATA_DIR"], !dataPath.isEmpty {
            self.directory = URL(fileURLWithPath: dataPath, isDirectory: true)
                .appendingPathComponent("Lifecycle", isDirectory: true)
        } else {
            self.directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/GaoJieZou", isDirectory: true)
        }
        self.maximumFileBytes = max(512, maximumFileBytes)
        self.archiveCount = min(5, max(0, archiveCount))
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.outputFormatting = [.sortedKeys]
    }

    func launch() {
        guard !launched else { return }
        launched = true
        do {
            try ensureDirectory()
            // A marker survives crashes/force quits. Its absence after terminate
            // distinguishes an orderly quit from an interrupted prior session.
            // This is diagnostic evidence, not proof of a particular crash cause.
            previousSessionWasUnclean = fileManager.fileExists(atPath: markerURL.path)
            if previousSessionWasUnclean { append("previous_session_unclean") }
            let marker = Session(id: sessionID, pid: ProcessInfo.processInfo.processIdentifier,
                                 startedAt: timestamp())
            try encoder.encode(marker).write(to: markerURL, options: .atomic)
        } catch {
            reportFailure()
        }
        append("launch")
    }

    /// Accept machine-readable event names only. Do not pass user text here.
    func record(_ event: String) {
        guard !terminated else { return }
        guard !event.isEmpty, event.utf8.count <= 96,
              event.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) ||
                  (48...57).contains(byte) || byte == 46 || byte == 95 || byte == 45
              }) else {
            append("invalid_event_rejected")
            return
        }
        append(event)
    }

    func terminate() {
        guard launched, !terminated else { return }
        append("terminate_clean")
        terminated = true
        do {
            guard fileManager.fileExists(atPath: markerURL.path) else { return }
            let marker = try JSONDecoder().decode(Session.self, from: Data(contentsOf: markerURL))
            // A different instance may have started during shutdown. Never
            // remove its marker or disguise its eventual unclean termination.
            if marker.id == sessionID { try fileManager.removeItem(at: markerURL) }
        } catch {
            reportFailure()
        }
    }

    private var markerURL: URL { directory.appendingPathComponent("active-session.json") }
    private var logURL: URL { directory.appendingPathComponent("lifecycle.log") }
    private func archiveURL(_ index: Int) -> URL {
        directory.appendingPathComponent("lifecycle.\(index).log")
    }

    private func timestamp() -> String { formatter.string(from: Date()) }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
    }

    private func append(_ event: String) {
        do {
            try ensureDirectory()
            let entry = Entry(timestamp: timestamp(), event: event, session: sessionID,
                              pid: ProcessInfo.processInfo.processIdentifier)
            var line = try encoder.encode(entry)
            line.append(0x0a)
            let existingBytes: Int
            if fileManager.fileExists(atPath: logURL.path) {
                existingBytes = (try fileManager.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.intValue ?? 0
            } else {
                existingBytes = 0
            }
            if existingBytes + line.count > maximumFileBytes { try rotate() }
            if !fileManager.fileExists(atPath: logURL.path) {
                guard fileManager.createFile(atPath: logURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            reportFailure()
        }
    }

    private func rotate() throws {
        guard fileManager.fileExists(atPath: logURL.path) else { return }
        if archiveCount == 0 {
            try fileManager.removeItem(at: logURL)
            return
        }
        let oldest = archiveURL(archiveCount)
        if fileManager.fileExists(atPath: oldest.path) { try fileManager.removeItem(at: oldest) }
        if archiveCount > 1 {
            for index in stride(from: archiveCount - 1, through: 1, by: -1) {
                let source = archiveURL(index)
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.moveItem(at: source, to: archiveURL(index + 1))
                }
            }
        }
        try fileManager.moveItem(at: logURL, to: archiveURL(1))
    }

    private func reportFailure() {
        guard !reportedWriteFailure else { return }
        reportedWriteFailure = true
        // Avoid including NSError descriptions: those can contain local paths.
        logger.error("Lifecycle diagnostics could not be written; application continues normally.")
    }
}
