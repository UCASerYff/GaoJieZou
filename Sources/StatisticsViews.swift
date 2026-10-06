import Charts
import SwiftUI

// MARK: - 数据统计页

private enum StatisticsRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30

    var id: Int { rawValue }

    var title: String {
        RhythmLocalization.text(self == .week ? "近 7 天" : "近 30 天")
    }
}

private struct StatisticsDayValue: Identifiable {
    let date: Date
    let value: Double

    var id: Date { date }
}

struct StatisticsDashboard: View {
    @EnvironmentObject private var store: RhythmStore
    @EnvironmentObject private var settings: RhythmSettings
    @State private var focusRange: StatisticsRange = .week
    @State private var sleepRange: StatisticsRange = .week
    @State private var habitRange: StatisticsRange = .week

    private var calendar: Calendar { .current }

    private func recentDays(_ count: Int) -> [Date] {
        let today = calendar.startOfDay(for: Date())
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: -(count - 1 - $0), to: today) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                streakCard
                focusTrendCard
                sleepTrendCard
                habitCompletionCard
            }
            .frame(maxWidth: 1100)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    // MARK: - 连续打卡

    private var streakCard: some View {
        StatisticsCard(title: "连续打卡", subtitle: "当天安排的打卡全部完成计为达标日，无安排的日子不打断也不计数") {
            if store.habits.isEmpty {
                StatisticsGuidance(symbol: "checkmark.circle", text: "还没有打卡目标，先去「日常打卡」创建一个吧")
            } else {
                let streaks = store.habitStreaks()
                HStack(spacing: 12) {
                    StatTile(
                        value: RhythmLocalization.format("%d 天", streaks.current),
                        label: "当前连续",
                        symbol: "flame.fill",
                        color: RhythmTheme.orange
                    )
                    StatTile(
                        value: RhythmLocalization.format("%d 天", streaks.longest),
                        label: "历史最长",
                        symbol: "trophy.fill",
                        color: RhythmTheme.purple
                    )
                }
            }
        }
    }

    // MARK: - 专注趋势

    private var focusTrendCard: some View {
        StatisticsCard(title: "专注趋势", subtitle: "每日有效专注时长（含进行中专注归属当天的部分）", range: $focusRange) {
            let items = recentDays(focusRange.rawValue).map {
                StatisticsDayValue(date: $0, value: store.focusSeconds(on: $0) / 60)
            }
            let total = items.reduce(0) { $0 + $1.value }
            if total <= 0 {
                StatisticsGuidance(symbol: "timer", text: "这段时间没有专注记录，从「工作专注」开始第一段专注")
            } else {
                Chart(items) { item in
                    BarMark(
                        x: .value(RhythmLocalization.text("日期"), item.date, unit: .day),
                        y: .value(RhythmLocalization.text("分钟"), item.value)
                    )
                    .foregroundStyle(RhythmTheme.blue.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis { dayAxis(stride: focusRange == .week ? 1 : 5) }
                .frame(height: 180)

                HStack(spacing: 16) {
                    Label(RhythmLocalization.format("合计 %@", minutesText(total)), systemImage: "sum")
                    Label(RhythmLocalization.format("日均 %@", minutesText(total / Double(items.count))), systemImage: "chart.line.uptrend.xyaxis")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 睡眠趋势

    private var sleepTrendCard: some View {
        StatisticsCard(title: "睡眠趋势", subtitle: "每晚睡眠时长（昨夜口径），虚线为睡眠目标", range: $sleepRange) {
            let items = recentDays(sleepRange.rawValue).compactMap { day -> StatisticsDayValue? in
                store.lastNightSleepDuration(on: day).map { StatisticsDayValue(date: day, value: $0 / 3600) }
            }
            if items.isEmpty {
                StatisticsGuidance(symbol: "moon.stars", text: "这段时间没有睡眠记录，从「睡眠计时」记录第一晚")
            } else {
                let target = settings.sleepTargetHours
                Chart {
                    ForEach(items) { item in
                        BarMark(
                            x: .value(RhythmLocalization.text("日期"), item.date, unit: .day),
                            y: .value(RhythmLocalization.text("小时"), item.value)
                        )
                        .foregroundStyle(RhythmTheme.purple.gradient)
                        .cornerRadius(3)
                    }
                    RuleMark(y: .value(RhythmLocalization.text("睡眠目标"), target))
                        .foregroundStyle(RhythmTheme.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text(RhythmLocalization.format("目标 %.1f 小时", target))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(RhythmTheme.orange)
                        }
                }
                .chartXAxis { dayAxis(stride: sleepRange == .week ? 1 : 5) }
                .frame(height: 180)

                let average = items.reduce(0) { $0 + $1.value } / Double(items.count)
                HStack(spacing: 16) {
                    Label(RhythmLocalization.format("日均 %.1f 小时（%d 晚有记录）", average, items.count), systemImage: "chart.line.uptrend.xyaxis")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 打卡完成率

    private var habitCompletionCard: some View {
        StatisticsCard(title: "打卡完成率", subtitle: "每天已完成打卡占已安排打卡的比例，无安排的日子不显示", range: $habitRange) {
            let items = recentDays(habitRange.rawValue).compactMap { day -> StatisticsDayValue? in
                let scheduled = store.habits(for: day)
                guard !scheduled.isEmpty else { return nil }
                let completed = scheduled.filter { store.isHabitCompleted($0, on: day) }.count
                return StatisticsDayValue(date: day, value: Double(completed) / Double(scheduled.count) * 100)
            }
            if items.isEmpty {
                StatisticsGuidance(symbol: "checkmark.circle", text: "这段时间没有安排任何打卡，去「日常打卡」创建目标后这里会出现趋势")
            } else {
                Chart(items) { item in
                    BarMark(
                        x: .value(RhythmLocalization.text("日期"), item.date, unit: .day),
                        y: .value(RhythmLocalization.text("完成率"), item.value)
                    )
                    .foregroundStyle(RhythmTheme.teal.gradient)
                    .cornerRadius(3)
                }
                .chartYScale(domain: 0...100)
                .chartXAxis { dayAxis(stride: habitRange == .week ? 1 : 5) }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel {
                            if let percent = value.as(Double.self) {
                                Text("\(Int(percent))%")
                            }
                        }
                    }
                }
                .frame(height: 180)

                let average = items.reduce(0) { $0 + $1.value } / Double(items.count)
                HStack(spacing: 16) {
                    Label(RhythmLocalization.format("日均完成率 %d%%", Int(average.rounded())), systemImage: "chart.line.uptrend.xyaxis")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 共用

    private func minutesText(_ minutes: Double) -> String {
        RhythmFormatters.duration(minutes * 60, showSeconds: false)
    }

    private func dayAxis(stride: Int) -> some AxisContent {
        AxisMarks(values: .stride(by: .day, count: stride)) {
            AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
            AxisValueLabel(format: .dateTime.month(.defaultDigits).day(.defaultDigits).locale(RhythmLocalization.language.locale))
        }
    }
}

// MARK: - 卡片骨架与空态

private struct StatisticsCard<Content: View>: View {
    let title: String
    let subtitle: String
    var range: Binding<StatisticsRange>? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(RhythmLocalization.text(title)).font(.headline)
                    Text(RhythmLocalization.text(subtitle))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let range {
                    Picker(selection: range) {
                        ForEach(StatisticsRange.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
            }
            content
        }
        .padding(16)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
}

private struct StatisticsGuidance: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(RhythmTheme.blue)
            Text(RhythmLocalization.text(text))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}
