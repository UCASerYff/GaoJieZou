import Foundation

enum FocusStatusPresentation {
    static func detail(elapsedSeconds: TimeInterval, targetMinutes: Int?, english: Bool) -> String {
        let roundedMinutes = (max(0, elapsedSeconds) / 60).rounded(.down)
        let elapsedMinutes = elapsedSeconds.isFinite ? Int(exactly: roundedMinutes) ?? Int.max : 0

        guard let targetMinutes, targetMinutes > 0 else {
            return english ? "\(elapsedMinutes) min elapsed (no countdown)" : "已专注 \(elapsedMinutes) 分钟（无倒计时）"
        }

        if elapsedMinutes < targetMinutes {
            let remaining = targetMinutes - elapsedMinutes
            return english ? "\(remaining) min left" : "剩余 \(remaining) 分钟"
        }

        let extra = elapsedMinutes - targetMinutes
        if extra == 0 { return english ? "target reached" : "目标已达" }
        return english ? "target reached (+\(extra) min)" : "目标已达（额外 \(extra) 分钟）"
    }
}
