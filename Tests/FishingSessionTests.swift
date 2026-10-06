import Foundation

@main struct FishingSessionTests {
    static func main() {
        let start=Date(timeIntervalSinceReferenceDate:10000)
        var session=FishingSession()
        assert(session.reel(at:start) == .noLine)
        session.cast(at:start,wait:2)
        let original=session.startedAt
        session.cast(at:start.addingTimeInterval(1),wait:9)
        assert(session.startedAt == original, "Repeated cast must not restart the session")
        session.advance(at:start.addingTimeInterval(1))
        assert(session.phase == .waiting)
        assert(session.reel(at:start.addingTimeInterval(1)) == .early)
        assert(session.phase == .idle)
        session.cast(at:start,wait:2)
        session.advance(at:start.addingTimeInterval(3.45))
        assert(session.phase == .bite)
        assert(session.reel(at:start.addingTimeInterval(3.45)) == .hooked)
        assert(session.reel(at:start.addingTimeInterval(3.45)) == .noLine, "Double click must not grant two catches")
        session.cast(at:start,wait:2)
        session.advance(at:start.addingTimeInterval(2.8))
        assert(session.reel(at:start.addingTimeInterval(2.8)) == .missed)
        session.cast(at:start,wait:2)
        assert(session.advance(at:start.addingTimeInterval(8)))
        assert(!session.advance(at:start.addingTimeInterval(9)), "Expiry is delivered only once")
        assert(session.reel(at:start.addingTimeInterval(9)) == .noLine)
        session.cast(at:start,wait:2)
        session.cancel()
        assert(session.phase == .idle)
        assert(!session.advance(at:start.addingTimeInterval(3)))
        print("FishingSession: early reel, bite timing, expiry, cancel and duplicate reward guards passed")
    }
}
