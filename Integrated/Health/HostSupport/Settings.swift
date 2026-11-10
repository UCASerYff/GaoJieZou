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
    @State private var status = ""
    var body: some View {
        Form {
            Section("数据目录") {
                Text("这里只打开现用健康资料和共享睡眠位置，不会创建空白目录。")
                Button("打开健康资料目录") { reveal(AppDataLocations.appSupport) }
                Button("打开共享睡眠目录") { reveal(AppDataLocations.groupContainer) }
                if !status.isEmpty { Text(status).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
    }
    private func reveal(_ url: URL?) {
        guard let url, FileManager.default.fileExists(atPath:url.path) else {
            status = "资料目录尚未创建，未新建空白目录。"
            return
        }
        status = ""
        NSWorkspace.shared.open(url)
    }
}
