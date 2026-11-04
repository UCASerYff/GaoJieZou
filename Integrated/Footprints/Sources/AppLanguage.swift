import Foundation

/// 足迹模块保留来源语言偏好，存入目标专属 suite，不覆盖搞节奏主宿主语言。
/// 各模块 framework 独立编译，本文件是该键在搞足迹模块内的最小读取实现。
enum GQNSLanguage {
    static let key = "gqns.language"

    static var raw: String { FootprintsBundle.defaults.string(forKey: key) ?? "system" }

    /// 解析后的界面语言是否为英文。system 时跟随系统首选语言：中文 → 简体，其余 → 英文；
    /// 读不到系统偏好时维持中文（与模块既有默认值一致）。
    static var isEnglish: Bool {
        switch raw {
        case "en": return true
        case "zh-Hans": return false
        default:
            guard let first = Locale.preferredLanguages.first else { return false }
            return !first.hasPrefix("zh")
        }
    }

    static var localeIdentifier: String { isEnglish ? "en" : "zh-Hans" }
}

/// 搞足迹最小双语机制（V1.9 新增）：zh-Hans 保持现有文案，en 走第二个参数。
/// 覆盖范围：侧栏/导航、地图页主要操作、旅行/时间轴页、设置页、编辑器 sheet、主要提示；
/// 地图画布统计与资料库错误/导出说明等仍为硬编码中文，列为遗留。
func tF(_ zh: String, _ en: String) -> String {
    GQNSLanguage.isEnglish ? en : zh
}
