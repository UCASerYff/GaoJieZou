import Foundation
import SwiftUI

extension Notification.Name {
    /// 菜单栏快捷键（⌘1–⌘9、⌘0）请求切换侧栏板块；userInfo["section"] 携带 RhythmSection.rawValue。
    static let rhythmSelectSection = Notification.Name("rhythm.selectSection")
}

struct Chore: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var title = ""
    var startDate = Calendar.current.startOfDay(for: Date())
    var endDate = Calendar.current.startOfDay(for: Date())
    var isCompleted = false
    var rewardClaimed = false
    var completedAt: Date?
    /// Stored as a hex string so the color survives backups and older archives.
    /// Optional 兼容缺少该字段的旧存档；迁移时会补齐调色板颜色。
    var createdAt: Date? = nil
    var colorHex: String? = nil
}

enum RhythmSection: String, CaseIterable, Identifiable {
    case today
    case habits
    case chores
    case focus
    case sleep
    case statistics
    case longGoals
    case shortActions
    case farm
    case pasture
    case fishing
    case collection

    var id: String { rawValue }

    var title: String {
        let key = switch self {
        case .today: "今日总览"
        case .habits: "日常打卡"
        case .chores: "一些琐事"
        case .focus: "工作专注"
        case .sleep: "睡眠计时"
        case .statistics: "数据统计"
        case .longGoals: "长期目标"
        case .shortActions: "短期行动"
        case .farm: "农场"
        case .pasture: "牧场"
        case .fishing: "渔场"
        case .collection: "庄园图鉴"
        }
        return RhythmLocalization.text(key)
    }

    var subtitle: String {
        let key = switch self {
        case .today: "把今天的行动与成长放在一起"
        case .habits: "完成每天的小事，积累稳定节奏"
        case .chores: "安排跨天琐事，每完成一项获得 %d 金币"
        case .focus: "只有有效专注时间会推动作物生长"
        case .sleep: "锁屏、熄屏和合盖不会中断睡眠记录"
        case .statistics: "回顾连续打卡、专注、睡眠与打卡完成率"
        case .longGoals: "用结果、里程碑和进度管理长期方向"
        case .shortActions: "把长期目标拆成下一步可以完成的行动"
        case .farm: "在场景中播种、浇水、施肥，让专注推动作物生长"
        case .pasture: "在场景中搭窝、饲养与收取，让规律睡眠带来产出"
        case .fishing: "在湖边抛竿、管理鱼篓，并进入水族馆照料收藏"
        case .collection: "查看已经收获、饲养和发现的庄园物种"
        }
        // 琐事奖励数值引用经济常量插值，避免界面提示与实际发放不一致。
        if self == .chores {
            return RhythmLocalization.format(key, RhythmEconomy.choreCoins)
        }
        return RhythmLocalization.text(key)
    }

    var symbol: String {
        switch self {
        case .today: "sun.max.fill"
        case .habits: "checkmark.circle.fill"
        case .chores: "tray.full.fill"
        case .focus: "timer"
        case .sleep: "moon.stars.fill"
        case .statistics: "chart.bar.xaxis"
        case .longGoals: "flag.checkered"
        case .shortActions: "list.bullet.clipboard.fill"
        case .farm: "leaf.fill"
        case .pasture: "pawprint.fill"
        case .fishing: "fish.fill"
        case .collection: "books.vertical.fill"
        }
    }
}

/// 统一经济参数。所有奖励、消耗与离线上限从这里读取，避免界面提示和实际扣款不一致。
enum RhythmEconomy {
    static let schemaVersion = 11
    static let focusMinutesPerCoin = 15
    static let focusSessionCoinCap = 20
    static let habitRewardRange = 1...10
    /// 琐事首次完成奖励金币数，界面文案统一引用此常量插值。
    static let choreCoins = 5
    static let shortActionCoins = 8
    static let shortActionBait = 1
    static let longGoalCoins = 60
    static let longGoalBait = 3
    static let waterCost = 1
    static let waterBoost = 0.15
    static let fertilizerCost = 4
    static let fertilizerBoost = 0.40
    static let maximumFocusBoost = 1.0
    static let aquariumCapacity = 25
    static let aquariumOfflineDayCap = 7

