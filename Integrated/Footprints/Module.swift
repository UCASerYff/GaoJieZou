import SwiftUI
import Foundation
import AppKit

public final class FootprintsBundleMarker: NSObject {}
enum FootprintsBundle {
    static let bundle = Bundle(for: FootprintsBundleMarker.self)
    static let defaults: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: FootprintsPreferences.suiteName) else {
            preconditionFailure("Cannot construct the fixed Footprints preferences domain")
        }
        return defaults
    }()
}

@MainActor enum FootprintsRuntime {
    private static var instance: Store?
    static var hasOpenedStore: Bool { instance != nil }
    static var handledRouteRevision = 0
    static var store: Store {
        if let instance { return instance }
        let result = Store(); instance = result; return result
    }
    static var atlasPaths: AtlasPaths { AtlasPaths(store.geography) }
}

/// No Store or default library is created before the explicit authority commit.
private struct FootprintsActivationGate<Content: View>: View {
    let content: () -> Content
    @State private var ready = false
    @State private var failure: String?
    @State private var attempt = 0
    var body: some View {
        Group {
            if ready { content() }
            else if let failure {
                VStack(spacing: 14) {
                    Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                    Text("足迹资料尚未就绪").font(.headline)
                    Text(failure).font(.caption).textSelection(.enabled)
                    Button("重新检查") { attempt &+= 1 }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView("正在核对足迹迁移资料…") }
        }
        .task(id: attempt) { @MainActor in
            do {
                try FootprintsPreferences.prepare()
                failure = nil; ready = true
            } catch { ready = false; failure = error.localizedDescription }
        }
    }
}

/// The main Rhythm sidebar owns navigation; each module view shows one leaf.
public enum FootprintsNavigationPage: String {
    case map, trips, timeline, residentCity, train

    var section: String {
        switch self {
        case .map: "地图"
        case .trips: "旅行"
        case .timeline: "时间轴"
        case .residentCity: "常驻城市"
        case .train: "列车"
        }
    }

    init?(section: String) {
        switch section {
        case "地图": self = .map
        case "旅行": self = .trips
        case "时间轴": self = .timeline
        case "常驻城市": self = .residentCity
        case "列车": self = .train
        default: return nil
        }
    }
}

public struct FootprintsModuleView: View {
    private let page: FootprintsNavigationPage
    private let route: URL?
    private let routeRevision: Int
    private let onNavigate: ((FootprintsNavigationPage) -> Void)?
    public init(page: FootprintsNavigationPage = .map, route: URL? = nil, routeRevision: Int = 0,
                onNavigate: ((FootprintsNavigationPage) -> Void)? = nil) {
        self.page = page; self.route = route; self.routeRevision = routeRevision
        self.onNavigate = onNavigate
    }
    public var body: some View {
        FootprintsActivationGate {
            ActiveFootprintsModuleView(page: page, route: route, routeRevision: routeRevision,
                                       onNavigate: onNavigate)
        }
    }
}

private struct ActiveFootprintsModuleView: View {
    @ObservedObject private var store = FootprintsRuntime.store
    @AppStorage("gqns.appearance", store: FootprintsBundle.defaults) private var appearance = "system"
    @State private var displayedPage: FootprintsNavigationPage
    let page: FootprintsNavigationPage
    let route: URL?
    let routeRevision: Int
    let onNavigate: ((FootprintsNavigationPage) -> Void)?

    init(page: FootprintsNavigationPage, route: URL?, routeRevision: Int,
         onNavigate: ((FootprintsNavigationPage) -> Void)?) {
        self.page = page; self.route = route; self.routeRevision = routeRevision
        self.onNavigate = onNavigate
        _displayedPage = State(initialValue: page)
    }

    private var contentPage: FootprintsNavigationPage {
        onNavigate == nil ? displayedPage : page
    }

    var body: some View {
        RootView(page: contentPage).environmentObject(store)
            .environment(\.locale, Locale(identifier: GQNSLanguage.localeIdentifier))
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
            .onAppear { select(page); handleRoute() }
            .onChange(of: page) { _, value in select(value) }
            .onChange(of: store.section) { _, value in
                if let destination = FootprintsNavigationPage(section: value) {
                    displayedPage = destination
                    if destination != page { onNavigate?(destination) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.footprints.game"))) { _ in select(.train) }
            .onChange(of: routeRevision) { _, _ in handleRoute() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.footprints.new"))) { _ in store.editor = EditorRequest() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.footprints.search"))) { _ in
                select(.map); focusSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.footprints.undo"))) { _ in store.undo() }
    }

    private func select(_ destination: FootprintsNavigationPage) {
        displayedPage = destination
        if store.section != destination.section { store.section = destination.section }
        if destination != page { onNavigate?(destination) }
    }

    private func focusSearch() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .focusSearch, object: nil) }
    }

