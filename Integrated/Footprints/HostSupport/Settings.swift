import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettings:View {
    @AppStorage("gqns.language", store: FootprintsBundle.defaults) private var language="system"
    @AppStorage("gqns.appearance", store: FootprintsBundle.defaults) private var appearance="system"
    var body:some View {
        Form {
            Picker("语言",selection:$language) { Text("跟随系统").tag("system");Text("中文").tag("zh-Hans");Text("English").tag("en") }
            Picker("外观",selection:$appearance) { Text("跟随系统").tag("system");Text("浅色").tag("light");Text("深色").tag("dark") }
            LabeledContent("版本",value:"V"+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "?"))
        }.formStyle(.grouped).preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
    }
}
enum AppAppearance: String {
    case system, light, dark
    var colorScheme: ColorScheme? { self == .system ? nil : (self == .dark ? .dark : .light) }
}
enum AppDataLocations {
    static var appSupport: URL? { try? FootprintsIntegratedStorage.dataDirectory() }
    static var groupContainer: URL? { try? FootprintsIntegratedStorage.widgetDirectory() }
}
struct DataSettings:View {
    @State private var busy=false
    @State private var status=""
    var body:some View {
        Form {
            Section("完整资料") {
                Text("包含业务历史、游戏进度、PDF、Word、图片及数据目录内的全部附件；密钥继续由系统钥匙串保管。")
                Button("导出完整资料…",action:export).disabled(busy)
                Button("从完整资料恢复…",action:restore).disabled(busy)
                if busy { ProgressView() }
                if !status.isEmpty { Text(status).textSelection(.enabled) }
            }
            Section("模块格式") {
                Button("导出模块备份…") { FootprintsModuleRuntime.exportModuleBackup() }
                Button("恢复模块备份…") { FootprintsModuleRuntime.restoreModuleBackup() }
            }
            Section("数据目录") {
                Button("打开数据目录") { reveal(AppDataLocations.appSupport) }
                Button("打开足迹组件共享目录") { reveal(AppDataLocations.groupContainer) }
            }
        }.formStyle(.grouped)
    }
    private func reveal(_ url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { status = "资料目录尚未激活或缺失，未新建空目录。"; return }
        NSWorkspace.shared.open(url)
    }
    private func export() {
        
        let panel=NSSavePanel();panel.allowedContentTypes=[.zip];panel.nameFieldStringValue="搞节奏-足迹完整资料.zip"
        guard panel.runModal() == .OK,let url=panel.url else {return}
        busy=true;status="正在备份并逐文件校验…"
        let support=AppDataLocations.appSupport,group=AppDataLocations.groupContainer
        Task { do {
            let result=try await Task.detached {try AppBackupExport.export(appSupport:support,group:group,destination:url)}.value
            busy=false;status="备份完成：\(result.fileCount) 个文件，全部 SHA-256 校验通过。"
        } catch {busy=false;status="备份失败：\(error.localizedDescription)"} }
    }
    private func restore() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.zip];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else {return}
        busy=true;status="正在校验完整资料…"
        Task { do {
            let (staged,manifest)=try await Task.detached {try AppBackupRestore.prepare(url)}.value
            busy=false
            let alert=NSAlert();alert.messageText="恢复这份完整资料？";alert.informativeText="已核验 \(manifest.files.count) 个文件。应用将在下次启动时恢复，当前数据会保留为安全副本。";alert.addButton(withTitle:"恢复并退出");alert.addButton(withTitle:"取消")
            if alert.runModal() == .alertFirstButtonReturn { try AppBackupRestore.schedule(staged);NSApp.terminate(nil) }
            else {try? FileManager.default.removeItem(at:staged);status="已取消"}
        } catch {busy=false;status="恢复未完成：\(error.localizedDescription)"} }
    }
}
