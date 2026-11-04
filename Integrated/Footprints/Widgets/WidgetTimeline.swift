import WidgetKit

struct FootprintWidgetEntry: TimelineEntry {
    let date: Date
    let data: FootprintWidgetData
}

struct FootprintWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FootprintWidgetEntry {
        FootprintWidgetEntry(date: Date(), data: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (FootprintWidgetEntry) -> Void) {
        let requestedAt = Date()
        let data = FootprintWidgetData.load(reason: context.isPreview ? "preview" : "snapshot", family: String(describing: context.family), requestedAt: requestedAt)
        completion(FootprintWidgetEntry(date: requestedAt, data: data))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FootprintWidgetEntry>) -> Void) {
        let now = Date()
        let data = FootprintWidgetData.load(reason: "timeline", family: String(describing: context.family), requestedAt: now)
        let entry = FootprintWidgetEntry(date: now, data: data)
        // 这是下一次请求的建议时间，实际调度由 WidgetKit 决定。
        // entry.date 只用于调度；资料更新时间始终来自已提交的 generation。
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60))))
    }
}
