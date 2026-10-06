import Combine
import Foundation
import OSLog
#if canImport(WidgetKit)
import WidgetKit
#endif

enum RhythmStoreError: LocalizedError {
    /// 备份由更新版本的应用生成；旧版应用恢复会静默丢字段，因此拒绝。
    case backupFromNewerVersion(found: Int)

    var errorDescription: String? {
        switch self {
        case .backupFromNewerVersion(let found):
            RhythmLocalization.format("备份由更新版本的应用生成（数据版本 %d），请升级搞节奏后再恢复。", found)
        }
    }
}

/// 对外门面：全部 @Published 状态与视图/测试使用的 API 都保留在这里。
/// 实现按职责委托给三个无状态协作者（SwiftUI 刷新路径因此不受影响）：
/// - `RhythmPersistence`：文件读写、原子保存、损坏隔离、版本迁移
/// - `RhythmRealtimeEngine`：1 秒计时器实时结算、系统锁屏/睡眠监听
/// - `RhythmEstateEngine`：农场/牧场/渔场/水族馆的经济事务
@MainActor
final class RhythmStore: ObservableObject {
    @Published var habits: [Habit] = []
    @Published var chores: [Chore] = []
    @Published var habitCompletionKeys: Set<String> = []
    @Published var habitRewardKeys: Set<String> = []
    @Published var activeFocus: ActiveFocus?
    @Published var focusRecords: [FocusRecord] = []
    @Published var activeSleep: ActiveSleep?
    @Published var sleepRecords: [SleepRecord] = []
    @Published var longGoals: [LongGoal] = []
    @Published var shortActions: [ShortAction] = []
    @Published var coins = 0
    @Published var bait = 0
    @Published var farmPlots: [FarmPlot] = []
    @Published var ownedAnimals: [OwnedAnimal] = []
    @Published var pastureAnimals: [PastureAnimal] = []
    @Published var animalShelterCapacity = 1
    @Published var fishInventory: [String: Int] = [:]
    @Published var fishCaught: [String: Int] = [:]
    @Published var aquariumFish: [AquariumFish] = []
    @Published var harvestedCrops: [String: Int] = [:]
    @Published var rewardEvents: [RewardEvent] = []
    @Published var decorations: [OwnedDecoration] = []
    @Published var notice: String?

    let aquariumCapacity = RhythmEconomy.aquariumCapacity

    private let persistence = RhythmPersistence()
    @Published private(set) var loadFailed=false
    private let realtimeEngine = RhythmRealtimeEngine()
    private let estateEngine = RhythmEstateEngine()

    private var lastWidgetReloadAt = Date.distantPast
    /// 小组件关心的数据（打卡/琐事/专注/睡眠/长期目标/短期行动）自上次
    /// 时间线重载以来是否发生过变更；纯游戏数值（农场/牧场/渔场）不置位。
    private var widgetDirty = false

    /// 存在进行中的专注或睡眠时，给小组件补充重载的节流间隔。
    private static let widgetActiveSessionReloadInterval: TimeInterval = 5 * 60
    /// 单条专注记录时长的告警阈值（只记日志，不截断记录本身）。
    private static let focusRecordWarningSeconds: TimeInterval = 24 * 3600

    init() {
        load()
        realtimeEngine.tickHandler = { [weak self] date in
            self?.synchronizeRealtimeProgress(at: date)
        }
        realtimeEngine.systemPauseHandler = { [weak self] in
            self?.pauseFocus(forSystem: true)
        }
        realtimeEngine.systemResumeHandler = { [weak self] in
            guard let self, self.activeFocus?.pausedForSystem == true else { return }
            self.resumeFocus()
        }
        realtimeEngine.start()
    }

    // MARK: - 持久化（委托 RhythmPersistence）

    private func load() {
        switch persistence.load() {
        case .loaded(let library):
            apply(library)
            if activeFocus?.segmentStartedAt != nil {
                pauseFocus()
            } else {
                synchronizeRealtimeProgress(at: Date(), persist: true)
            }
        case .missing:
            apply(.starter())
        case .corrupted(let quarantinedPath):
            loadFailed=true
            apply(.starter())
            if let quarantinedPath {
                notice = RhythmLocalization.format("资料库无法读取，已暂停写入。请从备份恢复。原始文件保留在：%@", quarantinedPath)
            } else {
                notice = RhythmLocalization.text("本地数据文件损坏，且保留副本失败。已使用初始模板重新启动，原始文件仍位于数据目录中。")
            }
        }
    }

    @discardableResult
    func save() -> Bool {
        guard !loadFailed else { return false }
        do {
            try persistence.write(snapshot())
            // widgetDirty 会在下方小组件重载后被清掉，先捕获供打卡提醒判断。
            let widgetDataChanged = widgetDirty
#if canImport(WidgetKit) && !SMOKE_TEST
            let now = Date()
            let hasActiveSession = activeFocus != nil || activeSleep != nil
            let activeSessionNeedsRefresh = hasActiveSession
                && now.timeIntervalSince(lastWidgetReloadAt) >= Self.widgetActiveSessionReloadInterval
            if widgetDirty || activeSessionNeedsRefresh {
                WidgetCenter.shared.reloadAllTimelines()
                lastWidgetReloadAt = now
                widgetDirty = false
            }
#endif
            // 打卡相关数据（widgetDirty 覆盖打卡/琐事/专注/睡眠/目标/行动）变化后重排每日打卡提醒。
            // store 是 @MainActor，调用同步收口在主线程；非 .app 环境下 RhythmNotifications 内部空转。
            if widgetDataChanged {
                RhythmNotifications.rescheduleDailyHabitReminder(pendingCount: pendingHabitCountToday)
            }
            return true
        } catch {
            RhythmLog.data.error("本地数据保存失败：\(error.localizedDescription, privacy: .public)")
            notice = RhythmLocalization.format("本地数据保存失败：%@", error.localizedDescription)
            return false
        }
    }

