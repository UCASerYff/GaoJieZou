import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    var route: URL? = nil
    var routeRevision: Int = 0
    @State private var handledRouteRevision = 0
    @EnvironmentObject private var store: RhythmStore
    @EnvironmentObject private var settings: RhythmSettings
    @Environment(\.colorScheme) private var colorScheme
    @SceneStorage("gqns.page.Rhythm") private var selection: RhythmSection = .today
    /// 侧栏隐藏/显示（场景级记忆；键全 app 唯一）。只有 隐藏↔显示 两态，无「收起成图标栏」。
    @SceneStorage("gqns.sidebarHidden.rhythm") private var sidebarHidden = false
    /// 自绘侧栏导航行的 hover 跟踪（浅灰反馈，与词元一致）。
    @State private var hoveredSection: RhythmSection?

    var body: some View {
        // 侧栏重设计（对齐词元 2.2/2.3 标杆）：弃用系统 NavigationSplitView 列表侧栏，
        // 改 HStack 自绘——品牌头部 + 浮动卡片选中态导航行 + hover 反馈 + 状态底卡。
        // 统一工具栏契约：.navigation 恰好一个 28×28 侧栏切换按钮（⌃⌘S）；
        // 本模块无 trailing 按钮，固定 360 空容器保住主壳胶囊条几何。
        HStack(spacing: 0) {
            if !sidebarHidden {
                sidebar
                // 自绘发丝线替代系统 Divider：避免 Tahoe 统一标题栏下系统 separator 冷启动首帧误渲染成灰带
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1).frame(maxHeight: .infinity)
            }
            ZStack {
                settings.canvasColor(for: colorScheme).ignoresSafeArea()
                VStack(spacing: 0) {
                    SectionHeader(section: selection)
                        .id(settings.language)
                    detail
                        .id(settings.language)
                }
            }
        }
        .frame(minWidth: 1040, minHeight: 700)
        .disabled(store.loadFailed)
        .animation(.easeInOut(duration: 0.22), value: sidebarHidden)
        .toolbar {
            toolbarItemNoChrome(.navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { sidebarHidden.toggle() }
                } label: {
                    SidebarToggleIcon()
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(RhythmLocalization.text(sidebarHidden ? "显示侧边栏" : "隐藏侧边栏"))
            }
            toolbarItemNoChrome(.primaryAction) {
                HStack(spacing: 12) {}
                    .frame(width: 360, alignment: .trailing)
            }
        }
        .alert(RhythmLocalization.text("提示"), isPresented: Binding(
            get: { store.notice != nil },
            set: { if !$0 { store.notice = nil } }
        )) {
            Button(RhythmLocalization.text("知道了")) { store.notice = nil }
        } message: {
            Text(store.notice ?? "")
        }
        .onAppear {
            updateWindowTitle()
            RhythmNotifications.rescheduleDailyHabitReminder(settings: settings, pendingCount: store.pendingHabitCountToday)
        }
        .onChange(of: settings.language) { _ in updateWindowTitle() }
        .onReceive(NotificationCenter.default.publisher(for:Notification.Name("GaoSeries.health.sleepReward"))) { note in
            let energy=note.userInfo?["energy"] as? Double ?? 0
            store.notice = energy>0 ? "睡眠已保存 · 牧场收益已结算 · 健康活力 +\(Int(energy))（每日最多 +24）" : "睡眠已保存 · 牧场收益已结算 · 健康活力今日额度已满或该睡眠已结算"
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.rhythm.game"))) { _ in selection = .farm }
        .onReceive(NotificationCenter.default.publisher(for: .rhythmSelectSection)) { note in
            guard let rawValue = note.userInfo?["section"] as? String,
                  let section = RhythmSection(rawValue: rawValue) else { return }
            selection = section
        }
        // 深链由主 app 统一路由（route/routeRevision），模块内不再挂 onOpenURL，避免执行两遍。
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.rhythm.startFocus"))) { _ in
            store.startFocus(linkedActionID: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.rhythm.startSleep"))) { _ in
            store.startSleep(targetHours: settings.sleepTargetHours)
        }
        // 主 app 总览页发来的手动记睡眠：userInfo 带 durationMinutes(Int) 与 night(Date，就寝日期)，
        // 起止换算与模块内手动录入同一规则（结束固定在该晚次日 07:00）。
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.rhythm.logSleep"))) { note in
            guard let durationMinutes = note.userInfo?["durationMinutes"] as? Int,
                  let night = note.userInfo?["night"] as? Date,
                  (30 ... 24 * 60).contains(durationMinutes) else { return }
            let interval = RhythmShared.manualSleepInterval(night: night, durationMinutes: durationMinutes)
            store.addManualSleep(start: interval.start, end: interval.end, targetHours: settings.sleepTargetHours)
        }
        .onAppear(perform: handleIntegratedRoute)
        .onChange(of: routeRevision) { _, _ in handleIntegratedRoute() }
    }

    private func handleIntegratedRoute() {
        guard routeRevision > handledRouteRevision, let route, route.scheme == "gaojiezou" else { return }
        handledRouteRevision = routeRevision
        handleRoute(route)
    }

    private func handleRoute(_ url: URL) {
        switch url.host {
        case "longGoals": selection = .longGoals
        default: selection = .today
        }
    }

    // MARK: 自绘侧边栏（词元标杆）：品牌头部 + 浮动卡片选中态导航行 + 状态底卡

    private var sidebar: some View {
        VStack(spacing: 0) {
            brandHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sidebarSection(RhythmLocalization.text("节奏管理"), sections: [.today, .habits, .chores, .focus, .sleep, .statistics])
                    sidebarSection(RhythmLocalization.text("目标规划"), sections: [.longGoals, .shortActions])
                    sidebarSection(RhythmLocalization.text("奖励系统"), sections: [.farm, .pasture, .fishing, .collection])
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            statusFooter
        }
        .frame(width: 236)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            if let image = NSImage(contentsOf: RhythmBundle.bundle.url(forResource: "GaoJieZouIcon", withExtension: "png") ?? URL(fileURLWithPath: "")) {
                Image(nsImage: image).resizable()
                    .interpolation(.high)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(RhythmLocalization.text("搞节奏")).font(.headline)
                Text(RhythmLocalization.text("节奏、目标与庄园")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func sidebarSection(_ title: String, sections: [RhythmSection]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            ForEach(sections) { sidebarRow($0) }
        }
    }

    /// 浮动卡片选中态导航行：accent 底白字 + 柔和投影（深色下投影 opacity 调高），hover 浅灰反馈；既有计数角标保留。
    private func sidebarRow(_ section: RhythmSection) -> some View {
        let selected = selection == section
        let hovered = hoveredSection == section
        return Button { selection = section } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.callout)
                    .frame(width: 20)
                Text(section.title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count = count(for: section) {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.05), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(RhythmTheme.blue)
                        .shadow(color: RhythmTheme.blue.opacity(colorScheme == .dark ? 0.45 : 0.32), radius: 5, y: 2)
                } else if hovered {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in hoveredSection = hovering ? section : nil }
        .help(section.subtitle)
    }

    /// 状态底卡（词元 statusFooter 风格）：原底栏的金币/鱼饵计数收进第一行，第二行存储说明。
    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(RhythmTheme.teal).frame(width: 7, height: 7)
                Text(RhythmLocalization.format("金币 %d · 鱼饵 %d", store.coins, store.bait)).font(.caption)
                Spacer(minLength: 0)
            }
            Text(RhythmLocalization.text("所有偏好与记录都只保存在这台 Mac 上")).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func count(for section: RhythmSection) -> Int? {
        switch section {
        case .habits: store.habits(for: Date()).count
        case .chores: store.chores.filter { !$0.isCompleted }.count
        case .longGoals: store.longGoals.filter { $0.status != .completed }.count
        case .shortActions: store.shortActions.filter { !$0.isCompleted }.count
        case .farm: store.farmPlots.filter { $0.cropID != nil }.count
        case .pasture: store.ownedAnimals.reduce(0) { $0 + $1.count }
        case .fishing: store.fishInventory.values.reduce(0, +) + store.aquariumFish.count
        case .collection: store.harvestedCrops.count + store.ownedAnimals.count + store.fishCaught.count
        default: nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .today:
            TodayDashboard(selection: $selection)
        case .habits:
            HabitDashboard()
        case .chores:
            ChoreDashboard()
        case .focus:
            FocusDashboard()
        case .sleep:
            SleepDashboard()
        case .statistics:
            StatisticsDashboard()
        case .longGoals:
            LongGoalDashboard()
        case .shortActions:
            ShortActionDashboard()
        case .farm:
            FarmGameView()
        case .pasture:
            PastureGameView()
        case .fishing:
            FishingHubView()
        case .collection:
            CollectionView()
        }
    }

    private func updateWindowTitle() {
        let title = RhythmAppInfo.windowTitle
        for window in NSApplication.shared.windows where window.title.contains("搞节奏") || window.title.contains("Rhythm") {
            window.title = title
        }
    }
}

