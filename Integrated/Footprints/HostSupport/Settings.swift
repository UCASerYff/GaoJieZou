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
    @State private var status=""
    var body:some View {
        Form {
            Section("数据目录") {
                Text("这里只打开现用足迹资料与组件共享位置，不会创建空白目录。")
                Button("打开数据目录") { reveal(AppDataLocations.appSupport) }
                Button("打开足迹组件共享目录") { reveal(AppDataLocations.groupContainer) }
                if !status.isEmpty { Text(status).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
    }
    private func reveal(_ url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { status = "资料目录尚未创建，未新建空目录。"; return }
        status = ""
        NSWorkspace.shared.open(url)
    }
}
