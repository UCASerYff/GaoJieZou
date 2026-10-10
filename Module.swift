import SwiftUI
import Foundation

public final class RhythmBundleMarker: NSObject {}
enum RhythmBundle {
    static let bundle = Bundle(for: RhythmBundleMarker.self)
    static let defaults = UserDefaults(suiteName: ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] == "1" ? "com.gaojiezou.rhythm.test.Rhythm" : "com.gaojiezou.rhythm.Rhythm") ?? .standard
}

@MainActor private enum RhythmRuntime {
    static let store = RhythmStore()
    static let settings = RhythmSettings()
}

/// The application owns termination, including when no content view is alive.
@MainActor public enum RhythmApplicationLifecycle {
    public static func prepareForTermination() {
        RhythmRuntime.store.prepareForTermination()
    }

    public static func backgroundSnapshot() -> RhythmBackgroundSnapshot {
        let store = RhythmRuntime.store
        if store.loadFailed { return .init(phase: .dataUnavailable, elapsedSeconds: 0) }
        if let focus = store.activeFocus {
            let phase: RhythmBackgroundSnapshot.Phase = focus.segmentStartedAt != nil
                ? .focusing : (focus.pausedForSystem ? .systemPaused : .paused)
            return .init(phase: phase, elapsedSeconds: store.focusElapsed())
        }
        if store.activeSleep != nil { return .init(phase: .sleeping, elapsedSeconds: store.sleepElapsed()) }
        return .init(phase: .idle, elapsedSeconds: 0)
    }

    public static func toggleFocusPause() {
        let store = RhythmRuntime.store
        guard !store.loadFailed, let focus = store.activeFocus else { return }
        if focus.segmentStartedAt == nil { store.resumeFocus() }
        else { store.pauseFocus() }
    }

    public static func warmup() {
        RhythmFormatters.warmup()
        _ = NSDatePicker().intrinsicContentSize
    }
}

public struct RhythmBackgroundSnapshot {
    public enum Phase: String { case idle, focusing, paused, systemPaused, sleeping, dataUnavailable }
    public let phase: Phase
    public let elapsedSeconds: TimeInterval
}

public struct RhythmModuleView: View {
    @ObservedObject private var store = RhythmRuntime.store
    @ObservedObject private var settings = RhythmRuntime.settings
    private let route: URL?
    private let routeRevision: Int
    public init(route: URL? = nil, routeRevision: Int = 0) {
        self.route = route
        self.routeRevision = routeRevision
    }
    public var body: some View {
        ContentView(route: route, routeRevision: routeRevision)
            .environmentObject(store)
            .environmentObject(settings)
            .environment(\.locale, settings.language.locale)
            .onReceive(DistributedNotificationCenter.default().publisher(for:Notification.Name("GaoSeries.health.sleepReward"))) { note in
                NotificationCenter.default.post(name:note.name,object:nil,userInfo:note.userInfo)
            }
            // 备份导出/恢复收拢到 app 级「数据」页：模块内入口已移除，能力经通知触发。
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.rhythm.export"))) { _ in
                store.exportFullBackup()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.rhythm.import"))) { _ in
                store.restoreFullBackup()
            }
    }
}

/// 搞节奏设置页（app 级设置中心嵌入用）：内容与模块原设置 sheet 完全一致，
/// store/settings 由 framework 内 singleton 注入，外部嵌入无需提供环境对象。
public struct RhythmSettingsView: View {
    @ObservedObject private var store = RhythmRuntime.store
    @ObservedObject private var settings = RhythmRuntime.settings
    public init() {}
    public var body: some View {
        RhythmSettingsPanelView()
            .environmentObject(store)
            .environmentObject(settings)
            .environment(\.locale, settings.language.locale)
    }
}
