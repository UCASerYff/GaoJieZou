import Foundation

/// 主程序与 WidgetKit 小组件共享的纯函数口径层（单一事实源）。
///
/// 小组件 target 不编译 Models.swift，因此这里只依赖 Foundation，
/// 函数签名统一使用原始类型与元组。小组件工程编译的是本文件的构建期拷贝
/// （WidgetExtension/RhythmShared.swift，由 scripts/build.sh 与
/// scripts/test-widgets.sh 在编译前同步），不要直接编辑那份拷贝。
enum RhythmShared {

    // MARK: - 打卡

    /// 打卡完成记录的存储 key：`<habitID>-<年>-<月>-<日>`，按指定日历取日期分量。
    static func habitKey(habitID: String, date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(habitID)-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    /// 打卡在某天是否出现：重复星期命中，且从创建日当天 00:00 起才出现
    /// （创建日之前的日期不显示该打卡）。createdAt 为空视为始终出现，兼容旧存档。
    static func habitIsScheduled(weekdays: Set<Int>, createdAt: Date?, on date: Date, calendar: Calendar = .current) -> Bool {
        guard weekdays.contains(calendar.component(.weekday, from: date)) else { return false }
        guard let createdAt else { return true }
        return calendar.startOfDay(for: createdAt) <= calendar.startOfDay(for: date)
    }

    /// 连续打卡口径（数据统计页单一事实源）：
    /// 当天所有「已安排打卡」全部完成计为达标日；无安排的日子既不计数也不打断；
    /// 今天未过完不打断当前连续（今天达标则计入，未达标则从今天之前回溯）。
    /// - Parameter days: 逐日汇总（日期、已安排数、已完成数），按日期升序。
    /// - Returns: 当前连续天数与历史最长连续天数。
    static func habitStreaks(
        days: [(date: Date, scheduled: Int, completed: Int)],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> (current: Int, longest: Int) {
        func qualified(_ day: (date: Date, scheduled: Int, completed: Int)) -> Bool {
            day.scheduled > 0 && day.completed >= day.scheduled
        }
        let todayStart = calendar.startOfDay(for: today)

        var longest = 0
        var run = 0
        for day in days {
            if qualified(day) {
                run += 1
                longest = max(longest, run)
            } else if day.scheduled > 0, !calendar.isDate(day.date, inSameDayAs: todayStart) {
                // 只有「有安排但未完成」的过去日子才中断连续；今天未达标不结算。
                run = 0
            }
        }

        var current = 0
        for day in days.reversed() {
            if qualified(day) {
                // 今天达标同样计入当前连续。
                current += 1
            } else if calendar.isDate(day.date, inSameDayAs: todayStart) {
                // 今天未过完/未达标：不打断，从今天之前继续回溯。
                continue
            } else if day.scheduled > 0 {
                break
            }
            // 无安排的日子跳过，既不计数也不打断。
        }
        return (current, longest)
    }

    // MARK: - 专注

    /// 某天的专注秒数 = 当天结束的记录时长合计 + 进行中专注归属当天的部分
    /// （开始于当天的累计时长 + 当前分段截断到 `[当天 00:00, min(now, 次日 00:00))` 的部分）。
    /// - Parameters:
    ///   - records: 已完成专注记录（结束时间、时长）。
    ///   - active: 进行中的专注（开始时间、已累计秒数、当前分段开始时间），无则传 nil。
    ///   - day: 目标日期；now: 进行时分段的结算时刻（默认当前时间）。
    static func focusSecondsOn(
        records: [(endedAt: Date, durationSeconds: TimeInterval)],
        active: (startedAt: Date, accumulatedSeconds: TimeInterval, segmentStartedAt: Date?)?,
        day: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TimeInterval {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        var total = records
            .filter { calendar.isDate($0.endedAt, inSameDayAs: day) }
            .reduce(0) { $0 + $1.durationSeconds }
        if let active {
            if calendar.isDate(active.startedAt, inSameDayAs: day) {
                total += active.accumulatedSeconds
            }
            if let segment = active.segmentStartedAt {
                total += max(0, min(now, dayEnd).timeIntervalSince(max(segment, dayStart)))
            }
        }
        return total
    }

    // MARK: - 睡眠

    /// 昨夜睡眠时长：当天 18:00 前结束、且开始于午夜前（开始小时 < 12 或早于当天 00:00）
    /// 的记录中，优先取健康来源，再取时长最长的一条；没有候选返回 nil。
    static func lastNightSleepDuration(
        records: [(startedAt: Date, endedAt: Date, durationSeconds: TimeInterval, isHealthSource: Bool)],
        on date: Date,
        calendar: Calendar = .current
    ) -> TimeInterval? {
        let morningEnd = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: date) ?? date
        let candidates = records.filter { record in
            calendar.isDate(record.endedAt, inSameDayAs: date)
                && record.endedAt < morningEnd
                && (calendar.component(.hour, from: record.startedAt) < 12
                    || record.startedAt < calendar.startOfDay(for: date))
        }
        let health = candidates.filter(\.isHealthSource)
        return (health.isEmpty ? candidates : health).max(by: { $0.durationSeconds < $1.durationSeconds })?.durationSeconds
    }

    /// 手动录入换算：把"时长（整分钟）+ 哪晚（就寝日期）"换成起止时间。
    /// 结束固定在该晚次日 07:00，开始 = 结束 - 时长。07:00 早于 lastNightSleepDuration
    /// 的 18:00 收口；时长在 0.5–24 小时内时，开始时刻必然落在次日 00:00–07:00
    /// （开始小时 < 12）或该晚 07:00–24:00（早于次日 00:00），两种情况都满足
    /// lastNightSleepDuration 的夜晚归属条件，统计稳定落在用户选的那晚。
    static func manualSleepInterval(night: Date, durationMinutes: Int, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let nightStart = calendar.startOfDay(for: night)
        let wakeDay = calendar.date(byAdding: .day, value: 1, to: nightStart) ?? nightStart
        let end = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: wakeDay) ?? wakeDay
        return (calendar.date(byAdding: .minute, value: -durationMinutes, to: end) ?? end, end)
    }

    // MARK: - 月历

    /// 月历第一格之前的前置空白数。沿用 `calendar.firstWeekday`，
    /// 中文/英文环境的星期起止差异由系统日历自然决定。
    static func monthLeadingBlankDays(month: Date, calendar: Calendar = .current) -> Int {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start else { return 0 }
        return (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
    }

    /// 月历格子数组：前置空白 + 当月全部日期，末尾补空白凑满整周。
    static func monthGridDates(for month: Date, calendar: Calendar = .current) -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let days = calendar.range(of: .day, in: .month, for: interval.start) else { return [] }
        var result = Array<Date?>(repeating: nil, count: monthLeadingBlankDays(month: month, calendar: calendar))
        result += days.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: interval.start)
        }.map(Optional.some)
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    // MARK: - 跨天事件车道

