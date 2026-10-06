import Foundation
import OSLog

/// library.json 的读写、原子保存、损坏隔离与版本迁移。
///
/// 只处理文件与 `RhythmLibrary` 值，不持有任何业务状态：
/// RhythmStore（门面）组装好快照后委托这里落盘，启动/恢复时从这里拿回
/// 已迁移完成的存档。数据目录与 App Group 镜像路径保持既有约定，不得改动。
final class RhythmPersistence {
    /// 启动加载结果，由 RhythmStore 决定后续状态应用与提示文案。
    enum LoadResult {
        /// 读取并迁移成功。
        case loaded(RhythmLibrary)
        /// 文件尚不存在，属于首次启动。
        case missing
        /// 文件无法读取；保持原文件并进入只读保护，值为原始文件路径。
        case corrupted(quarantinedPath: String?)
    }

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    var libraryDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["GAOJIEZOU_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("GaoSeries/Rhythm", isDirectory: true)
    }

    var libraryURL: URL {
        libraryDirectory.appendingPathComponent("library.json")
    }

    /// Shared read-only copy consumed by the WidgetKit extension. The main
    /// application keeps its established library location and mirrors the
    /// same JSON into the signed application-group container on each save.
    var widgetSnapshotURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "5G96498KGJ.com.gaojiezou.rhythm")?
            .appendingPathComponent("library.json")
    }

    private var failureMarker:URL { libraryURL.appendingPathExtension("read-only") }
    func clearFailureMarker() throws {
        if FileManager.default.fileExists(atPath:failureMarker.path) { try FileManager.default.removeItem(at:failureMarker) }
    }
    func load() -> LoadResult {
        if FileManager.default.fileExists(atPath:failureMarker.path) { return .corrupted(quarantinedPath:libraryDirectory.path) }
        let fileManager = FileManager.default
        // 上次写入中途崩溃可能残留临时文件，启动时清理，避免堆积。
        let temporaryURL = libraryURL.appendingPathExtension("tmp")
        if fileManager.fileExists(atPath: temporaryURL.path) {
            do {
                try fileManager.removeItem(at: temporaryURL)
                RhythmLog.data.warning("已清理上次写入中断残留的临时文件 library.json.tmp")
            } catch {
                RhythmLog.data.error("清理残留的临时文件失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            let data = try Data(contentsOf: libraryURL)
            let decoded=try decoder.decode(RhythmLibrary.self,from:data)
            guard decoded.version <= RhythmEconomy.schemaVersion else { throw RhythmStoreError.backupFromNewerVersion(found:decoded.version) }
            return .loaded(migratedLibrary(decoded))
        } catch {
            // 文件尚不存在属于首次启动，不是损坏，静默使用初始模板。
            guard fileManager.fileExists(atPath: libraryURL.path) else { return .missing }
            RhythmLog.data.error("本地数据文件读取或解码失败，保留原文件并进入只读保护：\(error.localizedDescription, privacy: .public)")
            // 保留原文件，并让只读状态跨重启延续，直到验证后的备份恢复成功。
            try? Data("Read-only protection: restore a verified backup.".utf8).write(to:failureMarker,options:.atomic)
            return .corrupted(quarantinedPath: libraryURL.path)
        }
    }

    /// 原子写入主库；非测试环境同时把同一份 JSON 镜像到 App Group 供小组件读取。
    func write(_ library: RhythmLibrary) throws {
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(library)
        let temporary = libraryURL.appendingPathExtension("tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: libraryURL.path) {
            _ = try FileManager.default.replaceItemAt(libraryURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: libraryURL)
        }
#if !SMOKE_TEST
        if ProcessInfo.processInfo.environment["GAOJIEZOU_DATA_DIR"] == nil, let widgetURL = widgetSnapshotURL {
            do {
                try FileManager.default.createDirectory(
                    at: widgetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: widgetURL, options: .atomic)
            } catch {
                // 镜像失败不影响主库，小组件下次成功保存时会拿到最新数据。
                RhythmLog.data.error("写入 App Group 小组件镜像失败：\(error.localizedDescription, privacy: .public)")
            }
        }
#endif
    }

    /// 把损坏的数据文件复制为带时间戳的副本并移走原文件，返回副本的展示路径。
    @discardableResult
    func quarantineCorruptedLibrary() -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: libraryURL.path) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let copyURL = libraryDirectory.appendingPathComponent("library.corrupted-\(formatter.string(from: Date())).json")
        do {
            try fileManager.copyItem(at: libraryURL, to: copyURL)
            try fileManager.removeItem(at: libraryURL)
            RhythmLog.data.warning("数据文件损坏，已保留副本 \(copyURL.lastPathComponent, privacy: .public) 并移走原文件")
            return copyURL.path
        } catch {
            RhythmLog.data.error("隔离损坏的数据文件失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - 版本迁移

    /// 存档迁移入口。各步骤按引入版本从旧到新级联执行，每步幂等，
    /// 任意旧存档完整重放后与一次性升级等价；最后统一盖上当前版本号。
    func migratedLibrary(_ source: RhythmLibrary) -> RhythmLibrary {
        var library = source
        migratePastureToResidents(&library)
        migrateAquariumCollection(&library)
        if source.version < RhythmEconomy.schemaVersion {
            migrateHabitRewardRange(&library)
            migrateFarmGrowthScale(&library)
            migratePastureGrowthScale(&library)
            migrateChoreColors(&library)
        }
        migrateFocusTitles(&library)
        library.version = RhythmEconomy.schemaVersion
        return library
    }

    /// 牧场改为独立动物实例时引入（版本 4 存档尚无 pastureAnimals 字段，版本 9 已携带）。
    /// 按字段是否缺席驱动而非版本号，因此对任何缺失该字段的存档都幂等适用。
    private func migratePastureToResidents(_ library: inout RhythmLibrary) {
        guard library.pastureAnimals == nil else { return }
        let migrationDate = Date()
        var migratedAnimals: [PastureAnimal] = []
        for owned in library.ownedAnimals {
            let count = max(0, owned.count)
            guard count > 0 else { continue }
            let baseProducts = owned.pendingProducts / count
            let extraProducts = owned.pendingProducts % count
            let maturity = RhythmCatalog.animal(owned.animalID)?.maturitySleepHours ?? 0
            for ordinal in 0..<count {
                migratedAnimals.append(PastureAnimal(
                    id: "\(owned.id)-\(ordinal)",
                    animalID: owned.animalID,
                    growthHours: maturity,
                    pendingProducts: baseProducts + (ordinal < extraProducts ? 1 : 0),
                    acquiredAt: migrationDate
                ))
            }
        }
        library.pastureAnimals = migratedAnimals
    }

    /// 水族馆收藏上线时引入（同样缺席驱动）：旧存档初始化为空收藏。
    private func migrateAquariumCollection(_ library: inout RhythmLibrary) {
        if library.aquariumFish == nil {
            library.aquariumFish = []
        }
    }

    /// 数值平衡调整引入：旧存档的打卡奖励归一化到当前允许区间。
    private func migrateHabitRewardRange(_ library: inout RhythmLibrary) {
        library.habits = library.habits.map { habit in
            var habit = habit
            habit.rewardCoins = min(
                RhythmEconomy.habitRewardRange.upperBound,
                max(RhythmEconomy.habitRewardRange.lowerBound, habit.rewardCoins)
            )
            return habit
        }
    }

    /// 数值平衡调整引入：作物成长时长重标定后，按完成百分比折算旧存档的成长值。
    private func migrateFarmGrowthScale(_ library: inout RhythmLibrary) {
        library.farmPlots = library.farmPlots.map { plot in
            var plot = plot
            guard let cropID = plot.cropID,
                  let newCrop = RhythmCatalog.crop(cropID),
                  let oldMinutes = legacyCropGrowthMinutes[cropID],
                  oldMinutes > 0 else { return plot }
            let completion = min(1, max(0, plot.growthMinutes / oldMinutes))
            plot.growthMinutes = completion * newCrop.growthMinutes
            return plot
        }
    }

    /// 数值平衡调整引入：幼崽成熟时长重标定后，按完成百分比折算旧存档的成长值。
    private func migratePastureGrowthScale(_ library: inout RhythmLibrary) {
        library.pastureAnimals = library.pastureAnimals?.map { resident in
            var resident = resident
            guard let animal = RhythmCatalog.animal(resident.animalID) else { return resident }
            let oldHours = 6 + Double(animal.level * 2)
            let completion = min(1, max(0, resident.growthHours / oldHours))
            resident.growthHours = completion * animal.maturitySleepHours
            return resident
        }
    }

    /// 琐事调色板配色上线时引入：为缺少颜色的旧琐事按顺序补配色。
    private func migrateChoreColors(_ library: inout RhythmLibrary) {
        library.chores = library.chores?.enumerated().map { index, chore in
            var chore = chore
            if chore.colorHex == nil {
                chore.colorHex = RhythmTheme.choreColors[index % RhythmTheme.choreColors.count].hex
            }
            return chore
        }
    }

    /// 始终执行的校准步骤：专注标题以当前短期行动为准，丢失关联的记为「其他事件」。
    private func migrateFocusTitles(_ library: inout RhythmLibrary) {
        let actionTitles = Dictionary(
            library.shortActions.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        if var focus = library.activeFocus {
            if let actionID = focus.linkedActionID, let actionTitle = actionTitles[actionID] {
                focus.title = actionTitle
            } else {
                focus.title = RhythmLocalization.text("其他事件")
            }
            library.activeFocus = focus
        }
        library.focusRecords = library.focusRecords.map { record in
            var record = record
            if let actionID = record.linkedActionID, let actionTitle = actionTitles[actionID] {
                record.title = actionTitle
            } else {
                record.title = RhythmLocalization.text("其他事件")
            }
            return record
        }
    }

    /// 数值平衡调整前的作物成长时长（分钟），仅用于按完成百分比折算旧存档。
    private var legacyCropGrowthMinutes: [String: Double] {
        [
            "carrot": 25, "potato": 35, "wheat": 40, "corn": 50, "tomato": 60,
            "cabbage": 70, "cucumber": 75, "onion": 80, "garlic": 85, "pepper": 90,
            "eggplant": 95, "broccoli": 100, "peanut": 110, "soybean": 115, "rice": 120,
            "strawberry": 130, "grape": 140, "watermelon": 150, "pumpkin": 160,
            "sunflower": 170, "tea": 180, "coffee": 200, "apple": 220, "peach": 240,
        ]
    }
}