    /// 庄园装饰价格：购买即 level 1（level = 0 时调用），之后每次升级价格翻倍
    /// （base × 2^level，level 为当前等级），无升级上限，作为金币永续消耗出口。
    /// level 封顶 40 档防御溢出，此时价格已达天文数字，正常游玩不可能触及。
    static func decorationPrice(base: Int, currentLevel: Int) -> Int {
        let shift = max(0, min(currentLevel, 40))
        return base << shift
    }

    static func farmPlotCost(existingCount: Int) -> Int {
        let expansions = max(0, existingCount - 1)
        return 50 + expansions * 18 + expansions * expansions * 2
    }

    static func animalShelterCost(existingCapacity: Int) -> Int {
        let expansions = max(0, existingCapacity - 1)
        return 70 + expansions * 22 + expansions * expansions * 3
    }

    /// 钓鱼稀有度掷骰（1...100 均匀roll）：区间划分是概率的唯一事实源。
    static func fishingRarity(for roll: Int) -> Int {
        switch min(100, max(1, roll)) {
        case 1: 5
        case 2...5: 4
        case 6...17: 3
        case 18...45: 2
        default: 1
        }
    }

    /// 各稀有度概率，由 `fishingRarity(for:)` 的掷骰区间派生，不再单独手写。
    static let fishingRarityProbability: [Int: Double] = {
        var counts: [Int: Int] = [:]
        for roll in 1...100 {
            counts[fishingRarity(for: roll), default: 0] += 1
        }
        return counts.mapValues { Double($0) / 100 }
    }()
}

struct Habit: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var symbol: String
    var weekdays: Set<Int>
    var rewardCoins: Int
    var createdAt: Date

    func isScheduled(on date: Date, calendar: Calendar = .current) -> Bool {
        RhythmShared.habitIsScheduled(weekdays: weekdays, createdAt: createdAt, on: date, calendar: calendar)
    }
}

struct ActiveFocus: Codable, Hashable {
    var id: String
    var title: String
    var linkedActionID: String?
    var startedAt: Date
    var accumulatedSeconds: TimeInterval
    var segmentStartedAt: Date?
    var pausedForSystem: Bool
    var growthCreditedSeconds: TimeInterval? = nil
}

struct FocusRecord: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var linkedActionID: String?
    var startedAt: Date
    var endedAt: Date
    var durationSeconds: TimeInterval
    var earnedCoins: Int
}

struct ActiveSleep: Codable, Hashable {
    var id: String
    var startedAt: Date
    var targetHours: Double? = nil
    var growthCreditedSeconds: TimeInterval? = nil
    var productionCyclesCredited: Int? = nil
    var pastureYieldCredited: Int? = nil
}

struct SleepRecord: Codable, Identifiable, Hashable {
    var id: String
    var startedAt: Date
    var endedAt: Date
    var durationSeconds: TimeInterval
    var score: Int
    var pastureYield: Int
    var healthSource: String? = nil
    var healthGrowthCreditedSeconds: TimeInterval? = nil
    var healthProductionCreditedCycles: Int? = nil
    /// 手动录入标记（V4.1 引入，可选字段兼容旧存档，schema 不变）。
    /// health* 三个遗留字段只表示健康来源已结算的量，手动录入的结算记账
    /// 单独使用下面两个 manual 字段，互不混用。
    var manualEntry: Bool? = nil
    /// 手动录入已补结算的动物成长秒数（单次封顶 14 小时），nil 表示尚未结算。
    var manualGrowthCreditedSeconds: TimeInterval? = nil
    /// 手动录入已补结算的产出周期数（单次封顶 2 个），nil 表示尚未结算。
    var manualProductionCreditedCycles: Int? = nil
}

enum GoalStatus: String, Codable, CaseIterable, Identifiable {
    case planned
    case active
    case paused
    case completed

    var id: String { rawValue }

    var title: String {
        let key = switch self {
        case .planned: "未开始"
        case .active: "进行中"
        case .paused: "已暂停"
        case .completed: "已完成"
        }
        return RhythmLocalization.text(key)
    }

    var symbol: String {
        switch self {
        case .planned: "circle.dashed"
        case .active: "play.circle.fill"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.seal.fill"
        }
    }
}

