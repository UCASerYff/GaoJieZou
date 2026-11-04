import SwiftUI
import AppKit

// 独立 App 入口（GaoZuJiApp 与 AppDelegate）已随整合版移除；
// 模块视图由 Footprints/Module.swift 的 FootprintsModuleView 承载。
struct RootView:View{
    @EnvironmentObject var store:Store
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.colorScheme) var scheme
    @AppStorage(GQNSLanguage.key, store: FootprintsBundle.defaults) private var appLanguage = "system"
    /// 侧栏隐藏/显示（场景级记忆；键全 app 唯一）。只有 隐藏↔显示 两态，无「收起成图标栏」。
    @SceneStorage("gqns.sidebarHidden.footprints") private var sidebarHidden = false
    /// 自绘侧栏导航行的 hover 跟踪（浅灰反馈，与词元一致）。
    @State private var hoveredSection:String?
    @State var paths:AtlasPaths?
    @State private var showResidentCityEditor = false
    var body:some View{
        // 侧栏重设计（对齐词元 2.2/2.3 标杆）：弃用系统 NavigationSplitView 列表侧栏，
        // 改 HStack 自绘——品牌头部 + 浮动卡片选中态导航行 + hover 反馈 + 状态底卡。
        // 统一工具栏契约：.navigation 恰好一个 28×28 侧栏切换按钮（⌃⌘S）；
        // 原有 trailing「点亮一个地方」按钮保留，包在固定宽 360 的右对齐容器里。
        HStack(spacing:0){
            if !sidebarHidden{
                sidebar
                // 自绘发丝线替代系统 Divider：避免 Tahoe 统一标题栏下系统 separator 冷启动首帧误渲染成灰带
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1).frame(maxHeight: .infinity)
            }
            VStack(spacing:0){
                ZStack(alignment:.bottom){
                    if let resourceError=store.resourceError{
                        VStack(spacing:16){
                            Image(systemName:"map.fill").font(.system(size:40)).foregroundStyle(Theme.teal)
                            Text(tF("离线地图暂时不可用","Offline map unavailable")).font(.headline)
                            Text(resourceError).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button(tF("重试","Retry")){store.retryResourceLoad();paths=FootprintsRuntime.atlasPaths}.buttonStyle(.borderedProminent)
                        }.padding(40).frame(maxWidth:.infinity,maxHeight:.infinity)
                    }else if !store.ready {
                        VStack(spacing: 14) {
                            Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                            Text(tF("足迹资料未能安全读取", "Footprints could not be safely loaded")).font(.headline)
                            Text(store.error ?? tF("写入已停止，原资料保持不变。", "Writing is stopped; original data is unchanged.")).font(.caption).textSelection(.enabled)
                            Button(tF("重新读取", "Retry")) { store.retryLibraryLoad() }
                        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }else if let paths{
                        Group{switch store.section{case "列车":TrainPage();case "旅行":TripsPage();case "时间轴":TimelinePage();default:MapPage(paths:paths)}}
                    }else{ProgressView(tF("正在展开离线地图…","Preparing offline map…")).frame(maxWidth:.infinity,maxHeight:.infinity)}
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                if let toast=store.toast{
                    HStack{Image(systemName:"checkmark.circle.fill").foregroundStyle(Theme.teal);Text(toast).font(.caption);Spacer();if store.undoAvailable{Button(tF("撤销","Undo")){store.undo()}.buttonStyle(.link)};Button{store.toast=nil}label:{Image(systemName:"xmark")}.buttonStyle(.plain).help(tF("关闭提示","Dismiss"))}.padding(.horizontal,24).padding(.vertical,10).background(Theme.teal.opacity(0.07)).transition(.opacity)
                }
            }
            .background(Theme.background(scheme == .dark))
        }
        .animation(.easeInOut(duration:0.22),value:sidebarHidden)
        .toolbar{
            toolbarItemNoChrome(.navigation){
                Button{
                    withAnimation(.easeInOut(duration:0.22)){sidebarHidden.toggle()}
                }label:{
                    SidebarToggleIcon()
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s",modifiers:[.command,.control])
                .help(tF(sidebarHidden ? "显示侧边栏" : "隐藏侧边栏",sidebarHidden ? "Show Sidebar" : "Hide Sidebar"))
            }
            toolbarItemNoChrome(.primaryAction){
                HStack(spacing:12){
                    Button{store.editor=EditorRequest()}label:{Label(tF("点亮一个地方","Light Up a Place"),systemImage:"plus")}.disabled(!store.ready)
                }
                .frame(width:360,alignment:.trailing)
            }
        }
        .overlay(alignment:.topTrailing) {
            if let name=store.celebration {
                VStack(spacing:8) { Image(systemName:"seal.fill").font(.system(size:32)).foregroundStyle(Theme.teal);Text(tF("初次抵达","First Arrival")).font(.caption).tracking(3).foregroundStyle(.secondary);Text(name).font(.system(size:22,weight:.semibold));Text(tF("世界又多了一处回忆","One more memory in the world")).font(.caption).foregroundStyle(.secondary) }.padding(24).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).stroke(Color.primary.opacity(0.07))).shadow(color:.black.opacity(0.08),radius:12,y:4).padding(.top,70).padding(.trailing,40).allowsHitTesting(false).transition(.scale(scale:0.9).combined(with:.opacity)).task(id:name) { try? await Task.sleep(for:.seconds(3)); if !Task.isCancelled {store.celebration=nil} }
            }
        }.tint(Theme.teal)
        .id(appLanguage)
        .animation(store.animationEnabled && !reduceMotion ? .spring(duration:0.35) : nil,value:store.celebration)
        .animation(store.animationEnabled && !reduceMotion ? .easeInOut(duration:0.18) : nil,value:store.section)
        .onAppear{if paths==nil{paths=FootprintsRuntime.atlasPaths};WidgetExporter.publish(store:store,onlyIfStale:true)}
        .sheet(item:$store.editor){request in VisitEditor(request:request).environmentObject(store)}
        .sheet(item:$store.tripEditor){trip in TripEditor(trip:trip).environmentObject(store)}
        .sheet(isPresented:$store.customEditor){if let paths{CustomCityEditor(paths:paths).environmentObject(store)}}
        .sheet(isPresented:$showResidentCityEditor){ResidentCityEditor().environmentObject(store)}
        .alert(tF("操作提示","Notice"),isPresented:Binding(get:{store.error != nil},set:{if !$0{store.error=nil}})){Button(tF("知道了","OK")){store.error=nil}}message:{Text(store.error ?? "")}
    }

    // MARK: 自绘侧边栏（词元标杆）：品牌头部 + 浮动卡片选中态导航行 + 状态底卡

    private var sidebar:some View{
        VStack(spacing:0){
            brandHeader
            ScrollView{
                VStack(alignment:.leading,spacing:20){
                    sidebarSection(tF("足迹收藏","Collections")){
                        sidebarRow("地图",title:tF("地图","Map"),symbol:"map")
                        sidebarRow("列车",title:tF("旅行列车","Travel Train"),symbol:"tram.fill")
                        sidebarRow("旅行",title:tF("旅行","Trips"),symbol:"suitcase.rolling")
                        sidebarRow("时间轴",title:tF("时间轴","Timeline"),symbol:"clock")
                    }
                }
                .padding(.horizontal,14)
                .padding(.vertical,14)
                .frame(maxWidth:.infinity,alignment:.leading)
            }
            ResidentCitySummary { showResidentCityEditor = true }
                .padding(.horizontal,14).padding(.bottom,12)
            statusFooter
        }
        .frame(width:236)
        .frame(maxHeight:.infinity)
        .background(.regularMaterial)
    }
    private var brandHeader:some View{
        HStack(spacing:10){
            if let url=FootprintsBundle.bundle.url(forResource:"GaoZuJiIcon",withExtension:"png"),let image=NSImage(contentsOf:url){
                Image(nsImage:image).resizable()
                    .interpolation(.high)
                    .frame(width:38,height:38)
                    .clipShape(RoundedRectangle(cornerRadius:9,style:.continuous))
                    .accessibilityHidden(true)
            }else{Image(systemName:"map.circle").font(.system(size:34,weight:.light)).foregroundStyle(Theme.teal)}
            VStack(alignment:.leading,spacing:2){
                Text(tF("搞足迹","Gao Footprints")).font(.headline)
                Text(tF("点亮走过的每一个地方","Every place you have lit up")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength:0)
        }
        .padding(.horizontal,14)
        .padding(.top,14)
        .padding(.bottom,10)
        .frame(maxWidth:.infinity)
    }
    @ViewBuilder private func sidebarSection<Rows:View>(_ title:String,@ViewBuilder rows:()->Rows)->some View{
        VStack(alignment:.leading,spacing:4){
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal,10)
                .padding(.bottom,2)
            rows()
        }
    }
    /// 浮动卡片选中态导航行：accent 底白字 + 柔和投影（深色下投影 opacity 调高），hover 浅灰反馈。
    private func sidebarRow(_ section:String,title:String,symbol:String)->some View{
        let selected=store.section==section
        let hovered=hoveredSection==section
        return Button{store.section=section}label:{
            HStack(spacing:10){
                Image(systemName:symbol)
                    .font(.callout)
                    .frame(width:20)
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength:0)
            }
            .padding(.horizontal,10)
            .frame(maxWidth:.infinity,minHeight:32)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background{
                if selected{
                    RoundedRectangle(cornerRadius:9,style:.continuous)
                        .fill(Theme.teal)
                        .shadow(color:Theme.teal.opacity(scheme == .dark ? 0.45 : 0.32),radius:5,y:2)
                }else if hovered{
                    RoundedRectangle(cornerRadius:9,style:.continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius:9,style:.continuous))
        }
        .buttonStyle(.plain)
        .onHover{hovering in hoveredSection = hovering ? section : nil}
    }
    /// 状态底卡（词元 statusFooter 风格）：足迹计数 + 存储说明。
    private var statusFooter:some View{
        VStack(alignment:.leading,spacing:7){
            HStack(spacing:7){
                Circle().fill(Theme.teal).frame(width:7,height:7)
                Text(store.ready ? tF("已点亮 \(store.journal.visits.count) 处足迹","\(store.journal.visits.count) places lit") : tF("资料未就绪 · 已停止写入", "Data unavailable · writing stopped")).font(.caption)
                Spacer(minLength:0)
            }
            Text(tF("本机保存 · 无需登录","Saved locally · No sign-in")).font(.system(size:10)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:12,style:.continuous))
        .padding(.horizontal,14)
        .padding(.vertical,12)
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
