import SwiftUI

private struct MonthSpan: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAction: Bool
    let colorHex: String?
}

private struct WeekSpan: Identifiable {
    let event: MonthSpan
    let first: Int
    let last: Int
    let lane: Int
    var id: String { event.id }
}

/// Each week owns its event lanes so a range is clipped and continued at week boundaries.
struct SpanningMonthGrid<Day: View>: View {
    @EnvironmentObject private var store: RhythmStore
    let dates: [Date?]
    let weekdayTitles: [String]
    var includeActions = false
    let headerHeight: CGFloat
    @ViewBuilder let dayContent: (Date) -> Day
    private let gap: CGFloat = 8
    private let laneHeight: CGFloat = 26

    private var events: [MonthSpan] {
        var items = store.chores.filter { !$0.isCompleted }.map {
            MonthSpan(id: "chore-" + $0.id, title: $0.title, start: $0.startDate, end: $0.endDate, isAction: false, colorHex: $0.colorHex)
        }
        if includeActions {
            items += store.shortActions.compactMap { action -> MonthSpan? in
                // Legacy dueDate is populated even for unscheduled actions.
                guard !action.isCompleted, let start = action.startDate else { return nil }
                return MonthSpan(id: "action-" + action.id, title: action.title,
                                 start: start,
                          end: action.normalizedEndDate ?? start, isAction: true, colorHex: nil)
            }
        }
        return items.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end > $1.end }
            return $0.id < $1.id
        }
    }

    private func segments(for week: [Date?]) -> [WeekSpan] {
        let calendar = Calendar.current
        let occupiedList = events.map {
            RhythmShared.occupiedColumns(in: week, start: $0.start, end: $0.end, calendar: calendar)
        }
        let lanes = RhythmShared.assignLanes(occupiedColumns: occupiedList)
        var result: [WeekSpan] = []
        for (index, event) in events.enumerated() {
            guard let lane = lanes[index],
                  let first = occupiedList[index].min(),
                  let last = occupiedList[index].max() else { continue }
            result.append(WeekSpan(event: event, first: first, last: last, lane: lane))
        }
        return result
    }

    var body: some View {
        VStack(spacing: gap) {
            HStack(spacing: gap) {
                ForEach(Array(weekdayTitles.enumerated()), id: \.offset) { _, title in
                    Text(title).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<((dates.count + 6) / 7), id: \.self) { row in
                let slice = Array(dates[(row * 7)..<min(dates.count, row * 7 + 7)])
                let week = slice + Array<Date?>(repeating: nil, count: 7 - slice.count)
                let spans = segments(for: week)
                let lanes = (spans.map(\.lane).max() ?? -1) + 1
                let height = headerHeight + max(30, CGFloat(lanes) * laneHeight + 8)
                GeometryReader { geometry in
                    let cellWidth = max(0, (geometry.size.width - gap * 6) / 7)
                    ZStack(alignment: .topLeading) {
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(0..<7, id: \.self) { column in
                                if let date = week[column] {
                                    dayContent(date)
                                        .frame(width: cellWidth, height: height, alignment: .topLeading)
                                        .background(RhythmTheme.orange.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                                } else {
                                    Color.clear.frame(width: cellWidth, height: height)
                                }
                            }
                        }
                        ForEach(spans) { span in
                            let tint = span.event.isAction
                                ? RhythmTheme.blue
                                : RhythmTheme.choreColor(hex: span.event.colorHex, fallbackIndex: spans.firstIndex(where: { $0.id == span.id }) ?? 0)
                            Label(span.event.title, systemImage: span.event.isAction ? "flag.fill" : "tray.full.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .frame(width: max(0, CGFloat(span.last - span.first + 1) * (cellWidth + gap) - gap - 6),
                                       height: laneHeight - 4, alignment: .leading)
                                .background(tint, in: RoundedRectangle(cornerRadius: 5))
                                .help("\(span.event.title) · \(RhythmFormatters.shortDate.string(from: span.event.start)) – \(RhythmFormatters.shortDate.string(from: span.event.end))")
                                .offset(x: CGFloat(span.first) * (cellWidth + gap) + 3,
                                        y: headerHeight + CGFloat(span.lane) * laneHeight)
                        }
                    }
                }
                .frame(height: height)
            }
        }
    }
}
