import SwiftUI

struct TodayDashboard: View {
    @EnvironmentObject private var store: RhythmStore
    @Binding var selection: RhythmSection
    @State private var monthOffset = 0

    private var todayHabits: [Habit] { store.habits(for: Date(), unfinishedFirst: true) }
    private var completedHabits: Int { todayHabits.filter { store.isHabitCompleted($0) }.count }
    private var nextActions: [ShortAction] {
        store.shortActions.filter { !$0.isCompleted }.sorted {
            ($0.startDate ?? $0.createdAt) < ($1.startDate ?? $1.createdAt)
        }
    }
    private var growingPlots: Int { store.farmPlots.filter { $0.cropID != nil }.count }
    private var readyPlots: Int {
        store.farmPlots.filter { plot in
            guard let crop = RhythmCatalog.crop(plot.cropID) else { return false }
            return plot.growthMinutes >= crop.growthMinutes
        }.count
    }
    private var calendar: Calendar { .current }
    private var displayedMonth: Date {
        let start = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        return calendar.date(byAdding: .month, value: monthOffset, to: start) ?? start
    }
    private var monthGridDates: [Date?] {
        RhythmShared.monthGridDates(for: displayedMonth, calendar: calendar)
    }
    private var weekdayTitles: [String] {
        let base = RhythmLocalization.language == .english
            ? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            : ["日", "一", "二", "三", "四", "五", "六"]
        let offset = max(0, min(6, calendar.firstWeekday - 1))
        return Array(base[offset...] + base[..<offset])
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    StatTile(value: "\(completedHabits)/\(todayHabits.count)", label: "今日打卡", symbol: "checkmark.circle.fill", color: RhythmTheme.teal)
                    StatTile(value: RhythmFormatters.duration(store.focusSeconds(on: Date()), showSeconds: false), label: "今日专注", symbol: "timer", color: RhythmTheme.blue)
                    StatTile(value: store.lastNightSleepDuration(on: Date()).map { RhythmFormatters.duration($0, showSeconds: false) } ?? "—", label: "昨夜睡眠", symbol: "moon.stars.fill", color: RhythmTheme.purple)
                    StatTile(value: "\(store.coins)", label: "庄园金币", symbol: "circle.fill", color: RhythmTheme.orange)
                }

                if store.activeFocus != nil || store.activeSleep != nil {
                    activeTimerCard
                }

                HStack(alignment: .top, spacing: 16) {
                    todayHabitCard
                    nextActionCard
                }

                // 联动③：只读展示搞健康当日数据（健康卡片内部自刷新，不写库）。
                HealthTodayCard()

                monthlyOverview

                estateSummary

                if !store.rewardEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(RhythmLocalization.text("最近奖励")).font(.headline)
                        ForEach(store.rewardEvents.prefix(4)) { event in
                            HStack(spacing: 12) {
                                Image(systemName: event.symbol)
                                    .foregroundStyle(RhythmTheme.green)
                                    .frame(width: 28, height: 28)
                                    .background(RhythmTheme.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).font(.callout.weight(.medium))
                                    Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if event.coins > 0 {
                                    Text("+\(event.coins) 🪙")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(RhythmTheme.orange)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
                }
            }
            .frame(maxWidth: 1100)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private var activeTimerCard: some View {
        HStack(spacing: 15) {
            Image(systemName: store.activeFocus != nil ? "timer" : "moon.stars.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(store.activeFocus != nil ? RhythmTheme.blue : RhythmTheme.purple, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(store.activeFocus.map { store.focusDisplayTitle(linkedActionID: $0.linkedActionID) } ?? RhythmLocalization.text("睡眠计时进行中"))
                    .font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(RhythmFormatters.duration(store.activeFocus != nil ? store.focusElapsed(at: context.date) : store.sleepElapsed(at: context.date)))
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
            }
            Spacer()
            Button(RhythmLocalization.text("查看")) { selection = store.activeFocus != nil ? .focus : .sleep }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background((store.activeFocus != nil ? RhythmTheme.blue : RhythmTheme.purple).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke((store.activeFocus != nil ? RhythmTheme.blue : RhythmTheme.purple).opacity(0.18)))
    }

    private var todayHabitCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(RhythmLocalization.text("今日打卡")).font(.headline)
                Spacer()
                Button(RhythmLocalization.text("全部")) { selection = .habits }.buttonStyle(.plain).foregroundStyle(RhythmTheme.blue)
            }
            if todayHabits.isEmpty {
                Text(RhythmLocalization.text("今天没有安排打卡目标。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(todayHabits) { habit in
                            Button {
                                store.toggleHabit(habit)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: store.isHabitCompleted(habit) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(store.isHabitCompleted(habit) ? RhythmTheme.teal : Color.secondary)
                                    Image(systemName: habit.symbol).foregroundStyle(.secondary).frame(width: 18)
                                    Text(habit.title).foregroundStyle(.primary).lineLimit(1)
                                    Spacer()
                                    Text("+\(habit.rewardCoins)").font(.caption).foregroundStyle(RhythmTheme.orange)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(RhythmLocalization.format(
                                store.isHabitCompleted(habit) ? "取消打卡：%@" : "完成打卡：%@",
                                habit.title
                            ))
                        }
                    }
                }
                .frame(maxHeight: 214)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 280, alignment: .top)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }

