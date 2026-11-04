import SwiftUI
import Foundation

public final class HealthBundleMarker: NSObject {}
enum HealthBundle {
    static let bundle = Bundle(for: HealthBundleMarker.self)
    static var defaults: UserDefaults { HealthPreferences.defaults }
}

@MainActor private enum HealthRuntimeOpening { static var didOpen = false }

@MainActor private enum HealthRuntime {
    static var handledRouteRevision = 0
    static let store: AppStore = {
        HealthRuntimeOpening.didOpen = true
        return AppStore()
    }()
}

private struct HealthActivationGate<Content: View>: View {
    let content: () -> Content
    @State private var ready = false
    @State private var error: String?
    @State private var attempt = 0
    var body: some View {
        Group {
            if ready { content() }
            else if let error {
                VStack(spacing: 12) {
                    Text("健康资料尚未就绪 / Health data not ready").font(.headline)
                    Text(error).textSelection(.enabled)
                    Button("重新检查 / Retry") { attempt += 1 }
                }.padding(24)
            } else { ProgressView("正在核对健康迁移资料…") }
        }.task(id: attempt) { @MainActor in
            do { try HealthPreferences.prepare(); error = nil; ready = true }
            catch { ready = false; self.error = error.localizedDescription }
        }
    }
}

public struct HealthModuleView: View {
    private let route: URL?
    private let routeRevision: Int
    public init(route: URL? = nil, routeRevision: Int = 0) { self.route = route; self.routeRevision = routeRevision }
    public var body: some View { HealthActivationGate { ActiveHealthModuleView(route: route, routeRevision: routeRevision) } }
}

private struct ActiveHealthModuleView: View {
    @ObservedObject private var store = HealthRuntime.store
    private let route: URL?
    private let routeRevision: Int
    public init(route: URL? = nil, routeRevision: Int = 0) {
        self.route = route
        self.routeRevision = routeRevision
    }
    public var body: some View {
        ContentView()
            .environmentObject(store)
            .environment(\.locale, Locale(identifier: store.en ? "en_US" : "zh_CN"))
            .onAppear { store.syncSleepRewards(); handleRoute() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.health.game"))) { _ in store.selectedTab = 3 }
            .onChange(of: routeRevision) { _, _ in handleRoute() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.health.new"))) { _ in store.new(.meal) }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.health.water"))) { _ in store.addWater() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.health.sleep"))) { _ in store.newSleep() }
            // 备份导出/恢复收拢到 app 级「数据」页：模块内入口已移除，能力经通知触发。
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.health.export"))) { _ in store.backup() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.health.import"))) { _ in store.restore() }
    }
    private func handleRoute() {
        guard routeRevision > HealthRuntime.handledRouteRevision, let route,
              route.scheme == "gaojiezou", route.host == "health" else { return }
        HealthRuntime.handledRouteRevision = routeRevision
        let destination = route.path.split(separator: "/").first.map(String.init) ?? ""
        if destination == "export" { store.backup() }
        else if destination == "import" { store.restore() }
        else if destination == "sleep" { store.selectedTab = 10 }
        else if destination == "events" { store.selectedTab = 5 }
        else if let kind = RecordKind(rawValue: destination) { store.new(kind) }
        else { store.selectedTab = 0 }
    }
}

/// 搞健康设置页（app 级设置中心嵌入用）：内容与模块原「设置」侧栏页一致，
/// store 由 framework 内 singleton 注入，外部嵌入无需提供环境对象。
public struct HealthSettingsView: View {
    public init() {}
    public var body: some View { HealthActivationGate { ActiveHealthSettingsView() } }
}

private struct ActiveHealthSettingsView: View {
    @ObservedObject private var store = HealthRuntime.store
    var body: some View {
        Group {
            if let failure = store.fatalError {
                VStack(spacing: 12) {
                    Text("健康资料暂不可用 / Health data unavailable").font(.headline)
                    Text(failure).font(.callout).textSelection(.enabled)
                    Button("重试 / Retry") { store.reload() }
                }.padding(24)
            } else {
                SettingsView().environmentObject(store)
            }
        }.environment(\.locale, Locale(identifier: store.en ? "en_US" : "zh_CN"))
    }
}

@MainActor public enum HealthModuleRuntime {
    /// Host calls before ANY store is opened. Old source pending jobs are never replayed.
    public static func applyPendingRestoreBeforeOpening() throws {
        guard FileManager.default.fileExists(atPath: AppBackupRestore.pending.path) else { return }
        guard !HealthRuntimeOpening.didOpen else { throw CocoaError(.fileWriteNoPermission) }
        try AppBackupRestore.applyPending()
    }
    public static func exportModuleBackup() { HealthRuntime.store.backup() }
    public static func restoreModuleBackup() { HealthRuntime.store.restore() }
    public static func syncSleep() {
        guard RhythmIntegrationPaths.isActive else { return }
        do { try HealthPreferences.prepare() } catch { return }
        HealthRuntime.store.syncSleepRewards()
    }
}

/// Complete scoped health ZIP and next-launch recovery, hosted natively in Rhythm.
public struct HealthDataSettingsView: View {
    public init() {}
    public var body: some View { DataSettings() }
}
/// Appearance/language are the merged host's shared explicit preferences.
public struct HealthAppearanceSettingsView: View {
    public init() {}
    public var body: some View { GeneralSettings() }
}
