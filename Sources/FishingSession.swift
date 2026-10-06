import Foundation

/// One cast owns one bite window. Rewards are committed only after `.hooked`.
struct FishingSession {
    enum Phase: String { case idle, casting, waiting, bite }
    enum ReelResult { case noLine, early, missed, hooked }
    private(set) var phase: Phase = .idle
    private(set) var startedAt = Date.distantPast
    private(set) var biteAt = Date.distantPast
    static let biteDuration = 5.0
    static let safeRange = 0.18...0.82

    mutating func cast(at now: Date, wait: TimeInterval) {
        guard phase == .idle else { return }
        startedAt=now
        biteAt=now.addingTimeInterval(0.8+max(1,wait))
        phase = .casting
    }
    /// Returns true once when the fish escapes. Idle ticks do not change state.
    @discardableResult mutating func advance(at now: Date) -> Bool {
        guard phase != .idle else { return false }
        if now >= biteAt.addingTimeInterval(Self.biteDuration) { phase = .idle; return true }
        if now >= biteAt { phase = .bite }
        else if now.timeIntervalSince(startedAt) >= 0.8 { phase = .waiting }
        return false
    }
    func marker(at now: Date) -> Double {
        (sin(max(0,now.timeIntervalSince(biteAt))*2.4 - .pi/2)+1)/2
    }
    mutating func reel(at now:Date) -> ReelResult {
        guard phase != .idle else { return .noLine }
        let previous=phase
        defer { phase = .idle }
        guard previous == .bite, now < biteAt.addingTimeInterval(Self.biteDuration) else {
            return previous == .bite ? .missed : .early
        }
        return Self.safeRange.contains(marker(at:now)) ? .hooked : .missed
    }
    mutating func cancel() { phase = .idle }
}
