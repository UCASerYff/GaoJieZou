import Foundation

@main
struct AppLifecycleLogRegression {
    @MainActor
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("rhythm-lifecycle-" + UUID().uuidString,
                                                                     isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let normal = root.appendingPathComponent("normal", isDirectory: true)
        let first = AppLifecycleLog(directory: normal)
        first.launch()
        first.launch()
        first.record("window.closed")
        first.terminate()
        first.terminate()
        require(!first.previousSessionWasUnclean, "first launch must have no prior interrupted session")
        require(!manager.fileExists(atPath: normal.appendingPathComponent("active-session.json").path),
                "normal termination must remove its active-session marker")
        try require(events(in: normal) == ["launch", "window.closed", "terminate_clean"],
                "launch and termination must be idempotent")
        let second = AppLifecycleLog(directory: normal)
        second.launch()
        require(!second.previousSessionWasUnclean, "a clean preceding session must remain clean")
        second.terminate()

        let interrupted = root.appendingPathComponent("interrupted", isDirectory: true)
        let abandoned = AppLifecycleLog(directory: interrupted)
        abandoned.launch()
        let recovered = AppLifecycleLog(directory: interrupted)
        recovered.launch()
        require(recovered.previousSessionWasUnclean, "an abandoned session marker must flag a prior unclean exit")
        try require(events(in: interrupted) == ["launch", "previous_session_unclean", "launch"],
                "the next launch must persist evidence of the previous incomplete termination")
        abandoned.terminate()
        require(manager.fileExists(atPath: interrupted.appendingPathComponent("active-session.json").path),
                "an older instance must not remove the newer instance's marker")
        recovered.terminate()
        require(!manager.fileExists(atPath: interrupted.appendingPathComponent("active-session.json").path),
                "the matching recovered session must remove its own marker")

        let privacy = root.appendingPathComponent("privacy", isDirectory: true)
        let privateLog = AppLifecycleLog(directory: privacy)
        privateLog.launch()
        privateLog.record("focus.system_paused")
        privateLog.record("私人记录标题 /Users/person/Secret.pdf")
        privateLog.record("window.closed\nforged_event")
        privateLog.record(String(repeating: "x", count: 97))
        privateLog.terminate()
        let privacyText = try String(contentsOf: privacy.appendingPathComponent("lifecycle.log"), encoding: .utf8)
        require(!privacyText.contains("Secret.pdf") && !privacyText.contains("私人") && !privacyText.contains("forged_event"),
                "private text, file paths and injected log lines must not enter diagnostics")
        try require(events(in: privacy).filter { $0 == "invalid_event_rejected" }.count == 3,
                "invalid event identifiers must be rejected without retaining their contents")

        let rotation = root.appendingPathComponent("rotation", isDirectory: true)
        let rotating = AppLifecycleLog(directory: rotation, maximumFileBytes: 768, archiveCount: 2)
        rotating.launch()
        for index in 0..<100 { rotating.record("tick.\(index)") }
        rotating.terminate()
        let files = try manager.contentsOfDirectory(at: rotation, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "log" }
        require(Set(files.map(\.lastPathComponent)) == ["lifecycle.log", "lifecycle.1.log", "lifecycle.2.log"],
                "rotation must retain exactly the current log and the configured archive count")
        for file in files {
            let data = try Data(contentsOf: file)
            require(data.count <= 768, "each retained log file must stay within the capacity limit")
            for line in data.split(separator: 0x0a) {
                _ = try JSONSerialization.jsonObject(with: Data(line))
            }
        }
        let remaining = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        require(remaining.contains("tick.99") && remaining.contains("terminate_clean") && !remaining.contains("tick.0\""),
                "rotation must preserve recent evidence and discard the oldest entries")

        let blocked = root.appendingPathComponent("blocked")
        try Data("file instead of a directory".utf8).write(to: blocked)
        let unavailable = AppLifecycleLog(directory: blocked)
        unavailable.launch()
        unavailable.record("window.closed")
        unavailable.terminate()
        try require(String(contentsOf: blocked, encoding: .utf8) == "file instead of a directory",
                "diagnostic failures must not overwrite unrelated files or interrupt the application")

        print("PASS Lifecycle diagnostics: clean/unclean sessions, matching marker ownership, private event filtering, bounded rotation, nonfatal storage failures")
    }

    private static func events(in directory: URL) throws -> [String] {
        let data = try Data(contentsOf: directory.appendingPathComponent("lifecycle.log"))
        return try data.split(separator: 0x0a).map { line in
            let json = try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
            return json["event"] as! String
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try condition() else { fatalError(message) }
    }
}
