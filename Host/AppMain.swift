import SwiftUI
import AppKit
import UserNotifications
import Carbon
import Rhythm
import RhythmHealth
import RhythmFootprints

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
        do {
                try HealthModuleRuntime.applyPendingRestoreBeforeOpening()
                try FootprintsModuleRuntime.applyPendingRestoreBeforeOpening()
        } catch {
                let alert = NSAlert()
                alert.messageText = "整合模块恢复未完成"
                alert.informativeText = error.localizedDescription + "\n当前资料、来源归档及待恢复任务均已保留。"
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
                Button("健康资料导出…") { delegate.openIntegratedAction("health", "export") }
                Button("健康资料恢复…") { delegate.openIntegratedAction("health", "import") }
                Button("足迹资料导出…") { delegate.openIntegratedAction("footprints", "export") }
                Button("足迹资料恢复…") { delegate.openIntegratedAction("footprints", "import") }
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
                IntegratedHealthSettings().tabItem { Label("健康", systemImage: "heart") }
                IntegratedFootprintsSettings().tabItem { Label("足迹", systemImage: "map") }
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
                consumeIntegratedAction()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.dataError"))) { dataError = $0.userInfo?["message"] as? String }
            .alert("数据操作未完成", isPresented: Binding(get: { dataError != nil }, set: { if !$0 { dataError = nil } })) {
                Button("知道了") { dataError = nil }
            } message: { Text(dataError ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.app.openSettings"))) { _ in openSettings() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("appOpenSettings"))) { _ in openSettings() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Standalone.showWindow"))) { _ in showMainWindow() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Standalone.consumeIntegratedURL"))) { _ in consumeIntegratedAction() }
            .onOpenURL { url in
                route = integratedURL(url)
                revision &+= 1
                showMainWindow()
            }
    }

    private func consumeIntegratedAction() {
        guard let url = delegate.pendingIntegratedURL else { return }
        delegate.pendingIntegratedURL = nil
        route = url; revision &+= 1
    }
}

/// Old links are aliases handled in this process; never launch a retired provider.
private func integratedURL(_ url: URL) -> URL {
    guard url.scheme == "gaojiankang" || url.scheme == "gaozuji" else { return url }
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    parts?.scheme = "gaojiezou"
    parts?.host = url.scheme == "gaojiankang" ? "health" : "footprints"
    parts?.path = "/" + (url.host ?? "") + url.path
    return parts?.url ?? url
}

private struct IntegratedHealthSettings: View {
    var body: some View {
        if RhythmIntegrationPaths.isActive {
            TabView {
                HealthSettingsView().tabItem { Text("健康设置") }
                HealthDataSettingsView().tabItem { Text("健康数据") }
                HealthAppearanceSettingsView().tabItem { Text("原外观偏好") }
            }
        } else { Text("健康资料尚未完成迁移激活，原资料保持原样。") }
    }
}

private struct IntegratedFootprintsSettings: View {
    var body: some View {
        if RhythmIntegrationPaths.isActive {
            TabView {
                FootprintsSettingsView().tabItem { Text("足迹设置") }
                FootprintsDataSettingsView().tabItem { Text("足迹数据") }
                FootprintsAppearanceSettingsView().tabItem { Text("原外观偏好") }
            }
        } else { Text("足迹资料尚未完成迁移激活，原资料保持原样。") }
    }
}

func post(_ name: String) { NotificationCenter.default.post(name: Notification.Name(name), object: nil) }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var showMainWindow: (() -> Void)?
    var showSettings: (() -> Void)?
    var pendingIntegratedURL: URL?
    func openIntegratedAction(_ module: String, _ action: String) {
        guard let url = URL(string: "gaojiezou://\(module)/\(action)") else { return }
        pendingIntegratedURL = url
        showMainWindow?()
        NotificationCenter.default.post(name:Notification.Name("Standalone.consumeIntegratedURL"),object:nil)
    }
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
        DispatchQueue.main.async { RhythmApplicationLifecycle.warmup() }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow,
                  window.identifier?.rawValue.hasPrefix("main") == true else { return }
            Task { @MainActor in self?.lifecycleLog.record("window.closed") }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidBecomeActive(_ notification: Notification) {
        RhythmApplicationLifecycle.refreshWidgetPublication()
    }
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
        guard RhythmApplicationLifecycle.prepareForTermination() else {
            lifecycleLog.record("quit.cancelled_save_failed")
            showMainWindow?()
            let alert = NSAlert()
            alert.messageText = "资料尚未保存，已取消退出"
            alert.informativeText = "当前记录和活动进度仍保留在内存中。请检查可用空间或资料目录权限后重试。"
            alert.runModal()
            return .terminateCancel
        }
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