    private var nextActionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(RhythmLocalization.text("下一步行动")).font(.headline)
                Spacer()
                Button(RhythmLocalization.text("全部")) { selection = .shortActions }.buttonStyle(.plain).foregroundStyle(RhythmTheme.blue)
            }
            if nextActions.isEmpty {
                Text(RhythmLocalization.text("所有短期行动都已完成。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(nextActions) { action in
                            HStack(spacing: 10) {
                                Button {
                                    store.toggleAction(action)
                                } label: {
                                    Image(systemName: "circle")
                                }
                                .buttonStyle(.plain)
                                Text(action.title).lineLimit(1)
                                Spacer()
                                Text("🎣 +1").font(.caption)
                            }
                        }
                    }
                }
                .frame(maxHeight: 214)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 280, alignment: .top)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }

    private var estateSummary: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(RhythmLocalization.text("节奏庄园")).font(.headline)
                Text(RhythmLocalization.format("%d 块农田生长中 · %d 块可收获 · %d 只牲畜 · 已发现 %d/%d 种鱼", growingPlots, readyPlots, store.ownedAnimals.reduce(0) { $0 + $1.count }, store.fishCaught.count, RhythmCatalog.fish.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(RhythmLocalization.text("进入农场")) { selection = .farm }
                .buttonStyle(.borderedProminent)
                .tint(RhythmTheme.green)
        }
        .padding(16)
        .background(RhythmTheme.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RhythmTheme.green.opacity(0.18)))
    }

    private var monthlyOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(RhythmLocalization.text("月度总览")).font(.headline)
                    Text(RhythmLocalization.text("打卡 · 专注 · 睡眠 · 琐事 · 短期行动"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(RhythmLocalization.text("上个月"))
                Text(RhythmFormatters.month.string(from: displayedMonth))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 110)
                Button { monthOffset += 1 } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(RhythmLocalization.text("下个月"))
                Button(RhythmLocalization.text("本月")) { monthOffset = 0 }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(monthOffset == 0)
            }

            SpanningMonthGrid(dates: monthGridDates, weekdayTitles: weekdayTitles,
                              includeActions: true, headerHeight: 100) { date in
                monthDayCell(date)
            }
        }
        .padding(16)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }

    private func monthDayCell(_ date: Date) -> some View {
        let scheduled = store.habits(for: date)
        let completed = scheduled.filter { store.isHabitCompleted($0, on: date) }.count
        let focus = store.focusSeconds(on: date)
        let sleep = store.sleepSeconds(on: date)
        let completion = scheduled.isEmpty ? 0 : Double(completed) / Double(scheduled.count)
        let isToday = calendar.isDateInToday(date)
        let isFuture = date > Date()

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(calendar.component(.day, from: date))")
                    .font(.callout.monospacedDigit().weight(isToday ? .bold : .medium))
                Spacer()
                if isToday {
                    Text(RhythmLocalization.text("今天"))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RhythmTheme.blue, in: Capsule())
                }
            }
            if !isFuture {
            Label("\(completed)/\(scheduled.count)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(RhythmTheme.teal)
            Label(RhythmFormatters.duration(focus, showSeconds: false), systemImage: "timer")
                .foregroundStyle(RhythmTheme.blue)
            Label(RhythmFormatters.duration(sleep, showSeconds: false), systemImage: "moon.stars.fill")
                .foregroundStyle(RhythmTheme.purple)
            } else { Text("—").foregroundStyle(.tertiary) }
        }
        .font(.system(size: 9).monospacedDigit())
        .lineLimit(1)
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [RhythmTheme.teal.opacity(0.04 + completion * 0.13), RhythmTheme.blue.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isToday ? RhythmTheme.blue : Color.primary.opacity(0.06), lineWidth: isToday ? 1.6 : 1)
        )
        .opacity(isFuture ? 0.85 : 1)
        // 3.37④：日期单元格逐项可聚焦（日期 + 打卡/专注/睡眠），不再整月糊成一段文本。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(monthDayAccessibilityLabel(date, completed: completed, scheduled: scheduled.count, focus: focus, sleep: sleep, isToday: isToday, isFuture: isFuture))
    }

    private func monthDayAccessibilityLabel(_ date: Date, completed: Int, scheduled: Int, focus: TimeInterval, sleep: TimeInterval, isToday: Bool, isFuture: Bool) -> String {
        let dateText = date.formatted(date: .abbreviated, time: .omitted)
        var parts: [String] = [isToday ? "\(dateText)（\(RhythmLocalization.text("今天"))）" : dateText]
        if isFuture {
            parts.append(RhythmLocalization.text("未来日期"))
        } else if scheduled > 0 {
            parts.append(RhythmLocalization.text("习惯打卡 \(completed)/\(scheduled)"))
        } else {
            parts.append(RhythmLocalization.text("无习惯安排"))
        }
        if focus > 0 { parts.append("\(RhythmLocalization.text("专注")) \(RhythmFormatters.duration(focus, showSeconds: false))") }
        if sleep > 0 { parts.append("\(RhythmLocalization.text("睡眠")) \(RhythmFormatters.duration(sleep, showSeconds: false))") }
        return parts.joined(separator: "，")
    }
}

