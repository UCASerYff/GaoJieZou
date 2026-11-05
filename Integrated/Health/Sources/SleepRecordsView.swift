import SwiftUI

struct SleepRecordsView: View {
    @EnvironmentObject var store: AppStore
    @State private var deletion: SharedSleepEntry?
    @State private var visibleCount = 30
    var body: some View {
        HStack(alignment:.bottom) {
            SectionTitle(title:store.t("睡眠记录","Sleep records"),subtitle:store.t("在健康睡眠页或睡眠计时页记一次，共享同一份记录。","Record once in the health sleep page or sleep timer. Both pages share the same records."))
            Spacer()
            Button { store.syncSleepRewards() } label:{ Label(store.t("同步记录","Sync records"),systemImage:"arrow.triangle.2.circlepath") }
            Button { store.newSleep(backfill:true) } label:{ Label(store.t("补记","Backfill"),systemImage:"clock.arrow.circlepath") }
            Button { store.newSleep() } label:{ Label(store.t("记录睡眠","Record sleep"),systemImage:"plus") }.buttonStyle(.borderedProminent).tint(Theme.purple)
        }
        SleepSummaryCard()
        VStack(alignment:.leading,spacing:10) {
            Label(store.t("睡眠也能恢复活力","Sleep restores energy, too"),systemImage:"moon.stars.fill").font(.headline).foregroundStyle(Theme.purple)
            Text(store.t("每小时恢复 3 点活力，每日最多 24 点。最近 36 小时内结束、时长 30 分钟至 24 小时的睡眠可领取一次；更早的记录仍会保留。岛屿暂停或关闭时不领奖，恢复后在有效期内自动补领。","Restore 3 energy per hour, up to 24 per day. Completed sleep of 30 minutes to 24 hours can be rewarded once within 36 hours. Older records are retained. Rewards wait while the island is paused or disabled.")).font(.callout).foregroundStyle(.secondary)
            Text(store.t("同一份记录用于健康睡眠页、睡眠计时页和小组件。下次打开搞节奏时会刷新历史；已获得的奖励不会重复发放。","The health sleep page, sleep timer and widgets share these records. History refreshes when Gao Rhythm next opens. Earned rewards are not granted twice.")).font(.caption).foregroundStyle(.secondary)
        }.card()
        if let error = store.sleepSyncError {
            Label(error,systemImage:"exclamationmark.triangle").font(.callout).foregroundStyle(Theme.orange).card()
        } else if let date = store.sleepSyncedAt {
            Label(store.t("自动同步已开启 · 最近同步 ","Automatic sync · Updated ")+date.formatted(date:.omitted,time:.shortened),systemImage:"checkmark.circle").font(.caption).foregroundStyle(.secondary)
        }
        VStack(alignment:.leading,spacing:0) {
            HStack { Text(store.t("睡眠历史","Sleep history")).font(.headline); Spacer(); Text(store.t("共 \(store.sleepRecords.count) 条","\(store.sleepRecords.count) records")).font(.caption).foregroundStyle(.secondary) }.padding(.bottom,12)
            if store.sleepRecords.isEmpty {
                EmptyCard(symbol:"moon.zzz.fill",title:store.t("记录一个安稳的夜晚","A place for your nights"),detail:store.t("填写睡眠小时、分钟并选择哪晚，健康睡眠页和睡眠计时页会共同显示。","Enter sleep hours and minutes, then choose the night. The health sleep page and sleep timer share the record."))
            }
            ForEach(Array(store.sleepRecords.prefix(visibleCount))) { record in
                HStack(spacing:14) {
                    SymbolTile(symbol:"moon.stars.fill",color:Theme.purple)
                    VStack(alignment:.leading,spacing:5) {
                        Text(record.endedAt.formatted(date:.abbreviated,time:.omitted)).font(.callout.weight(.medium))
                        Text(record.startedAt.formatted(date:.abbreviated,time:.shortened)+" → "+record.endedAt.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                        Text(record.origin == "health" ? store.t("来自健康记录","From the health page") : store.t("来自睡眠计时","From the sleep timer")).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(sleepDuration(record.durationSeconds,en:store.en)).font(.title3.monospacedDigit().weight(.semibold))
                    Button(role:.destructive) { deletion = record } label:{ Image(systemName:"trash") }.buttonStyle(.borderless).help(store.t("删除这条共享睡眠记录","Delete this shared sleep record"))
                }.padding(.vertical,12)
                Divider()
            }
            if visibleCount < store.sleepRecords.count {
                Button(store.t("显示更多","Show more")) { visibleCount += 30 }.padding(.top,12)
            }
        }.card()
        .alert(store.t("删除这条睡眠记录？","Delete this sleep record?"),isPresented:Binding(get:{ deletion != nil },set:{ if !$0 { deletion = nil } })) {
            Button(store.t("取消","Cancel"),role:.cancel) { deletion = nil }
            Button(store.t("删除共享记录","Delete shared record"),role:.destructive) { if let deletion { store.removeSleep(deletion) }; deletion = nil }
        } message:{ Text(store.t("健康睡眠页与睡眠计时页会共同移除这条记录，已获得的游戏奖励不会回退。","This removes the record from the health sleep page and sleep timer. Earned game rewards are retained.")) }
    }
}

struct SleepSummaryCard: View {
    @EnvironmentObject var store: AppStore
    private var today: [SharedSleepEntry] { store.sleepRecords.filter { Engine.day($0.endedAt,store.state) == Engine.day(Date(),store.state) } }
    var body: some View {
        HStack(spacing:16) {
            SymbolTile(symbol:"moon.stars.fill",color:Theme.purple)
            VStack(alignment:.leading,spacing:4) {
                Text(store.t("今日睡眠","Today's sleep")).font(.headline)
                Text(store.t("按起床日期统计 · 与睡眠计时页共享记录","Grouped by wake-up date · Shared with the sleep timer")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(today.isEmpty ? "—" : sleepDuration(today.reduce(0) { $0+$1.durationSeconds },en:store.en)).font(.title2.monospacedDigit().weight(.semibold))
            Button(store.t("记录睡眠","Record sleep")) { store.newSleep() }.tint(Theme.purple)
            if store.selectedTab != 10 { Button(store.t("查看记录","View records")) { store.selectedTab = 10 } }
        }.card()
    }
}

struct SleepRecordEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var hours = 8
    @State private var minutes = 0
    @State private var night = Calendar.current.date(byAdding:.day,value:-1,to:Calendar.current.startOfDay(for:Date())) ?? Date()
    private var durationMinutes: Int? { HealthSleepImport.durationMinutes(hours:hours,minutes:minutes) }
    private var interval: (start: Date,end: Date) { HealthSleepImport.manualInterval(night:night,durationMinutes:durationMinutes ?? 0) }
    private var valid: Bool { durationMinutes != nil && interval.end <= Date() }
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            Label(store.t(store.sleepBackfill ? "补记睡眠" : "记录睡眠",store.sleepBackfill ? "Backfill sleep" : "Record sleep"),systemImage:"moon.stars.fill").font(.title2.weight(.semibold)).foregroundStyle(Theme.purple)
            Text(store.t("填写睡了几小时几分钟，健康睡眠页与睡眠计时页只需记录一次。","Enter hours and minutes once for the health sleep page and sleep timer.")).foregroundStyle(.secondary)
            HStack(spacing:10) {
                Text(store.t("睡眠时长","Sleep duration"))
                Spacer()
                TextField("",value:$hours,format:.number).textFieldStyle(.roundedBorder).frame(width:64).multilineTextAlignment(.trailing).accessibilityLabel(store.t("睡眠小时","Sleep hours"))
                Text(store.t("小时","hours"))
                TextField("",value:$minutes,format:.number).textFieldStyle(.roundedBorder).frame(width:64).multilineTextAlignment(.trailing).accessibilityLabel(store.t("睡眠分钟","Sleep minutes"))
                Text(store.t("分钟","minutes"))
            }
            HStack {
                DatePicker(store.t("哪晚（就寝日期）","Which night (bedtime date)"),selection:$night,in:...Date(),displayedComponents:[.date]).datePickerStyle(.field)
                Button(store.t("昨晚","Last night")) { night = Calendar.current.date(byAdding:.day,value:-1,to:Calendar.current.startOfDay(for:Date())) ?? Date() }
            }
            if let durationMinutes {
                Text(sleepDuration(Double(durationMinutes)*60,en:store.en)).font(.title3.weight(.semibold)).foregroundStyle(Theme.purple)
                Text("\(interval.start.formatted(date:.abbreviated,time:.shortened)) → \(interval.end.formatted(date:.abbreviated,time:.shortened))").font(.callout).foregroundStyle(.secondary)
                if interval.end > Date() { Text(store.t("这晚的起床时间尚未到，请选择已结束的睡眠。","This night's wake-up time is still in the future. Choose completed sleep.")).font(.callout).foregroundStyle(Theme.orange) }
            } else {
                Text(store.t("小时为 0–24，分钟为 0–59，总时长为 30 分钟至 24 小时。","Enter 0–24 hours and 0–59 minutes, totaling 30 minutes to 24 hours.")).font(.callout).foregroundStyle(Theme.orange)
            }
            Text(store.t("起床时间按次日早上 7:00 固定换算；选择昨天或更早的日期即可补记。睡眠计时页按所选那晚统计，健康页的今日睡眠按起床日期统计。","Wake-up is set to 07:00 the next day. Choose yesterday or an earlier date to backfill. The sleep timer groups by the selected night; the health daily card groups by wake-up date.")).font(.caption).foregroundStyle(.secondary)
            Text(store.t("保存后自动同步。近期有效睡眠按每小时 3 点恢复岛屿活力，每日最多 24 点。","Automatically syncs on save. Recent eligible sleep restores 3 island energy per hour, up to 24 per day.")).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(store.t("取消","Cancel")) { dismiss() }.keyboardShortcut(.cancelAction); Button(store.t("保存并同步","Save and sync")) { _ = store.addSleep(start:interval.start,end:interval.end) }.buttonStyle(.borderedProminent).tint(Theme.purple).disabled(!valid).keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width:540)
    }
}

private func sleepDuration(_ seconds: Double, en: Bool) -> String {
    let minutes = Int(max(0,seconds)/60)
    return en ? "\(minutes/60)h \(minutes%60)m" : "\(minutes/60) 小时 \(minutes%60) 分钟"
}
