import AppKit
import SwiftUI

struct WeeklyReviewHabitLocation {
    let id: String
    let date: Date
    let completionKey: String
}

enum WeeklyReviewDestination {
    case list(RhythmSection)
    case focus(String)
    case sleep(String)
    case habit(WeeklyReviewHabitLocation)
    case action(String)
    case goal(String)

    var section: RhythmSection {
        switch self {
        case let .list(section): section
        case .focus: .focus
        case .sleep: .sleep
        case .habit: .habits
        case .action: .shortActions
        case .goal: .longGoals
        }
    }

    func recordID(for section: RhythmSection) -> String? {
        guard self.section == section else { return nil }
        switch self {
        case let .focus(id), let .sleep(id), let .action(id), let .goal(id): return id
        case .list, .habit: return nil
        }
    }

    var habitLocation: WeeklyReviewHabitLocation? {
        guard case let .habit(location) = self else { return nil }
        return location
    }
}

func weeklyReviewText(_ chinese: String, _ english: String) -> String {
    RhythmLocalization.language == .english ? english : chinese
}

func weeklyReviewFullDate(_ date: Date) -> String {
    weeklyReviewFormat(date, template: "yMMMMEEEEd")
}

private func weeklyReviewFormat(_ date: Date, template: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = RhythmLocalization.language.locale
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date)
}

func weeklyReviewVisibleRecords<Record: Identifiable>(
    _ records: [Record], limit: Int, target: String?
) -> [Record] where Record.ID == String {
    let recent = Array(records.prefix(limit))
    guard let target, !recent.contains(where: { $0.id == target }),
          let match = records.first(where: { $0.id == target }) else { return recent }
    return recent + [match]
}

struct WeeklyReviewRecordScroll<Content: View>: View {
    var target: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content() }
                .task(id: target) {
                    guard let target else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(target, anchor: .center)
                }
        }
    }
}

