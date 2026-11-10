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

/// The merged host owns navigation; these are individual content pages only.
public enum HealthNavigationPage: String, CaseIterable, Hashable {
    case overview, records, events, water, sleep, meals, exercise, weight, trends, island

    var selectedTab: Int {
        switch self {
        case .overview: 0
        case .records: 11
        case .events: 5
        case .water: 6
        case .sleep: 10
        case .meals: 7
        case .exercise: 8
        case .weight: 9
        case .trends: 2
        case .island: 3
        }
    }

    init?(selectedTab: Int) {
        guard let page = Self.allCases.first(where: { $0.selectedTab == selectedTab }) else { return nil }
        self = page
    }
}

public struct HealthModuleView: View {
    private let page: HealthNavigationPage
    private let route: URL?
    private let routeRevision: Int
    private let onNavigate: ((HealthNavigationPage) -> Void)?
    public init(page: HealthNavigationPage = .overview, route: URL? = nil, routeRevision: Int = 0,
                onNavigate: ((HealthNavigationPage) -> Void)? = nil) {
        self.page = page; self.route = route; self.routeRevision = routeRevision; self.onNavigate = onNavigate
    }
    public var body: some View {
        HealthActivationGate {
            ActiveHealthModuleView(page: page, route: route, routeRevision: routeRevision, onNavigate: onNavigate)
        }
    }
}

private struct ActiveHealthModuleView: View {
    @ObservedObject private var store = HealthRuntime.store
    @State private var displayedPage: HealthNavigationPage
    private let page: HealthNavigationPage
    private let route: URL?
    private let routeRevision: Int
    private let onNavigate: ((HealthNavigationPage) -> Void)?
    init(page: HealthNavigationPage, route: URL?, routeRevision: Int,
         onNavigate: ((HealthNavigationPage) -> Void)?) {
        self.page = page; self.route = route; self.routeRevision = routeRevision; self.onNavigate = onNavigate
        _displayedPage = State(initialValue: page)
    }
    var body: some View {
        ContentView(page: contentPage)
            .environmentObject(store)
            .environment(\.locale, Locale(identifier: store.en ? "en_US" : "zh_CN"))
            .onAppear { enter(page); store.syncSleepRewards(); handleRoute() }
            .onChange(of: page) { _, value in enter(value) }
            .onChange(of: store.selectedTab) { _, tab in
                guard let value = HealthNavigationPage(selectedTab: tab) else { return }
                let previous = displayedPage
                displayedPage = value
                if let onNavigate {
                    if value != page { onNavigate(value) }
                } else if value == .island && previous != value { store.welcome() }
            }
            .onChange(of: routeRevision) { _, _ in handleRoute() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.health.game"))) { _ in
                select(.island); onNavigate?(.island)
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.health.new"))) { _ in store.new(.meal) }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.health.water"))) { _ in store.addWater() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.health.sleep"))) { _ in store.newSleep() }
    }
    private var contentPage: HealthNavigationPage {
        // With a host callback, its page is authoritative even on the first
        // frame. The fallback keeps older route-only embedding source-compatible.
        if case .some = onNavigate { return page }
        return displayedPage
    }
    private func enter(_ value: HealthNavigationPage) {
        let previouslyDisplayed = displayedPage
        select(value)
        if value == .island {
            if case .some = onNavigate { store.welcome() }
            else if previouslyDisplayed == value { store.welcome() }
        }
    }
    private func select(_ value: HealthNavigationPage) {
        let previous = displayedPage
        displayedPage = value
        if store.selectedTab != value.selectedTab { store.selectedTab = value.selectedTab }
        if case .none = onNavigate, value == .island && previous != value { store.welcome() }
    }
    private func handleRoute() {
        guard routeRevision > HealthRuntime.handledRouteRevision, let route,
              route.scheme == "gaojiezou", route.host == "health" else { return }
        HealthRuntime.handledRouteRevision = routeRevision
        let destination = route.path.split(separator: "/").first.map(String.init) ?? ""
        if destination == "sleep" { select(.sleep) }
        else if destination == "events" { select(.events) }
        else if destination == "records" { select(.records) }
        else if destination == "island" || destination == "game" { select(.island) }
        else if destination == "trends" { select(.trends) }
        else if let kind = RecordKind(rawValue: destination) {
            let target: HealthNavigationPage = switch kind {
            case .water: .water
            case .meal: .meals
            case .exercise: .exercise
            case .weight: .weight
            }
            select(target)
            store.new(kind)
        }
        else { select(.overview) }
        onNavigate?(displayedPage)
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