    /// 一周内某日期范围占用的列索引集合（nil 空格不占列），起止都按当天 00:00 归一。
    static func occupiedColumns(in week: [Date?], start: Date, end: Date, calendar: Calendar = .current) -> Set<Int> {
        let rangeStart = calendar.startOfDay(for: start)
        let rangeEnd = calendar.startOfDay(for: end)
        return Set(week.indices.filter { index in
            guard let date = week[index] else { return false }
            let day = calendar.startOfDay(for: date)
            return day >= rangeStart && day <= rangeEnd
        })
    }

    /// 为一行（一周）内的跨天事件分配车道：按输入顺序（调用方自行排序，
    /// 新建记录优先）把每个事件放进第一条占用列不相交的车道，非重叠事件复用空余轨道
    /// （README 的车道复用口径）。容量不足或本周无占用列的事件对应位置为 nil，
    /// 且不会占用车道。capacity 传 nil 表示不限车道数。
    static func assignLanes(occupiedColumns: [Set<Int>], capacity: Int? = nil) -> [Int?] {
        let limit = capacity ?? .max
        var lanes: [Set<Int>] = []
        return occupiedColumns.map { occupied -> Int? in
            guard !occupied.isEmpty else { return nil }
            if let lane = lanes.firstIndex(where: { $0.isDisjoint(with: occupied) }) {
                lanes[lane].formUnion(occupied)
                return lane
            }
            guard lanes.count < limit else { return nil }
            lanes.append(occupied)
            return lanes.count - 1
        }
    }

    // MARK: - 格式化

    /// 月份标题格式化器（「yyyy年M月」/「MMMM yyyy」）。语言由调用方以 english 传入，
    /// 保持纯函数；主程序 RhythmFormatters.month 与小组件 RhythmWidgetLocale.monthFormatter 共用此口径。
    /// 时长文案两侧刻意不同（小组件精简「X分」截断到分钟；主程序 RhythmFormatters.duration
    /// 可显示秒、文案用「分钟」），不合并，改动时请对照两处。
    static func monthFormatter(english: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: english ? "en" : "zh-Hans")
        formatter.dateFormat = english ? "MMMM yyyy" : "yyyy年M月"
        return formatter
    }

    // MARK: - 颜色

    /// 解析 `#RRGGBB` 字符串为 0...1 的 RGB 分量；格式不符返回 nil。
    static func rgbComponents(hex: String) -> (red: Double, green: Double, blue: Double)? {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6, let value = Int(clean, radix: 16) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