struct LongGoal: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var reason: String
    var outcome: String
    var targetValue: Double
    var currentValue: Double
    var unit: String
    var startDate: Date
    var targetDate: Date
    var status: GoalStatus
    var rewardClaimed: Bool
    var createdAt: Date
}

struct ShortAction: Codable, Identifiable, Hashable {
    var id: String
    var goalID: String?
    var title: String
    var notes: String
    var dueDate: Date
    var startDate: Date?
    var endDate: Date?
    var estimatedMinutes: Int
    var focusedSeconds: TimeInterval
    var isCompleted: Bool
    var rewardClaimed: Bool
    var createdAt: Date
    var completedAt: Date?

    var normalizedEndDate: Date? {
        guard let startDate else { return nil }
        return max(startDate, endDate ?? startDate)
    }
}

struct FarmPlot: Codable, Identifiable, Hashable {
    var id: String
    var cropID: String?
    var growthMinutes: Double
    var nextFocusBoost: Double
    var plantedAt: Date?
}

struct OwnedAnimal: Codable, Identifiable, Hashable {
    var id: String
    var animalID: String
    var count: Int
    var pendingProducts: Int
}

struct PastureAnimal: Codable, Identifiable, Hashable {
    var id: String
    var animalID: String
    var growthHours: Double
    var pendingProducts: Int
    var acquiredAt: Date
}

struct AquariumFish: Codable, Identifiable, Hashable {
    var id: String
    var fishID: String
    var addedAt: Date
    var lastIncomeDate: Date
}

/// 已购庄园装饰：纯展示、无产出，升级无上限（金币永续消耗出口）。
/// 贴图复用作物/动物/鱼类现有图集，见 DecorationDefinition.sprite。
struct OwnedDecoration: Codable, Identifiable, Hashable {
    var id: String
    var definitionID: String
    var level: Int
    var placedAt: Date
}

struct RewardEvent: Codable, Identifiable, Hashable {
    var id: String
    var date: Date
    var title: String
    var detail: String
    var coins: Int
    var symbol: String
}

struct RhythmLibrary: Codable {
    var version: Int
    var habits: [Habit]
    var habitCompletionKeys: Set<String>
    var habitRewardKeys: Set<String>
    var activeFocus: ActiveFocus?
    var focusRecords: [FocusRecord]
    var activeSleep: ActiveSleep?
    var sleepRecords: [SleepRecord]
    var longGoals: [LongGoal]
    var shortActions: [ShortAction]
    var coins: Int
    var bait: Int
    var farmPlots: [FarmPlot]
    /// 派生状态：始终由 pastureAnimals 汇总重建（见 RhythmStore.apply），
    /// 不再写入存档；解码时容忍旧存档里的该字段，仅作为牧场迁移的输入。
    var ownedAnimals: [OwnedAnimal] = []
    var pastureAnimals: [PastureAnimal]?
    var animalShelterCapacity: Int?
    var fishInventory: [String: Int]
    var fishCaught: [String: Int]
    var aquariumFish: [AquariumFish]?
    var harvestedCrops: [String: Int]
    var rewardEvents: [RewardEvent]
    var chores: [Chore]? = nil
    /// 庄园装饰。decodeIfPresent 兼容 schema 11 之前的旧存档，版本号不变。
    var decorations: [OwnedDecoration] = []

