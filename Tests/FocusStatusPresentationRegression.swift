import Foundation

@main
struct FocusStatusPresentationRegression {
    static func main() {
        check(0, 25, "25 min left", "剩余 25 分钟")
        check(59.999, 25, "25 min left", "剩余 25 分钟")
        check(60, 25, "24 min left", "剩余 24 分钟")
        check(1_499.999, 25, "1 min left", "剩余 1 分钟")
        check(1_500, 25, "target reached", "目标已达")
        check(1_559.999, 25, "target reached", "目标已达")
        check(1_560, 25, "target reached (+1 min)", "目标已达（额外 1 分钟）")
        check(179.9, nil, "2 min elapsed (no countdown)", "已专注 2 分钟（无倒计时）")
        check(180, 0, "3 min elapsed (no countdown)", "已专注 3 分钟（无倒计时）")
        check(180, -2, "3 min elapsed (no countdown)", "已专注 3 分钟（无倒计时）")
        check(-20, nil, "0 min elapsed (no countdown)", "已专注 0 分钟（无倒计时）")
        check(.nan, 25, "25 min left", "剩余 25 分钟")
        check(.infinity, nil, "0 min elapsed (no countdown)", "已专注 0 分钟（无倒计时）")
        print("PASS Focus status in English and Chinese: minute boundaries, target reached, overtime, no countdown and invalid elapsed")
    }

    private static func check(_ elapsed: TimeInterval, _ target: Int?, _ english: String, _ chinese: String) {
        let actualEnglish = FocusStatusPresentation.detail(elapsedSeconds: elapsed, targetMinutes: target, english: true)
        let actualChinese = FocusStatusPresentation.detail(elapsedSeconds: elapsed, targetMinutes: target, english: false)
        precondition(actualEnglish == english && actualChinese == chinese,
                     "Unexpected focus status at \(elapsed) seconds: \(actualEnglish) / \(actualChinese)")
    }
}
