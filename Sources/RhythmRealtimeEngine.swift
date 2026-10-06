import AppKit
import Combine
import Foundation
import OSLog

/// 实时结算引擎：1 秒计时器驱动的增量结算 + NSWorkspace 锁屏/睡眠监听。
///
/// 全部 @Published 状态仍住在 RhythmStore（门面）；引擎不持有业务状态，
/// 只通过回调通知 store 系统事件，并在计时循环里直接读写 store 的内部状态。
/// 这样 SwiftUI 的刷新路径保持单一（始终经由 store），不会因为拆出
/// 嵌套 ObservableObject 而丢失 objectWillChange 转发。
@MainActor
final class RhythmRealtimeEngine {
    /// 单次专注增量结算上限，防止崩溃或强杀后整段离线时长被计入。
    static let maximumFocusDeltaSeconds: TimeInterval = 8 * 3600
    /// 单次睡眠推动动物成长的封顶时长（实时与手动录入补结算共用）。
    static let sleepGrowthCapSeconds: TimeInterval = 14 * 3600
    /// 单次睡眠产出周期封顶（实时与手动录入补结算共用）。
    static let sleepProductionCycleCap = 2
    /// 实时结算的落盘节流间隔。
    static let realtimeSaveInterval: TimeInterval = 30

    private var workspaceObservers: [NSObjectProtocol] = []
    private var realtimeTimer: AnyCancellable?
    private var lastRealtimeSaveAt = Date.distantPast

    /// 每秒计时回调，参数为计时器触发时间。
    var tickHandler: (Date) -> Void = { _ in }
    /// 锁屏/熄屏/系统即将睡眠回调。
    var systemPauseHandler: () -> Void = {}
    /// 解锁/亮屏/唤醒回调。
    var systemResumeHandler: () -> Void = {}

    func start() {
        startRealtimeClock()
        observeWorkspaceState()
    }

    deinit {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        realtimeTimer?.cancel()
    }