struct HabitDashboard: View {
    @EnvironmentObject private var store: RhythmStore
    @State private var showingEditor = false
    @State private var editingHabit: Habit?
    @State private var deleteCandidate: Habit?

    private let habitColumns = [GridItem(.adaptive(minimum: 210, maximum: 290), spacing: 14)]

    private var todayHabits: [Habit] { store.habits(for: Date(), unfinishedFirst: true) }
    private var completedCount: Int { todayHabits.filter { store.isHabitCompleted($0) }.count }
    private var remainingCount: Int { max(0, todayHabits.count - completedCount) }
    private var pendingCoins: Int {
        todayHabits.filter { !store.isHabitCompleted($0) }.reduce(0) { $0 + $1.rewardCoins }
    }
    private var completionProgress: Double {
        todayHabits.isEmpty ? 0 : Double(completedCount) / Double(todayHabits.count)
    }
    private var lastSevenDayRate: Int {
        let calendar = Calendar.current
        var completed = 0
        var scheduled = 0
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let habits = store.habits(for: date)
            scheduled += habits.count
            completed += habits.filter { store.isHabitCompleted($0, on: date) }.count
        }
        return scheduled == 0 ? 0 : Int((Double(completed) / Double(scheduled) * 100).rounded())
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                habitHero

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(RhythmLocalization.text("今天的节奏")).font(.title3.weight(.semibold))
                        Text(RhythmLocalization.text("先完成未打卡项目，完成项会自动排到后面。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        editingHabit = nil
                        showingEditor = true
                    } label: {
                        Label(RhythmLocalization.text("新建打卡目标"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if todayHabits.isEmpty {
                    EmptyStateView(symbol: "checkmark.circle", title: "今天没有打卡目标", message: "新建一个每天或每周重复的目标，完成后可获得庄园金币。", actionTitle: "新建目标") {
                        editingHabit = nil
                        showingEditor = true
                    }
                } else {
                    LazyVGrid(columns: habitColumns, alignment: .leading, spacing: 14) {
                        ForEach(todayHabits) { habit in
                            HabitRow(habit: habit) {
                                store.toggleHabit(habit)
                            } edit: {
                                editingHabit = habit
                                showingEditor = true
                            } delete: {
                                deleteCandidate = habit
                            }
                        }
                    }
                }

                if store.habits.count > todayHabits.count {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(RhythmLocalization.text("其他日期的目标")).font(.headline)
                        LazyVGrid(columns: habitColumns, alignment: .leading, spacing: 14) {
                            ForEach(store.habits.filter { !todayHabits.contains($0) }) { habit in
                                HabitRow(habit: habit, disabled: true, toggle: {}, edit: {
                                    editingHabit = habit
                                    showingEditor = true
                                }, delete: { deleteCandidate = habit })
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: 1120)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .sheet(isPresented: $showingEditor) {
            HabitEditor(habit: editingHabit)
                .environmentObject(store)
        }
        .alert(RhythmLocalization.text("删除这个打卡目标？"), isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )) {
            Button(RhythmLocalization.text("取消"), role: .cancel) { deleteCandidate = nil }
            Button(RhythmLocalization.text("删除"), role: .destructive) {
                if let deleteCandidate { store.deleteHabit(deleteCandidate) }
                deleteCandidate = nil
            }
        } message: {
            Text(RhythmLocalization.text("已经获得的金币不会被扣除。"))
        }
    }

    private var habitHero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RhythmTheme.blue.opacity(0.18),
                            RhythmTheme.purple.opacity(0.11),
                            RhythmTheme.orange.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .fill(RhythmTheme.blue.opacity(0.08))
                .frame(width: 170, height: 170)
                .offset(x: 430, y: -62)
            Circle()
                .fill(RhythmTheme.orange.opacity(0.08))
                .frame(width: 110, height: 110)
                .offset(x: 505, y: 72)

            HStack(spacing: 24) {
                HabitProgressRing(progress: completionProgress, completed: completedCount, total: todayHabits.count)

                VStack(alignment: .leading, spacing: 7) {
                    Text(RhythmLocalization.format("今天 · %@", RhythmFormatters.date.string(from: Date())))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(RhythmLocalization.text(remainingCount == 0 && !todayHabits.isEmpty ? "今天的节奏已经完成" : "把今天过成有节奏的一天"))
                        .font(.title2.weight(.semibold))
                    Text(remainingCount == 0
                        ? RhythmLocalization.text("全部完成，今天已经获得稳定的一小步。")
                        : RhythmLocalization.format("还有 %d 项等待完成，预计可获得 %d 金币。", remainingCount, pendingCoins))
                    .font(.callout).foregroundStyle(.secondary)
                }
                .layoutPriority(1)

                Spacer(minLength: 18)

                HStack(spacing: 10) {
                    HabitHeroMetric(value: "\(remainingCount)", label: "今日剩余", symbol: "circle.dotted", color: RhythmTheme.blue)
                    HabitHeroMetric(value: "\(pendingCoins)", label: "待领金币", symbol: "circle.fill", color: RhythmTheme.orange)
                    HabitHeroMetric(value: "\(lastSevenDayRate)%", label: "近7天完成率", symbol: "chart.line.uptrend.xyaxis", color: RhythmTheme.teal)
                }
            }
            .padding(22)
        }
        .frame(minHeight: 166)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(RhythmTheme.blue.opacity(0.13)))
    }
}

private struct HabitProgressRing: View {
    let progress: Double
    let completed: Int
    let total: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 10)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(colors: [RhythmTheme.blue, RhythmTheme.teal, RhythmTheme.blue], center: .center),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.45, dampingFraction: 0.82), value: progress)
            VStack(spacing: 1) {
                Text("\(completed)/\(total)")
                    .font(.title2.monospacedDigit().weight(.bold))
                Text(RhythmLocalization.text("今日完成"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 108, height: 108)
        .accessibilityElement(children: .combine)
    }
}

