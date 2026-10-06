import Charts
import SwiftUI

struct LongGoalDashboard: View {
    @EnvironmentObject private var store: RhythmStore
    @State private var showingEditor = false
    @State private var editingGoal: LongGoal?
    @State private var deleteCandidate: LongGoal?

    private var activeCount: Int { store.longGoals.filter { $0.status == .active }.count }
    private var completedCount: Int { store.longGoals.filter { $0.status == .completed }.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    StatTile(value: "\(activeCount)", label: "进行中", symbol: "play.circle.fill", color: RhythmTheme.blue)
                    StatTile(value: "\(store.shortActions.filter { !$0.isCompleted }.count)", label: "待完成行动", symbol: "list.bullet.clipboard.fill", color: RhythmTheme.orange)
                    StatTile(value: "\(completedCount)", label: "已完成长期目标", symbol: "checkmark.seal.fill", color: RhythmTheme.teal)
                }

                if !store.longGoals.isEmpty {
                    LongGoalGanttChart(goals: store.longGoals)
                }

                HStack {
                    Text(RhythmLocalization.text("长期目标")).font(.headline)
                    Spacer()
                    Button {
                        editingGoal = nil
                        showingEditor = true
                    } label: {
                        Label(RhythmLocalization.text("新建长期目标"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if store.longGoals.isEmpty {
                    EmptyStateView(symbol: "flag.checkered", title: "还没有长期目标", message: "描述想达到的结果、衡量方式和期望日期，再把它拆成短期行动。", actionTitle: "新建长期目标") {
                        editingGoal = nil
                        showingEditor = true
                    }
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(store.longGoals.sorted(by: goalSort)) { goal in
                            LongGoalCard(goal: goal) {
                                editingGoal = goal
                                showingEditor = true
                            } delete: {
                                deleteCandidate = goal
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1000)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .sheet(isPresented: $showingEditor) {
            LongGoalEditor(goal: editingGoal)
                .environmentObject(store)
        }
        .alert(RhythmLocalization.text("删除这个长期目标？"), isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )) {
            Button(RhythmLocalization.text("取消"), role: .cancel) { deleteCandidate = nil }
            Button(RhythmLocalization.text("删除"), role: .destructive) {
                if let deleteCandidate { store.deleteGoal(deleteCandidate) }
                deleteCandidate = nil
            }
        } message: {
            Text(RhythmLocalization.text("关联的短期行动会保留，但会变成未归属状态。"))
        }
    }

    private func goalSort(_ lhs: LongGoal, _ rhs: LongGoal) -> Bool {
        if lhs.status == .completed && rhs.status != .completed { return false }
        if lhs.status != .completed && rhs.status == .completed { return true }
        return lhs.targetDate < rhs.targetDate
    }
}

private struct LongGoalCard: View {
    @EnvironmentObject private var store: RhythmStore
    let goal: LongGoal
    let edit: () -> Void
    let delete: () -> Void

    private var progress: Double { store.goalProgress(goal) }
    private var actions: [ShortAction] { store.actions(for: goal.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: goal.status.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 42, height: 42)
                    .background(statusColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(goal.status.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor)
                        Text(RhythmLocalization.format("目标日期 %@", RhythmFormatters.shortDate.string(from: goal.targetDate)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(goal.title).font(.title3.weight(.semibold))
                    if !goal.outcome.isEmpty {
                        Text(goal.outcome).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Menu {
                    ForEach(GoalStatus.allCases) { status in
                        Button {
                            store.setGoalStatus(goal, status: status)
                        } label: {
                            Label(status.title, systemImage: status.symbol)
                        }
                    }
                    Divider()
                    Button(action: edit) { Label(RhythmLocalization.text("编辑"), systemImage: "square.and.pencil") }
                    Button(role: .destructive, action: delete) { Label(RhythmLocalization.text("删除"), systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(RhythmLocalization.text("更多操作"))
            }

            VStack(spacing: 6) {
                HStack {
                    Text(RhythmLocalization.text("总体进度")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                ProgressView(value: progress)
                    .tint(statusColor)
            }

            HStack(spacing: 18) {
                Label("\(goal.currentValue.formatted()) / \(goal.targetValue.formatted()) \(goal.unit)", systemImage: "target")
                Label(RhythmLocalization.format("%d / %d 项行动", actions.filter(\.isCompleted).count, actions.count), systemImage: "list.bullet")
                Label(RhythmFormatters.duration(actions.reduce(0) { $0 + $1.focusedSeconds }, showSeconds: false), systemImage: "timer")
                Spacer()
                if !goal.rewardClaimed {
                    Text(RhythmLocalization.format(
                        "完成奖励：%d 🪙 · %d 🎣",
                        RhythmEconomy.longGoalCoins,
                        RhythmEconomy.longGoalBait
                    ))
                        .font(.caption).foregroundStyle(RhythmTheme.orange)
                } else {
                    Label(RhythmLocalization.text("奖励已领取"), systemImage: "gift.fill")
                        .font(.caption).foregroundStyle(RhythmTheme.teal)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }

    private var statusColor: Color {
        switch goal.status {
        case .planned: .secondary
        case .active: RhythmTheme.blue
        case .paused: RhythmTheme.orange
        case .completed: RhythmTheme.teal
        }
    }
}

private struct LongGoalEditor: View {
    @EnvironmentObject private var store: RhythmStore
    @Environment(\.dismiss) private var dismiss
    let goal: LongGoal?
    @State private var title: String
    @State private var reason: String
    @State private var outcome: String
    @State private var targetValue: Double
    @State private var currentValue: Double
    @State private var unit: String
    @State private var startDate: Date
    @State private var targetDate: Date
    @State private var status: GoalStatus

    init(goal: LongGoal?) {
        self.goal = goal
        let now = Date()
        _title = State(initialValue: goal?.title ?? "")
        _reason = State(initialValue: goal?.reason ?? "")
        _outcome = State(initialValue: goal?.outcome ?? "")
        _targetValue = State(initialValue: goal?.targetValue ?? 1)
        _currentValue = State(initialValue: goal?.currentValue ?? 0)
        _unit = State(initialValue: goal?.unit ?? "项")
        _startDate = State(initialValue: goal?.startDate ?? now)
        _targetDate = State(initialValue: goal?.targetDate ?? Calendar.current.date(byAdding: .month, value: 1, to: now) ?? now)
        _status = State(initialValue: goal?.status ?? .active)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(RhythmLocalization.text(goal == nil ? "新建长期目标" : "编辑长期目标")).font(.title2.weight(.semibold))
                    Text(RhythmLocalization.text("长期目标描述结果，具体执行步骤放在短期行动中。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(RhythmLocalization.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(RhythmLocalization.text("保存")) {
                    store.saveGoal(
                        existingID: goal?.id,
                        title: title,
                        reason: reason,
                        outcome: outcome,
                        targetValue: targetValue,
                        currentValue: currentValue,
                        unit: unit,
                        startDate: startDate,
                        targetDate: targetDate,
                        status: status
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(22)
            Divider()
            Form {
                TextField(RhythmLocalization.text("目标名称"), text: $title)
                TextField(RhythmLocalization.text("为什么要完成它"), text: $reason, axis: .vertical)
                    .lineLimit(2...4)
                TextField(RhythmLocalization.text("最终希望得到什么结果"), text: $outcome, axis: .vertical)
                    .lineLimit(2...4)
                HStack {
                    TextField(RhythmLocalization.text("当前值"), value: $currentValue, format: .number)
                    Text("/").foregroundStyle(.secondary)
                    TextField(RhythmLocalization.text("目标值"), value: $targetValue, format: .number)
                    TextField(RhythmLocalization.text("单位"), text: $unit).frame(width: 100)
                }
                DatePicker(RhythmLocalization.text("开始日期"), selection: $startDate, displayedComponents: .date)
                DatePicker(RhythmLocalization.text("期望完成日期"), selection: $targetDate, in: startDate..., displayedComponents: .date)
                Picker(RhythmLocalization.text("状态"), selection: $status) {
                    ForEach(GoalStatus.allCases) { status in Text(status.title).tag(status) }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 560, idealHeight: 620)
    }
}

private struct ShortActionEditorRoute: Identifiable {
    let id: String
    let action: ShortAction?

    static func create() -> ShortActionEditorRoute {
        ShortActionEditorRoute(id: "new-\(UUID().uuidString)", action: nil)
    }

    static func edit(_ action: ShortAction) -> ShortActionEditorRoute {
        ShortActionEditorRoute(id: "edit-\(action.id)", action: action)
    }
}

struct ShortActionDashboard: View {
    @EnvironmentObject private var store: RhythmStore
    @State private var editorRoute: ShortActionEditorRoute?
    @State private var deleteCandidate: ShortAction?
    @State private var goalFilter: String?

    private var displayed: [ShortAction] {
        store.shortActions
            .filter { goalFilter == nil || $0.goalID == goalFilter }
            .sorted {
                if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
                return ($0.startDate ?? $0.createdAt) < ($1.startDate ?? $1.createdAt)
            }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    StatTile(value: "\(store.shortActions.filter { !$0.isCompleted }.count)", label: "待完成", symbol: "circle.dashed", color: RhythmTheme.blue)
                    StatTile(value: "\(store.shortActions.filter(\.isCompleted).count)", label: "已完成", symbol: "checkmark.circle.fill", color: RhythmTheme.teal)
                    StatTile(value: RhythmFormatters.duration(store.shortActions.reduce(0) { $0 + $1.focusedSeconds }, showSeconds: false), label: "累计关联专注", symbol: "timer", color: RhythmTheme.purple)
                }

                ShortActionTwoMonthTimeline(actions: displayed)

                HStack {
                    Picker(RhythmLocalization.text("目标筛选"), selection: $goalFilter) {
                        Text(RhythmLocalization.text("全部长期目标")).tag(Optional<String>.none)
                        ForEach(store.longGoals) { goal in
                            Text(goal.title).tag(Optional(goal.id))
                        }
                    }
                    .frame(maxWidth: 360)
                    Spacer()
                    Button {
                        editorRoute = .create()
                    } label: {
                        Label(RhythmLocalization.text("新建短期行动"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if displayed.isEmpty {
                    EmptyStateView(symbol: "list.bullet.clipboard", title: "没有匹配的短期行动", message: "把长期目标拆成下一步可以明确完成的行动，并在专注时关联它。", actionTitle: "新建短期行动") {
                        editorRoute = .create()
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(displayed) { action in
                            ShortActionRow(action: action) {
                                editorRoute = .edit(action)
                            } delete: {
                                deleteCandidate = action
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1000)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .sheet(item: $editorRoute) { route in
            ShortActionEditor(action: route.action)
                .id(route.id)
                .environmentObject(store)
        }
        .alert(RhythmLocalization.text("删除这个短期行动？"), isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )) {
            Button(RhythmLocalization.text("取消"), role: .cancel) { deleteCandidate = nil }
            Button(RhythmLocalization.text("删除"), role: .destructive) {
                if let deleteCandidate { store.deleteAction(deleteCandidate) }
                deleteCandidate = nil
            }
        }
    }
}

private struct ShortActionRow: View {
    @EnvironmentObject private var store: RhythmStore
    let action: ShortAction
    let edit: () -> Void
    let delete: () -> Void

    private var goal: LongGoal? { store.longGoals.first { $0.id == action.goalID } }
    var body: some View {
        HStack(spacing: 14) {
            Button {
                store.toggleAction(action)
            } label: {
                Image(systemName: action.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(action.isCompleted ? RhythmTheme.teal : Color.secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 6) {
                Text(action.title)
                    .font(.headline)
                    .strikethrough(action.isCompleted)
                    .foregroundStyle(action.isCompleted ? .secondary : .primary)
                HStack(spacing: 12) {
                    Label(goal?.title ?? "未归属长期目标", systemImage: "flag")
                    if let start = action.startDate, let end = action.normalizedEndDate {
                        Label("\(RhythmFormatters.shortDate.string(from: start)) – \(RhythmFormatters.shortDate.string(from: end))", systemImage: "calendar")
                    }
                    Label(RhythmLocalization.format("预计 %d 分钟", action.estimatedMinutes), systemImage: "hourglass")
                    Label(RhythmLocalization.format("已专注 %@", RhythmFormatters.duration(action.focusedSeconds, showSeconds: false)), systemImage: "timer")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if action.rewardClaimed {
                Text(RhythmLocalization.text("奖励已领取"))
                    .font(.caption).foregroundStyle(RhythmTheme.teal)
            } else {
                Text(RhythmLocalization.format(
                    "%d 🪙 · %d 🎣",
                    RhythmEconomy.shortActionCoins,
                    RhythmEconomy.shortActionBait
                ))
                    .font(.caption).foregroundStyle(RhythmTheme.orange)
            }
            Menu {
                Button(action: edit) { Label(RhythmLocalization.text("编辑"), systemImage: "square.and.pencil") }
                Button(role: .destructive, action: delete) { Label(RhythmLocalization.text("删除"), systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(RhythmLocalization.text("更多操作"))
        }
        .padding(14)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
}

private struct ShortActionEditor: View {
    @EnvironmentObject private var store: RhythmStore
    @Environment(\.dismiss) private var dismiss
    let action: ShortAction?
    @State private var goalID: String?
    @State private var title: String
    @State private var notes: String
    @State private var hasTimeSpan: Bool
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var estimatedMinutes: Int
    @State private var isCompleted: Bool

    init(action: ShortAction?) {
        self.action = action
        _goalID = State(initialValue: action?.goalID)
        _title = State(initialValue: action?.title ?? "")
        _notes = State(initialValue: action?.notes ?? "")
        let defaultStart = action?.startDate ?? Date()
        _hasTimeSpan = State(initialValue: action?.startDate != nil)
        _startDate = State(initialValue: defaultStart)
        _endDate = State(initialValue: action?.normalizedEndDate ?? defaultStart)
        _estimatedMinutes = State(initialValue: action?.estimatedMinutes ?? 25)
        _isCompleted = State(initialValue: action?.isCompleted ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(RhythmLocalization.text(action == nil ? "新建短期行动" : "编辑短期行动")).font(.title2.weight(.semibold))
                    Text(RhythmLocalization.text("完成行动可获得金币和鱼饵，专注时间也可以归集到这里。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(RhythmLocalization.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(RhythmLocalization.text("保存")) {
                    store.saveAction(
                        existingID: action?.id,
                        goalID: goalID,
                        title: title,
                        notes: notes,
                        startDate: hasTimeSpan ? startDate : nil,
                        endDate: hasTimeSpan ? max(startDate, endDate) : nil,
                        estimatedMinutes: estimatedMinutes,
                        isCompleted: isCompleted
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(22)
            Divider()
            Form {
                TextField(RhythmLocalization.text("行动名称"), text: $title)
                Picker(RhythmLocalization.text("所属长期目标"), selection: $goalID) {
                    Text(RhythmLocalization.text("暂不归属")).tag(Optional<String>.none)
                    ForEach(store.longGoals) { goal in Text(goal.title).tag(Optional(goal.id)) }
                }
                TextField(RhythmLocalization.text("备注或完成标准"), text: $notes, axis: .vertical)
                    .lineLimit(2...5)
                Toggle(RhythmLocalization.text("设置时间跨度（可选）"), isOn: $hasTimeSpan)
                if hasTimeSpan {
                    DatePicker(RhythmLocalization.text("开始日期"), selection: $startDate, displayedComponents: .date)
                    DatePicker(RhythmLocalization.text("结束日期"), selection: $endDate, in: startDate..., displayedComponents: .date)
                }
                Stepper(RhythmLocalization.format("预计投入：%d 分钟", estimatedMinutes), value: $estimatedMinutes, in: 5...1440, step: 5)
                Toggle(RhythmLocalization.text("已完成"), isOn: $isCompleted)
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 520)
    }
}

private enum GoalTimelineState {
    case completed
    case overdue
    case active
    case paused
    case upcoming

    var title: String {
        switch self {
        case .completed: RhythmLocalization.text("已完成")
        case .overdue: RhythmLocalization.text("已逾期")
        case .active: RhythmLocalization.text("进行中")
        case .paused: RhythmLocalization.text("已暂停")
        case .upcoming: RhythmLocalization.text("未开始")
        }
    }

    var color: Color {
        switch self {
        case .completed: RhythmTheme.teal
        case .overdue: .red
        case .active: RhythmTheme.blue
        case .paused: RhythmTheme.orange
        case .upcoming: .secondary
        }
    }
}

private struct LongGoalGanttItem: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let chartEndDate: Date
    let state: GoalTimelineState
}

private struct LongGoalYearSlice: Identifiable {
    let item: LongGoalGanttItem
    let year: Int
    let startDate: Date
    let endDate: Date

    var id: String { "\(item.id)-\(year)" }
}

private struct LongGoalGanttChart: View {
    let goals: [LongGoal]

    private var items: [LongGoalGanttItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return goals.map { goal in
            let start = calendar.startOfDay(for: goal.startDate)
            let end = calendar.startOfDay(for: max(goal.startDate, goal.targetDate))
            let state: GoalTimelineState
            if goal.status == .completed {
                state = .completed
            } else if end < today {
                state = .overdue
            } else if goal.status == .paused {
                state = .paused
            } else if start > today || goal.status == .planned {
                state = .upcoming
            } else {
                state = .active
            }
            return LongGoalGanttItem(
                id: goal.id,
                title: goal.title,
                startDate: start,
                chartEndDate: calendar.date(byAdding: .day, value: 1, to: end) ?? end,
                state: state
            )
        }
        .sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.title < $1.title
        }
    }

    private var years: [Int] {
        guard let first = items.map(\.startDate).min(),
              let last = items.map(\.chartEndDate).max() else { return [] }
        let calendar = Calendar.current
        let firstYear = calendar.component(.year, from: first)
        let lastYear = calendar.component(.year, from: last.addingTimeInterval(-1))
        return Array(firstYear...max(firstYear, lastYear))
    }

    private func bounds(for year: Int) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = calendar.date(byAdding: .year, value: 1, to: start)!
        return start...end
    }

    private func axisDates(for year: Int) -> [Date] {
        [1, 4, 7, 10, 12].compactMap {
            Calendar.current.date(from: DateComponents(year: year, month: $0, day: 1))
        }
    }

    private func slices(for year: Int) -> [LongGoalYearSlice] {
        let domain = bounds(for: year)
        return items.compactMap { item in
            guard item.startDate < domain.upperBound, item.chartEndDate > domain.lowerBound else { return nil }
            return LongGoalYearSlice(
                item: item,
                year: year,
                startDate: max(item.startDate, domain.lowerBound),
                endDate: min(item.chartEndDate, domain.upperBound)
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(RhythmLocalization.text("长期目标甘特图")).font(.headline)
                Text(RhythmLocalization.text("按年份展示每个长期目标的开始、结束时间和当前状态"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                ForEach([
                    GoalTimelineState.completed,
                    .overdue, .active, .paused, .upcoming,
                ], id: \.title) { state in
                    HStack(spacing: 5) {
                        Circle().fill(state.color).frame(width: 7, height: 7)
                        Text(state.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            VStack(spacing: 18) {
                ForEach(years, id: \.self) { year in
                    let yearSlices = slices(for: year)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(year))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Chart {
                            ForEach(yearSlices) { slice in
                                BarMark(
                                    xStart: .value(RhythmLocalization.text("开始"), slice.startDate),
                                    xEnd: .value(RhythmLocalization.text("结束"), slice.endDate),
                                    y: .value(RhythmLocalization.text("长期目标"), slice.item.title),
                                    height: .fixed(14)
                                )
                                .foregroundStyle(slice.item.state.color)
                                .cornerRadius(4)
                            }

                            let today = Calendar.current.startOfDay(for: Date())
                            if Calendar.current.component(.year, from: today) == year {
                                RuleMark(x: .value(RhythmLocalization.text("今天"), today))
                                    .foregroundStyle(Color.orange)
                                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                                    .annotation(position: .top, alignment: .leading) {
                                        Text(RhythmLocalization.text("今天"))
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Color.orange)
                                    }
                            }
                        }
                        .chartXScale(domain: bounds(for: year))
                        .chartLegend(.hidden)
                        .chartXAxis {
                            AxisMarks(values: axisDates(for: year)) {
                                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                                AxisValueLabel(format: .dateTime.month(.abbreviated).locale(RhythmLocalization.language.locale))
                            }
                        }
                        .chartPlotStyle { plot in plot.padding(.horizontal, 8) }
                        .frame(height: max(84, CGFloat(yearSlices.count) * 32 + 42))
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(16)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
}

private struct ShortActionMonthSlice: Identifiable {
    let action: ShortAction
    let startDate: Date
    let endDate: Date

    var id: String { action.id }
}

private struct ShortActionTwoMonthTimeline: View {
    let actions: [ShortAction]

    private var monthStarts: [Date] {
        let calendar = Calendar.current
        let current = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        let next = calendar.date(byAdding: .month, value: 1, to: current)!
        return [current, next]
    }

    private var unscheduledCount: Int { actions.filter { $0.startDate == nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(RhythmLocalization.text("短期行动时间图")).font(.headline)
                Text(RhythmLocalization.text("本月与下个月并排展示；时间跨度为可选项"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                ShortActionMonthPanel(title: RhythmLocalization.text("本月"), monthStart: monthStarts[0], actions: actions)
                ShortActionMonthPanel(title: RhythmLocalization.text("下个月"), monthStart: monthStarts[1], actions: actions)
            }

            if unscheduledCount > 0 {
                Text(RhythmLocalization.format("另有 %d 个行动未设置时间跨度，暂不显示在图中。", unscheduledCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
}

private struct ShortActionMonthPanel: View {
    let title: String
    let monthStart: Date
    let actions: [ShortAction]

    private var monthEnd: Date {
        Calendar.current.date(byAdding: .month, value: 1, to: monthStart)!
    }

    private var slices: [ShortActionMonthSlice] {
        let calendar = Calendar.current
        return actions.compactMap { action in
            guard let rawStart = action.startDate, let rawEnd = action.normalizedEndDate else { return nil }
            let start = calendar.startOfDay(for: rawStart)
            let endDay = calendar.startOfDay(for: rawEnd)
            let chartEnd = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            guard start < monthEnd, chartEnd > monthStart else { return nil }
            return ShortActionMonthSlice(
                action: action,
                startDate: max(start, monthStart),
                endDate: min(chartEnd, monthEnd)
            )
        }
        .sorted { $0.startDate < $1.startDate }
    }

    private var axisDates: [Date] {
        [1, 8, 15, 22].compactMap {
            Calendar.current.date(byAdding: .day, value: $0 - 1, to: monthStart)
        }
    }

    private func color(for action: ShortAction) -> Color {
        if action.isCompleted { return RhythmTheme.teal }
        let palette: [Color] = [RhythmTheme.blue, RhythmTheme.purple, RhythmTheme.orange, .pink, .indigo]
        let seed = action.id.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % palette.count }
        return palette[seed]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(monthStart.formatted(.dateTime.year().month(.wide).locale(RhythmLocalization.language.locale)))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if slices.isEmpty {
                Text(RhythmLocalization.text("暂无设置了时间跨度的行动"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 106, alignment: .center)
            } else {
                Chart {
                    ForEach(slices) { slice in
                        BarMark(
                            xStart: .value(RhythmLocalization.text("开始"), slice.startDate),
                            xEnd: .value(RhythmLocalization.text("结束"), slice.endDate),
                            y: .value(RhythmLocalization.text("短期行动"), slice.action.title),
                            height: .fixed(12)
                        )
                        .foregroundStyle(color(for: slice.action))
                        .cornerRadius(4)
                    }
                    let today = Calendar.current.startOfDay(for: Date())
                    if today >= monthStart, today < monthEnd {
                        RuleMark(x: .value(RhythmLocalization.text("今天"), today))
                            .foregroundStyle(Color.orange)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                .chartXScale(domain: monthStart...monthEnd)
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: axisDates) {
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel(format: .dateTime.day())
                    }
                }
                .frame(height: max(112, CGFloat(slices.count) * 28 + 38))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06)))
    }
}
