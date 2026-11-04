import Foundation

/// The shared journal is authoritative. Reading the legacy library only seeds
/// previously unseen IDs and never overwrites a synchronized record or deletion.
enum HealthSleepImport {
    /// The production migration imports/verifies legacy IDs, pending receipts,
    /// tombstones and seed markers before activation. Runtime never seeds a peer
    /// file again, including when a stale source App is still installed.
    static func migrateLegacy(to shared: SharedSleepStore) throws {
        _ = try RhythmIntegrationPaths.sharedSleepDirectory()
        _ = try shared.records()
    }

    static func durationMinutes(hours: Int, minutes: Int) -> Int? {
        guard (0...24).contains(hours), (0...59).contains(minutes) else { return nil }
        let total = hours * 60 + minutes
        return (30...1440).contains(total) ? total : nil
    }

    /// Match Rhythm's duration entry: the selected night wakes at 07:00 the next day.
    static func manualInterval(night: Date, durationMinutes: Int, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let nightStart = calendar.startOfDay(for:night)
        let wakeDay = calendar.date(byAdding:.day,value:1,to:nightStart) ?? nightStart
        let end = calendar.date(bySettingHour:7,minute:0,second:0,of:wakeDay) ?? wakeDay
        return (calendar.date(byAdding:.minute,value:-durationMinutes,to:end) ?? end,end)
    }

    static func manual(start: Date, end: Date, now: Date = Date()) throws -> SharedSleepEntry {
        let duration = end.timeIntervalSince(start)
        guard start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
              (1800...86400).contains(duration), end <= now else {
            throw HealthError("请填写已结束的睡眠，就寝早于起床，时长为 30 分钟至 24 小时。 / Enter completed sleep lasting 30 minutes to 24 hours.")
        }
        return SharedSleepEntry(id:UUID().uuidString,startedAt:start,endedAt:end,durationSeconds:duration,
            score:max(0,min(100,Int(100-abs(duration/3600-8)*18))),pastureYield:0,
            manualEntry:true,manualGrowthCreditedSeconds:0,manualProductionCreditedCycles:0,origin:"health")
    }
}
