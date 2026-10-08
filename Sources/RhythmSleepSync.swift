import AppKit
import Combine
import Foundation

/// The app keeps its own complete archive. Only completed sleep records use the
/// shared journal; neither app writes the other app's library or game state.
@MainActor
final class RhythmSleepSync {
    private var subscriptions: Set<AnyCancellable> = []
    private var shared: SharedSleepStore?

    var enabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["GAOSERIES_SLEEP_TEST_DIRECTORY"] != nil { return true }
#if SMOKE_TEST
        return false
#else
        return environment["GAOJIEZOU_DATA_DIR"] == nil
#endif
    }

    func start(synchronize: @escaping () -> Void) {
        guard enabled else { return }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in Task { @MainActor in synchronize() } }
            .store(in: &subscriptions)
        DistributedNotificationCenter.default().publisher(for: SharedSleepStore.changedNotification)
            .sink { _ in Task { @MainActor in synchronize() } }
            .store(in: &subscriptions)
        Timer.publish(every: 15, on: .main, in: .common).autoconnect()
            .sink { _ in Task { @MainActor in synchronize() } }
            .store(in: &subscriptions)
        synchronize()
    }

    private func database() throws -> SharedSleepStore {
        if let shared { return shared }
        let opened = try SharedSleepStore()
        shared = opened
        return opened
    }

    func records(seeding records: [SleepRecord]) throws -> [SharedSleepEntry] {
        let shared = try database()
        // Only the first upgrade may import overlapping historical IDs. New
        // locally queued records must use the same duplicate check as the UI.
        try shared.seedLegacyOnce(records.map(\.sharedSleepEntry), key: SharedSleepStore.legacyMigrationKey)
        let canonical = try shared.records()
        for record in records where !canonical.contains(where: { $0.id == record.id }) {
            var settlement = record
            if record.manualEntry != true && record.healthSource == nil {
                // Completed local timers have already settled in real time.
                // Their duplicate alias must not receive a manual settlement.
                settlement.manualGrowthCreditedSeconds = max(settlement.manualGrowthCreditedSeconds ?? 0,
                                                             min(record.durationSeconds, RhythmRealtimeEngine.sleepGrowthCapSeconds))
                settlement.manualProductionCreditedCycles = max(settlement.manualProductionCreditedCycles ?? 0,
                                                                RhythmRealtimeEngine.sleepProductionCycleCap)
            }
            // The winner lookup, receipt transfer and alias tombstone are one
            // transaction, including when another app deletes the winner.
            try shared.reconcilePending(record.sharedSleepEntry, settlement: settlement.sharedSleepEntry)
        }
        return try shared.records()
    }

    func publish(_ record: SleepRecord) throws {
        guard enabled else { return }
        try database().upsert(record.sharedSleepEntry)
    }

    func publishSettlement(_ record: SleepRecord) throws {
        try database().updateRhythmSettlement(record.sharedSleepEntry)
    }
}

extension SleepRecord {
    init(shared entry: SharedSleepEntry) {
        self.init(
            id: entry.id, startedAt: entry.startedAt, endedAt: entry.endedAt,
            durationSeconds: entry.durationSeconds, score: entry.score,
            pastureYield: entry.pastureYield,
            healthSource: entry.healthSource ?? (entry.origin == "health" ? "搞健康" : nil),
            healthGrowthCreditedSeconds: entry.healthGrowthCreditedSeconds,
            healthProductionCreditedCycles: entry.healthProductionCreditedCycles,
            manualEntry: entry.manualEntry,
            manualGrowthCreditedSeconds: entry.manualGrowthCreditedSeconds,
            manualProductionCreditedCycles: entry.manualProductionCreditedCycles
        )
    }

    var sharedSleepEntry: SharedSleepEntry {
        SharedSleepEntry(
            id: id, startedAt: startedAt, endedAt: endedAt,
            durationSeconds: durationSeconds, score: score, pastureYield: pastureYield,
            healthSource: healthSource,
            healthGrowthCreditedSeconds: healthGrowthCreditedSeconds,
            healthProductionCreditedCycles: healthProductionCreditedCycles,
            manualEntry: manualEntry,
            manualGrowthCreditedSeconds: manualGrowthCreditedSeconds,
            manualProductionCreditedCycles: manualProductionCreditedCycles,
            origin: healthSource == nil ? "rhythm" : "health"
        )
    }

    /// A save may have committed locally before the shared metadata update was
    /// interrupted. Keep its receipt so retrying cannot grant pasture rewards twice.
    mutating func preserveSettlement(from local: SleepRecord) {
        pastureYield = max(pastureYield, local.pastureYield)
        healthGrowthCreditedSeconds = maximum(healthGrowthCreditedSeconds, local.healthGrowthCreditedSeconds)
        healthProductionCreditedCycles = maximum(healthProductionCreditedCycles, local.healthProductionCreditedCycles)
        manualGrowthCreditedSeconds = maximum(manualGrowthCreditedSeconds, local.manualGrowthCreditedSeconds)
        manualProductionCreditedCycles = maximum(manualProductionCreditedCycles, local.manualProductionCreditedCycles)
    }

    func hasDifferentSettlement(from entry: SharedSleepEntry) -> Bool {
        pastureYield != entry.pastureYield ||
        healthGrowthCreditedSeconds != entry.healthGrowthCreditedSeconds ||
        healthProductionCreditedCycles != entry.healthProductionCreditedCycles ||
        manualGrowthCreditedSeconds != entry.manualGrowthCreditedSeconds ||
        manualProductionCreditedCycles != entry.manualProductionCreditedCycles
    }

    private func maximum<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
        switch (lhs, rhs) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }
}
