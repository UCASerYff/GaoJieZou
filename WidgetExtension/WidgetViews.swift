import SwiftUI

enum RhythmWidgetTheme {
    static let blue = Color(red: 0.20, green: 0.45, blue: 0.82)
    static let teal = Color(red: 0.16, green: 0.63, blue: 0.53)
    static let purple = Color(red: 0.48, green: 0.36, blue: 0.78)
    static let orange = Color(red: 0.92, green: 0.53, blue: 0.20)
    static let ink = Color(red: 0.10, green: 0.13, blue: 0.19)

    static func color(hex: String?) -> Color {
        guard let hex, let rgb = RhythmShared.rgbComponents(hex: hex) else { return orange }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

enum RhythmWidgetLocale {
    static var english: Bool {
        UserDefaults.standard.string(forKey: "rhythm.language") == "en"
    }

    /// 口径在 RhythmShared.monthFormatter（与主程序 RhythmFormatters.month 共用）。
    static var monthFormatter: DateFormatter {
        RhythmShared.monthFormatter(english: english)
    }

    /// 小组件专用精简时长：截断到分钟、文案用「分」。主程序 RhythmFormatters.duration
    /// 语义不同（可显示秒、文案用「分钟」），刻意不合并；改动时请对照两处。
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 60 { return english ? "\(minutes)m" : "\(minutes)分" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 { return english ? "\(hours)h" : "\(hours)小时" }
        return english ? "\(hours)h \(remainder)m" : "\(hours)小时\(remainder)分"
    }
}

struct RhythmWidgetEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAction: Bool
    let colorHex: String?
    let createdAt: Date
    let sequence: Int
}

struct RhythmWidgetEventSegment: Identifiable {
    let event: RhythmWidgetEvent
    let first: Int
    let last: Int
    let lane: Int
    var id: String { event.id }
}

private func monthDates(for date: Date, calendar: Calendar) -> [Date?] {
    RhythmShared.monthGridDates(for: date, calendar: calendar)
}

// Capacity is based on complete readable rows; no fixed record limit.
func widgetRowCapacity(height: CGFloat, rowHeight: CGFloat, spacing: CGFloat = 0) -> Int {
    guard rowHeight > 0, height > 0 else { return 0 }
    return max(0, Int((height + spacing) / (rowHeight + spacing)))
}

func widgetEvents(from data: RhythmWidgetData, calendar: Calendar) -> [RhythmWidgetEvent] {
    var result = data.chores.enumerated().filter { !$0.element.isCompleted }.map { index, chore in
        RhythmWidgetEvent(id: "chore-\(chore.id)", title: chore.title, start: chore.startDate,
                          end: max(chore.startDate, chore.endDate), isAction: false, colorHex: chore.colorHex,
                          createdAt: chore.createdAt ?? chore.startDate, sequence: index)
    }
    result += data.shortActions.enumerated().compactMap { index, action in
        guard !action.isCompleted, let start = action.startDate else { return nil }
        return RhythmWidgetEvent(id: "action-\(action.id)", title: action.title, start: start,
                                 end: max(start, action.endDate ?? start), isAction: true, colorHex: nil,
                                 createdAt: action.createdAt ?? start, sequence: index)
    }
    return result.sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
        if $0.sequence != $1.sequence { return $0.sequence > $1.sequence }
        return $0.id < $1.id
    }
}

func eventSegments(for week: [Date?], events: [RhythmWidgetEvent], calendar: Calendar, capacity: Int) -> [RhythmWidgetEventSegment] {
    // Lane assignment lives in RhythmShared (occupied-days reuse, README V3.5);
    // hidden events get a nil lane and never reserve a visible lane.
    let occupiedList = events.map {
        RhythmShared.occupiedColumns(in: week, start: $0.start, end: $0.end, calendar: calendar)
    }
    let lanes = RhythmShared.assignLanes(occupiedColumns: occupiedList, capacity: capacity)
    var result: [RhythmWidgetEventSegment] = []
    for (index, event) in events.enumerated() {
        guard let lane = lanes[index],
              let first = occupiedList[index].min(),
              let last = occupiedList[index].max() else { continue }
        result.append(RhythmWidgetEventSegment(event: event, first: first, last: last, lane: lane))
    }
    return result
}

