import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettings: View {
    @AppStorage("gqns.language") private var language = "system"
    @AppStorage("gqns.appearance") private var appearance = "system"
    var body: some View {
        Form {
            Text("语言和外观与搞节奏共用。原搞健康设置随来源档案保留，不覆盖当前宿主设置。")
            Picker("语言", selection: $language) { Text("跟随系统").tag("system"); Text("中文").tag("zh-Hans"); Text("English").tag("en") }
            Picker("外观", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
        }.formStyle(.grouped).onChange(of: appearance) { _, value in
            NSApp.appearance = value == "system" ? nil : NSAppearance(named: value == "dark" ? .darkAqua : .aqua)
        }
    }
}


struct DataSettings: View {
    @State private var busy = false
    @State private var status = ""
    var body: some View {
        Form {
            Section("完整健康资料") {
                Text("健康历史、岛屿、模板、附件和共享睡眠包含在 ZIP 中。模块恢复仅替换健康自身资料，不替换节奏或足迹。共享睡眠请使用宿主完整整合备份统一恢复。系统钥匙串与权限仍由系统管理。")
                Button("导出完整健康资料…", action: export).disabled(busy || !RhythmIntegrationPaths.isActive)
                Button("从完整健康资料恢复…", action: restore).disabled(busy || !RhythmIntegrationPaths.isActive)
                if busy { ProgressView() }
                if !status.isEmpty { Text(status).textSelection(.enabled) }
            }
            Section("兼容模块格式") {
                Button("导出健康与岛屿备份…") { HealthModuleRuntime.exportModuleBackup() }
                Button("恢复健康与岛屿备份…") { HealthModuleRuntime.restoreModuleBackup() }
            }
            Section("数据目录") {
                Button("打开健康资料目录") { reveal(AppDataLocations.appSupport) }
                Button("原健康文件") { revealImportedSupport() }
                Button("打开共享睡眠目录") { reveal(AppDataLocations.groupContainer) }
            }
        }.formStyle(.grouped)
    }
    private func revealImportedSupport() {
        do {
            if let url = try AppDataLocations.importedSupport() { NSWorkspace.shared.open(url) }
            else { status = "来源健康文件目录已明确记录为不存在，未迁入也未创建空白目录。" }
        } catch { status = "无法打开原健康文件：\(error.localizedDescription)" }
    }
    private func reveal(_ url: URL?) { if let url { NSWorkspace.shared.open(url) } else { status = "健康整合尚未激活，未创建空白目录。" } }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = "搞节奏-完整健康资料.zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; status = "正在备份并逐文件校验…"
        Task { do {
            let result = try await Task.detached { try AppBackupExport.export(destination: url) }.value
            busy = false; status = "备份完成：\(result.fileCount) 个文件，SHA-256 校验通过。"
        } catch { busy = false; status = "备份失败：\(error.localizedDescription)" } }
    }
    private func restore() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.zip]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; status = "正在校验完整资料…"
        Task { do {
            let (staged, manifest) = try await Task.detached { try AppBackupRestore.prepare(url) }.value
            busy = false
            let alert = NSAlert(); alert.messageText = "下次启动恢复健康资料？"
            alert.informativeText = "已核验 \(manifest.files.count) 个文件。仅健康自身资料恢复到备份时点，当前健康资料保留为安全副本。共享睡眠和来源档案不被替换；已消费的奖励与请求去重身份保留。请先保存并结束所有在途工作，再正常退出搞节奏。"
            alert.addButton(withTitle: "安排恢复"); alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                try AppBackupRestore.schedule(staged)
                status = "已安排下次启动恢复。请保存当前工作并正常退出搞节奏；当前资料尚未替换。"
            } else { try? FileManager.default.removeItem(at: staged); status = "已取消" }
        } catch { busy = false; status = "恢复未完成：\(error.localizedDescription)" } }
    }
}
