import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
