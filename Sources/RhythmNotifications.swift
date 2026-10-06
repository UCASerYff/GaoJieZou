import Foundation
@preconcurrency import UserNotifications

/// 每日打卡提醒。所有入口先检查是否在打包后的 .app 中运行：
/// 冒烟测试与命令行构建的可执行文件访问通知中心会崩溃，因此直接空转。
/// 不设置 UNUserNotificationCenterDelegate，前台不弹横幅，保持简单。
@MainActor
enum RhythmNotifications {
    nonisolated static let dailyHabitReminderIdentifier = "daily-habit-reminder"

    private static var isAppBundle: Bool {
        RhythmBundle.bundle.bundleURL.pathExtension == "app"
    }

    /// 重排每日打卡提醒：先移除旧提醒；开启且仍有未完成打卡时，
    /// 注册每天固定时分重复的日历触发器。首次开启会请求通知授权。
    static func rescheduleDailyHabitReminder(enabled: Bool, hour: Int, minute: Int, pendingCount: Int) {
        guard isAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [dailyHabitReminderIdentifier])
        guard enabled else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                RhythmLog.data.error("请求通知授权失败：\(error.localizedDescription, privacy: .public)")
            }
            guard granted else {
                RhythmLog.data.warning("通知授权未开启，每日打卡提醒不会送达")
                return
            }
            guard pendingCount > 0 else { return }
            let content = UNMutableNotificationContent()
            content.userInfo["module"] = "rhythm"
            content.title = RhythmLocalization.text("搞节奏")
            content.body = RhythmLocalization.format("今天还有 %d 项打卡未完成", pendingCount)
            content.sound = .default
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let request = UNNotificationRequest(identifier: dailyHabitReminderIdentifier, content: content, trigger: trigger)
            center.add(request) { error in
                if let error {
                    RhythmLog.data.error("注册每日打卡提醒失败：\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// 持有设置对象的入口（设置页、主窗口 onAppear）使用。
    static func rescheduleDailyHabitReminder(settings: RhythmSettings, pendingCount: Int) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: settings.habitReminderTime)
        rescheduleDailyHabitReminder(
            enabled: settings.habitReminderEnabled,
            hour: components.hour ?? 21,
            minute: components.minute ?? 0,
            pendingCount: pendingCount
        )
    }

    /// 没有设置对象的入口（RhythmStore.save）直接读持久化设置后重排。
    static func rescheduleDailyHabitReminder(pendingCount: Int) {
        guard isAppBundle else { return }
        let defaults = RhythmBundle.defaults
        let time = defaults.object(forKey: RhythmSettings.Keys.habitReminderTime) as? Date
            ?? RhythmSettings.defaultHabitReminderTime
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        rescheduleDailyHabitReminder(
            enabled: defaults.bool(forKey: RhythmSettings.Keys.habitReminderEnabled),
            hour: components.hour ?? 21,
            minute: components.minute ?? 0,
            pendingCount: pendingCount
        )
    }
}
