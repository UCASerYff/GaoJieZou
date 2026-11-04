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
                try FootprintsModuleRuntime.applyPendingRestoreBeforeOpening()
                try FootprintsPreferences.prepare()
                failure = nil; ready = true
            } catch { ready = false; failure = error.localizedDescription }
        }
    }
}

public struct FootprintsModuleView: View {
    private let route: URL?
    private let routeRevision: Int
    public init(route: URL? = nil, routeRevision: Int = 0) {
        self.route = route; self.routeRevision = routeRevision
    }
    public var body: some View {
        FootprintsActivationGate { ActiveFootprintsModuleView(route: route, routeRevision: routeRevision) }
    }
}

private struct ActiveFootprintsModuleView: View {
    @ObservedObject private var store = FootprintsRuntime.store
    @AppStorage("gqns.appearance", store: FootprintsBundle.defaults) private var appearance = "system"
    let route: URL?
    let routeRevision: Int
    var body: some View {
        RootView().environmentObject(store)
            .environment(\.locale, Locale(identifier: GQNSLanguage.localeIdentifier))
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
            .onAppear(perform: handleRoute)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.footprints.game"))) { _ in store.section = "列车" }
            .onChange(of: routeRevision) { _, _ in handleRoute() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.footprints.new"))) { _ in store.editor = EditorRequest() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.footprints.search"))) { _ in
                store.section = "地图"; NotificationCenter.default.post(name: .focusSearch, object: nil)
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.footprints.undo"))) { _ in store.undo() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.footprints.export"))) { _ in store.exportBackup() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.footprints.import"))) { _ in store.restoreBackup() }
    }
    private func handleRoute() {
        guard routeRevision > FootprintsRuntime.handledRouteRevision, let route,
              route.scheme == "gaojiezou", route.host == "footprints" else { return }
        FootprintsRuntime.handledRouteRevision = routeRevision
        let section = route.path.split(separator: "/").first.map(String.init) ?? "map"
        switch section {
        case "train": store.section = "列车"
        case "trips": store.section = "旅行"
        case "timeline": store.section = "时间轴"
        case "new": if store.ready { store.editor = EditorRequest() }
        case "search":
            store.section = "地图"
            NotificationCenter.default.post(name: .focusSearch, object: nil)
        case "undo": store.undo()
        case "export": store.exportBackup()
        case "import": store.restoreBackup()
        default:
            store.section = "地图"
            let scope = URLComponents(url: route, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value
            store.search = ""; store.year = 0; store.tripFilter = ""; store.selectedCity = nil
            if scope == "china" || scope == "world" { store.widgetMapScope = scope; store.widgetMapNavigationRevision &+= 1 }
        }
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
    public static func exportModuleBackup() { FootprintsRuntime.store.exportBackup() }
    public static func restoreModuleBackup() { FootprintsRuntime.store.restoreBackup() }

    /// Root invokes this before initializing any integrated Store. Only the new
    /// host's recovery jobs are eligible; source jobs remain archived/blocked.
    public static func applyPendingRestoreBeforeOpening() throws {
        try AppBackupRestore.applyPending()
    }

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