    static func starter() -> RhythmLibrary {
        let now = Date()
        let calendar = Calendar.current
        let allDays = Set(1...7)
        let sampleGoalID = UUID().uuidString
        return RhythmLibrary(
            version: RhythmEconomy.schemaVersion,
            habits: [
                Habit(id: UUID().uuidString, title: "喝够八杯水", symbol: "drop.fill", weekdays: allDays, rewardCoins: 5, createdAt: now),
                Habit(id: UUID().uuidString, title: "整理桌面", symbol: "sparkles", weekdays: allDays, rewardCoins: 5, createdAt: now),
                Habit(id: UUID().uuidString, title: "阅读二十分钟", symbol: "book.fill", weekdays: allDays, rewardCoins: 8, createdAt: now),
            ],
            habitCompletionKeys: [],
            habitRewardKeys: [],
            activeFocus: nil,
            focusRecords: [],
            activeSleep: nil,
            sleepRecords: [],
            longGoals: [
                LongGoal(
                    id: sampleGoalID,
                    title: "建立稳定的工作与休息节奏",
                    reason: "让每天的精力更可控，也为长期目标留出空间。",
                    outcome: "连续四周保持规律专注与睡眠",
                    targetValue: 4,
                    currentValue: 0,
                    unit: "周",
                    startDate: now,
                    targetDate: calendar.date(byAdding: .month, value: 1, to: now) ?? now,
                    status: .active,
                    rewardClaimed: false,
                    createdAt: now
                ),
            ],
            shortActions: [
                ShortAction(
                    id: UUID().uuidString,
                    goalID: sampleGoalID,
                    title: "完成第一次 25 分钟专注",
                    notes: "开始时可把专注记录关联到这个行动。",
                    dueDate: calendar.date(byAdding: .day, value: 1, to: now) ?? now,
                    startDate: nil,
                    endDate: nil,
                    estimatedMinutes: 25,
                    focusedSeconds: 0,
                    isCompleted: false,
                    rewardClaimed: false,
                    createdAt: now,
                    completedAt: nil
                ),
            ],
            coins: 100,
            bait: 2,
            farmPlots: [
                FarmPlot(id: UUID().uuidString, cropID: nil, growthMinutes: 0, nextFocusBoost: 0, plantedAt: nil),
            ],
            ownedAnimals: [],
            pastureAnimals: [],
            animalShelterCapacity: 1,
            fishInventory: [:],
            fishCaught: [:],
            aquariumFish: [],
            harvestedCrops: [:],
            rewardEvents: [
                RewardEvent(
                    id: UUID().uuidString,
                    date: now,
                    title: RhythmLocalization.text("欢迎来到节奏庄园"),
                    detail: RhythmLocalization.text("已获得 100 金币、2 个鱼饵，以及农场和牧场各 1 个初始坑位。"),
                    coins: 100,
                    symbol: "leaf.fill"
                ),
            ]
        )
    }
}

/// 自定义归档格式：ownedAnimals 是派生状态，编码时跳过；
/// 解码用 decodeIfPresent 容忍旧存档（字段仅作为牧场迁移输入，加载后会被重建）。
/// 扩展内的自定义 Codable 不影响主声明的成员级初始化器。
extension RhythmLibrary {
    private enum CodingKeys: String, CodingKey {
        case version, habits, habitCompletionKeys, habitRewardKeys
        case activeFocus, focusRecords, activeSleep, sleepRecords
        case longGoals, shortActions, coins, bait, farmPlots
        case ownedAnimals, pastureAnimals, animalShelterCapacity
        case fishInventory, fishCaught, aquariumFish, harvestedCrops
        case rewardEvents, chores
        case decorations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        habits = try container.decode([Habit].self, forKey: .habits)
        habitCompletionKeys = try container.decode(Set<String>.self, forKey: .habitCompletionKeys)
        habitRewardKeys = try container.decode(Set<String>.self, forKey: .habitRewardKeys)
        activeFocus = try container.decodeIfPresent(ActiveFocus.self, forKey: .activeFocus)
        focusRecords = try container.decode([FocusRecord].self, forKey: .focusRecords)
        activeSleep = try container.decodeIfPresent(ActiveSleep.self, forKey: .activeSleep)
        sleepRecords = try container.decode([SleepRecord].self, forKey: .sleepRecords)
        longGoals = try container.decode([LongGoal].self, forKey: .longGoals)
        shortActions = try container.decode([ShortAction].self, forKey: .shortActions)
        coins = try container.decode(Int.self, forKey: .coins)
        bait = try container.decode(Int.self, forKey: .bait)
        farmPlots = try container.decode([FarmPlot].self, forKey: .farmPlots)
        ownedAnimals = try container.decodeIfPresent([OwnedAnimal].self, forKey: .ownedAnimals) ?? []
        pastureAnimals = try container.decodeIfPresent([PastureAnimal].self, forKey: .pastureAnimals)
        animalShelterCapacity = try container.decodeIfPresent(Int.self, forKey: .animalShelterCapacity)
        fishInventory = try container.decode([String: Int].self, forKey: .fishInventory)
        fishCaught = try container.decode([String: Int].self, forKey: .fishCaught)
        aquariumFish = try container.decodeIfPresent([AquariumFish].self, forKey: .aquariumFish)
        harvestedCrops = try container.decode([String: Int].self, forKey: .harvestedCrops)
        rewardEvents = try container.decode([RewardEvent].self, forKey: .rewardEvents)
        chores = try container.decodeIfPresent([Chore].self, forKey: .chores)
        decorations = try container.decodeIfPresent([OwnedDecoration].self, forKey: .decorations) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(habits, forKey: .habits)
        try container.encode(habitCompletionKeys, forKey: .habitCompletionKeys)
        try container.encode(habitRewardKeys, forKey: .habitRewardKeys)
        try container.encodeIfPresent(activeFocus, forKey: .activeFocus)
        try container.encode(focusRecords, forKey: .focusRecords)
        try container.encodeIfPresent(activeSleep, forKey: .activeSleep)
        try container.encode(sleepRecords, forKey: .sleepRecords)
        try container.encode(longGoals, forKey: .longGoals)
        try container.encode(shortActions, forKey: .shortActions)
        try container.encode(coins, forKey: .coins)
        try container.encode(bait, forKey: .bait)
        try container.encode(farmPlots, forKey: .farmPlots)
        // ownedAnimals 刻意不写入：它由 pastureAnimals 派生，落盘只会产生不一致风险。
        try container.encodeIfPresent(pastureAnimals, forKey: .pastureAnimals)
        try container.encodeIfPresent(animalShelterCapacity, forKey: .animalShelterCapacity)
        try container.encode(fishInventory, forKey: .fishInventory)
        try container.encode(fishCaught, forKey: .fishCaught)
        try container.encodeIfPresent(aquariumFish, forKey: .aquariumFish)
        try container.encode(harvestedCrops, forKey: .harvestedCrops)
        try container.encode(rewardEvents, forKey: .rewardEvents)
        try container.encodeIfPresent(chores, forKey: .chores)
        try container.encode(decorations, forKey: .decorations)
    }
}

