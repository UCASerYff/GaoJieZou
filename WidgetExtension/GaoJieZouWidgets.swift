import WidgetKit
import SwiftUI

struct RhythmMonthlyOverviewWidget: Widget {
    let kind = "com.gaojiezou.rhythm.monthly-overview"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RhythmWidgetProvider()) { entry in
            RhythmWidgetMonthlyOverviewView(entry: entry)
        }
        .configurationDisplayName("月度总览")
        .description("查看本月琐事与短期行动的跨天安排。")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

struct RhythmMetricsWidget: Widget {
    let kind = "com.gaojiezou.rhythm.metrics"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RhythmWidgetProvider()) { entry in
            RhythmWidgetMetricsView(entry: entry)
        }
        .configurationDisplayName("今日指标")
        .description("显示今日目标、今日专注和昨夜睡眠。")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct RhythmLongGoalsWidget: Widget {
    let kind = "com.gaojiezou.rhythm.long-goals"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RhythmWidgetProvider()) { entry in
            RhythmWidgetGoalsView(entry: entry)
        }
        .configurationDisplayName("长期目标")
        .description("按新建时间优先显示长期目标，按可用高度显示尽可能多的记录。")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

@main
struct GaoJieZouWidgets: WidgetBundle {
    var body: some Widget {
        RhythmMonthlyOverviewWidget()
        RhythmMetricsWidget()
        RhythmLongGoalsWidget()
    }
}
