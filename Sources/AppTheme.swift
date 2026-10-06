import AppKit
import SwiftUI

enum RhythmAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: RhythmLocalization.text("跟随系统")
        case .light: RhythmLocalization.text("浅色")
        case .dark: RhythmLocalization.text("深色")
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum RhythmLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

enum RhythmLocalization {
    /// 语言来源统一为 app 级 gqns.language（GQNSLanguage 直读 UserDefaults.standard）。
    static var language: RhythmLanguage {
        RhythmLanguage(rawValue: GQNSLanguage.localeIdentifier) ?? .simplifiedChinese
    }

    static func text(_ key: String) -> String {
        guard
            let path = RhythmBundle.bundle.path(forResource: language.rawValue, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: language.locale, arguments: arguments)
    }
}

/// 应用版本信息：整合版统一以主 app Bundle.main 的 Info.plist 为准
/// （CFBundleShortVersionString/CFBundleVersion），模块 framework plist 仅作回退。
enum RhythmAppInfo {
    static var shortVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (RhythmBundle.bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "4.1"
    }

    static var buildVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? (RhythmBundle.bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "1"
    }

    /// 中文显示习惯的版本号，如「V4.0」。
    static var displayVersion: String { "V\(shortVersion)" }

    /// 主窗口标题，如「搞节奏 V4.0」（英文界面为「Rhythm V4.0」）。
    static var windowTitle: String {
        RhythmLocalization.format("搞节奏 %@", displayVersion)
    }
}

@MainActor
final class RhythmSettings: ObservableObject {
    /// RhythmNotifications 需要在没有 settings 实例的入口（RhythmStore.save）直接读键，保持 internal。
    enum Keys {
        static let appearance = "rhythm.appearance"
        static let backgroundHex = "rhythm.backgroundHex"
        static let sleepTargetHours = "rhythm.sleepTargetHours"
        static let habitReminderEnabled = "rhythm.habitReminderEnabled"
        static let habitReminderTime = "rhythm.habitReminderTime"
    }

    private let defaults: UserDefaults

    @Published var appearance: RhythmAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// 界面语言：统一读 app 级设置中心的 gqns.language，模块内不再单独持久化。
    var language: RhythmLanguage { RhythmLocalization.language }

    @Published var backgroundHex: String {
        didSet { defaults.set(backgroundHex, forKey: Keys.backgroundHex) }
    }

    @Published var sleepTargetHours: Double {
        didSet { defaults.set(sleepTargetHours, forKey: Keys.sleepTargetHours) }
    }

    @Published var habitReminderEnabled: Bool {
        didSet { defaults.set(habitReminderEnabled, forKey: Keys.habitReminderEnabled) }
    }

    @Published var habitReminderTime: Date {
        didSet { defaults.set(habitReminderTime, forKey: Keys.habitReminderTime) }
    }

    /// 每日打卡提醒默认时间：当天 21:00。
    static var defaultHabitReminderTime: Date {
        Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: Date()) ?? Date()
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 旧版模块级语言偏好（rhythm.language）一次性迁移到 app 级 gqns.language。
        GQNSLanguage.migrateLegacy(defaults: .standard, legacyKey: "rhythm.language")
        appearance = RhythmAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "system") ?? .system
        backgroundHex = defaults.string(forKey: Keys.backgroundHex) ?? ""
        let stored = defaults.double(forKey: Keys.sleepTargetHours)
        sleepTargetHours = stored > 0 ? stored : 8
        habitReminderEnabled = defaults.bool(forKey: Keys.habitReminderEnabled)
        habitReminderTime = defaults.object(forKey: Keys.habitReminderTime) as? Date ?? Self.defaultHabitReminderTime
        // gqns.language 由 app 级设置中心修改；.defaults 变化时通知界面按新语言重渲染。
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    var hasCustomBackground: Bool { !backgroundHex.isEmpty }

    var backgroundPickerColor: Color {
        Color(rhythmHex: backgroundHex) ?? Color(nsColor: .windowBackgroundColor)
    }

    func setBackgroundColor(_ color: Color) {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
        let red = Int(round(converted.redComponent * 255))
        let green = Int(round(converted.greenComponent * 255))
        let blue = Int(round(converted.blueComponent * 255))
        backgroundHex = String(format: "#%02X%02X%02X", red, green, blue)
    }

    func resetBackgroundColor() {
        backgroundHex = ""
    }

    func canvasColor(for colorScheme: ColorScheme) -> Color {
        let base = colorScheme == .dark
            ? NSColor(srgbRed: 0.075, green: 0.082, blue: 0.095, alpha: 1)
            : NSColor(srgbRed: 0.975, green: 0.98, blue: 0.985, alpha: 1)
        guard let selected = NSColor(rhythmHex: backgroundHex) else { return Color(nsColor: base) }
        return Color(nsColor: base.blended(withFraction: 0.28, of: selected) ?? base)
    }
}