struct WeeklyReviewMissingRecord: View {
    var body: some View {
        Label(weeklyReviewText("这条记录已无法在列表中找到。", "This record is no longer available."),
              systemImage: "exclamationmark.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

extension View {
    func weeklyReviewHighlight(_ isHighlighted: Bool) -> some View {
        overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

@MainActor
struct WeeklyReviewView: View {
    @EnvironmentObject private var store: RhythmStore
    @EnvironmentObject private var settings: RhythmSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedWeek: Date?
    @State private var selectedDay: Date?

    var open: (WeeklyReviewDestination) -> Void

    private var calendar: Calendar { .autoupdatingCurrent }
    private let topAnchor = "weekly-review-top"
    private let detailAnchor = "weekly-review-day-details"
    private let datesAnchor = "weekly-review-day-picker"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(weeklyReviewText("每周复盘", "Weekly Review"), systemImage: "chart.bar.xaxis")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { dismiss() } label: {
                    Label(weeklyReviewText("返回今日", "Back to Today"), systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("rhythm.weeklyReview.close")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            Divider()
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                let now = Date()
                if let report = store.weeklyReview(containing: selectedWeek ?? now,
                                                   sleepTargetHours: settings.sleepTargetHours, now: now) {
                    VStack(spacing: 0) {
                        weekPicker(report)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                        Divider()
                        weekContent(report)
                    }
                } else {
                    ContentUnavailableView {
                        Label(weeklyReviewText("无法读取这周的记录", "Weekly Records Unavailable"),
                              systemImage: "calendar.badge.exclamationmark")
                    } description: {
                        Text(weeklyReviewText("资料可用后可再次查看。", "Try again once your library is available."))
                    } actions: {
                        Button(weeklyReviewText("返回本周", "Return to This Week"), action: showCurrentWeek)
                    }
                }
            }
        }
        .frame(minWidth: 540, idealWidth: 840, minHeight: 510, idealHeight: 670)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("rhythm.weeklyReview.sheet")
    }

    private func weekPicker(_ report: WeeklyReview) -> some View {
        HStack {
            Text(range(report.weekStart, report.weekEnd, style: .medium))
                .font(.headline.monospacedDigit())
                .accessibilityIdentifier("rhythm.weeklyReview.range")
            Spacer()
            Button { shiftWeek(report, by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel(weeklyReviewText("上一周", "Previous Week"))
            .accessibilityIdentifier("rhythm.weeklyReview.previous")
            Button(weeklyReviewText("本周", "This Week"), action: showCurrentWeek)
            .accessibilityIdentifier("rhythm.weeklyReview.current")
            Button { shiftWeek(report, by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel(weeklyReviewText("下一周", "Next Week"))
            .accessibilityIdentifier("rhythm.weeklyReview.next")
        }
        .buttonStyle(.bordered)
    }

    private func shiftWeek(_ report: WeeklyReview, by amount: Int) {
        guard let next = calendar.date(byAdding: .day, value: amount * 7, to: report.weekStart) else { return }
        selectedWeek = calendar.isDate(next, inSameDayAs: report.currentWeekStart) ? nil : next
        selectedDay = nil
    }

    private func showCurrentWeek() {
        selectedWeek = nil
        selectedDay = nil
    }

    private func weekContent(_ report: WeeklyReview) -> some View {
        let day = report.days.first { calendar.isDate($0.date, inSameDayAs: selectedDay ?? report.today) } ?? report.days.first
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !report.days.contains(where: hasRecords) {
                        Label(weeklyReviewText("这周还没有可显示的记录。", "There are no records for this week yet."),
                              systemImage: "tray")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    overview(report)
                    dayPicker(report, selected: day?.date) { date in
                        selectedDay = date
                        scroll(proxy, to: detailAnchor)
                    }
                    .id(datesAnchor)
                    if let day {
                        dailyRecords(day, sleepUnavailable: report.sleepUnavailable) {
                            scroll(proxy, to: datesAnchor)
                        }
                        .id(detailAnchor)
                    }
                }
                .padding(20)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity)
                .id(topAnchor)
            }
            .onChange(of: report.weekStart) { _, _ in
                proxy.scrollTo(topAnchor, anchor: .top)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to target: String) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            proxy.scrollTo(target, anchor: .top)
        }
    }

    private func hasRecords(_ day: WeeklyReview.Day) -> Bool {
        !(day.focus.isEmpty && day.habits.isEmpty && day.sleep.isEmpty && day.actions.isEmpty && day.goals.isEmpty)
    }

    private func overview(_ report: WeeklyReview) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                comparison(report).frame(minWidth: 370, maxWidth: .infinity)
                schedule(report.plan).frame(minWidth: 245, maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 14) {
                comparison(report)
                schedule(report.plan)
            }
        }
    }

    private func comparison(_ report: WeeklyReview) -> some View {
        let rows = metrics(report)
        return panel(weeklyReviewText("计划与实际", "Plan and Actuals")) {
            Text(report.plan == nil
                 ? weeklyReviewText("未留存这周的计划，计划栏显示 —。", "A dash marks past plans that were not saved.")
                 : weeklyReviewText("计划根据带日期的安排和当前设置计算。", "Plans use dated schedules and current settings."))
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text(weeklyReviewText("项目", "Activity")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(weeklyReviewText("计划", "Plan"))
                    Text(weeklyReviewText("实际", "Actual"))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows) { row in
                    GridRow(alignment: .top) {
                        Label(row.title, systemImage: row.symbol)
                        Text(row.plan).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.actual).fontWeight(.semibold)
                            if let note = row.note {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if row.id != rows.last?.id {
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .font(.callout)
            .monospacedDigit()

            if report.undatedGoalCount > 0 || report.undatedActionCount > 0 {
                let actions = report.undatedActionCount > 0
                    ? count(report.undatedActionCount, " 项已完成行动", " action", " actions") : nil
                let goals = report.undatedGoalCount > 0
                    ? count(report.undatedGoalCount, " 项已完成目标", " goal", " goals") : nil
                let missing = [actions, goals]
                    .compactMap { $0 }.joined(separator: weeklyReviewText("、", " and "))
                Text(weeklyReviewText("\(missing)无法核实完成日期，未计入每周数据。",
                                      "Weekly totals exclude \(missing) completed without a verifiable date."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(weeklyReviewText("统计口径", "How Totals Are Counted")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(weeklyReviewText("专注只计已保存的记录。跨午夜的暂停无法确定日期时，按两天所占时长估算。",
                                          "Focus counts saved sessions. Cross-midnight sessions with unplaced pauses are apportioned by time."))
                    Text(weeklyReviewText("睡眠归入本地起床日期；每晚睡眠实际值是有记录日期的平均值。",
                                          "Sleep is grouped by the local wake date. Sleep per night averages dates with records."))
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    private struct Metric: Identifiable {
        let title: String
        let symbol: String
        let plan: String
        let actual: String
        var note: String? = nil

        var id: String { symbol }
    }

    private func metrics(_ report: WeeklyReview) -> [Metric] {
        let nights = report.sleepNights ?? 0
        let average = nights > 0 ? report.sleepSeconds.map { duration($0 / Double(nights)) } : nil
        let sleepNote: String
        if report.sleepUnavailable {
            sleepNote = weeklyReviewText("共享睡眠暂不可用", "Shared sleep unavailable")
        } else if let seconds = report.sleepSeconds, nights > 0 {
            sleepNote = count(nights, " 晚记录", " night logged", " nights logged") + " · " + duration(seconds)
        } else {
            sleepNote = weeklyReviewText("没有睡眠记录", "No sleep records")
        }
        return [
            Metric(title: weeklyReviewText("专注时长", "Focus Time"), symbol: "timer",
                   plan: report.plan?.focusMinutes.map { duration(Double($0) * 60) } ?? "—",
                   actual: estimate(report.focusSeconds, estimated: report.focusEstimated),
                   note: report.focusEstimated ? weeklyReviewText("含跨日估算", "Includes cross-day estimates") : nil),
            Metric(title: weeklyReviewText("习惯打卡", "Habit Check-ins"), symbol: "checkmark.circle",
                   plan: count(report.plan?.habitCount, " 次", " check-in", " check-ins"),
                   actual: count(report.habitDone, " 次", " check-in", " check-ins")),
            Metric(title: weeklyReviewText("每晚睡眠", "Sleep per Night"), symbol: "moon.stars",
                   plan: report.plan?.sleepTargetHours.map { duration($0 * 3600) } ?? "—",
                   actual: average ?? "—", note: sleepNote),
            Metric(title: weeklyReviewText("短期行动", "Short Actions"), symbol: "list.bullet",
                   plan: count(report.plan?.items.count, " 项", " action", " actions"),
                   actual: count(report.actionDone, " 项", " action", " actions")),
            Metric(title: weeklyReviewText("长期目标", "Long-term Goals"), symbol: "flag",
                   plan: count(report.plan?.goals.count, " 项", " goal", " goals"),
                   actual: count(report.goalDone, " 项", " goal", " goals"))
        ]
    }

    private func schedule(_ plan: WeeklyReview.Plan?) -> some View {
        panel(weeklyReviewText("周内安排", "Weekly Schedule")) {
            if let plan {
                if plan.items.isEmpty {
                    quiet(weeklyReviewText("这周没有带日期的行动。", "There are no dated actions this week."))
                }
                ForEach(plan.items) { item in
                    original(
                        item.action.title,
                        subtitle: [item.goalTitle, range(item.startDate, item.endDate)]
                            .compactMap { $0 }.joined(separator: " · "),
                        value: duration(Double(item.action.estimatedMinutes) * 60),
                        destination: .action(item.action.id)
                    )
                }
                if !plan.goals.isEmpty {
                    Divider()
                    Text(weeklyReviewText("本周长期目标", "Long-term Goals This Week")).font(.callout.weight(.semibold))
                    ForEach(plan.goals) { goal in
                        original(goal.title, subtitle: range(goal.startDate, goal.targetDate),
                                 value: goal.status.title, destination: .goal(goal.id))
                    }
                }
            } else {
                quiet(weeklyReviewText("这周未留存行动计划。", "No action plan was saved for this week."))
            }
            sectionShortcut(weeklyReviewText("打开行动", "Open Actions"), .shortActions)
        }
    }

    private func dayPicker(_ report: WeeklyReview, selected: Date?, choose: @escaping (Date) -> Void) -> some View {
        let peak = max(report.days.map(\.focusSeconds).max() ?? 0, 1)
        return panel(weeklyReviewText("七日记录", "Seven-Day Activity")) {
            Text(weeklyReviewText("选择日期查看当天记录。条形表示专注时长。", "Select a date for its records. Bars show focus time."))
                .font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    ForEach(report.days) { day in
                        dayButton(day, selected: selected, today: report.today, peak: peak, choose: choose)
                            .frame(minWidth: 76)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                    ForEach(report.days) { day in
                        dayButton(day, selected: selected, today: report.today, peak: peak, choose: choose)
                    }
                }
            }
        }
    }

    private func dayButton(_ day: WeeklyReview.Day, selected: Date?, today: Date, peak: TimeInterval,
                           choose: @escaping (Date) -> Void) -> some View {
        let active = selected.map { calendar.isDate(day.date, inSameDayAs: $0) } ?? false
        let current = calendar.isDate(day.date, inSameDayAs: today)
        let focus = estimate(day.focusSeconds, estimated: day.focusEstimated)
        let habits = day.habitPlan.map { "\(day.habits.count)/\($0)" } ?? String(day.habits.count)
        return Button { choose(day.date) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(weeklyReviewFormat(day.date, template: "EEE")).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(weeklyReviewFormat(day.date, template: "d"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(current ? Color.accentColor : Color.primary)
                }
                ProgressView(value: day.focusSeconds, total: peak)
                    .progressViewStyle(.linear)
                Label(focus, systemImage: "timer")
                Label(habits, systemImage: "checkmark.circle")
            }
            .font(.caption2)
            .monospacedDigit()
            .frame(maxWidth: .infinity, minHeight: 65, alignment: .leading)
            .padding(7)
            .background(Color.accentColor.opacity(active ? 0.13 : 0.035), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(active ? Color.accentColor : Color.primary.opacity(0.13))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(weeklyReviewFullDate(day.date))
        .accessibilityValue(weeklyReviewText("专注 \(focus)，打卡 \(habits)", "Focus \(focus), habit check-ins \(habits)"))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func dailyRecords(_ day: WeeklyReview.Day, sleepUnavailable: Bool, backToDates: @escaping () -> Void) -> some View {
        panel(weeklyReviewFullDate(day.date)) {
            HStack {
                Text(weeklyReviewText("当天记录", "Daily Records")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: backToDates) {
                    Label(weeklyReviewText("返回日期", "Back to Dates"), systemImage: "chevron.up")
                }
                .buttonStyle(.borderless)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 275), spacing: 10)], alignment: .leading, spacing: 10) {
                recordGroup(weeklyReviewText("专注", "Focus"), "timer", .focus, empty: day.focus.isEmpty,
                            emptyText: weeklyReviewText("当天没有已保存的专注。", "No saved focus sessions for this day.")) {
                    ForEach(day.focus) { entry in
                        original(entry.record.title, subtitle: recordTimes(entry.record.startedAt, entry.record.endedAt),
                                 value: estimate(entry.seconds, estimated: entry.estimated), destination: .focus(entry.record.id))
                    }
                }
                recordGroup(weeklyReviewText("打卡", "Habit Check-ins"), "checkmark.circle", .habits, empty: day.habits.isEmpty,
                            emptyText: weeklyReviewText("当天没有完成打卡。", "No habit check-ins for this day.")) {
                    ForEach(day.habits) { entry in
                        original(entry.title ?? RhythmLocalization.text("已删除打卡"),
                                 destination: .habit(WeeklyReviewHabitLocation(
                                    id: entry.id, date: day.date, completionKey: entry.completionKey
                                 )))
                    }
                }
                recordGroup(weeklyReviewText("睡眠", "Sleep"), "moon.stars", .sleep, empty: day.sleep.isEmpty,
                            emptyText: sleepUnavailable ? weeklyReviewText("共享睡眠资料暂不可用。", "Shared sleep records are unavailable.") :
                                weeklyReviewText("当天没有睡眠记录。", "No sleep entries for this day.")) {
                    ForEach(day.sleep) { entry in
                        original(weeklyReviewText("睡眠记录", "Sleep Entry"), subtitle: recordTimes(entry.startedAt, entry.endedAt),
                                 value: duration(entry.durationSeconds), destination: .sleep(entry.id))
                    }
                }
                recordGroup(weeklyReviewText("短期行动", "Short Actions"), "list.bullet", .shortActions, empty: day.actions.isEmpty,
                            emptyText: weeklyReviewText("当天没有完成短期行动。", "No short actions completed on this day.")) {
                    ForEach(day.actions) { entry in
                        original(entry.title, subtitle: entry.completedAt.map { weeklyReviewFormat($0, template: "jmm") },
                                 destination: .action(entry.id))
                    }
                }
                recordGroup(weeklyReviewText("长期目标", "Long-term Goals"), "flag", .longGoals, empty: day.goals.isEmpty,
                            emptyText: weeklyReviewText("当天没有完成长期目标。", "No long-term goals completed on this day.")) {
                    ForEach(day.goals) { entry in
                        original(entry.title, subtitle: entry.completedAt.map { weeklyReviewFormat($0, template: "jmm") },
                                 value: entry.status.title, destination: .goal(entry.id))
                    }
                }
            }
        }
        .accessibilityIdentifier("rhythm.weeklyReview.dayRecords")
    }

    private func recordGroup<Rows: View>(
        _ label: String, _ symbol: String, _ section: RhythmSection, empty: Bool, emptyText: String,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(label, systemImage: symbol).font(.callout.weight(.semibold))
                Spacer(minLength: 5)
                sectionShortcut(weeklyReviewText("打开列表", "Open List"), section)
                    .accessibilityLabel(weeklyReviewText("打开\(label)列表", "Open \(label) List"))
            }
            if empty { quiet(emptyText) } else { rows() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func original(_ title: String, subtitle: String? = nil, value: String? = nil,
                          destination: WeeklyReviewDestination) -> some View {
        Button { open(destination) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 4)
                if let value { Text(value).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(weeklyReviewText("打开这条原记录", "Open the original record"))
    }

    private func sectionShortcut(_ title: String, _ section: RhythmSection) -> some View {
        Button(title) { open(.list(section)) }
            .buttonStyle(.borderless)
            .font(.caption)
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func panel<Body: View>(_ title: String, @ViewBuilder body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            body()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.09)) }
    }

    private func range(_ start: Date, _ end: Date, style: DateIntervalFormatter.Style = .short) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = RhythmLocalization.language.locale
        formatter.dateStyle = style
        formatter.timeStyle = .none
        return formatter.string(from: start, to: end)
    }

    private func recordTimes(_ start: Date, _ end: Date) -> String {
        weeklyReviewFormat(start, template: "MMMdjmm") + " – " + weeklyReviewFormat(end, template: "MMMdjmm")
    }

    private func duration(_ seconds: TimeInterval) -> String {
        if seconds > 0 && seconds < 60 { return weeklyReviewText("不足 1 分钟", "<1 min") }
        return RhythmFormatters.duration(seconds, showSeconds: false)
    }

    private func estimate(_ seconds: TimeInterval, estimated: Bool) -> String {
        (estimated ? weeklyReviewText("约 ", "≈ ") : "") + duration(seconds)
    }

    private func count(_ count: Int?, _ chinese: String, _ singular: String, _ plural: String) -> String {
        guard let count else { return "—" }
        return String(count) + weeklyReviewText(chinese, count == 1 ? singular : plural)
    }
}
