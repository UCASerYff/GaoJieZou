import WidgetKit
import SwiftUI

struct FootprintMapWidget: Widget {
    let kind = "com.gaojiezou.rhythm.footprints.map"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FootprintWidgetProvider()) { entry in
            FootprintMapWidgetView(entry: entry)
                .widgetURL(entry.data.mapURL)
        }
        .configurationDisplayName("点亮地图")
        .description("羊皮纸地图上的点亮进度：城市、国家与中国收集进度。")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct RhythmFootprintsWidgets: WidgetBundle {
    var body: some Widget {
        FootprintMapWidget()
    }
}
