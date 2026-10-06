import AppKit
import UniformTypeIdentifiers

/// 完整备份导出/恢复：原 ContentView 工具栏菜单的实现，V1.9 起模块内入口移除，
/// 收拢到 app 级「数据」页，经通知 `GaoSeries.rhythm.export` / `.import` 触发（Module.swift）。
extension RhythmStore {
    func exportFullBackup() {
        let panel = NSSavePanel()
        panel.title = RhythmLocalization.text("导出搞节奏完整备份")
        panel.nameFieldStringValue = "搞节奏备份-\(Self.backupDateString()).gaojiezou"
        panel.allowedContentTypes = [UTType(exportedAs: "com.gaojiezou.backup", conformingTo: .archive)]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try backupData().write(to: url, options: .atomic)
            notice = RhythmLocalization.text("完整备份已经导出。")
        } catch {
            notice = RhythmLocalization.format("备份导出失败：%@", error.localizedDescription)
        }
    }

    func restoreFullBackup() {
        let panel = NSOpenPanel()
        panel.title = RhythmLocalization.text("选择搞节奏完整备份")
        panel.allowedContentTypes = [UTType(exportedAs: "com.gaojiezou.backup", conformingTo: .archive)]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try restore(from: Data(contentsOf: url))
        } catch {
            notice = RhythmLocalization.format("备份恢复失败：%@", error.localizedDescription)
        }
    }

    private static func backupDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }
}
