import SwiftUI
import AppKit
import UserNotifications
import Carbon
import Rhythm

@main struct StandaloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var menuBarInserted = true

    init() {
        do { try AppBackupRestore.applyPending() } catch {
            let alert = NSAlert()
            alert.messageText = "数据恢复未完成"
            alert.informativeText = error.localizedDescription + "\n当前数据和恢复前副本已保留。"
            alert.runModal()
            exit(1)
        }
        AppAppearance.current.apply()
    }

    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "main" || $0.identifier?.rawValue.hasPrefix("main-") == true
        }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    var body: some Scene {
        WindowGroup("搞节奏 V\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")", id: "main", for: String.self) { _ in
            MainWindowContent(delegate: delegate)
        } defaultValue: { "main" }
        .defaultSize(width: 1380, height: 860)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("显示搞节奏") { delegate.showMainWindow?() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("数据") {
                Button("导出模块备份…") { post("GaoSeries.rhythm.export") }
                Button("恢复模块备份…") { post("GaoSeries.rhythm.import") }
                Divider()
                Button("完整资料备份与恢复…") { delegate.showSettings?() }
            }
        }
        // The binding keeps removing the item from implicitly terminating this app.
        MenuBarExtra(isInserted: $menuBarInserted) {
            ResidentMenuContent(controller: delegate.resident)
        } label: {
            ResidentMenuLabel(controller: delegate.resident)
        }
        .menuBarExtraStyle(.menu)
        Settings {
            TabView {
                RhythmSettingsView().tabItem { Label("模块设置", systemImage: "slider.horizontal.3") }
                GeneralSettings().tabItem { Label("外观", systemImage: "paintpalette") }
                DataSettings().tabItem { Label("数据", systemImage: "externaldrive") }
            }.frame(width: 820, height: 740)
        }
    }
}

/// Capture window actions from a mounted View environment, not the App root.
private struct MainWindowContent: View {
    let delegate: AppDelegate
    @State private var route: URL?
    @State private var revision = 0
    @State private var dataError: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private func showMainWindow() {
        openWindow(id: "main", value: "main")
        DispatchQueue.main.async { StandaloneApp.activate() }
    }

    var body: some View {
        RhythmModuleView(route: route, routeRevision: revision)
            .frame(minWidth: 1040, minHeight: 720)
            .modifier(WindowToolbarOpaqueBackground())
            .onAppear {
                delegate.showMainWindow = showMainWindow
                delegate.showSettings = { openSettings() }
                delegate.lifecycleLog.record("window.opened")
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.dataError"))) { dataError = $0.userInfo?["message"] as? String }
            .alert("数据操作未完成", isPresented: Binding(get: { dataError != nil }, set: { if !$0 { dataError = nil } })) {
                Button("知道了") { dataError = nil }
            } message: { Text(dataError ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.app.openSettings"))) { _ in openSettings() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("appOpenSettings"))) { _ in openSettings() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Standalone.showWindow"))) { _ in showMainWindow() }
            .onOpenURL { url in
                route = url
                revision &+= 1
                showMainWindow()
            }
    }
}

func post(_ name: String) { NotificationCenter.default.post(name: Notification.Name(name), object: nil) }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var showMainWindow: (() -> Void)?
    var showSettings: (() -> Void)?
    let lifecycleLog: AppLifecycleLog
    let resident: ResidentAppController
    private var windowObserver: NSObjectProtocol?
    private static let residencyReason = "搞节奏菜单栏与后台计时常驻"

    override init() {
        let log = AppLifecycleLog()
        lifecycleLog = log
        resident = ResidentAppController(log: log)
        super.init()
        // This counter also survives SwiftUI enabling automatic termination later.
        // It does not prevent explicit Quit, logout, shutdown or system sleep.
        ProcessInfo.processInfo.disableAutomaticTermination(Self.residencyReason)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        lifecycleLog.launch()
        lifecycleLog.record("automatic_termination.disabled")
        UNUserNotificationCenter.current().delegate = self
        resident.start()
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow,
                  window.identifier?.rawValue.hasPrefix("main") == true else { return }
            Task { @MainActor in self?.lifecycleLog.record("window.closed") }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        lifecycleLog.record("application.reopen")
        showMainWindow?()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lifecycleLog.record("quit.requested")
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value ?? 0
            lifecycleLog.record("quit.sender.\(pid)")
            if let source = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
                lifecycleLog.record("quit.source.\(source)")
            }
            if let reason = event.paramDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue {
                lifecycleLog.record("quit.reason.\(reason)")
            }
        }
        RhythmApplicationLifecycle.prepareForTermination()
        lifecycleLog.record("quit.state_save_requested")
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        resident.stop()
        if let observer = windowObserver { NotificationCenter.default.removeObserver(observer) }
        lifecycleLog.terminate()
        ProcessInfo.processInfo.enableAutomaticTermination(Self.residencyReason)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .list, .sound]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.showMainWindow?(); completionHandler() }
    }
}

private struct WindowToolbarOpaqueBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar).toolbarBackgroundVisibility(.visible, for: .windowToolbar) }
        else { content.toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar) }
    }
}
