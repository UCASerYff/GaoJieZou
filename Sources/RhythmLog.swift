import os.log

/// 统一日志入口。subsystem 与主程序 bundle ID 保持一致，
/// 可在「控制台」中按 subsystem:com.gaojiezou.rhythm 过滤。
enum RhythmLog {
    /// 业务状态与计时结算相关的异常（截断、告警等）。
    static let store = Logger(subsystem: "com.gaojiezou.rhythm", category: "store")
    /// 本地数据文件的读写、迁移与备份恢复。
    static let data = Logger(subsystem: "com.gaojiezou.rhythm", category: "data")
}
