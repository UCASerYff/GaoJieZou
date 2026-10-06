import Foundation

/// 记录 CSV 导出：中文表头、UTF-8 带 BOM（Excel 直接打开不乱码）、
/// 字段含逗号/引号/换行时按 RFC 4180 加引号并双写内部引号。
/// 这里只做纯文本拼装，文件面板与落盘在设置页；纯函数便于冒烟测试断言。
enum RhythmCSVExport {

    /// UTF-8 BOM，Excel 据此识别编码。
    static let bom = "\u{FEFF}"

    private static var timestampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    private static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// RFC 4180 字段转义：含逗号、引号或换行时整体加引号，内部引号双写。
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func document(header: [String], rows: [[String]]) -> String {
        let lines = ([header] + rows).map { $0.map(escape).joined(separator: ",") }
        return bom + lines.joined(separator: "\r\n") + "\r\n"
    }

    /// 专注记录：开始时间、结束时间、时长分钟、关联行动、金币。按开始时间升序。
    static func focusRecordsCSV(_ records: [FocusRecord]) -> String {
        let formatter = timestampFormatter
        let rows = records.sorted { $0.startedAt < $1.startedAt }.map { record in
            [
                formatter.string(from: record.startedAt),
                formatter.string(from: record.endedAt),
                String(format: "%.1f", record.durationSeconds / 60),
                record.title,
                String(record.earnedCoins),
            ]
        }
        return document(header: ["开始时间", "结束时间", "时长（分钟）", "关联行动", "金币"], rows: rows)
    }

    /// 睡眠记录：开始、结束、时长小时、目标、评分。目标是导出时的设置值
    /// （SleepRecord 本身不存目标，ActiveSleep.targetHours 仅存在于进行中会话）。
    static func sleepRecordsCSV(_ records: [SleepRecord], targetHours: Double) -> String {
        let formatter = timestampFormatter
        let rows = records.sorted { $0.startedAt < $1.startedAt }.map { record in
            [
                formatter.string(from: record.startedAt),
                formatter.string(from: record.endedAt),
                String(format: "%.2f", record.durationSeconds / 3600),
                String(format: "%.1f", targetHours),
                String(record.score),
            ]
        }
        return document(header: ["开始时间", "结束时间", "时长（小时）", "目标（小时）", "评分"], rows: rows)
    }

    /// 打卡完成记录：打卡名、日期、奖励。按日期升序；
    /// 已删除的打卡保留记录行，名称记为「已删除打卡」，奖励留空。
    static func habitCompletionsCSV(habits: [Habit], completionKeys: Set<String>, calendar: Calendar = .current) -> String {
        let habitByID = Dictionary(habits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let formatter = dayFormatter
        let parsed = completionKeys.compactMap { parseHabitCompletionKey($0, calendar: calendar) }
        let rows = parsed.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.habitID < rhs.habitID
        }.map { item in
            let habit = habitByID[item.habitID]
            return [
                habit?.title ?? RhythmLocalization.text("已删除打卡"),
                formatter.string(from: item.date),
                habit.map { String($0.rewardCoins) } ?? "",
            ]
        }
        return document(header: ["打卡名称", "日期", "奖励金币"], rows: rows)
    }

    /// 解析打卡完成 key：`<habitID>-<年>-<月>-<日>`（habitID 自身含连字符，
    /// 因此从右往左取最后三段作为日期分量）。格式不符返回 nil。
    static func parseHabitCompletionKey(_ key: String, calendar: Calendar = .current) -> (habitID: String, date: Date)? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4,
              let year = Int(parts[parts.count - 3]),
              let month = Int(parts[parts.count - 2]),
              let day = Int(parts[parts.count - 1]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return nil }
        return (parts.dropLast(3).joined(separator: "-"), date)
    }
}
