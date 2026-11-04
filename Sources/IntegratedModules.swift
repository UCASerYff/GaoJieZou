import SwiftUI
import RhythmHealth
import RhythmFootprints

/// A failed or unfinished cutover cannot instantiate a source store with defaults.
struct IntegrationAvailability<Content: View>: View {
    let content: () -> Content
    @State private var active = RhythmIntegrationPaths.isActive
    var body: some View {
        if active {
            content()
        } else {
            VStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                Text("资料整合尚未激活").font(.headline)
                Text("迁移和来源停写核验完成后才能打开。原资料保持原样，不会创建空白库替代。")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重新检查") { active = RhythmIntegrationPaths.isActive }
            }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct IntegratedHealthView: View {
    let route: URL?
    let routeRevision: Int
    var body: some View {
        IntegrationAvailability { HealthModuleView(route: route, routeRevision: routeRevision) }
    }
}

struct IntegratedFootprintsView: View {
    let route: URL?
    let routeRevision: Int
    var body: some View {
        IntegrationAvailability { FootprintsModuleView(route: route, routeRevision: routeRevision) }
    }
}