struct RhythmWidgetMonthlyOverviewView: View {
    let entry: RhythmWidgetEntry
    private let calendar = Calendar.current

    private var dates: [Date?] { monthDates(for: entry.date, calendar: calendar) }
    private var weeks: [[Date?]] {
        stride(from: 0, to: dates.count, by: 7).map {
            Array(dates[$0..<min($0 + 7, dates.count)]) + Array<Date?>(repeating: nil, count: max(0, 7 - min(7, dates.count - $0)))
        }
    }
    private var events: [RhythmWidgetEvent] { widgetEvents(from: entry.data, calendar: calendar) }
    private var weekdayTitles: [String] {
        let base = RhythmWidgetLocale.english ? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] : ["日", "一", "二", "三", "四", "五", "六"]
        let offset = calendar.firstWeekday - 1
        return Array(base[offset...] + base[..<offset])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label(RhythmWidgetLocale.english ? "Monthly overview" : "月度总览", systemImage: "calendar")
                    .font(.headline.weight(.bold))
                Spacer()
                Text(RhythmWidgetLocale.monthFormatter.string(from: entry.date))
                    .font(.caption.weight(.semibold))
            }
            HStack(spacing: 4) {
                ForEach(weekdayTitles, id: \.self) { title in
                    Text(title).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            GeometryReader { proxy in
                VStack(spacing: 3) {
                    ForEach(weeks.indices, id: \.self) { index in
                        RhythmWidgetMonthWeekView(week: weeks[index], events: events, data: entry.data, referenceDate: entry.date, calendar: calendar, height: max(20, (proxy.size.height - CGFloat(weeks.count - 1) * 3) / CGFloat(max(1, weeks.count))))
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(RhythmWidgetTheme.ink)
        .background(Color.white)
        .containerBackground(for: .widget) { Color.white }
        .widgetURL(URL(string: "gaojiezou://today"))
    }
}

private struct RhythmWidgetMonthWeekView: View {
    let week: [Date?]
    let events: [RhythmWidgetEvent]
    let data: RhythmWidgetData
    let referenceDate: Date
    let calendar: Calendar
    private let gap: CGFloat = 4
    let height: CGFloat
    private let barTop: CGFloat = 16
    private let laneHeight: CGFloat = 9
    private var laneCapacity: Int { widgetRowCapacity(height: height - barTop, rowHeight: laneHeight) }
    private var spans: [RhythmWidgetEventSegment] {
        eventSegments(for: week, events: events, calendar: calendar, capacity: laneCapacity)
    }

    var body: some View {
        GeometryReader { geometry in
            let cellWidth = max(0, (geometry.size.width - gap * 6) / 7)
            ZStack(alignment: .topLeading) {
                HStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { index in
                        if let date = week[index] {
                            widgetDayCell(date, width: cellWidth)
                        } else {
                            Color.clear.frame(width: cellWidth, height: height)
                        }
                    }
                }
                ForEach(spans) { span in
                    let tint = span.event.isAction ? RhythmWidgetTheme.blue : RhythmWidgetTheme.color(hex: span.event.colorHex)
                    Label(span.event.title, systemImage: span.event.isAction ? "flag.fill" : "tray.full.fill")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 3)
                        .frame(width: max(0, CGFloat(span.last - span.first + 1) * (cellWidth + gap) - gap - 3), height: laneHeight - 1, alignment: .leading)
                        .background(tint, in: RoundedRectangle(cornerRadius: 3))
                        .offset(x: CGFloat(span.first) * (cellWidth + gap) + 2, y: barTop + CGFloat(span.lane) * laneHeight)
                }
            }
            .clipped()
        }
        .frame(height: height)
    }

    private func widgetDayCell(_ date: Date, width: CGFloat) -> some View {
        let isToday = calendar.isDate(date, inSameDayAs: referenceDate)
        return VStack(alignment: .leading, spacing: 1) {
            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 10, weight: isToday ? .bold : .semibold).monospacedDigit())
        }
        .font(.system(size: 7, weight: .medium).monospacedDigit())
        .padding(5)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(Color.white.opacity(isToday ? 0.74 : 0.48), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isToday ? RhythmWidgetTheme.blue : Color.black.opacity(0.06), lineWidth: isToday ? 1.2 : 0.6))
        .opacity(date > referenceDate ? 0.74 : 1)
    }
}