private extension NSColor {
    convenience init?(rhythmHex: String) {
        guard let rgb = RhythmShared.rgbComponents(hex: rhythmHex) else { return nil }
        self.init(
            srgbRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: 1
        )
    }
}

private extension Color {
    init?(rhythmHex: String) {
        guard let color = NSColor(rhythmHex: rhythmHex) else { return nil }
        self.init(nsColor: color)
    }
}

enum RhythmTheme {
    static let blue = Color(red: 0.20, green: 0.45, blue: 0.82)
    static let teal = Color(red: 0.16, green: 0.63, blue: 0.53)
    static let green = Color(red: 0.24, green: 0.62, blue: 0.36)
    static let orange = Color(red: 0.92, green: 0.53, blue: 0.20)
    static let purple = Color(red: 0.48, green: 0.36, blue: 0.78)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)

    struct ChoreColorOption: Identifiable {
        let id: String
        let title: String
        let hex: String
        var color: Color { RhythmTheme.color(hex: hex) ?? RhythmTheme.orange }
    }

    /// A compact, high-contrast palette that keeps the calendar readable in both appearances.
    static let choreColors: [ChoreColorOption] = [
        ChoreColorOption(id: "orange", title: "橙色", hex: "#EA8733"),
        ChoreColorOption(id: "blue", title: "蓝色", hex: "#3373D1"),
        ChoreColorOption(id: "teal", title: "青色", hex: "#2AAA8A"),
        ChoreColorOption(id: "purple", title: "紫色", hex: "#7B5CC6"),
        ChoreColorOption(id: "pink", title: "粉色", hex: "#D96186"),
        ChoreColorOption(id: "green", title: "绿色", hex: "#4EAB68"),
        ChoreColorOption(id: "indigo", title: "靛蓝", hex: "#637FE6"),
        ChoreColorOption(id: "gold", title: "金色", hex: "#C79A32"),
    ]

    static func color(hex: String) -> Color? {
        Color(rhythmHex: hex)
    }

    static func hex(for color: Color) -> String? {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let red = Int(round(converted.redComponent * 255))
        let green = Int(round(converted.greenComponent * 255))
        let blue = Int(round(converted.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    static func choreColor(hex: String?, fallbackIndex: Int = 0) -> Color {
        if let hex, let color = color(hex: hex) { return color }
        return choreColors[((fallbackIndex % choreColors.count) + choreColors.count) % choreColors.count].color
    }
}

struct SectionHeader: View {
    let section: RhythmSection

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: section.symbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(RhythmTheme.blue)
                .frame(width: 44, height: 44)
                .background(RhythmTheme.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.system(size: 24, weight: .semibold))
                Text(section.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }
}

struct StatTile: View {
    let value: String
    let label: String
    let symbol: String
    var color: Color = RhythmTheme.blue

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(RhythmLocalization.text(label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(RhythmTheme.blue)
                .frame(width: 70, height: 70)
                .background(RhythmTheme.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
            Text(RhythmLocalization.text(title)).font(.title3.weight(.semibold))
            Text(RhythmLocalization.text(message))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            if let actionTitle, let action {
                Button(RhythmLocalization.text(actionTitle), action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(34)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07)))
    }
}
