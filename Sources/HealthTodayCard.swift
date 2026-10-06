import Foundation
import SQLite3
import SwiftUI

/// 联动③：搞节奏「今日」页只读展示搞健康当日数据。
/// 直接以只读方式打开 App Group 的 Health/health.sqlite（WAL），绝不写库。
/// 表结构与当日聚合口径对齐 Features/Health：
/// - state 表（id=1 的 JSON blob）：preferences.timezone 决定「今日」边界，
///   preferences.configs 取当日饮水目标（同 Preferences.config 口径：effectiveDay <= 今日的最后一条）；
/// - records 表：kind / occurred_at（epoch 秒）/ json（含 amount），
///   今日饮水 = 当日 water 的 amount 求和，三餐 = 当日 meal 条数，运动 = 当日 exercise 的 amount（分钟）求和
///   （与 Widgets/HealthWidgets.swift 的 systemLarge 分支同一口径）。

struct HealthTodaySnapshot {
    var waterML: Double
    var waterGoalML: Double?
    var mealCount: Int
    var exerciseMinutes: Double
}

enum HealthTodayReader {
    static let groupID = "5G96498KGJ.com.gaoseries.GaoJianKang"

    /// 读取今日聚合；库不存在、打不开或解码失败时返回 nil（界面展示引导文案）。
    static func read(now: Date = Date()) -> HealthTodaySnapshot? {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        let url = group.appendingPathComponent("Health/health.sqlite", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var handle: OpaquePointer?
        // WAL 只读打开依赖已有的 -shm/-wal；失败时退回读写打开（本读取器只执行 SELECT，不产生写入）。
        if sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            sqlite3_close(handle)
            handle = nil
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return nil }
        }
        guard let db = handle else { return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil)

        guard let prefs = readPreferences(db) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = prefs.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        let today = dayKey(now, calendar: calendar)
        let goal = (prefs.configs ?? [])
            .filter { $0.effectiveDay <= today }
            .sorted { $0.effectiveDay < $1.effectiveDay }
            .last?.waterGoal

        var water = 0.0, exercise = 0.0, meals = 0
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT kind, occurred_at, json FROM records", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let kindPtr = sqlite3_column_text(statement, 0) else { continue }
            let kind = String(cString: kindPtr)
            guard kind == "water" || kind == "meal" || kind == "exercise" else { continue }
            let occurredAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            guard dayKey(occurredAt, calendar: calendar) == today else { continue }
            let amount = blobAmount(statement, index: 2) ?? 0
            switch kind {
            case "water": water += amount
            case "exercise": exercise += amount
            default: meals += 1
            }
        }
        return HealthTodaySnapshot(waterML: water, waterGoalML: goal, mealCount: meals, exerciseMinutes: exercise)
    }

    // MARK: - 解码（只取需要的字段，HealthState 其余键忽略）

    private struct CoreBlob: Decodable {
        struct Preferences: Decodable {
            struct DailyConfig: Decodable {
                var effectiveDay: String
                var waterGoal: Double?
            }
            var timezone: String?
            var configs: [DailyConfig]?
        }
        var preferences: Preferences
    }

    private struct RecordBlob: Decodable { var amount: Double? }

    private static func readPreferences(_ db: OpaquePointer?) -> CoreBlob.Preferences? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT json FROM state WHERE id=1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let ptr = sqlite3_column_blob(statement, 0) else { return nil }
        let data = Data(bytes: ptr, count: Int(sqlite3_column_bytes(statement, 0)))
        return (try? JSONDecoder().decode(CoreBlob.self, from: data))?.preferences
    }

    private static func blobAmount(_ statement: OpaquePointer?, index: Int32) -> Double? {
        guard let ptr = sqlite3_column_blob(statement, index) else { return nil }
        let data = Data(bytes: ptr, count: Int(sqlite3_column_bytes(statement, index)))
        return (try? JSONDecoder().decode(RecordBlob.self, from: data))?.amount
    }

    /// 与搞健康 Engine.day 同一口径： Gregorian 日历 + 偏好时区的 yyyy-MM-dd。
    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

/// 「今日」页的健康小卡片：onAppear 与每 60 秒刷新；数据缺失时显示引导文案。
struct HealthTodayCard: View {
    @State private var snapshot: HealthTodaySnapshot?
    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(RhythmLocalization.text("今日健康"), systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(RhythmTheme.green)
                Spacer()
            }
            if let snapshot {
                HStack(spacing: 12) {
                    metric(
                        symbol: "drop.fill",
                        tint: RhythmTheme.blue,
                        value: snapshot.waterGoalML.map {
                            "\(Int(snapshot.waterML))/\(Int($0)) mL"
                        } ?? "\(Int(snapshot.waterML)) mL",
                        label: RhythmLocalization.text("饮水")
                    )
                    metric(
                        symbol: "fork.knife",
                        tint: RhythmTheme.orange,
                        value: RhythmLocalization.format("%d 餐", snapshot.mealCount),
                        label: RhythmLocalization.text("三餐")
                    )
                    metric(
                        symbol: "figure.walk",
                        tint: RhythmTheme.teal,
                        value: RhythmLocalization.format("%d 分钟", Int(snapshot.exerciseMinutes)),
                        label: RhythmLocalization.text("运动")
                    )
                    Spacer()
                }
            } else {
                Text(RhythmLocalization.text("今日还没有健康数据，去搞健康记录。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
        .onAppear(perform: reload)
        .onReceive(refreshTimer) { _ in reload() }
    }

    private func metric(symbol: String, tint: Color, value: String, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.callout.monospacedDigit().weight(.semibold))
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reload() {
        snapshot = HealthTodayReader.read()
    }
}