    private func handleRoute() {
        guard routeRevision > FootprintsRuntime.handledRouteRevision, let route,
              route.scheme == "gaojiezou", route.host == "footprints" else { return }
        FootprintsRuntime.handledRouteRevision = routeRevision
        let section = route.path.split(separator: "/").first.map(String.init) ?? "map"
        switch section {
        case "train": select(.train)
        case "trips": select(.trips)
        case "timeline": select(.timeline)
        case "residentCity", "resident-city", "home": select(.residentCity)
        case "new": if store.ready { store.editor = EditorRequest() }
        case "search":
            select(.map)
            focusSearch()
        case "undo": store.undo()
        default:
            select(.map)
            let scope = URLComponents(url: route, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value
            store.search = ""; store.year = 0; store.tripFilter = ""; store.selectedCity = nil
            if scope == "china" || scope == "world" { store.widgetMapScope = scope; store.widgetMapNavigationRevision &+= 1 }
        }
    }
}

/// The shared host navigation presents the same visit action without changing the window toolbar.
public struct FootprintsModuleActionsView: View {
    @ObservedObject private var store = FootprintsRuntime.store
    public init() {}

    public var body: some View {
        Button { store.editor = EditorRequest() } label: {
            Label(tF("点亮一个地方", "Light Up a Place"), systemImage: "plus")
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.plain)
        .disabled(!store.ready)
        .fixedSize()
    }
}

public struct FootprintsSettingsView: View {
    public init() {}
    public var body: some View {
        FootprintsActivationGate {
            SettingsPage().environmentObject(FootprintsRuntime.store)
                .environment(\.locale, Locale(identifier: GQNSLanguage.localeIdentifier))
        }
    }
}

public struct FootprintsDataSettingsView: View {
    public init() {}
    public var body: some View { FootprintsActivationGate { DataSettings() } }
}

public struct FootprintsAppearanceSettingsView: View {
    public init() {}
    public var body: some View { FootprintsActivationGate { GeneralSettings() } }
}

public struct FootprintsPublicationReceipt: Codable {
    public let published: Bool
    public let generationID: String
    public let sourceDigest: String
    public let sourceModifiedAt: Date
    public let publishedAt: Date
    public let cities: Int
    public let countries: Int
    public let visits: Int
}

@MainActor public enum FootprintsModuleRuntime {
    /// Headless installer/runtime bridge, with no game settlement or GUI.
    /// The source Repository is read-only and every photo is checked.
    public static func publishSavedSnapshot(requireHostStopped: Bool = true) throws -> FootprintsPublicationReceipt {
        try RhythmIntegrationPaths.withWriterLease {
            try publishSavedSnapshotUnderLease(requireHostStopped: requireHostStopped)
        }
    }
    private static func publishSavedSnapshotUnderLease(requireHostStopped: Bool) throws -> FootprintsPublicationReceipt {
        if requireHostStopped {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.gaojiezou.rhythm").isEmpty else {
                throw AppFailure("请先正常退出搞节奏，再运行升级快照发布。")
            }
        }
        let root = try FootprintsIntegratedStorage.dataDirectory()
        let shared = try FootprintsIntegratedStorage.widgetDirectory()
        guard let file = FootprintsBundle.bundle.url(forResource: "Geography", withExtension: "json") else { throw AppFailure("足迹离线地图资源缺失。") }
        let geography = try JSONDecoder().decode(Geography.self, from: Data(contentsOf: file))
        let repository = try Repository(root: root, readOnly: true)
        let journal = try repository.load()
        try repository.validate(journal, geography: geography)
        for attachment in journal.attachments {
            let bytes = try Data(contentsOf: repository.photoURL(attachment))
            guard bytes.count == attachment.size, digest(bytes) == attachment.sha256 else { throw AppFailure("足迹照片校验失败，未发布快照。") }
        }
        guard try WidgetSourceFingerprint.make(journal: repository.load(), geography: geography) == WidgetSourceFingerprint.make(journal: journal, geography: geography) else { throw AppFailure("发布准备期间资料发生变化，请在停止写入后重试。") }
        let changed = try WidgetPublisherCore.publish(journal: journal, geography: geography, root: shared,
            appVersion: FootprintsBundle.bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            appBuild: FootprintsBundle.bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        let generation = try WidgetGenerationStore(root: shared).load()
        return FootprintsPublicationReceipt(published: changed, generationID: generation.generationID,
            sourceDigest: generation.sourceDigest, sourceModifiedAt: generation.sourceModifiedAt,
            publishedAt: generation.publishedAt, cities: generation.snapshot.cities,
            countries: generation.snapshot.countries, visits: generation.snapshot.visits)
    }
}
