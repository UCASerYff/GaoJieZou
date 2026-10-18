import Foundation
#if !WIDGET_SYNC_TEST
import WidgetKit
import OSLog
#endif

struct RhythmWidgetEntry {
    let date: Date
    let snapshot: RhythmWidgetReadResult
    var data: RhythmWidgetData? { snapshot.data }
}

enum RhythmWidgetTimelineSchedule {
    /// Calendar arithmetic keeps every midnight correct across short/long DST
    /// days and month/year boundaries, even if the app stays closed for weeks.
    static func dates(now: Date, calendar: Calendar = .current) -> [Date] {
        var result = [now]
        let today = calendar.startOfDay(for: now)
        for offset in 1...32 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today),
                  date > (result.last ?? now) else { continue }
            result.append(date)
        }
        return result
    }
}

#if !WIDGET_SYNC_TEST
extension RhythmWidgetEntry: TimelineEntry {}

struct RhythmWidgetProvider: TimelineProvider {
    let kind: String
    private static let log = Logger(subsystem: "com.gaojiezou.rhythm", category: "WidgetTimeline")

    private func recordRequest(phase: String, context: Context, at date: Date) {
        let requestedAt = ISO8601DateFormatter().string(from: date)
        let family = String(describing: context.family)
        // A provider request is observable, but it is not an acknowledgement
        // that the desktop actually displayed this entry.
        Self.log.info("phase=\(phase, privacy: .public) kind=\(kind, privacy: .public) family=\(family, privacy: .public) requestedAt=\(requestedAt, privacy: .public)")
    }

    func placeholder(in context: Context) -> RhythmWidgetEntry {
        let now = Date()
        return RhythmWidgetEntry(date: now, snapshot: .placeholder(at: now))
    }

    func getSnapshot(in context: Context, completion: @escaping (RhythmWidgetEntry) -> Void) {
        let now = Date()
        recordRequest(phase: "getSnapshot", context: context, at: now)
        completion(RhythmWidgetEntry(date: now, snapshot: RhythmWidgetReader.load(now: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RhythmWidgetEntry>) -> Void) {
        let now = Date()
        recordRequest(phase: "getTimeline", context: context, at: now)
        let snapshot = RhythmWidgetReader.load(now: now)
        let entries = RhythmWidgetTimelineSchedule.dates(now: now).map {
            RhythmWidgetEntry(date: $0, snapshot: snapshot)
        }
        // This requests another read; WidgetKit chooses the actual delivery time.
        // Future entries only re-evaluate calendar/day totals. They never advance
        // contentUpdatedAt or pretend that new business records were received.
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}
#endif
