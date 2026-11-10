import SwiftUI
import AppKit

/// A single selected Footprints page inside the Rhythm shell.
/// Navigation, product branding and sidebar visibility belong to the host.
struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.colorScheme) var scheme
    @AppStorage(GQNSLanguage.key, store: FootprintsBundle.defaults) private var appLanguage = "system"
    let page: FootprintsNavigationPage
    @State var paths: AtlasPaths?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if let resourceError = store.resourceError {
                    VStack(spacing: 16) {
                        Image(systemName: "map.fill").font(.system(size: 40)).foregroundStyle(Theme.teal)
                        Text(tF("离线地图暂时不可用", "Offline map unavailable")).font(.headline)
                        Text(resourceError).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button(tF("重试", "Retry")) {
                            store.retryResourceLoad(); paths = FootprintsRuntime.atlasPaths
                        }.buttonStyle(.borderedProminent)
                    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !store.ready {
                    VStack(spacing: 14) {
                        Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                        Text(tF("足迹资料未能安全读取", "Footprints could not be safely loaded")).font(.headline)
                        Text(store.error ?? tF("写入已停止，原资料保持不变。", "Writing is stopped; original data is unchanged."))
                            .font(.caption).textSelection(.enabled)
                        Button(tF("重新读取", "Retry")) { store.retryLibraryLoad() }
                    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let paths {
                    Group {
                        switch page {
                        case .train: TrainPage()
                        case .trips: TripsPage()
                        case .timeline: TimelinePage()
                        case .residentCity: ResidentCityPage()
                        case .map: MapPage(paths: paths)
                        }
                    }
                } else {
                    ProgressView(tF("正在展开离线地图…", "Preparing offline map…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let toast = store.toast {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                    Text(toast).font(.caption)
                    Spacer()
                    if store.undoAvailable {
                        Button(tF("撤销", "Undo")) { store.undo() }.buttonStyle(.link)
                    }
                    Button { store.toast = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help(tF("关闭提示", "Dismiss"))
                }.padding(.horizontal, 24).padding(.vertical, 10)
                    .background(Theme.teal.opacity(0.07)).transition(.opacity)
            }
        }
        .background(Theme.background(scheme == .dark))
        .overlay(alignment: .topTrailing) {
            if let name = store.celebration {
                VStack(spacing: 8) {
                    Image(systemName: "seal.fill").font(.system(size: 32)).foregroundStyle(Theme.teal)
                    Text(tF("初次抵达", "First Arrival")).font(.caption).tracking(3).foregroundStyle(.secondary)
                    Text(name).font(.system(size: 22, weight: .semibold))
                    Text(tF("世界又多了一处回忆", "One more memory in the world")).font(.caption).foregroundStyle(.secondary)
                }.padding(24).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07)))
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                    .padding(.top, 70).padding(.trailing, 40).allowsHitTesting(false)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .task(id: name) {
                        try? await Task.sleep(for: .seconds(3))
                        if !Task.isCancelled { store.celebration = nil }
                    }
            }
        }
        .tint(Theme.teal)
        .id(appLanguage)
        .animation(store.animationEnabled && !reduceMotion ? .spring(duration: 0.35) : nil, value: store.celebration)
        .animation(store.animationEnabled && !reduceMotion ? .easeInOut(duration: 0.18) : nil, value: page)
        .onAppear {
            if paths == nil { paths = FootprintsRuntime.atlasPaths }
            WidgetExporter.publish(store: store, onlyIfStale: true)
        }
        .sheet(item: $store.editor) { request in VisitEditor(request: request).environmentObject(store) }
        .sheet(item: $store.tripEditor) { trip in TripEditor(trip: trip).environmentObject(store) }
        .sheet(isPresented: $store.customEditor) {
            if let paths { CustomCityEditor(paths: paths).environmentObject(store) }
        }
        .alert(tF("操作提示", "Notice"), isPresented: Binding(
            get: { store.error != nil }, set: { if !$0 { store.error = nil } }
        )) {
            Button(tF("知道了", "OK")) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}