/// 搞节奏设置页内容（app 级设置中心经 RhythmSettingsView 嵌入；模块内不再有独立入口）。
struct RhythmSettingsPanelView: View {
    @EnvironmentObject private var settings: RhythmSettings
    @EnvironmentObject private var store: RhythmStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(RhythmLocalization.text("设置")).font(.title2.weight(.semibold))
                    Text(RhythmLocalization.text("所有偏好与记录都只保存在这台 Mac 上"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(RhythmLocalization.text("完成")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(22)

            Divider()

            Form {
                Section {
                    HStack {
                        ColorPicker(
                            selection: Binding(
                                get: { settings.backgroundPickerColor },
                                set: { settings.setBackgroundColor($0) }
                            ),
                            supportsOpacity: false
                        ) {
                            Label(RhythmLocalization.text("背景颜色"), systemImage: "paintpalette.fill")
                        }
                        if settings.hasCustomBackground {
                            Button(RhythmLocalization.text("恢复系统颜色")) { settings.resetBackgroundColor() }
                        }
                    }
                } header: {
                    Text(RhythmLocalization.text("外观"))
                } footer: {
                    Text(RhythmLocalization.text("背景颜色会与当前浅色或深色画布柔和混合，以保持文字和卡片清晰。"))
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(RhythmLocalization.text("睡眠目标"))
                            Spacer()
                            Text(RhythmLocalization.format("%.1f 小时", settings.sleepTargetHours))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.sleepTargetHours, in: 5...12, step: 0.5)
                    }
                } header: {
                    Text(RhythmLocalization.text("睡眠"))
                }

                Section {
                    Toggle(isOn: $settings.habitReminderEnabled) {
                        Label(RhythmLocalization.text("每日打卡提醒"), systemImage: "bell.badge")
                    }
                    DatePicker(
                        RhythmLocalization.text("提醒时间"),
                        selection: $settings.habitReminderTime,
                        displayedComponents: .hourAndMinute
                    )
                    .disabled(!settings.habitReminderEnabled)
                } header: {
                    Text(RhythmLocalization.text("提醒"))
                } footer: {
                    Text(RhythmLocalization.text("开启后，每天到点时如果还有未完成的打卡，会收到一条系统通知。"))
                }
                .onChange(of: settings.habitReminderEnabled) { _ in rescheduleHabitReminder() }
                .onChange(of: settings.habitReminderTime) { _ in rescheduleHabitReminder() }

                Section {
                    LabeledContent(RhythmLocalization.text("数据位置")) {
                        Text("~/Library/Application Support/GaoSeries/Rhythm")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent(RhythmLocalization.text("版本")) { Text(RhythmAppInfo.displayVersion) }
                    Button {
                        exportDiagnostics()
                    } label: {
                        Label(RhythmLocalization.text("导出诊断信息"), systemImage: "stethoscope")
                    }
                    Button {
                        exportRecordsCSV()
                    } label: {
                        Label(RhythmLocalization.text("导出记录 CSV"), systemImage: "tablecells")
                    }
                } header: {
                    Text(RhythmLocalization.text("关于"))
                } footer: {
                    Text(RhythmLocalization.text("诊断信息包含版本、数据文件状态与最近 1 小时的本地日志，仅保存到你选择的位置。"))
                    Text(RhythmLocalization.text("CSV 导出会在你选择的目录生成专注、睡眠、打卡三个文件，UTF-8 编码可直接用 Excel 打开。"))
                }
            }
            .formStyle(.grouped)
            .padding(6)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 640, idealHeight: 720)
    }

