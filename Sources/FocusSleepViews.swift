import SwiftUI

struct FocusDashboard: View {
    @EnvironmentObject private var store: RhythmStore
    @State private var selectedActionID: String?
    @State private var confirmCancel = false

    private var availableActions: [ShortAction] {
        store.shortActions.filter { !$0.isCompleted }.sorted {
            ($0.startDate ?? $0.createdAt) < ($1.startDate ?? $1.createdAt)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if store.activeFocus != nil {
                    activeFocusPanel
                } else {
                    startFocusPanel
                }

                farmEffectPanel

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(RhythmLocalization.text("专注记录")).font(.headline)
                        Spacer()
                        Text(RhythmLocalization.format("共 %d 次", store.focusRecords.count))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.focusRecords.isEmpty {
                        Text(RhythmLocalization.text("完成第一次专注后，记录会出现在这里。"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
                    } else {
                        ForEach(store.focusRecords.prefix(30)) { record in
                            HStack(spacing: 12) {
                                Image(systemName: "timer")
                                    .foregroundStyle(RhythmTheme.blue)
                                    .frame(width: 34, height: 34)
                                    .background(RhythmTheme.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(store.focusDisplayTitle(linkedActionID: record.linkedActionID))
                                        .font(.callout.weight(.medium))
                                    Text("\(RhythmFormatters.shortDate.string(from: record.endedAt)) \(RhythmFormatters.time.string(from: record.startedAt))–\(RhythmFormatters.time.string(from: record.endedAt))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(RhythmFormatters.duration(record.durationSeconds, showSeconds: false))
                                    .font(.callout.monospacedDigit().weight(.semibold))
                                if record.earnedCoins > 0 {
                                    Text("+\(record.earnedCoins) 🪙")
                                        .font(.caption).foregroundStyle(RhythmTheme.orange)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(16)
                .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
            }
            .frame(maxWidth: 1000)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .alert(RhythmLocalization.text("放弃这次专注？"), isPresented: $confirmCancel) {
            Button(RhythmLocalization.text("继续专注"), role: .cancel) {}
            Button(RhythmLocalization.text("放弃记录"), role: .destructive) { store.cancelFocus() }
        } message: {
            Text(RhythmLocalization.text("本次专注记录不会保存；已经实时产生的作物成长会保留。"))
        }
    }

    private var startFocusPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "timer")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(RhythmTheme.blue, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(RhythmLocalization.text("开始一段有效专注")).font(.title3.weight(.semibold))
                    Text(RhythmLocalization.text("锁屏、熄屏或 Mac 睡眠时自动暂停，解锁后自动继续。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Picker(RhythmLocalization.text("关联短期行动"), selection: $selectedActionID) {
                Text(RhythmLocalization.text("其他事件")).tag(Optional<String>.none)
                ForEach(availableActions) { action in
                    Text(action.title).tag(Optional(action.id))
                }
            }

            HStack {
                Text(RhythmLocalization.format(
                    "每有效专注 %d 分钟获得 1 金币，每次最多 %d 金币；所有已播种作物同时成长。",
                    RhythmEconomy.focusMinutesPerCoin,
                    RhythmEconomy.focusSessionCoinCap
                ))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.startFocus(linkedActionID: selectedActionID)
                    selectedActionID = nil
                } label: {
                    Label(RhythmLocalization.text("开始专注"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(store.activeSleep != nil)
            }
        }
        .padding(20)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07)))
    }

    private var activeFocusPanel: some View {
        VStack(spacing: 18) {
            Image(systemName: store.activeFocus?.segmentStartedAt == nil ? "pause.circle.fill" : "timer.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(RhythmTheme.blue)
            Text(store.focusDisplayTitle(linkedActionID: store.activeFocus?.linkedActionID))
                .font(.title2.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(RhythmFormatters.duration(store.focusElapsed(at: context.date)))
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            if let focus = store.activeFocus, let actionID = focus.linkedActionID,
               let action = store.shortActions.first(where: { $0.id == actionID }) {
                Label(RhythmLocalization.format("关联：%@", action.title), systemImage: "link")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if store.activeFocus?.pausedForSystem == true {
                Label(RhythmLocalization.text("检测到锁屏或休眠，专注已暂停，解锁后会自动继续"), systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(RhythmTheme.orange)
            } else if store.activeFocus?.segmentStartedAt == nil {
                Text(RhythmLocalization.text("已手动暂停")).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if store.activeFocus?.segmentStartedAt == nil {
                    Button(RhythmLocalization.text("继续"), systemImage: "play.fill") { store.resumeFocus() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .keyboardShortcut(.space, modifiers: [])
                } else {
                    Button(RhythmLocalization.text("暂停"), systemImage: "pause.fill") { store.pauseFocus() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .keyboardShortcut(.space, modifiers: [])
                }
                Button(RhythmLocalization.text("结束并保存"), systemImage: "checkmark.circle.fill") { store.finishFocus() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button(RhythmLocalization.text("放弃"), role: .destructive) { confirmCancel = true }
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(RhythmTheme.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RhythmTheme.blue.opacity(0.18)))
    }

    private var farmEffectPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(RhythmLocalization.text("专注将推动这些作物生长")).font(.headline)
                Spacer()
                Text(RhythmLocalization.format("%d 块生长中", store.farmPlots.filter { $0.cropID != nil }.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            let planted = store.farmPlots.filter { $0.cropID != nil }
            if planted.isEmpty {
                Text(RhythmLocalization.text("庄园里还没有作物。先去农场播种，下一次专注就会转化为成长时间。"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 18) {
                        ForEach(planted) { plot in
                            if let crop = RhythmCatalog.crop(plot.cropID) {
                                let progress = store.farmGrowthProgress(for: plot, at: context.date)
                                VStack(spacing: 5) {
                                    Text(crop.emoji).font(.system(size: 28))
                                    Text(crop.displayName).font(.caption)
                                    Text("\(Int(progress * 100))%")
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(progress >= 1
                                        ? RhythmLocalization.text("已成熟")
                                        : RhythmLocalization.format("%@ 后成熟", RhythmFormatters.duration(store.farmMaturityRemainingSeconds(for: plot))))
                                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(progress >= 1 ? RhythmTheme.orange : RhythmTheme.green)
                                        .lineLimit(1)
                                    ProgressView(value: progress)
                                        .tint(RhythmTheme.green)
                                        .frame(maxWidth: 80)
                                        .animation(.linear(duration: 1), value: progress)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
}

struct SleepDashboard: View {
    @EnvironmentObject private var store: RhythmStore
    @EnvironmentObject private var settings: RhythmSettings
    @State private var proposedStart = Date()
    @State private var proposedStartIsCustom = false
    @State private var confirmCancel = false
    @State private var showingManualEntry = false
    @State private var showingTimerEntry = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if store.activeSleep != nil {
                    activeSleepPanel
                } else {
                    startSleepPanel
                }

                pastureEffectPanel

                HStack(spacing: 12) {
                    StatTile(value: RhythmLocalization.format("%.1f 小时", settings.sleepTargetHours), label: "个人睡眠目标", symbol: "target", color: RhythmTheme.purple)
                    StatTile(value: store.sleepRecords.first.map { "\($0.score)" } ?? RhythmLocalization.text("暂无"), label: "最近睡眠评分", symbol: "chart.line.uptrend.xyaxis", color: RhythmTheme.teal)
                    StatTile(value: "\(store.ownedAnimals.reduce(0) { $0 + $1.pendingProducts })", label: "待收牧场产物", symbol: "pawprint.fill", color: RhythmTheme.orange)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(RhythmLocalization.text("睡眠记录")).font(.headline)
                    if store.sleepRecords.isEmpty {
                        Text(RhythmLocalization.text("完成第一次睡眠计时后，记录会出现在这里。"))
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
                    } else {
                        // store.apply 已按 endedAt 倒序排列（与本视图原排序方向一致），直接取前 100 条。
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(store.sleepRecords.prefix(100)) { record in
                            HStack(spacing: 12) {
                                Image(systemName: "moon.stars.fill")
                                    .foregroundStyle(RhythmTheme.purple)
                                    .frame(width: 36, height: 36)
                                    .background(RhythmTheme.purple.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(RhythmLocalization.format("%@ 夜间睡眠", RhythmFormatters.shortDate.string(from: record.startedAt)))
                                            .font(.callout.weight(.medium))
                                        if record.manualEntry == true {
                                            Text(RhythmLocalization.text("手动"))
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(RhythmTheme.purple)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(RhythmTheme.purple.opacity(0.12), in: Capsule())
                                        }
                                    }
                                    Text("\(RhythmFormatters.shortDate.string(from: record.startedAt)) \(RhythmFormatters.time.string(from: record.startedAt)) → \(RhythmFormatters.shortDate.string(from: record.endedAt)) \(RhythmFormatters.time.string(from: record.endedAt))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(RhythmFormatters.duration(record.durationSeconds, showSeconds: false))
                                    .font(.callout.monospacedDigit().weight(.semibold))
                                Text(RhythmLocalization.format("%d 分", record.score))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(record.score >= 80 ? RhythmTheme.teal : RhythmTheme.orange)
                                Text(RhythmLocalization.format("牧场 +%d", record.pastureYield))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            }
                        }
                        if store.sleepRecords.count > 100 {
                            Text(RhythmLocalization.format("仅显示最近 100 条，共 %d 条", store.sleepRecords.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 4)
                        }
                    }
                }
                .padding(16)
                .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
            }
            .frame(maxWidth: 1000)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .sheet(isPresented: $showingManualEntry) {
            ManualSleepEditor()
                .environmentObject(store)
                .environmentObject(settings)
        }
        .alert(RhythmLocalization.text("放弃这次睡眠记录？"), isPresented: $confirmCancel) {
            Button(RhythmLocalization.text("保留计时"), role: .cancel) {}
            Button(RhythmLocalization.text("放弃记录"), role: .destructive) { store.cancelSleep() }
        } message: {
            Text(RhythmLocalization.text("睡眠记录会被放弃；已经实时产生的成长和产物会保留。"))
        }
    }

    private var pastureEffectPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(RhythmLocalization.text("牧场实时进度")).font(.headline)
                Spacer()
                if store.activeSleep != nil {
                    Label(RhythmLocalization.text("正在实时生效"), systemImage: "waveform.path.ecg")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RhythmTheme.purple)
                }
            }

            if store.pastureAnimals.isEmpty {
                Text(RhythmLocalization.text("牧场里还没有动物。幼崽会随睡眠实时成长，成年动物会显示本次产出进度。"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 18) {
                        ForEach(store.pastureAnimals) { resident in
                            if let animal = RhythmCatalog.animal(resident.animalID) {
                                let isAdult = resident.growthHours >= animal.maturitySleepHours
                                let growthProgress = store.pastureGrowthProgress(for: resident, at: context.date)
                                let productionProgress = store.pastureProductionProgress(targetHours: settings.sleepTargetHours, at: context.date)
                                let maturityRemaining = store.pastureMaturityRemainingSeconds(for: resident)
                                let productionRemaining = store.pastureProductionRemainingSeconds(targetHours: settings.sleepTargetHours, at: context.date)
                                VStack(spacing: 5) {
                                    Text(animal.emoji).font(.system(size: 28))
                                    Text(animal.displayName).font(.caption).lineLimit(1)
                                    if isAdult, store.activeSleep == nil {
                                        Text(RhythmLocalization.format("已成年 · 待收 %d", resident.pendingProducts))
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    } else {
                                        let progress = isAdult ? productionProgress : growthProgress
                                        Text(RhythmLocalization.format(isAdult ? "本次产出 %d%%" : "成长 %d%%", Int(progress * 100)))
                                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                        Text(isAdult
                                            ? (productionRemaining > 0
                                                ? RhythmLocalization.format("%@ 后出产", RhythmFormatters.duration(productionRemaining))
                                                : RhythmLocalization.text("本次已出产"))
                                            : (maturityRemaining > 0
                                                ? RhythmLocalization.format("%@ 后成年", RhythmFormatters.duration(maturityRemaining))
                                                : RhythmLocalization.text("已成年")))
                                            .font(.system(size: 8, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(isAdult ? RhythmTheme.purple : RhythmTheme.orange)
                                            .lineLimit(1)
                                        ProgressView(value: progress)
                                            .tint(isAdult ? RhythmTheme.purple : RhythmTheme.orange)
                                            .frame(maxWidth: 78)
                                            .animation(.linear(duration: 1), value: progress)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }

            Text(RhythmLocalization.text("成长与产出会在计时过程中逐秒生效并自动保存，无需等待结束睡眠。"))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RhythmTheme.purple.opacity(0.15)))
    }

    private var startSleepPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(RhythmTheme.purple, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(RhythmLocalization.text("准备睡觉")).font(.title3.weight(.semibold))
                    Text(RhythmLocalization.text("睡醒后直接记录睡了几小时几分钟即可；想要随睡随产出再用睡眠计时。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }

            // 主要操作：手动记录（只需时长 + 哪晚）
            HStack {
                Text(RhythmLocalization.text("达到睡眠目标的一半和全部时，成年动物会各产出 1 份产品；手动记录在保存时一次补算。"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingManualEntry = true
                } label: {
                    Label(RhythmLocalization.text("记录睡眠"), systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .tint(RhythmTheme.purple)
                .controlSize(.large)
            }

            // 次要入口：睡眠计时（折叠保留，不删除）
            DisclosureGroup(isExpanded: $showingTimerEntry) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(RhythmLocalization.text("计时采用开始与结束时间差，锁屏、熄屏、合盖和系统睡眠都会继续。"))
                        .font(.callout).foregroundStyle(.secondary)

                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        DatePicker(
                            RhythmLocalization.text("入睡计时开始于"),
                            selection: Binding(
                                get: { proposedStartIsCustom ? proposedStart : timeline.date },
                                set: { value in
                                    proposedStart = value
                                    proposedStartIsCustom = true
                                }
                            ),
                            in: ...timeline.date
                        )
                        .datePickerStyle(.field)
                    }

                    if proposedStartIsCustom {
                        Button(RhythmLocalization.text("改为从现在开始")) { proposedStartIsCustom = false }
                            .font(.callout)
                    }
                    if store.activeFocus != nil {
                        Label(RhythmLocalization.text("请先结束工作专注，再开始睡眠计时。"), systemImage: "timer")
                            .font(.callout).foregroundStyle(RhythmTheme.orange)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(RhythmTheme.orange)
                        Text(RhythmLocalization.text("可以锁屏或合盖；如果关机，请在下次开机后打开“搞节奏”结束记录。开始时间会立即保存，不会丢失。"))
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(12)
                    .background(RhythmTheme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                    HStack {
                        Text(RhythmLocalization.text("达到睡眠目标的一半和全部时，成年动物会各实时产出 1 份产品。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            store.startSleep(at: proposedStartIsCustom ? proposedStart : Date(), targetHours: settings.sleepTargetHours)
                            if store.activeSleep != nil { proposedStartIsCustom = false }
                        } label: {
                            Label(RhythmLocalization.text("开始睡眠计时"), systemImage: "moon.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.activeFocus != nil)
                    }
                }
                .padding(.top, 12)
            } label: {
                Label(RhythmLocalization.text("改用睡眠计时"), systemImage: "timer")
                    .font(.callout.weight(.medium))
            }
        }
        .padding(20)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07)))
    }

    private var activeSleepPanel: some View {
        VStack(spacing: 18) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 42))
                .foregroundStyle(RhythmTheme.purple)
            Text(RhythmLocalization.text("睡眠计时中")).font(.title2.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(RhythmFormatters.duration(store.sleepElapsed(at: context.date)))
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            if let sleep = store.activeSleep {
                let target = max(1, sleep.targetHours ?? settings.sleepTargetHours)
                let targetDate = sleep.startedAt.addingTimeInterval(target * 3600)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 6) {
                        ProgressView(value: min(1, store.sleepElapsed(at: context.date) / (target * 3600)))
                            .tint(RhythmTheme.purple)
                        Text(RhythmLocalization.format("本次目标 %.1f 小时 · %@ %@ 达成", target,
                            RhythmFormatters.shortDate.string(from: targetDate), RhythmFormatters.time.string(from: targetDate)))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: 360)
                }
            }
            if let start = store.activeSleep?.startedAt {
                Text(RhythmLocalization.format("开始于 %@ %@", RhythmFormatters.date.string(from: start), RhythmFormatters.time.string(from: start)))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(RhythmLocalization.text("现在可以锁屏或合盖，睡眠计时仍会继续。"))
                .font(.callout).foregroundStyle(RhythmTheme.purple)
            HStack(spacing: 12) {
                Button(RhythmLocalization.text("醒来，结束并保存"), systemImage: "sun.max.fill") {
                    store.finishSleep(targetHours: settings.sleepTargetHours)
                }
                .buttonStyle(.borderedProminent)
                .tint(RhythmTheme.purple)
                .controlSize(.large)
                Button(RhythmLocalization.text("放弃"), role: .destructive) { confirmCancel = true }
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(RhythmTheme.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RhythmTheme.purple.opacity(0.18)))
    }
}

/// 手动录入睡眠：分别填写小时和分钟，以及哪一晚（就寝日期，默认昨晚）。
/// 起止时间由 RhythmShared.manualSleepInterval 换算：结束固定在该晚次日 07:00，
/// 开始 = 结束 - 时长，保证夜晚归属与 lastNightSleepDuration 统计口径一致。
/// 预估评分随输入实时更新，校验不通过时保存按钮禁用并显示原因。
private struct ManualSleepEditor: View {
    @EnvironmentObject private var store: RhythmStore
    @EnvironmentObject private var settings: RhythmSettings
    @Environment(\.dismiss) private var dismiss
    @State private var hours = 8
    @State private var minutes = 0
    @State private var night: Date
    /// 保存时才可能命中的错误（查重）；时长问题由下方实时校验拦截。
    @State private var saveError: String?

    init() {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        _night = State(initialValue: calendar.startOfDay(for: yesterday))
    }

    private var durationMinutes: Int? {
        guard (0 ... 24).contains(hours), (0 ... 59).contains(minutes) else { return nil }
        let total = hours * 60 + minutes
        return (30 ... 24 * 60).contains(total) ? total : nil
    }

    private var duration: TimeInterval {
        TimeInterval(durationMinutes ?? 0) * 60
    }

    private var interval: (start: Date, end: Date) {
        RhythmShared.manualSleepInterval(night: night, durationMinutes: durationMinutes ?? 0)
    }

    private var validationError: String? {
        if durationMinutes == nil {
            return RhythmLocalization.text("睡眠时长需在 30 分钟至 24 小时之间，分钟需为 0–59。")
        }
        return nil
    }

    private var estimatedScore: Int {
        max(0, min(100, Int(100 - abs(duration / 3600 - max(1, settings.sleepTargetHours)) * 18)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(RhythmLocalization.text("手动录入睡眠")).font(.title2.weight(.semibold))
                    Text(RhythmLocalization.text("保存后会按当前睡眠目标补算一次牧场成长与产出。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(RhythmLocalization.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(RhythmLocalization.text("保存")) { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(RhythmTheme.purple)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil)
            }
            .padding(22)
            Divider()
            Form {
                LabeledContent(RhythmLocalization.text("睡眠时长")) {
                    HStack(spacing: 8) {
                        TextField(RhythmLocalization.text("小时"), value: $hours, format: .number)
                            .labelsHidden()
                            .frame(width: 62)
                        Text(RhythmLocalization.text("小时"))
                        TextField(RhythmLocalization.text("分钟"), value: $minutes, format: .number)
                            .labelsHidden()
                            .frame(width: 62)
                        Text(RhythmLocalization.text("分钟"))
                    }
                }
                DatePicker(
                    RhythmLocalization.text("哪晚（就寝日期）"),
                    selection: $night,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.field)
                Section {
                    LabeledContent(RhythmLocalization.text("睡眠时长")) {
                        Text(RhythmFormatters.duration(max(0, duration), showSeconds: false))
                            .monospacedDigit()
                    }
                    LabeledContent(RhythmLocalization.text("换算起止")) {
                        Text("\(RhythmFormatters.shortDate.string(from: interval.start)) \(RhythmFormatters.time.string(from: interval.start)) → \(RhythmFormatters.shortDate.string(from: interval.end)) \(RhythmFormatters.time.string(from: interval.end))")
                            .monospacedDigit()
                    }
                    LabeledContent(RhythmLocalization.text("预估评分")) {
                        Text(RhythmLocalization.format("%d 分", estimatedScore))
                            .monospacedDigit()
                    }
                } header: {
                    Text(RhythmLocalization.format("按当前目标 %.1f 小时估算", settings.sleepTargetHours))
                } footer: {
                    Text(RhythmLocalization.text("起床时间按次日早上 7:00 固定换算，统计会记在你选的那晚。"))
                }
                if let message = validationError ?? saveError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(RhythmTheme.orange)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 420, idealHeight: 460)
    }

    private func save() {
        saveError = nil
        switch store.addManualSleep(start: interval.start, end: interval.end, targetHours: settings.sleepTargetHours) {
        case .added:
            dismiss()
        case .invalidRange:
            saveError = RhythmLocalization.text("起床时间必须晚于就寝时间。")
        case .invalidDuration:
            saveError = RhythmLocalization.text("睡眠时长需在 30 分钟至 24 小时之间，分钟需为 0–59。")
        case .duplicate:
            saveError = RhythmLocalization.text("已有一条起止时间几乎相同的睡眠记录，请勿重复录入。")
        }
    }
}