enum RhythmFormatters {
    private static var cachedDate: (RhythmLanguage, DateFormatter)?
    private static var cachedShortDate: (RhythmLanguage, DateFormatter)?
    private static var cachedTime: (RhythmLanguage, DateFormatter)?

    /// 预热常用格式化器，消除冷启动延迟
    static func warmup() {
        _ = date
        _ = shortDate
        _ = time
        _ = month
    }

    static var date: DateFormatter {
        let currentLang = RhythmLocalization.language
        if let (lang, formatter) = cachedDate, lang == currentLang {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = currentLang.locale
        formatter.dateFormat = currentLang == .english ? "MMM d, yyyy" : "yyyy年M月d日"
        cachedDate = (currentLang, formatter)
        return formatter
    }

    static var shortDate: DateFormatter {
        let currentLang = RhythmLocalization.language
        if let (lang, formatter) = cachedShortDate, lang == currentLang {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = currentLang.locale
        formatter.dateFormat = currentLang == .english ? "MMM d" : "M月d日"
        cachedShortDate = (currentLang, formatter)
        return formatter
    }

    /// 口径在 RhythmShared.monthFormatter（小组件共用），这里只把当前语言换算成 english 参数。
    static var month: DateFormatter {
        RhythmShared.monthFormatter(english: RhythmLocalization.language == .english)
    }

    static var time: DateFormatter {
        let currentLang = RhythmLocalization.language
        if let (lang, formatter) = cachedTime, lang == currentLang {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = currentLang.locale
        formatter.dateFormat = "HH:mm"
        cachedTime = (currentLang, formatter)
        return formatter
    }

    /// 主程序时长文案：showSeconds 时显示秒，否则用「分钟」。小组件侧
    /// （WidgetExtension/WidgetViews.swift 的 RhythmWidgetLocale.duration）刻意用
    /// 精简口径（截断到分钟、文案用「分」），两者不合并；改动时请对照两处。
    static func duration(_ seconds: TimeInterval, showSeconds: Bool = true) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return showSeconds
                ? String(format: "%02d:%02d:%02d", hours, minutes, secs)
                : RhythmLocalization.language == .english ? "\(hours)h \(minutes)m" : "\(hours)小时\(minutes)分钟"
        }
        return showSeconds
            ? String(format: "%02d:%02d", minutes, secs)
            : RhythmLocalization.language == .english ? "\(minutes)m" : "\(minutes)分钟"
    }
}
