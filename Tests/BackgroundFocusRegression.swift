import AppKit
import Foundation

// The regression runner compiles the real store, timer, persistence and models.
// Only the framework resource locator is replaced; the runner creates no UI.
enum RhythmBundle {
    static let bundle = Bundle.main
    static let defaults = UserDefaults(suiteName: "com.gaojiezou.rhythm.background-focus-regression")!
}

@main
struct BackgroundFocusRegression {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhythm-background-focus-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("GAOJIEZOU_DATA_DIR", root.path, 1)

        let store = RhythmStore()
        require(store.activeFocus == nil, "fixture must start without a focus session")
        store.startFocus(linkedActionID: nil)
        let sessionID = store.activeFocus!.id

        // No ContentView/Window exists: the store must own and run its timer.
        pumpRunLoop(for: 2.4)
        require(store.activeFocus?.segmentStartedAt != nil, "focus must continue without a window")
        require((store.activeFocus?.growthCreditedSeconds ?? 0) >= 1.5,
                "the real timer must settle focus progress without a SwiftUI view")

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        pumpRunLoop(for: 0.15)
        require(store.activeFocus?.pausedForSystem == true, "screen sleep must retain the automatic pause policy")
        let systemPausedSeconds = store.focusElapsed()
        pumpRunLoop(for: 0.15)
        require(abs(store.focusElapsed() - systemPausedSeconds) < 0.001, "system-paused focus must not grow")

        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        pumpRunLoop(for: 0.15)
        require(store.activeFocus?.segmentStartedAt != nil, "system-paused focus must resume after screen wake")
        require(store.activeFocus?.pausedForSystem == false, "resume must clear the system-pause marker")

        store.pauseFocus()
        let manuallyPausedSeconds = store.focusElapsed()
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        pumpRunLoop(for: 0.15)
        require(store.activeFocus?.segmentStartedAt == nil, "wake must not resume a manually paused focus")
        require(abs(store.focusElapsed() - manuallyPausedSeconds) < 0.001, "manual pause must stop accumulation")

        store.resumeFocus()
        pumpRunLoop(for: 0.15)
        store.prepareForTermination()
        let saved = try JSONDecoder().decode(RhythmLibrary.self,
                                            from: Data(contentsOf: root.appendingPathComponent("library.json")))
        require(saved.activeFocus?.id == sessionID, "quit must preserve the current focus identity")
        require(saved.activeFocus?.segmentStartedAt == nil, "quit with no window must persist a paused session")
        require(saved.activeFocus?.pausedForSystem == false, "explicit quit must not auto-resume on wake")
        let savedSeconds = saved.activeFocus!.accumulatedSeconds
        require(savedSeconds >= manuallyPausedSeconds, "quit must persist the last uncredited running segment")

        // Simulated time after exit cannot turn into focus time on reload.
        pumpRunLoop(for: 0.15)
        let restored = RhythmStore()
        require(restored.activeFocus?.id == sessionID, "relaunch must restore the same paused focus")
        require(abs(restored.focusElapsed() - savedSeconds) < 0.001, "relaunch must not credit time after quit")
        restored.resumeFocus()
        pumpRunLoop(for: 0.15)
        restored.finishFocus()
        require(restored.activeFocus == nil, "finish must clear the running session")
        require(restored.focusRecords.count == 1 && restored.focusRecords[0].id == sessionID,
                "finish must save exactly one record for the existing session")
        require(restored.focusRecords[0].durationSeconds >= savedSeconds, "finish must retain the pre-quit duration")
        restored.finishFocus()
        require(restored.focusRecords.count == 1, "repeated finish must not duplicate a record or reward")
        restored.startFocus(linkedActionID: nil)
        restored.cancelFocus()
        require(restored.activeFocus == nil && restored.focusRecords.count == 1,
                "cancel must release the session without adding a completed record")

        print("PASS Background focus: real timer without UI; system/manual pause and resume; window-independent quit save; paused relaunch; single completion; cancel")
    }

    @MainActor
    private static func pumpRunLoop(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.main.run(until: min(until, Date().addingTimeInterval(0.02)))
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
