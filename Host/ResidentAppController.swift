import AppKit
import Rhythm

@MainActor
final class ResidentAppController: NSObject, NSMenuDelegate {
    let log: AppLifecycleLog
    private var timer: Timer?
    private var statusItem: NSStatusItem?
    private var showMainWindow: (() -> Void)?
    private var lastPhase: RhythmBackgroundSnapshot.Phase?
    private var lastSymbol: String?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var showWindowItem = command(#selector(showMainWindowFromMenu(_:)))
    private lazy var toggleItem = command(#selector(toggleFocusFromMenu(_:)))
    private lazy var quitItem = command(#selector(quitFromMenu(_:)))

    init(log: AppLifecycleLog) { self.log = log }

    func start(showMainWindow: @escaping () -> Void) {
        guard statusItem == nil else { return }
        self.showMainWindow = showMainWindow

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(showWindowItem)
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.behavior = .removalAllowed
        item.menu = menu
        statusItem = item
        refresh()
        log.record("menubar.visible")

        let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        clock.tolerance = 0.15
        timer = clock
        RunLoop.main.add(clock, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let statusItem {
            statusItem.menu?.removeAllItems()
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        showMainWindow = nil
        lastPhase = nil
        lastSymbol = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    private func refresh() {
        guard let button = statusItem?.button else { return }
        let snapshot = RhythmApplicationLifecycle.backgroundSnapshot()
        let english = RhythmApplicationLifecycle.usesEnglish
        let app = english ? "Rhythm" : "搞节奏"
        let status: String
        let symbol: String
        let canToggleFocus: Bool

        switch snapshot.phase {
        case .idle:
            status = english ? "Running in the background · No active timer" : "后台运行中 · 当前无计时"
            symbol = "metronome"
            canToggleFocus = false
        case .focusing, .paused, .systemPaused:
            let label: String
            switch snapshot.phase {
            case .focusing: label = english ? "Focus" : "专注中"
            case .systemPaused: label = english ? "Focus paused by macOS" : "系统暂停专注"
            default: label = english ? "Focus paused" : "专注已暂停"
            }
            let detail = FocusStatusPresentation.detail(
                elapsedSeconds: snapshot.elapsedSeconds, targetMinutes: snapshot.focusTargetMinutes, english: english
            )
            status = english ? "\(label): \(detail)" : "\(label) · \(detail)"
            symbol = snapshot.phase == .focusing ? "timer" : "pause.circle"
            canToggleFocus = true
        case .sleeping:
            let seconds = Int(exactly: max(0, snapshot.elapsedSeconds).rounded(.down)) ?? 0
            let elapsed = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            let label = english ? "Sleep timer running" : "睡眠计时中"
            status = "\(label) · \(elapsed)"
            symbol = "moon.zzz"
            canToggleFocus = false
        case .dataUnavailable:
            status = english ? "Data unavailable. Open the main window." : "资料读取异常，请打开主窗口"
            symbol = "exclamationmark.triangle"
            canToggleFocus = false
        }

        // The background timer polls once a second, while native focus UI only
        // changes when the minute, phase, target or language changes.
        if statusLine.title != status { statusLine.title = status }
        let tooltip = snapshot.phase == .idle ? app : "\(app) · \(status)"
        if button.toolTip != tooltip {
            button.toolTip = tooltip
            button.setAccessibilityLabel(tooltip)
        }
        if lastSymbol != symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            lastSymbol = symbol
        }

        let showTitle = english ? "Show Rhythm" : "显示搞节奏"
        let quitTitle = english ? "Quit Rhythm" : "退出搞节奏"
        let toggleTitle = snapshot.phase == .focusing
            ? (english ? "Pause Focus" : "暂停专注")
            : (english ? "Resume Focus" : "继续专注")
        if showWindowItem.title != showTitle { showWindowItem.title = showTitle }
        if quitItem.title != quitTitle { quitItem.title = quitTitle }
        if toggleItem.title != toggleTitle { toggleItem.title = toggleTitle }
        if toggleItem.isEnabled != canToggleFocus { toggleItem.isEnabled = canToggleFocus }
        if lastPhase != snapshot.phase {
            log.record("state.\(snapshot.phase.rawValue)")
            lastPhase = snapshot.phase
        }
    }

    private func command(_ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showMainWindowFromMenu(_ sender: NSMenuItem) {
        log.record("menubar.show_window")
        showMainWindow?()
    }

    @objc private func toggleFocusFromMenu(_ sender: NSMenuItem) {
        RhythmApplicationLifecycle.toggleFocusPause()
        refresh()
    }

    @objc private func quitFromMenu(_ sender: NSMenuItem) {
        log.record("menubar.quit")
        NSApp.terminate(nil)
    }
}
