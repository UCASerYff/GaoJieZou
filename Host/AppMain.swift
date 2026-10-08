import SwiftUI
import AppKit
import UserNotifications
import Rhythm

@main struct StandaloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var route: URL?
    @State private var revision = 0
    @State private var dataError: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    init() {
        
        do { try AppBackupRestore.applyPending() } catch {
            let alert=NSAlert();alert.messageText="数据恢复未完成";alert.informativeText=error.localizedDescription+"\n当前数据和恢复前副本已保留。";alert.runModal();exit(1)
        }
        AppAppearance.current.apply()
        
    }
    static func activate() {
        NSApp.activate(ignoringOtherApps:true)
        if let w=NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.windows.first(where:{$0.styleMask.contains(.titled) && !($0 is NSPanel)}) {
            if w.isMiniaturized { w.deminiaturize(nil) };w.makeKeyAndOrderFront(nil)
        }
    }
    var body: some Scene {
        // A single Window scene quits on close. A value-based WindowGroup keeps
        // the runtime alive and reuses the same main window when reopened.
        WindowGroup("搞节奏 V\(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "?")",id:"main",for:String.self) { _ in
            RhythmModuleView(route:route,routeRevision:revision)
                .frame(minWidth:1040,minHeight:720)
                .modifier(WindowToolbarOpaqueBackground())
                .onAppear {
                    delegate.showMainWindow = {
                        openWindow(id:"main",value:"main")
                        Self.activate()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for:Notification.Name("GaoSeries.dataError"))) { dataError=$0.userInfo?["message"] as? String }
                .alert("数据操作未完成",isPresented:Binding(get:{dataError != nil},set:{if !$0 {dataError=nil}})) { Button("知道了") {dataError=nil} } message:{Text(dataError ?? "")}
                .onReceive(NotificationCenter.default.publisher(for:Notification.Name("GaoSeries.app.openSettings"))) { _ in openSettings() }
                .onReceive(NotificationCenter.default.publisher(for:Notification.Name("appOpenSettings"))) { _ in openSettings() }
                .onReceive(NotificationCenter.default.publisher(for:Notification.Name("Standalone.showWindow"))) { _ in delegate.showMainWindow?() }
                
                .onOpenURL { url in
                    route=url;revision &+= 1;openWindow(id:"main",value:"main");Self.activate()
                    
                }
        } defaultValue: { "main" }
        .defaultSize(width:1380,height:860)
        .handlesExternalEvents(matching:["*"])
        .commands {
            CommandGroup(replacing:.newItem) {
                Button("显示搞节奏") { openWindow(id:"main",value:"main");Self.activate() }
                    .keyboardShortcut("0",modifiers:.command)
            }
            CommandMenu("数据") {
                Button("导出模块备份…") { post("GaoSeries.rhythm.export") }
                Button("恢复模块备份…") { post("GaoSeries.rhythm.import") }
                Divider()
                Button("完整资料备份与恢复…") { openSettings() }
            }
        }
        Settings {
            TabView {
                RhythmSettingsView().tabItem { Label("模块设置",systemImage:"slider.horizontal.3") }
                GeneralSettings().tabItem { Label("外观",systemImage:"paintpalette") }
                DataSettings().tabItem { Label("数据",systemImage:"externaldrive") }
            }.frame(width:820,height:740)
        }
        
    }
}
func post(_ name:String) { NotificationCenter.default.post(name:Notification.Name(name),object:nil) }
final class AppDelegate:NSObject,NSApplicationDelegate,UNUserNotificationCenterDelegate {
    var showMainWindow: (() -> Void)?
    func applicationDidFinishLaunching(_ notification:Notification) { UNUserNotificationCenter.current().delegate=self }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        showMainWindow?()
        return false
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        RhythmApplicationLifecycle.prepareForTermination()
        return .terminateNow
    }
    func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping(UNNotificationPresentationOptions)->Void) { completionHandler([.banner,.list,.sound]) }
    func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping()->Void) {
        DispatchQueue.main.async { self.showMainWindow?();completionHandler() }
    }
}
private struct WindowToolbarOpaqueBackground:ViewModifier {
    func body(content:Content)->some View {
        if #available(macOS 15.0,*) { content.toolbarBackground(Color(nsColor:.windowBackgroundColor),for:.windowToolbar).toolbarBackgroundVisibility(.visible,for:.windowToolbar) }
        else { content.toolbarBackground(Color(nsColor:.windowBackgroundColor),for:.windowToolbar) }
    }
}
