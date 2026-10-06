import SwiftUI

private func covers(_ date: Date, start: Date, end: Date) -> Bool {
    let calendar = Calendar.current
    let day = calendar.startOfDay(for: date)
    return day >= calendar.startOfDay(for: start) && day <= calendar.startOfDay(for: end)
}

struct CalendarTasks: View {
    @EnvironmentObject private var store: RhythmStore
    let date: Date
    var includeActions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.chores.filter { !$0.isCompleted && covers(date, start: $0.startDate, end: $0.endDate) }) { chore in
                Label(chore.title, systemImage: chore.isCompleted ? "checkmark.circle.fill" : "tray.full.fill")
                    .strikethrough(chore.isCompleted)
                    .foregroundStyle(RhythmTheme.orange)
                    .help(chore.title)
            }
            if includeActions {
                ForEach(store.shortActions.filter { action in
                    guard !action.isCompleted else { return false }
                    if let start = action.startDate, let end = action.endDate {
                        return covers(date, start: start, end: end)
                    }
                    return Calendar.current.isDate(date, inSameDayAs: action.completedAt ?? action.dueDate)
                }) { action in
                    Label(action.title, systemImage: action.isCompleted ? "checkmark.circle.fill" : "flag.fill")
                        .strikethrough(action.isCompleted)
                        .foregroundStyle(RhythmTheme.blue)
                        .help(action.title)
                }
            }
        }
        .font(.caption2)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ChoreDashboard: View {
    @EnvironmentObject private var store: RhythmStore
    @State private var monthOffset = 0
    @State private var editor: Chore?
    @State private var deleting: Chore?
    private var calendar: Calendar { .current }
    private var month: Date {
        calendar.date(byAdding: .month, value: monthOffset,
                      to: calendar.dateInterval(of: .month, for: Date())!.start)!
    }
    private var dates: [Date?] {
        RhythmShared.monthGridDates(for: month, calendar: calendar)
    }
    private var ordered: [Chore] {
        store.chores.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.id < $1.id
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(RhythmLocalization.format("每项完成奖励 %d 金币；重新勾选不会重复奖励。", RhythmEconomy.choreCoins))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(RhythmLocalization.text("添加琐事"), systemImage: "plus") { editor = Chore() }
                        .buttonStyle(.borderedProminent)
                }
                VStack(spacing: 12) {
                    HStack {
                        Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel(RhythmLocalization.text("上个月"))
                        Text(RhythmFormatters.month.string(from: month)).font(.headline)
                        Button { monthOffset += 1 } label: { Image(systemName: "chevron.right") }
                            .accessibilityLabel(RhythmLocalization.text("下个月"))
                        Spacer()
                        Button(RhythmLocalization.text("本月")) { monthOffset = 0 }
                    }
                    SpanningMonthGrid(
                        dates: dates,
                        weekdayTitles: (0..<7).map { calendar.shortWeekdaySymbols[($0 + calendar.firstWeekday - 1) % 7] },
                        headerHeight: 36
                    ) { date in
                                VStack(alignment: .leading, spacing: 6) {
                                    Button {
                                        var draft = Chore()
                                        draft.startDate = date
                                        draft.endDate = date
                                        editor = draft
                                    } label: {
                                        Text("\(calendar.component(.day, from: date))")
                                            .font(.callout.bold())
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .background(RhythmTheme.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(calendar.isDateInToday(date) ? RhythmTheme.orange : Color.clear))
                    }
                }
                .padding(16)
                .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                if ordered.isEmpty {
                    Text(RhythmLocalization.text("还没有琐事，点击添加或选择月历中的日期开始。"))
                        .foregroundStyle(.secondary).padding()
                }
                ForEach(ordered) { chore in
                    HStack(spacing: 12) {
                        Button { store.toggleChore(chore.id) } label: {
                            Image(systemName: chore.isCompleted ? "checkmark.circle.fill" : "circle")
                                .font(.title2).foregroundStyle(RhythmTheme.orange)
                        }.buttonStyle(.plain)
                        Circle()
                            .fill(RhythmTheme.choreColor(hex: chore.colorHex,
                                                          fallbackIndex: ordered.firstIndex(of: chore) ?? 0))
                            .frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chore.title).strikethrough(chore.isCompleted)
                            Text("\(RhythmFormatters.shortDate.string(from: chore.startDate)) – \(RhythmFormatters.shortDate.string(from: chore.endDate))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(chore.rewardClaimed ? RhythmLocalization.text("奖励已领取") : "+5 🪙")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(RhythmLocalization.text("修改")) { editor = chore }
                        Button(RhythmLocalization.text("删除"), role: .destructive) { deleting = chore }
                    }
                    .padding(14)
                    .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: 1200)
            .padding(24)
        }
        .sheet(item: $editor) { chore in ChoreEditor(draft: chore) }
        .alert(RhythmLocalization.text("删除琐事？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(RhythmLocalization.text("取消"), role: .cancel) { deleting = nil }
            Button(RhythmLocalization.text("删除"), role: .destructive) {
                if let chore = deleting { store.deleteChore(chore.id) }
                deleting = nil
            }
        }
    }
}

private struct ChoreEditor: View {
    @EnvironmentObject private var store: RhythmStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: Chore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(RhythmLocalization.text("一些琐事")).font(.title2.bold())
            TextField(RhythmLocalization.text("琐事名称"), text: $draft.title)
            DatePicker(RhythmLocalization.text("开始日期"), selection: $draft.startDate, displayedComponents: .date)
            DatePicker(RhythmLocalization.text("结束日期"), selection: $draft.endDate, displayedComponents: .date)
            VStack(alignment: .leading, spacing: 9) {
                Text(RhythmLocalization.text("显示颜色")).font(.callout.weight(.medium))
                HStack(spacing: 8) {
                    ForEach(Array(RhythmTheme.choreColors.enumerated()), id: \.element.id) { _, option in
                        Button {
                            draft.colorHex = option.hex
                        } label: {
                            ZStack {
                                Circle().fill(option.color).frame(width: 24, height: 24)
                                if draft.colorHex == option.hex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help(RhythmLocalization.text(option.title))
                    }
                    ColorPicker(RhythmLocalization.text("自定义"), selection: Binding(
                        get: { RhythmTheme.choreColor(hex: draft.colorHex) },
                        set: { draft.colorHex = RhythmTheme.hex(for: $0) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .help(RhythmLocalization.text("自定义颜色"))
                }
            }
            if draft.endDate < draft.startDate {
                Text(RhythmLocalization.text("结束日期不能早于开始日期")).foregroundStyle(.red)
            }
            HStack {
                Button(RhythmLocalization.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(RhythmLocalization.text("保存")) { store.saveChore(draft); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.endDate < draft.startDate)
            }
        }
        .padding(24).frame(minWidth: 400, idealWidth: 440)
    }
}