    /// 开关或时间变化后重排每日打卡提醒；非 .app 环境下内部空转。
    private func rescheduleHabitReminder() {
        RhythmNotifications.rescheduleDailyHabitReminder(settings: settings, pendingCount: store.pendingHabitCountToday)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = RhythmLocalization.text("导出诊断信息")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "搞节奏-诊断-\(formatter.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.diagnosticReport().write(to: url, atomically: true, encoding: .utf8)
            store.notice = RhythmLocalization.text("诊断信息已导出。")
        } catch {
            store.notice = RhythmLocalization.format("诊断信息导出失败：%@", error.localizedDescription)
        }
    }

    /// 一次导出三个 CSV 到用户自选目录；失败记日志并通过 store.notice 提示。
    private func exportRecordsCSV() {
        let panel = NSOpenPanel()
        panel.title = RhythmLocalization.text("选择 CSV 导出目录")
        panel.prompt = RhythmLocalization.text("导出到这里")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let files: [(name: String, content: String)] = [
            ("focus-records.csv", RhythmCSVExport.focusRecordsCSV(store.focusRecords)),
            ("sleep-records.csv", RhythmCSVExport.sleepRecordsCSV(store.sleepRecords, targetHours: settings.sleepTargetHours)),
            ("habit-completions.csv", RhythmCSVExport.habitCompletionsCSV(habits: store.habits, completionKeys: store.habitCompletionKeys)),
        ]
        do {
            for file in files {
                try file.content.write(
                    to: directory.appendingPathComponent(file.name),
                    atomically: true,
                    encoding: .utf8
                )
            }
            store.notice = RhythmLocalization.format("已导出 %d 个 CSV 文件到：%@", files.count, directory.path)
        } catch {
            RhythmLog.data.error("CSV 记录导出失败：\(error.localizedDescription, privacy: .public)")
            store.notice = RhythmLocalization.format("CSV 导出失败：%@", error.localizedDescription)
        }
    }
}


// MARK: - 工具栏项 chrome 隐藏（macOS 26 起工具栏项带 sharedBackground 玻璃胶囊，
// 自绘的侧栏切换按钮与固定宽 360 trailing 容器会被罩上多余色块；只去底色，不改几何与交互）
@ToolbarContentBuilder
private func toolbarItemNoChrome<Content: View>(
    _ placement: ToolbarItemPlacement,
    @ViewBuilder content: @escaping () -> Content
) -> some ToolbarContent {
    if #available(macOS 26.0, *) {
        ToolbarItem(placement: placement, content: content)
            .sharedBackgroundVisibility(.hidden)
    } else {
        ToolbarItem(placement: placement, content: content)
    }
}

/// 侧栏切换按钮图标：chrome 隐藏后补轻量 hover 底色，保证图标清晰、反馈合理。
private struct SidebarToggleIcon: View {
    @State private var hovering = false
    var body: some View {
        Image(systemName: "sidebar.left")
            .frame(width: 28, height: 28)
            .background(
                Color.primary.opacity(hovering ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}
