import AppKit
import SwiftUI
import Rhythm
import UniformTypeIdentifiers

struct GeneralSettings:View {
    @AppStorage("gqns.language") private var language="system"
    @AppStorage("gqns.appearance") private var appearance="system"
    var body:some View {
        Form {
            Picker("语言",selection:$language) { Text("跟随系统").tag("system");Text("中文").tag("zh-Hans");Text("English").tag("en") }
            Picker("外观",selection:$appearance) { Text("跟随系统").tag("system");Text("浅色").tag("light");Text("深色").tag("dark") }
            LabeledContent("版本",value:"V"+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "?"))
        }.formStyle(.grouped).onChange(of:appearance) { _,_ in AppAppearance.current.apply() }
    }
}
enum AppAppearance:String {
    case system,light,dark
    static var current:Self { Self(rawValue:UserDefaults.standard.string(forKey:"gqns.appearance") ?? "system") ?? .system }
    func apply() { guard let app=NSApp else { DispatchQueue.main.async {self.apply()};return };app.appearance=self == .system ? nil : NSAppearance(named:self == .dark ? .darkAqua : .aqua) }
}
enum AppDataLocations {
    static var appSupport:URL? { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first?.appendingPathComponent("GaoSeries/Rhythm",isDirectory:true) }
    static var sharedSleepContainer:URL? { try? RhythmIntegrationPaths.sharedSleepDirectory() }
    static var groupContainer:URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:"5G96498KGJ.com.gaojiezou.rhythm") }
}
struct DataSettings:View {
    @State private var status=""
    var body:some View {
        Form {
            Section("数据目录") {
                Text("这里只打开现用资料位置，不会创建空白资料库。记录、设置、附件与游戏进度继续保存在原路径。")
                Button("打开数据目录") { reveal(AppDataLocations.appSupport, name:"资料目录") }
                Button("打开小组件共享目录") { reveal(AppDataLocations.groupContainer, name:"小组件共享目录") }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
    }
    private func reveal(_ url:URL?,name:String) {
        guard let url,FileManager.default.fileExists(atPath:url.path) else {
            status="\(name)尚未创建"
            return
        }
        status=""
        NSWorkspace.shared.open(url)
    }
}