private struct HabitHeroMetric: View {
    let value: String
    let label: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
            Text(RhythmLocalization.text(label))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 80, alignment: .leading)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.11)))
    }
}

private struct HabitRow: View {
    @EnvironmentObject private var store: RhythmStore
    let habit: Habit
    var disabled = false
    let toggle: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    private var isCompleted: Bool { !disabled && store.isHabitCompleted(habit) }

    private var accent: Color {
        let palette: [Color] = [
            RhythmTheme.blue, RhythmTheme.teal, RhythmTheme.purple,
            RhythmTheme.orange, RhythmTheme.green, .pink, .indigo,
        ]
        let position = store.habits.firstIndex(where: { $0.id == habit.id }) ?? 0
        return palette[position % palette.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule()
                .fill(accent)
                .frame(width: isCompleted ? 42 : 72, height: 4)
                .animation(.spring(response: 0.35), value: isCompleted)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: habit.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 48, height: 48)
                    .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer()
                Button(action: toggle) {
                    Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(isCompleted ? accent : Color.secondary.opacity(0.72))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityLabel(RhythmLocalization.format(
                    isCompleted ? "取消打卡：%@" : "完成打卡：%@",
                    habit.title
                ))
                Menu {
                    Button(RhythmLocalization.text("编辑"), systemImage: "square.and.pencil", action: edit)
                    Button(RhythmLocalization.text("删除"), systemImage: "trash", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.callout.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.055), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(RhythmLocalization.format("更多操作：%@", habit.title))
            }

            Text(habit.title)
                .font(.headline)
                .lineLimit(2)
                .foregroundStyle(isCompleted ? .secondary : .primary)

            Spacer(minLength: 2)

            HStack(spacing: 7) {
                Label(weekdaySummary(habit.weekdays), systemImage: "calendar")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.045), in: Capsule())
                Spacer(minLength: 4)
                Text("+\(habit.rewardCoins) 🪙")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(RhythmTheme.orange)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RhythmTheme.orange.opacity(0.1), in: Capsule())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 166, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [accent.opacity(isCompleted ? 0.06 : 0.15), accent.opacity(0.035), RhythmTheme.panel],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(isCompleted ? 0.12 : 0.24)))
        .shadow(color: accent.opacity(isCompleted ? 0.03 : 0.08), radius: 10, y: 4)
        .opacity(disabled ? 0.68 : 1)
    }

    private func weekdaySummary(_ weekdays: Set<Int>) -> String {
        if weekdays.count == 7 { return RhythmLocalization.text("每天") }
        let names = [1: "周日", 2: "周一", 3: "周二", 4: "周三", 5: "周四", 6: "周五", 7: "周六"]
        return weekdays.sorted().compactMap { names[$0].map(RhythmLocalization.text) }.joined(separator: RhythmLocalization.language == .english ? ", " : "、")
    }
}