    func backupData() throws -> Data {
        try persistence.encoder.encode(snapshot())
    }

    func restore(from data: Data) throws {
        let decoded: RhythmLibrary
        do {
            decoded = try persistence.decoder.decode(RhythmLibrary.self, from: data)
        } catch {
            RhythmLog.data.error("备份文件解码失败：\(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard decoded.version <= RhythmEconomy.schemaVersion else {
            RhythmLog.data.error("拒绝恢复数据版本 \(decoded.version) 的备份，当前应用支持版本 \(RhythmEconomy.schemaVersion)")
            throw RhythmStoreError.backupFromNewerVersion(found: decoded.version)
        }
        let library = persistence.migratedLibrary(decoded)
        try persistence.write(library)
        try persistence.clearFailureMarker()
        loadFailed=false
        apply(library)
        widgetDirty = true
        guard save() else { throw CocoaError(.fileWriteUnknown) }
        notice = RhythmLocalization.text("完整备份已经恢复。")
    }

    private func snapshot() -> RhythmLibrary {
        RhythmLibrary(
            version: RhythmEconomy.schemaVersion,
            habits: habits,
            habitCompletionKeys: habitCompletionKeys,
            habitRewardKeys: habitRewardKeys,
            activeFocus: activeFocus,
            focusRecords: focusRecords,
            activeSleep: activeSleep,
            sleepRecords: sleepRecords,
            longGoals: longGoals,
            shortActions: shortActions,
            coins: coins,
            bait: bait,
            farmPlots: farmPlots,
            pastureAnimals: pastureAnimals,
            animalShelterCapacity: animalShelterCapacity,
            fishInventory: fishInventory,
            fishCaught: fishCaught,
            aquariumFish: aquariumFish,
            harvestedCrops: harvestedCrops,
            rewardEvents: rewardEvents,
            chores: chores,
            decorations: decorations
        )
    }

    private func apply(_ library: RhythmLibrary) {
        habits = library.habits
        chores = library.chores ?? []
        habitCompletionKeys = library.habitCompletionKeys
        habitRewardKeys = library.habitRewardKeys
        activeFocus = library.activeFocus
        focusRecords = library.focusRecords.sorted { $0.endedAt > $1.endedAt }
        activeSleep = library.activeSleep
        sleepRecords = library.sleepRecords.sorted { $0.endedAt > $1.endedAt }
        longGoals = library.longGoals
        shortActions = library.shortActions
        coins = library.coins
        bait = library.bait
        farmPlots = library.farmPlots
        pastureAnimals = library.pastureAnimals ?? []
        // ownedAnimals 是派生状态（不再持久化）：无论存档里带的是什么，都无条件重建。
        synchronizeAnimalSummaries()
        animalShelterCapacity = max(
            library.animalShelterCapacity ?? max(1, pastureAnimals.count),
            pastureAnimals.count
        )
        fishInventory = library.fishInventory
        fishCaught = library.fishCaught
        aquariumFish = library.aquariumFish ?? []
        harvestedCrops = library.harvestedCrops
        rewardEvents = Array(library.rewardEvents.sorted { $0.date > $1.date }.prefix(300))
        decorations = library.decorations
    }

    /// 由 pastureAnimals 重建 ownedAnimals 汇总（ownedAnimals 的唯一事实源）。
    func synchronizeAnimalSummaries() {
        var order: [String] = []
        var countByID: [String: Int] = [:]
        var productsByID: [String: Int] = [:]
        for animal in pastureAnimals {
            if countByID[animal.animalID] == nil { order.append(animal.animalID) }
            countByID[animal.animalID, default: 0] += 1
            productsByID[animal.animalID, default: 0] += animal.pendingProducts
        }
        ownedAnimals = order.map { animalID in
            OwnedAnimal(
                id: animalID,
                animalID: animalID,
                count: countByID[animalID, default: 0],
                pendingProducts: productsByID[animalID, default: 0]
            )
        }
    }

    // MARK: - Chores

    func saveChore(_ chore: Chore) {
        var updated = chore
        updated.title = chore.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.title.isEmpty, updated.endDate >= updated.startDate else { return }
        if updated.colorHex == nil {
            let existingIndex = chores.firstIndex(where: { $0.id == chore.id }) ?? chores.count
            updated.colorHex = RhythmTheme.choreColors[existingIndex % RhythmTheme.choreColors.count].hex
        }
        if let index = chores.firstIndex(where: { $0.id == chore.id }) {
            updated.createdAt = chores[index].createdAt
            updated.isCompleted = chores[index].isCompleted
            updated.rewardClaimed = chores[index].rewardClaimed
            updated.completedAt = chores[index].completedAt
            chores[index] = updated
        } else {
            updated.createdAt = Date()
            chores.append(updated)
        }
        widgetDirty = true
        save()
    }

    func toggleChore(_ id: String) {
        guard let index = chores.firstIndex(where: { $0.id == id }) else { return }
        chores[index].isCompleted.toggle()
        chores[index].completedAt = chores[index].isCompleted ? Date() : nil
        if chores[index].isCompleted && !chores[index].rewardClaimed {
            chores[index].rewardClaimed = true
            coins += RhythmEconomy.choreCoins
            addReward(
                title: RhythmLocalization.text("完成琐事"),
                detail: chores[index].title,
                coins: RhythmEconomy.choreCoins,
                symbol: "tray.full.fill"
            )
        }
        widgetDirty = true
        save()
    }

    func deleteChore(_ id: String) {
        chores.removeAll { $0.id == id }
        widgetDirty = true
        save()
    }

    // MARK: - Habits

    /// 今天安排了但尚未完成的打卡数量，用于每日打卡提醒文案与设置页展示。
    var pendingHabitCountToday: Int {
        let today = Date()
        return habits(for: today).filter { !isHabitCompleted($0, on: today) }.count
    }

    func habits(for date: Date, unfinishedFirst: Bool = false) -> [Habit] {
        let scheduled = habits.filter { $0.isScheduled(on: date) }
        guard unfinishedFirst else { return scheduled }

        return scheduled.enumerated().sorted { lhs, rhs in
            let lhsCompleted = isHabitCompleted(lhs.element, on: date)
            let rhsCompleted = isHabitCompleted(rhs.element, on: date)
            if lhsCompleted != rhsCompleted {
                return !lhsCompleted
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    func isHabitCompleted(_ habit: Habit, on date: Date = Date()) -> Bool {
        habitCompletionKeys.contains(RhythmShared.habitKey(habitID: habit.id, date: date))
    }

    func toggleHabit(_ habit: Habit, on date: Date = Date()) {
        let key = RhythmShared.habitKey(habitID: habit.id, date: date)
        if habitCompletionKeys.contains(key) {
            habitCompletionKeys.remove(key)
        } else {
            habitCompletionKeys.insert(key)
            if !habitRewardKeys.contains(key) {
                habitRewardKeys.insert(key)
                coins += habit.rewardCoins
                addReward(
                    title: RhythmLocalization.text("完成日常打卡"),
                    detail: RhythmLocalization.format("“%@”为庄园带来了 %d 金币。", habit.title, habit.rewardCoins),
                    coins: habit.rewardCoins,
                    symbol: habit.symbol
                )
            }
        }
        widgetDirty = true
        save()
    }

    func saveHabit(existingID: String?, title: String, symbol: String, weekdays: Set<Int>, rewardCoins: Int) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        if let existingID, let index = habits.firstIndex(where: { $0.id == existingID }) {
            habits[index].title = cleanTitle
            habits[index].symbol = symbol
            habits[index].weekdays = weekdays
            habits[index].rewardCoins = max(RhythmEconomy.habitRewardRange.lowerBound, min(RhythmEconomy.habitRewardRange.upperBound, rewardCoins))
        } else {
            habits.append(Habit(
                id: UUID().uuidString,
                title: cleanTitle,
                symbol: symbol,
                weekdays: weekdays.isEmpty ? Set(1...7) : weekdays,
                rewardCoins: max(RhythmEconomy.habitRewardRange.lowerBound, min(RhythmEconomy.habitRewardRange.upperBound, rewardCoins)),
                createdAt: Date()
            ))
        }
        widgetDirty = true
        save()
    }

    func deleteHabit(_ habit: Habit) {
        habits.removeAll { $0.id == habit.id }
        widgetDirty = true
        save()
    }

    /// 逐日打卡汇总（已安排数/已完成数），供数据统计页与连续打卡口径使用。
    /// 起点取最早的打卡创建日期；没有打卡目标时返回空数组。
    func habitDaySummaries(until today: Date = Date(), calendar: Calendar = .current) -> [(date: Date, scheduled: Int, completed: Int)] {
        guard let earliest = habits.map({ calendar.startOfDay(for: $0.createdAt) }).min() else { return [] }
        let todayStart = calendar.startOfDay(for: today)
        guard earliest <= todayStart else { return [] }
        var result: [(date: Date, scheduled: Int, completed: Int)] = []
        var day = earliest
        while day <= todayStart {
            let scheduled = habits.filter { $0.isScheduled(on: day, calendar: calendar) }
            let completed = scheduled.filter { isHabitCompleted($0, on: day) }.count
            result.append((date: day, scheduled: scheduled.count, completed: completed))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// 连续打卡：当前连续与历史最长（口径见 RhythmShared.habitStreaks）。
    func habitStreaks(today: Date = Date()) -> (current: Int, longest: Int) {
        RhythmShared.habitStreaks(days: habitDaySummaries(until: today), today: today)
    }

    // MARK: - Focus

    func focusElapsed(at date: Date = Date()) -> TimeInterval {
        guard let focus = activeFocus else { return 0 }
        let running = focus.segmentStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return focus.accumulatedSeconds + running
    }

    /// 作物成长值会由实时计时器逐秒写入；读取时只返回已经生效的状态。
    func farmGrowthMinutes(for plot: FarmPlot, at date: Date = Date()) -> Double {
        plot.growthMinutes
    }

    func farmGrowthProgress(for plot: FarmPlot, at date: Date = Date()) -> Double {
        guard let crop = RhythmCatalog.crop(plot.cropID), crop.growthMinutes > 0 else { return 0 }
        return min(1, max(0, farmGrowthMinutes(for: plot, at: date) / crop.growthMinutes))
    }

    func farmMaturityRemainingSeconds(for plot: FarmPlot) -> TimeInterval {
        guard let crop = RhythmCatalog.crop(plot.cropID) else { return 0 }
        let remainingMinutes = max(0, crop.growthMinutes - plot.growthMinutes)
        let multiplier = max(0.01, 1 + plot.nextFocusBoost)
        return remainingMinutes / multiplier * 60
    }

    func focusDisplayTitle(linkedActionID: String?) -> String {
        guard let linkedActionID,
              let action = shortActions.first(where: { $0.id == linkedActionID })
        else { return RhythmLocalization.text("其他事件") }
        return action.title
    }

    func startFocus(linkedActionID: String?) {
        guard activeFocus == nil, activeSleep == nil else {
            notice = RhythmLocalization.text("同一时间只能运行一个专注或睡眠计时。")
            return
        }
        let linkedAction = linkedActionID.flatMap { actionID in
            shortActions.first(where: { $0.id == actionID })
        }
        let now = Date()
        activeFocus = ActiveFocus(
            id: UUID().uuidString,
            title: linkedAction?.title ?? RhythmLocalization.text("其他事件"),
            linkedActionID: linkedAction?.id,
            startedAt: now,
            accumulatedSeconds: 0,
            segmentStartedAt: now,
            pausedForSystem: false,
            growthCreditedSeconds: 0
        )
        widgetDirty = true
        save()
    }

    func pauseFocus(forSystem: Bool = false) {
        let now = Date()
        synchronizeRealtimeProgress(at: now)
        guard var focus = activeFocus, let segmentStart = focus.segmentStartedAt else { return }
        let segmentDelta = max(0, now.timeIntervalSince(segmentStart))
        if segmentDelta > RhythmRealtimeEngine.maximumFocusDeltaSeconds {
            RhythmLog.store.warning("暂停专注时发现异常分段时长 \(segmentDelta / 3600, privacy: .public) 小时，按上限 8 小时结算")
        }
        focus.accumulatedSeconds += min(segmentDelta, RhythmRealtimeEngine.maximumFocusDeltaSeconds)
        focus.segmentStartedAt = nil
        focus.pausedForSystem = forSystem
        focus.growthCreditedSeconds = focus.accumulatedSeconds
        activeFocus = focus
        widgetDirty = true
        save()
    }

    func resumeFocus() {
        guard var focus = activeFocus, focus.segmentStartedAt == nil, activeSleep == nil else { return }
        focus.segmentStartedAt = Date()
        focus.pausedForSystem = false
        activeFocus = focus
        widgetDirty = true
        save()
    }

    func finishFocus() {
        let now = Date()
        synchronizeRealtimeProgress(at: now)
        guard let focus = activeFocus else { return }
        let duration = focusElapsed(at: now)
        if duration > Self.focusRecordWarningSeconds {
            RhythmLog.store.warning("生成超过 24 小时的专注记录（\(duration / 3600, privacy: .public) 小时），记录保留但请确认计时是否异常")
        }
        let earned = min(
            RhythmEconomy.focusSessionCoinCap,
            Int(duration / Double(RhythmEconomy.focusMinutesPerCoin * 60))
        )
        let record = FocusRecord(
            id: focus.id,
            title: focus.title,
            linkedActionID: focus.linkedActionID,
            startedAt: focus.startedAt,
            endedAt: now,
            durationSeconds: duration,
            earnedCoins: earned
        )
        focusRecords.insert(record, at: 0)
        activeFocus = nil

        if let actionID = focus.linkedActionID,
           let index = shortActions.firstIndex(where: { $0.id == actionID }) {
            shortActions[index].focusedSeconds += duration
        }

        if duration > 0 {
            for index in farmPlots.indices where farmPlots[index].cropID != nil {
                farmPlots[index].nextFocusBoost = 0
            }
        }

        coins += earned
        addReward(
            title: RhythmLocalization.text("完成专注"),
            detail: RhythmLocalization.format("有效专注 %@，作物已实时获得成长。", RhythmFormatters.duration(duration, showSeconds: false)),
            coins: earned,
            symbol: "timer"
        )
        widgetDirty = true
        save()
    }

    func cancelFocus() {
        synchronizeRealtimeProgress(at: Date())
        if (activeFocus?.growthCreditedSeconds ?? 0) > 0 {
            for index in farmPlots.indices where farmPlots[index].cropID != nil {
                farmPlots[index].nextFocusBoost = 0
            }
        }
        activeFocus = nil
        widgetDirty = true
        save()
    }

    func focusSeconds(on date: Date) -> TimeInterval {
        RhythmShared.focusSecondsOn(
            records: focusRecords.map { (endedAt: $0.endedAt, durationSeconds: $0.durationSeconds) },
            active: activeFocus.map { (startedAt: $0.startedAt, accumulatedSeconds: $0.accumulatedSeconds, segmentStartedAt: $0.segmentStartedAt) },
            day: date
        )
    }

    /// 门面转发：实时结算由 RhythmRealtimeEngine 执行（1 秒计时器同样由它持有）。
    func synchronizeRealtimeProgress(at date: Date = Date(), persist: Bool = false) {
        realtimeEngine.synchronizeRealtimeProgress(of: self, at: date, persist: persist)
    }

    // MARK: - Sleep

    func sleepElapsed(at date: Date = Date()) -> TimeInterval {
        guard let sleep = activeSleep else { return 0 }
        return max(0, date.timeIntervalSince(sleep.startedAt))
    }

    /// 幼崽成长值会由实时计时器逐秒写入；读取时只返回已经生效的状态。
    func pastureGrowthHours(for resident: PastureAnimal, at date: Date = Date()) -> Double {
        guard let animal = RhythmCatalog.animal(resident.animalID) else { return resident.growthHours }
        return min(animal.maturitySleepHours, resident.growthHours)
    }

    func pastureGrowthProgress(for resident: PastureAnimal, at date: Date = Date()) -> Double {
        guard let animal = RhythmCatalog.animal(resident.animalID), animal.maturitySleepHours > 0 else { return 0 }
        return min(1, max(0, pastureGrowthHours(for: resident, at: date) / animal.maturitySleepHours))
    }

    func pastureProductionProgress(targetHours: Double, at date: Date = Date()) -> Double {
        guard let sleep = activeSleep else { return 0 }
        let interval = max(1, sleep.targetHours ?? targetHours) * 3600 / 2
        let cycles = max(0, sleep.productionCyclesCredited ?? 0)
        guard cycles < 2 else { return 1 }
        let elapsedInCycle = max(0, sleepElapsed(at: date) - Double(cycles) * interval)
        return min(1, elapsedInCycle / interval)
    }

    func pastureMaturityRemainingSeconds(for resident: PastureAnimal) -> TimeInterval {
        guard let animal = RhythmCatalog.animal(resident.animalID) else { return 0 }
        return max(0, animal.maturitySleepHours - resident.growthHours) * 3600
    }

    func pastureProductionRemainingSeconds(targetHours: Double, at date: Date = Date()) -> TimeInterval {
        guard let sleep = activeSleep else { return max(1, targetHours) * 3600 / 2 }
        let interval = max(1, sleep.targetHours ?? targetHours) * 3600 / 2
        let cycles = max(0, sleep.productionCyclesCredited ?? 0)
        guard cycles < 2 else { return 0 }
        let elapsedInCycle = max(0, sleepElapsed(at: date) - Double(cycles) * interval)
        return max(0, interval - elapsedInCycle)
    }

    func startSleep(at date: Date = Date(), targetHours: Double = 8) {
        guard activeSleep == nil, activeFocus == nil else {
            notice = RhythmLocalization.text("请先结束当前计时，再开始睡眠记录。")
            return
        }
        guard date <= Date(), targetHours.isFinite, targetHours > 0 else {
            notice = RhythmLocalization.text("开始时间不能晚于现在，睡眠目标必须大于零。")
            return
        }
        activeSleep = ActiveSleep(
            id: UUID().uuidString,
            startedAt: date,
            targetHours: max(1, targetHours),
            growthCreditedSeconds: 0,
            productionCyclesCredited: 0,
            pastureYieldCredited: 0
        )
        synchronizeRealtimeProgress(at: Date(), persist: true)
        widgetDirty = true
        save()
    }

    func finishSleep(at date: Date = Date(), targetHours: Double) {
        guard let existing = activeSleep, date >= existing.startedAt else { return }
        synchronizeRealtimeProgress(at: date)
        guard let sleep = activeSleep else { return }
        let duration = max(0, date.timeIntervalSince(sleep.startedAt))
        let hours = duration / 3600
        let sessionTarget = max(1, sleep.targetHours ?? targetHours)
        let score = max(0, min(100, Int(100 - abs(hours - sessionTarget) * 18)))
        let yield = sleep.pastureYieldCredited ?? 0
        synchronizeAnimalSummaries()
        sleepRecords.insert(SleepRecord(
            id: sleep.id,
            startedAt: sleep.startedAt,
            endedAt: date,
            durationSeconds: duration,
            score: score,
            pastureYield: yield
        ), at: 0)
        activeSleep = nil
        addReward(
            title: RhythmLocalization.text("完成睡眠记录"),
            detail: RhythmLocalization.format("记录了 %@，成长与 %d 份牧场产物均已实时保存。", RhythmFormatters.duration(duration, showSeconds: false), yield),
            coins: 0,
            symbol: "moon.stars.fill"
        )
        widgetDirty = true
        if save() {
            NotificationCenter.default.post(name: Notification.Name("GaoSeries.rhythm.sleepSaved"), object:nil)
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("GaoSeries.rhythm.sleepSaved"), object:nil, userInfo:nil, deliverImmediately:true)
        }
    }

    func cancelSleep() {
        synchronizeRealtimeProgress(at: Date())
        activeSleep = nil
        widgetDirty = true
        save()
    }

    /// 手动录入睡眠的明确结果（与 EstateActionResult/DecorationResult 同模式），
    /// 视图层据此映射文案，不再比较记录数前后推断成败。
    enum ManualSleepResult: Equatable {
        /// 录入成功，score 为按录入时睡眠目标计算的评分。
        case added(score: Int)
        /// 起床时间不晚于就寝时间。
        case invalidRange
        /// 时长不在 0.5–24 小时之间。
        case invalidDuration
        /// 已有起止时间完全相同（误差 1 分钟内）的记录。
        case duplicate
    }

    /// 手动录入一条已完成的睡眠（用户在 Apple Watch 等其他软件里计时，只把结果记进来）。
    /// 评分沿用计时结束公式，目标取调用方传入的录入时设置值；录入成功后按
    /// 实时结算同规则为这条记录补一次牧场成长与产出（记账在记录的 manual 字段上）。
    @discardableResult
    func addManualSleep(start: Date, end: Date, targetHours: Double = 8) -> ManualSleepResult {
        guard end > start else { return .invalidRange }
        let duration = end.timeIntervalSince(start)
        guard (0.5 * 3600 ... 24 * 3600).contains(duration) else { return .invalidDuration }
        let isDuplicate = sleepRecords.contains {
            abs($0.startedAt.timeIntervalSince(start)) < 60 && abs($0.endedAt.timeIntervalSince(end)) < 60
        }
        guard !isDuplicate else { return .duplicate }

        let sessionTarget = max(1, targetHours)
        let hours = duration / 3600
        let score = max(0, min(100, Int(100 - abs(hours - sessionTarget) * 18)))
        let record = SleepRecord(
            id: UUID().uuidString,
            startedAt: start,
            endedAt: end,
            durationSeconds: duration,
            score: score,
            pastureYield: 0,
            manualEntry: true,
            manualGrowthCreditedSeconds: 0,
            manualProductionCreditedCycles: 0
        )
        sleepRecords.insert(record, at: 0)
        // 手动记录可以落在过去任意夜晚，insert(0) 会破坏 endedAt 倒序约定，重排保持一致。
        sleepRecords.sort { $0.endedAt > $1.endedAt }
        settleManualSleep(recordID: record.id, targetHours: sessionTarget)
        let yield = sleepRecords.first { $0.id == record.id }?.pastureYield ?? 0
        addReward(
            title: RhythmLocalization.text("手动录入睡眠记录"),
            detail: RhythmLocalization.format("记录了 %@，牧场成长与 %d 份产物已补结算。", RhythmFormatters.duration(duration, showSeconds: false), yield),
            coins: 0,
            symbol: "moon.stars.fill"
        )
        widgetDirty = true
        if save() {
            NotificationCenter.default.post(name: Notification.Name("GaoSeries.rhythm.sleepSaved"), object:nil)
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("GaoSeries.rhythm.sleepSaved"), object:nil, userInfo:nil, deliverImmediately:true)
        }
        return .added(score: score)
    }

    /// 门面转发：手动录入的牧场补结算由 RhythmRealtimeEngine 执行。
    /// 按记录的 manual 结算字段增量记账，重复调用幂等（不会重复计入成长与产出）。
    func settleManualSleep(recordID: String, targetHours: Double) {
        realtimeEngine.settleManualSleep(of: self, recordID: recordID, targetHours: targetHours)
    }

    func sleepSeconds(on date: Date) -> TimeInterval {
        lastNightSleepDuration(on: date) ?? 0
    }

    func lastNightSleepDuration(on date: Date) -> TimeInterval? {
        RhythmShared.lastNightSleepDuration(
            records: sleepRecords.map {
                (startedAt: $0.startedAt, endedAt: $0.endedAt,
                 durationSeconds: $0.durationSeconds, isHealthSource: $0.healthSource != nil)
            },
            on: date
        )
    }

    // MARK: - Goals and actions

    func actions(for goalID: String) -> [ShortAction] {
        shortActions.filter { $0.goalID == goalID }
    }

    func goalProgress(_ goal: LongGoal) -> Double {
        let metricProgress = goal.targetValue > 0 ? min(1, max(0, goal.currentValue / goal.targetValue)) : 0
        let children = actions(for: goal.id)
        let actionProgress = children.isEmpty ? 0 : Double(children.filter(\.isCompleted).count) / Double(children.count)
        return max(metricProgress, actionProgress)
    }

    func saveGoal(
        existingID: String?,
        title: String,
        reason: String,
        outcome: String,
        targetValue: Double,
        currentValue: Double,
        unit: String,
        startDate: Date,
        targetDate: Date,
        status: GoalStatus
    ) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        if let existingID, let index = longGoals.firstIndex(where: { $0.id == existingID }) {
            longGoals[index].title = cleanTitle
            longGoals[index].reason = reason
            longGoals[index].outcome = outcome
            longGoals[index].targetValue = max(0, targetValue)
            longGoals[index].currentValue = max(0, currentValue)
            longGoals[index].unit = unit
            longGoals[index].startDate = startDate
            longGoals[index].targetDate = max(startDate, targetDate)
            let oldStatus = longGoals[index].status
            longGoals[index].status = status
            if status == .completed && oldStatus != .completed {
                claimGoalReward(at: index)
            }
        } else {
            var goal = LongGoal(
                id: UUID().uuidString,
                title: cleanTitle,
                reason: reason,
                outcome: outcome,
                targetValue: max(0, targetValue),
                currentValue: max(0, currentValue),
                unit: unit,
                startDate: startDate,
                targetDate: max(startDate, targetDate),
                status: status,
                rewardClaimed: false,
                createdAt: Date()
            )
            longGoals.append(goal)
            if status == .completed, let index = longGoals.firstIndex(where: { $0.id == goal.id }) {
                claimGoalReward(at: index)
                goal = longGoals[index]
            }
        }
        widgetDirty = true
        save()
    }

    func setGoalStatus(_ goal: LongGoal, status: GoalStatus) {
        guard let index = longGoals.firstIndex(where: { $0.id == goal.id }) else { return }
        longGoals[index].status = status
        if status == .completed { claimGoalReward(at: index) }
        widgetDirty = true
        save()
    }

    private func claimGoalReward(at index: Int) {
        guard !longGoals[index].rewardClaimed else { return }
        longGoals[index].rewardClaimed = true
        bait += RhythmEconomy.longGoalBait
        coins += RhythmEconomy.longGoalCoins
        addReward(
            title: RhythmLocalization.text("长期目标完成"),
            detail: RhythmLocalization.format("获得 %d 金币和 %d 个鱼饵。", RhythmEconomy.longGoalCoins, RhythmEconomy.longGoalBait),
            coins: RhythmEconomy.longGoalCoins,
            symbol: "flag.checkered"
        )
    }

    func deleteGoal(_ goal: LongGoal) {
        longGoals.removeAll { $0.id == goal.id }
        for index in shortActions.indices where shortActions[index].goalID == goal.id {
            shortActions[index].goalID = nil
        }
        widgetDirty = true
        save()
    }

    func saveAction(
        existingID: String?,
        goalID: String?,
        title: String,
        notes: String,
        startDate: Date?,
        endDate: Date?,
        estimatedMinutes: Int,
        isCompleted: Bool
    ) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        if let existingID, let index = shortActions.firstIndex(where: { $0.id == existingID }) {
            shortActions[index].goalID = goalID
            shortActions[index].title = cleanTitle
            shortActions[index].notes = notes
            shortActions[index].startDate = startDate
            shortActions[index].endDate = startDate.map { max($0, endDate ?? $0) }
            shortActions[index].estimatedMinutes = max(1, estimatedMinutes)
            if shortActions[index].isCompleted != isCompleted {
                completeAction(at: index, completed: isCompleted)
            }
        } else {
            let action = ShortAction(
                id: UUID().uuidString,
                goalID: goalID,
                title: cleanTitle,
                notes: notes,
                dueDate: endDate ?? startDate ?? Date(),
                startDate: startDate,
                endDate: startDate.map { max($0, endDate ?? $0) },
                estimatedMinutes: max(1, estimatedMinutes),
                focusedSeconds: 0,
                isCompleted: false,
                rewardClaimed: false,
                createdAt: Date(),
                completedAt: nil
            )
            shortActions.append(action)
            if isCompleted, let index = shortActions.firstIndex(where: { $0.id == action.id }) {
                completeAction(at: index, completed: true)
            }
        }
        widgetDirty = true
        save()
    }

    func toggleAction(_ action: ShortAction) {
        guard let index = shortActions.firstIndex(where: { $0.id == action.id }) else { return }
        completeAction(at: index, completed: !shortActions[index].isCompleted)
        widgetDirty = true
        save()
    }

    private func completeAction(at index: Int, completed: Bool) {
        shortActions[index].isCompleted = completed
        shortActions[index].completedAt = completed ? Date() : nil
        if completed && !shortActions[index].rewardClaimed {
            shortActions[index].rewardClaimed = true
            bait += RhythmEconomy.shortActionBait
            coins += RhythmEconomy.shortActionCoins
            addReward(
                title: RhythmLocalization.text("完成短期行动"),
                detail: RhythmLocalization.format("“%@”带来了 %d 金币和 %d 个鱼饵。", shortActions[index].title, RhythmEconomy.shortActionCoins, RhythmEconomy.shortActionBait),
                coins: RhythmEconomy.shortActionCoins,
                symbol: "checkmark.circle.fill"
            )
        }
    }

    func deleteAction(_ action: ShortAction) {
        shortActions.removeAll { $0.id == action.id }
        widgetDirty = true
        save()
    }

    // MARK: - Estate（门面转发给 RhythmEstateEngine）

    @discardableResult
    func plant(cropID: String, in plotID: String) -> RhythmEstateEngine.EstateActionResult {
        estateEngine.plant(self, cropID: cropID, in: plotID)
    }

    @discardableResult
    func buyFarmPlot() -> RhythmEstateEngine.EstateActionResult {
        estateEngine.buyFarmPlot(self)
    }

    var nextPlotCost: Int {
        estateEngine.nextPlotCost(of: self)
    }

    var occupiedAnimalShelters: Int {
        estateEngine.occupiedAnimalShelters(of: self)
    }

    var availableAnimalShelters: Int {
        estateEngine.availableAnimalShelters(of: self)
    }

    var nextAnimalShelterCost: Int {
        estateEngine.nextAnimalShelterCost(of: self)
    }

    @discardableResult
    func buildAnimalShelter() -> RhythmEstateEngine.EstateActionResult {
        estateEngine.buildAnimalShelter(self)
    }

    @discardableResult
    func water(plotID: String) -> RhythmEstateEngine.EstateActionResult {
        estateEngine.water(self, plotID: plotID)
    }

    @discardableResult
    func fertilize(plotID: String) -> RhythmEstateEngine.EstateActionResult {
        estateEngine.fertilize(self, plotID: plotID)
    }

    func harvest(plotID: String) {
        estateEngine.harvest(self, plotID: plotID)
    }

    @discardableResult
    func harvestAll() -> Int {
        estateEngine.harvestAll(self)
    }

    @discardableResult
    func buyAnimal(_ animalID: String) -> RhythmEstateEngine.EstateActionResult {
        estateEngine.buyAnimal(self, animalID)
    }

    func collectAnimalProducts(_ resident: PastureAnimal) {
        estateEngine.collectAnimalProducts(self, resident)
    }

    @discardableResult
    func collectAllAnimalProducts() -> Int {
        estateEngine.collectAllAnimalProducts(self)
    }

    func animalSaleValue(_ resident: PastureAnimal) -> Int {
        estateEngine.animalSaleValue(self, resident)
    }

    @discardableResult
    func sellPastureAnimal(id: String) -> Int {
        estateEngine.sellPastureAnimal(self, id: id)
    }

    func movePastureAnimal(fromID: String, beforeID: String) {
        estateEngine.movePastureAnimal(self, fromID: fromID, beforeID: beforeID)
    }

    func movePastureAnimal(fromID: String, toIndex: Int) {
        estateEngine.movePastureAnimal(self, fromID: fromID, toIndex: toIndex)
    }

    @discardableResult
    func goFishing() -> FishDefinition? {
        estateEngine.goFishing(self)
    }

    func sellFish(_ fishID: String) {
        estateEngine.sellFish(self, fishID)
    }

    /// 出售全部渔获，返回实际入账金币（0 表示鱼篓为空）。
    @discardableResult
    func sellAllFish() -> Int {
        estateEngine.sellAllFish(self)
    }

    @discardableResult
    func moveFishToAquarium(_ fishID: String, at date: Date = Date()) -> Bool {
        estateEngine.moveFishToAquarium(self, fishID, at: date)
    }

    @discardableResult
    func returnAquariumFish(id: String) -> Bool {
        estateEngine.returnAquariumFish(self, id: id)
    }

    func aquariumPendingIncome(at date: Date = Date()) -> Int {
        estateEngine.aquariumPendingIncome(self, at: date)
    }

    @discardableResult
    func collectAquariumIncome(at date: Date = Date()) -> Int {
        estateEngine.collectAquariumIncome(self, at: date)
    }

    // MARK: - 庄园装饰（纯展示，不影响小组件，无需置位 widgetDirty）

    func decorationStatus(definitionID: String) -> (owned: OwnedDecoration?, nextPrice: Int)? {
        estateEngine.decorationStatus(of: self, definitionID: definitionID)
    }

    @discardableResult
    func purchaseDecoration(definitionID: String) -> RhythmEstateEngine.DecorationResult {
        estateEngine.purchaseDecoration(self, definitionID: definitionID)
    }

    @discardableResult
    func upgradeDecoration(id: String) -> RhythmEstateEngine.DecorationResult {
        estateEngine.upgradeDecoration(self, id: id)
    }

    // MARK: - Diagnostics

    /// 生成纯文本诊断报告，供设置页导出。文件属性与日志读取全部降级处理，绝不抛出。
    func diagnosticReport() -> String {
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func stamp(_ date: Date?) -> String {
            date.map { timestampFormatter.string(from: $0) } ?? "未知"
        }

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = info?["CFBundleVersion"] as? String ?? "未知"

        var lines: [String] = []
        lines.append("搞节奏诊断信息")
        lines.append("生成时间：\(timestampFormatter.string(from: Date()))")
        lines.append("应用版本：\(version)（build \(build)）")
        lines.append("数据版本 schemaVersion：\(RhythmEconomy.schemaVersion)")
        lines.append("macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("")
        lines.append("记录条数：")
        lines.append("- 打卡目标：\(habits.count)")
        lines.append("- 琐事：\(chores.count)")
        lines.append("- 专注记录：\(focusRecords.count)")
        lines.append("- 睡眠记录：\(sleepRecords.count)")
        lines.append("- 长期目标：\(longGoals.count)")
        lines.append("- 短期行动：\(shortActions.count)")
        lines.append("- 金币：\(coins)")
        lines.append("- 鱼饵：\(bait)")
        lines.append("- 农田：\(farmPlots.count)")
        lines.append("- 牧场动物：\(pastureAnimals.count)")
        lines.append("- 鱼（鱼篓 + 水族馆）：\(fishInventory.values.reduce(0, +) + aquariumFish.count)")
        lines.append("")

        let fileManager = FileManager.default
        if let attributes = try? fileManager.attributesOfItem(atPath: persistence.libraryURL.path) {
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let modified = stamp(attributes[.modificationDate] as? Date)
            lines.append("library.json：\(size) 字节，最后修改 \(modified)")
        } else {
            lines.append("library.json：不存在或不可读")
        }
        if let mirrorURL = persistence.widgetSnapshotURL, fileManager.fileExists(atPath: mirrorURL.path) {
            let size = ((try? fileManager.attributesOfItem(atPath: mirrorURL.path))?[.size] as? NSNumber)?.intValue ?? 0
            lines.append("App Group 镜像：存在，\(size) 字节")
        } else {
            lines.append("App Group 镜像：不存在")
        }
        lines.append("")

        lines.append("当前 notice：\(notice ?? "无")")
        if let focus = activeFocus {
            let state = focus.segmentStartedAt == nil ? "已暂停" : "计时中"
            lines.append("进行中：专注「\(focus.title)」，\(state)，已累计 \(Int(focusElapsed() / 60)) 分钟")
        } else if let sleep = activeSleep {
            lines.append("进行中：睡眠，开始于 \(stamp(sleep.startedAt))，已计时 \(Int(sleepElapsed() / 60)) 分钟")
        } else {
            lines.append("进行中：无")
        }
        lines.append("")

        lines.append("最近 1 小时本进程日志（subsystem com.gaojiezou.rhythm）：")
        lines.append(recentLogText())
        return lines.joined(separator: "\n")
    }

    /// 读取最近 1 小时本进程 os_log；任何一步失败都降级为占位文字。
    private func recentLogText() -> String {
        guard let logStore = try? OSLogStore(scope: .currentProcessIdentifier) else { return "日志不可用" }
        let position = logStore.position(date: Date().addingTimeInterval(-3600))
        guard let entries = try? logStore.getEntries(at: position) else { return "日志不可用" }
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let lines = entries
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "com.gaojiezou.rhythm" }
            .suffix(200)
            .map { "\(timestampFormatter.string(from: $0.date)) [\($0.category)] \($0.composedMessage)" }
        return lines.isEmpty ? "最近 1 小时无日志" : lines.joined(separator: "\n")
    }

    /// 供门面内部与各引擎共用（庄园事务结算奖励、实时引擎间接触发）。
    func addReward(title: String, detail: String, coins: Int, symbol: String) {
        rewardEvents.insert(RewardEvent(
            id: UUID().uuidString,
            date: Date(),
            title: title,
            detail: detail,
            coins: coins,
            symbol: symbol
        ), at: 0)
        if rewardEvents.count > 300 {
            rewardEvents = Array(rewardEvents.prefix(300))
        }
    }
}
