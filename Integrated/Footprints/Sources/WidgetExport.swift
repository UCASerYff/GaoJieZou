import Foundation
import AppKit
import WidgetKit

/// Complete generations; hooks live for the Store lifetime, including closed windows.
@MainActor enum WidgetExporter {
    static let appGroupID = "5G96498KGJ.com.gaojiezou.rhythm"
    static let widgetKind = "com.gaojiezou.rhythm.footprints.map"
    private static var observers: [NSObjectProtocol] = []
    private static var retry: Task<Void, Never>?
    private static var failures = 0
    static var containerURL: URL? {
        try? FootprintsIntegratedStorage.widgetDirectory()
    }
    static func start(store: Store) {
        guard observers.isEmpty else { return }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.willTerminateNotification,
                     NSNotification.Name.NSSystemTimeZoneDidChange, NSNotification.Name.NSCalendarDayChanged,
                     NSNotification.Name("NSSystemClockDidChangeNotification")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak store] _ in
                MainActor.assumeIsolated { if let store { publish(store: store) } }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak store] _ in
            MainActor.assumeIsolated { if let store { publish(store: store) } }
        })
        publish(store: store)
    }
    /// Compare source content and installed version, never file age alone.
    static func publish(store: Store, onlyIfStale: Bool = false) {
        retry?.cancel(); retry = nil
        guard store.ready else { status(store: store, pending: true, code: "source_unavailable"); return }
        do {
            guard let root = containerURL else { throw WidgetPublicationFailure.containerUnavailable }
            status(store: store, pending: true, code: "publishing")
            let changed = try RhythmIntegrationPaths.withWriterLease {
                guard let repository = store.repo else { throw WidgetPublicationFailure.containerUnavailable }
                try repository.requireWritableAuthority()
                return try WidgetPublisherCore.publish(journal: store.journal, geography: store.geography, root: root,
                    appVersion: FootprintsBundle.bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    appBuild: FootprintsBundle.bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
            }
            failures = 0
            status(store: store, pending: false, code: changed ? "published" : "current")
            if changed { WidgetCenter.shared.reloadTimelines(ofKind: widgetKind) }
        } catch {
            // A digest mismatch remains durable in SQLite versus the last good bundle,
            // even if a full disk also prevents writing this supplementary status file.
            status(store: store, pending: true, code: "publish_failed")
            let delays: [UInt64] = [30, 120, 600, 1800]
            let delay = delays[min(failures, delays.count - 1)]; failures += 1
            retry = Task { @MainActor [weak store] in
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
                guard !Task.isCancelled, let store else { return }
                retry = nil // Do not cancel the retry task that is currently publishing.
                publish(store: store)
            }
        }
    }
    private static func status(store: Store, pending: Bool, code: String) {
        store.widgetSyncStatus = pending ? tF("小组件等待同步", "Widget sync pending") : tF("小组件资料已同步", "Widget data synced")
        let report: [String: Any] = ["schema": 1, "pending": pending, "result": code,
            "attemptedAt": ISO8601DateFormatter().string(from: Date()),
            "sourceModifiedAt": store.ready ? ISO8601DateFormatter().string(from: store.journal.footprintModifiedAt ?? store.journal.modifiedAt) as Any : NSNull()]
        guard let root = store.repo?.root, let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
        try? RhythmIntegrationPaths.withWriterLease {
            guard let repository = store.repo else { throw WidgetPublicationFailure.containerUnavailable }
            try repository.requireWritableAuthority()
            try bytes.write(to: root.appendingPathComponent("widget-publication-status.json"), options: .atomic)
        }
    }
}
private enum WidgetPublicationFailure: Error { case containerUnavailable }