struct RhythmWidgetMetricsView: View {
    let entry: RhythmWidgetEntry
    var body: some View {
        let stats = entry.data.habitStats(on: entry.date)
        VStack(alignment: .leading, spacing: 7) {
            Label(RhythmWidgetLocale.english ? "Rhythm" : "搞节奏", systemImage: "leaf.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(RhythmWidgetTheme.green)
            RhythmWidgetMetricRow(symbol: "checkmark.circle.fill", tint: RhythmWidgetTheme.teal,
                                  value: "\(stats.completed)/\(stats.total)", label: RhythmWidgetLocale.english ? "Today's goals" : "今日目标")
            RhythmWidgetMetricRow(symbol: "timer", tint: RhythmWidgetTheme.blue,
                                  value: RhythmWidgetLocale.duration(entry.data.focusSeconds(on: entry.date, now: entry.date)), label: RhythmWidgetLocale.english ? "Focus today" : "今日专注")
            RhythmWidgetMetricRow(symbol: "moon.stars.fill", tint: RhythmWidgetTheme.purple,
                                  value: entry.data.lastNightSleepDuration(on: entry.date).map(RhythmWidgetLocale.duration) ?? "—", label: RhythmWidgetLocale.english ? "Last night's sleep" : "昨夜睡眠")
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(RhythmWidgetTheme.ink)
        .background(Color.white)
        .containerBackground(for: .widget) { Color.white }
        .widgetURL(URL(string: "gaojiezou://today"))
    }
}

private extension RhythmWidgetTheme {
    static let green = Color(red: 0.24, green: 0.62, blue: 0.36)
}

private struct RhythmWidgetMetricRow: View {
    let symbol: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 13, weight: .bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct RhythmWidgetGoalsView: View {
    let entry: RhythmWidgetEntry

    private var rows: [(goal: RhythmWidgetData.LongGoal, completed: Int, total: Int)] {
        dataRows.sorted { lhs, rhs in
            let leftDate = lhs.goal.createdAt ?? .distantPast
            let rightDate = rhs.goal.createdAt ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            // Arrays in older archives were appended in creation order.
            return (entry.data.longGoals.firstIndex { $0.id == lhs.goal.id } ?? 0)
                > (entry.data.longGoals.firstIndex { $0.id == rhs.goal.id } ?? 0)
        }
    }

    private var dataRows: [(goal: RhythmWidgetData.LongGoal, completed: Int, total: Int)] {
        entry.data.longGoals.map { goal in
            let actions = entry.data.shortActions.filter { $0.goalID == goal.id }
            return (goal, actions.filter(\.isCompleted).count, actions.count)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(RhythmWidgetLocale.english ? "Long-term goals" : "长期目标", systemImage: "flag.checkered")
                    .font(.headline.weight(.bold))
                Spacer()
                Text("\(rows.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text(RhythmWidgetLocale.english ? "No long-term goals yet." : "还没有长期目标。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                GeometryReader { geometry in
                    let capacity = widgetRowCapacity(height: geometry.size.height, rowHeight: 12, spacing: 1)
                    let visible = Array(rows.prefix(capacity))
                    VStack(alignment: .leading, spacing: 1) {
                    ForEach(visible, id: \.goal.id) { row in
                        let isComplete = row.goal.status == "completed"
                        HStack(spacing: 4) {
                            Image(systemName: isComplete ? "checkmark.square.fill" : "square")
                                .foregroundStyle(isComplete ? RhythmWidgetTheme.teal : RhythmWidgetTheme.blue)
                            Text("\(row.goal.title) (\(row.completed)/\(row.total))")
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .strikethrough(isComplete)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 10))
                        .frame(height: 12)
                        .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                    }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .clipped()
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(RhythmWidgetTheme.ink)
        .background(Color.white)
        .containerBackground(for: .widget) { Color.white }
        .widgetURL(URL(string: "gaojiezou://longGoals"))
    }
}
