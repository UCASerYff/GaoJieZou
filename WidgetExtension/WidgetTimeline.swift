import WidgetKit

struct RhythmWidgetEntry: TimelineEntry {
    let date: Date
    let data: RhythmWidgetData
}

struct RhythmWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> RhythmWidgetEntry {
        RhythmWidgetEntry(date: Date(), data: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (RhythmWidgetEntry) -> Void) {
        completion(RhythmWidgetEntry(date: Date(), data: RhythmWidgetData.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RhythmWidgetEntry>) -> Void) {
        let now = Date()
        let entry = RhythmWidgetEntry(date: now, data: RhythmWidgetData.load())
        // A short policy keeps active focus and daily totals feeling live even when
        // the host app is closed. The app also calls reloadAllTimelines() after saves.
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        let nextDay = RhythmWidgetEntry(date: midnight, data: entry.data)
        completion(Timeline(entries: [entry, nextDay], policy: .after(now.addingTimeInterval(15 * 60))))
    }
}
