import AppKit
import SwiftUI
import Rhythm

/// Application-owned status observer. The persistent UI is a MenuBarExtra scene.
@MainActor
final class ResidentAppController: ObservableObject {
    @Published private(set) var status = "搞节奏正在启动"
    @Published private(set) var symbol = "metronome"
    @Published private(set) var canToggleFocus = false
    @Published private(set) var toggleTitle = "继续专注"
    let log: AppLifecycleLog
    private var timer: Timer?
    private var lastPhase: RhythmBackgroundSnapshot.Phase?

    init(log: AppLifecycleLog) { self.log = log }

    func start() {
        guard timer == nil else { return }
        refresh()
        let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer = clock
        RunLoop.main.add(clock, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let snapshot = RhythmApplicationLifecycle.backgroundSnapshot()
        let label: String
        let icon: String
        switch snapshot.phase {
        case .idle: label = "后台运行中 · 当前无计时"; icon = "metronome"
        case .focusing: label = "专注中"; icon = "timer"
        case .paused: label = "专注已暂停"; icon = "pause.circle"
        case .systemPaused: label = "专注已暂停（锁屏或休眠）"; icon = "pause.circle"
        case .sleeping: label = "睡眠计时中"; icon = "moon.zzz"
        case .dataUnavailable: label = "资料读取异常，请打开主窗口"; icon = "exclamationmark.triangle"
        }
        let seconds = max(0, Int(snapshot.elapsedSeconds))
        let duration = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        let hasSession = [.focusing, .paused, .systemPaused, .sleeping].contains(snapshot.phase)
        status = hasSession ? "\(label) · \(duration)" : label
        if lastPhase != snapshot.phase {
            canToggleFocus = [.focusing, .paused, .systemPaused].contains(snapshot.phase)
            toggleTitle = snapshot.phase == .focusing ? "暂停专注" : "继续专注"
            symbol = icon
            log.record("state.\(snapshot.phase.rawValue)")
            lastPhase = snapshot.phase
        }
    }

    func toggleFocus() {
        RhythmApplicationLifecycle.toggleFocusPause()
        refresh()
    }
}

struct ResidentMenuContent: View {
    @ObservedObject var controller: ResidentAppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.status)
        Divider()
        Button("显示搞节奏") {
            controller.log.record("menubar.show_window")
            openWindow(id: "main", value: "main")
            DispatchQueue.main.async { StandaloneApp.activate() }
        }
        Button(controller.toggleTitle) { controller.toggleFocus() }
            .disabled(!controller.canToggleFocus)
        Divider()
        Button("退出搞节奏") {
            controller.log.record("menubar.quit")
            NSApp.terminate(nil)
        }
    }
}

struct ResidentMenuLabel: View {
    @ObservedObject var controller: ResidentAppController

    var body: some View {
        Label("节奏", systemImage: controller.symbol)
            .accessibilityLabel("搞节奏，\(controller.status)")
            .help("搞节奏 · \(controller.status)")
            .onAppear { controller.log.record("menubar.visible") }
    }
}