    private func startRealtimeClock() {
        realtimeTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                Task { @MainActor in
                    self?.tickHandler(date)
                }
            }
    }

    private func observeWorkspaceState() {
        let center = NSWorkspace.shared.notificationCenter
        let pauseNames: [Notification.Name] = [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.willSleepNotification,
        ]
        let resumeNames: [Notification.Name] = [
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
        ]
        for name in pauseNames {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.systemPauseHandler() }
            })
        }
        for name in resumeNames {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.systemResumeHandler() }
            })
        }
    }

    /// 把当前计时已经经过、但尚未写入庄园的时长增量落到模型中。
    /// 此方法按增量结算，因此暂停、恢复、重启应用或手动结束都不会重复累计。
    func synchronizeRealtimeProgress(of store: RhythmStore, at date: Date = Date(), persist: Bool = false) {
        var changed = false

        if var focus = store.activeFocus {
            let elapsed = store.focusElapsed(at: date)
            let credited = max(0, focus.growthCreditedSeconds ?? 0)
            var deltaSeconds = max(0, elapsed - credited)
            if deltaSeconds > Self.maximumFocusDeltaSeconds {
                RhythmLog.store.warning("专注实时结算增量异常（\(deltaSeconds / 3600, privacy: .public) 小时），已按上限 8 小时截断")
                deltaSeconds = Self.maximumFocusDeltaSeconds
            }
            if deltaSeconds > 0 {
                let deltaMinutes = deltaSeconds / 60
                for index in store.farmPlots.indices {
                    guard let crop = RhythmCatalog.crop(store.farmPlots[index].cropID) else { continue }
                    let growth = deltaMinutes * (1 + store.farmPlots[index].nextFocusBoost)
                    store.farmPlots[index].growthMinutes = min(crop.growthMinutes, store.farmPlots[index].growthMinutes + growth)
                }
                focus.growthCreditedSeconds = elapsed
                store.activeFocus = focus
                changed = true
            }
        }

        if var sleep = store.activeSleep {
            let elapsedSeconds = store.sleepElapsed(at: date)
            let growthEligibleSeconds = min(Self.sleepGrowthCapSeconds, elapsedSeconds)
            let growthCredited = max(0, sleep.growthCreditedSeconds ?? 0)
            let growthDeltaSeconds = max(0, growthEligibleSeconds - growthCredited)
            if growthDeltaSeconds > 0 {
                let growthDeltaHours = growthDeltaSeconds / 3600
                for index in store.pastureAnimals.indices {
                    guard let animal = RhythmCatalog.animal(store.pastureAnimals[index].animalID) else { continue }
                    store.pastureAnimals[index].growthHours = min(
                        animal.maturitySleepHours,
                        store.pastureAnimals[index].growthHours + growthDeltaHours
                    )
                }
                sleep.growthCreditedSeconds = growthEligibleSeconds
                changed = true
            }

            let targetHours = max(1, sleep.targetHours ?? 8)
            let productionInterval = targetHours * 3600 / 2
            let eligibleCycles = min(Self.sleepProductionCycleCap, Int(elapsedSeconds / productionInterval))
            let creditedCycles = max(0, sleep.productionCyclesCredited ?? 0)
            let newCycles = max(0, eligibleCycles - creditedCycles)
            if newCycles > 0 {
                var newYield = 0
                for index in store.pastureAnimals.indices {
                    guard let animal = RhythmCatalog.animal(store.pastureAnimals[index].animalID),
                          store.pastureAnimals[index].growthHours >= animal.maturitySleepHours else { continue }
                    store.pastureAnimals[index].pendingProducts += newCycles
                    newYield += newCycles
                }
                sleep.productionCyclesCredited = eligibleCycles
                sleep.pastureYieldCredited = (sleep.pastureYieldCredited ?? 0) + newYield
                store.synchronizeAnimalSummaries()
                changed = true
            }

            store.activeSleep = sleep
        }

        if persist || (changed && date.timeIntervalSince(lastRealtimeSaveAt) >= Self.realtimeSaveInterval) {
            lastRealtimeSaveAt = date
            store.save()
        }
    }

    /// 手动录入睡眠的事后补结算：与实时结算同规则（成长封顶 14 小时、产出封顶
    /// 2 个周期，产出只发给补结算后已成年的动物）。记账写在记录的 manual 结算
    /// 字段上（health* 遗留字段只表示健康来源已结算的量，不混用），按增量结算，
    /// 因此重复调用或重新加载后再次调用都不会重复计入。
    /// 只修改内存状态，落盘由调用方收口。
    func settleManualSleep(of store: RhythmStore, recordID: String, targetHours: Double) {
        guard let index = store.sleepRecords.firstIndex(where: { $0.id == recordID }) else { return }
        var record = store.sleepRecords[index]
        let duration = max(0, record.durationSeconds)

        let growthEligibleSeconds = min(Self.sleepGrowthCapSeconds, duration)
        let growthCredited = max(0, record.manualGrowthCreditedSeconds ?? 0)
        let growthDeltaSeconds = max(0, growthEligibleSeconds - growthCredited)
        if growthDeltaSeconds > 0 {
            let growthDeltaHours = growthDeltaSeconds / 3600
            for animalIndex in store.pastureAnimals.indices {
                guard let animal = RhythmCatalog.animal(store.pastureAnimals[animalIndex].animalID) else { continue }
                store.pastureAnimals[animalIndex].growthHours = min(
                    animal.maturitySleepHours,
                    store.pastureAnimals[animalIndex].growthHours + growthDeltaHours
                )
            }
            record.manualGrowthCreditedSeconds = growthEligibleSeconds
        }

        let productionInterval = max(1, targetHours) * 3600 / 2
        let eligibleCycles = min(Self.sleepProductionCycleCap, Int(duration / productionInterval))
        let creditedCycles = max(0, record.manualProductionCreditedCycles ?? 0)
        let newCycles = max(0, eligibleCycles - creditedCycles)
        if newCycles > 0 {
            var newYield = 0
            for animalIndex in store.pastureAnimals.indices {
                guard let animal = RhythmCatalog.animal(store.pastureAnimals[animalIndex].animalID),
                      store.pastureAnimals[animalIndex].growthHours >= animal.maturitySleepHours else { continue }
                store.pastureAnimals[animalIndex].pendingProducts += newCycles
                newYield += newCycles
            }
            record.manualProductionCreditedCycles = eligibleCycles
            record.pastureYield += newYield
        }

        store.sleepRecords[index] = record
        store.synchronizeAnimalSummaries()
    }
}