private struct HabitEditor: View {
    @EnvironmentObject private var store: RhythmStore
    @Environment(\.dismiss) private var dismiss
    let habit: Habit?
    @State private var title: String
    @State private var symbol: String
    @State private var weekdays: Set<Int>
    @State private var rewardCoins: Int

    private let symbols = ["checkmark.circle.fill", "drop.fill", "book.fill", "figure.walk", "dumbbell.fill", "pills.fill", "sparkles", "leaf.fill", "heart.fill", "brain.head.profile"]
    private let dayNames = [(2, "周一"), (3, "周二"), (4, "周三"), (5, "周四"), (6, "周五"), (7, "周六"), (1, "周日")]

    init(habit: Habit?) {
        self.habit = habit
        _title = State(initialValue: habit?.title ?? "")
        _symbol = State(initialValue: habit?.symbol ?? "checkmark.circle.fill")
        _weekdays = State(initialValue: habit?.weekdays ?? Set(1...7))
        _rewardCoins = State(initialValue: habit?.rewardCoins ?? 5)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(RhythmLocalization.text(habit == nil ? "新建打卡目标" : "编辑打卡目标")).font(.title2.weight(.semibold))
                    Text(RhythmLocalization.text("完成一次只会领取一次金币，取消勾选不会重复领取。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(RhythmLocalization.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(RhythmLocalization.text("保存")) {
                    store.saveHabit(existingID: habit?.id, title: title, symbol: symbol, weekdays: weekdays, rewardCoins: rewardCoins)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || weekdays.isEmpty)
            }
            .padding(22)
            Divider()
            Form {
                TextField(RhythmLocalization.text("目标名称"), text: $title)
                Picker(RhythmLocalization.text("图标"), selection: $symbol) {
                    ForEach(symbols, id: \.self) { value in
                        Label(value, systemImage: value).tag(value)
                    }
                }
                Stepper(
                    RhythmLocalization.format("完成奖励：%d 金币", rewardCoins),
                    value: $rewardCoins,
                    in: RhythmEconomy.habitRewardRange
                )
                Section(RhythmLocalization.text("重复日期")) {
                    ForEach(dayNames, id: \.0) { day, name in
                        Toggle(RhythmLocalization.text(name), isOn: Binding(
                            get: { weekdays.contains(day) },
                            set: { enabled in
                                if enabled { weekdays.insert(day) } else { weekdays.remove(day) }
                            }
                        ))
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 600, idealHeight: 650)
    }
}
