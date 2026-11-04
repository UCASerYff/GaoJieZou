import Foundation

// A virtual journey owns endpoint snapshots so editing a footprint cannot teleport a moving train.
struct TrainJourney: Codable, Equatable, Identifiable {
    var id = UUID()
    let origin: City
    let destination: City
    let startedAt: Date
    let arrivesAt: Date
    let reward: Int
    var completed = false
    var domestic: Bool { origin.countryID == destination.countryID }
    var distanceKm: Double { TrainEngine.distance(origin,destination) }
    func progress(at now: Date) -> Double { min(1,max(0,now.timeIntervalSince(startedAt)/max(1,arrivesAt.timeIntervalSince(startedAt)))) }
    // Shortest great-circle interpolation, including routes across the date line.
    func coordinate(at progress: Double) -> (lon: Double,lat: Double) {
        let t=min(1,max(0,progress)),d=Double.pi/180
        func vector(_ c:City)->[Double] { [cos(c.latitude*d)*cos(c.longitude*d),cos(c.latitude*d)*sin(c.longitude*d),sin(c.latitude*d)] }
        let a=vector(origin),b=vector(destination),angle=acos(min(1,max(-1,zip(a,b).reduce(0){$0+$1.0*$1.1})))
        if abs(sin(angle))<0.000001 {
            let delta=(destination.longitude-origin.longitude+540).truncatingRemainder(dividingBy:360)-180
            let lon=(origin.longitude+delta*t+540).truncatingRemainder(dividingBy:360)-180
            return (lon,origin.latitude+(destination.latitude-origin.latitude)*t)
        }
        let x=zip(a,b).map { (sin((1-t)*angle)*$0.0+sin(t*angle)*$0.1)/sin(angle) }
        return (atan2(x[1],x[0])/d,atan2(x[2],hypot(x[0],x[1]))/d)
    }
}

struct TrainState: Codable, Equatable {
    var materials = 0
    var lifetimeMaterials = 0
    var carriageLevels: [String: Int] = [:]
    var claimedVisitIDs: [String] = []
    var claimedCityIDs: [String] = []
    var claimedPhotoIDs: [String] = []
    var claimedTripIDs: [String] = []
    var claimedNoteIDs: [String] = []
    var lastCruiseAt: Date? = nil
    var cruiseCount = 0
    var carriageOrder: [String] = []
    var routeCityID: String = ""
    var currentStation: City? = nil
    var journey: TrainJourney? = nil
    private enum CodingKeys: String, CodingKey {
        case materials, lifetimeMaterials, carriageLevels, claimedVisitIDs, claimedCityIDs,
             claimedPhotoIDs, claimedTripIDs, claimedNoteIDs, lastCruiseAt, cruiseCount,
             carriageOrder, routeCityID, currentStation, journey
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        materials = try c.decodeIfPresent(Int.self, forKey: .materials) ?? 0
        lifetimeMaterials = try c.decodeIfPresent(Int.self, forKey: .lifetimeMaterials) ?? 0
        carriageLevels = try c.decodeIfPresent([String:Int].self, forKey: .carriageLevels) ?? [:]
        claimedVisitIDs = try c.decodeIfPresent([String].self, forKey: .claimedVisitIDs) ?? []
        claimedCityIDs = try c.decodeIfPresent([String].self, forKey: .claimedCityIDs) ?? []
        claimedPhotoIDs = try c.decodeIfPresent([String].self, forKey: .claimedPhotoIDs) ?? []
        claimedTripIDs = try c.decodeIfPresent([String].self, forKey: .claimedTripIDs) ?? []
        claimedNoteIDs = try c.decodeIfPresent([String].self, forKey: .claimedNoteIDs) ?? []
        lastCruiseAt = try c.decodeIfPresent(Date.self, forKey: .lastCruiseAt)
        cruiseCount = try c.decodeIfPresent(Int.self, forKey: .cruiseCount) ?? 0
        carriageOrder = try c.decodeIfPresent([String].self, forKey: .carriageOrder) ?? []
        routeCityID = try c.decodeIfPresent(String.self, forKey: .routeCityID) ?? ""
        currentStation = try c.decodeIfPresent(City.self, forKey: .currentStation)
        journey = try c.decodeIfPresent(TrainJourney.self, forKey: .journey)
    }
}

enum TrainCarriage: String, CaseIterable, Identifiable {
    case sleeper, dining, observation, garden, library
    var id: String { rawValue }
    var name: String {
        switch self {
        case .sleeper: return tF("卧铺车", "Sleeper")
        case .dining: return tF("餐车", "Dining car")
        case .observation: return tF("观景车", "Observation car")
        case .garden: return tF("花园车", "Garden car")
        case .library: return tF("书房车", "Library car")
        }
    }
    var symbol: String {
        switch self {
        case .sleeper: return "bed.double.fill"
        case .dining: return "fork.knife"
        case .observation: return "binoculars.fill"
        case .garden: return "leaf.fill"
        case .library: return "books.vertical.fill"
        }
    }
    var effect: String {
        switch self {
        case .sleeper: return tF("每级缩短虚拟巡游等待 2 小时", "Each level shortens cruise wait by 2 hours")
        case .dining: return tF("每级增加巡游获得的 1 份物资", "Each level adds 1 cruise supply")
        case .observation: return tF("每级增加新城市奖励 1 份物资", "Each level adds 1 supply per new city")
        case .garden: return tF("每级增加新照片奖励 1 份物资", "Each level adds 1 supply per new photo")
        case .library: return tF("每级增加回忆文字奖励 1 份物资", "Each level adds 1 supply per memory note")
        }
    }
    func cost(for level: Int) -> Int { [6, 12, 20, 30][min(max(level, 1), 4) - 1] }
}

enum TrainEngine {
    static func level(_ carriage: TrainCarriage, in state: TrainState) -> Int { state.carriageLevels[carriage.rawValue] ?? 0 }
    static func validStation(_ c: City) -> Bool {
        !c.id.isEmpty && c.id.count<200 && !c.countryID.isEmpty && c.longitude.isFinite && c.latitude.isFinite && (-180...180).contains(c.longitude) && (-90...90).contains(c.latitude)
    }
    static func validate(_ state: TrainState) throws {
        if let c=state.currentStation, !validStation(c) { throw AppFailure("Invalid train station") }
        if let j=state.journey {
            guard validStation(j.origin),validStation(j.destination),j.origin.id != j.destination.id,
                  j.startedAt.timeIntervalSince1970.isFinite,j.arrivesAt.timeIntervalSince1970.isFinite,
                  (1...3600).contains(j.arrivesAt.timeIntervalSince(j.startedAt)),(0...6).contains(j.reward),
                  state.currentStation?.id == (j.completed ? j.destination.id : j.origin.id) else { throw AppFailure("Invalid train journey") }
        }
        guard (0...1_000_000).contains(state.materials), (0...1_000_000).contains(state.lifetimeMaterials), state.materials <= state.lifetimeMaterials,
              (0...1_000_000).contains(state.cruiseCount),
              state.carriageLevels.allSatisfy({ key, value in TrainCarriage(rawValue: key) != nil && (0...4).contains(value) }),
              state.carriageOrder.count <= TrainCarriage.allCases.count,
              Set(state.carriageOrder).count == state.carriageOrder.count,
              state.carriageOrder.allSatisfy({ TrainCarriage(rawValue: $0) != nil }),
              state.routeCityID.count < 200,
              [state.claimedVisitIDs, state.claimedCityIDs, state.claimedPhotoIDs, state.claimedTripIDs, state.claimedNoteIDs].allSatisfy({ $0.count <= 100_000 && Set($0).count == $0.count && $0.allSatisfy({ !$0.isEmpty && $0.count < 200 }) }),
              state.lastCruiseAt.map({ $0 <= Date().addingTimeInterval(300) }) ?? true else {
            throw AppFailure(tF("旅行列车存档无效。", "Travel train save is invalid."))
        }
    }
    @discardableResult static func settle(_ state: inout TrainState, journal: Journal) -> Int {
        var visitIDs = Set(state.claimedVisitIDs), cityIDs = Set(state.claimedCityIDs)
        var photoIDs = Set(state.claimedPhotoIDs), tripIDs = Set(state.claimedTripIDs), noteIDs = Set(state.claimedNoteIDs)
        var gained = 0
        for visit in journal.visits {
            if visitIDs.insert(visit.id).inserted { state.claimedVisitIDs.append(visit.id); gained += 1 }
            if cityIDs.insert(visit.cityID).inserted { state.claimedCityIDs.append(visit.cityID); gained += 2 + level(.observation, in: state) }
            if visit.note.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4,
               noteIDs.insert(visit.id).inserted { state.claimedNoteIDs.append(visit.id); gained += 2 + level(.library, in: state) }
            for photo in visit.photoIDs where photoIDs.insert(photo).inserted {
                state.claimedPhotoIDs.append(photo); gained += 2 + level(.garden, in: state)
            }
        }
        let linkedTrips = Set(journal.visits.compactMap(\.tripID))
        for trip in journal.trips where linkedTrips.contains(trip.id) && tripIDs.insert(trip.id).inserted {
            state.claimedTripIDs.append(trip.id); gained += 3
        }
        state.materials += gained; state.lifetimeMaterials += gained
        return gained
    }
    static func upgrade(_ carriage: TrainCarriage, state: inout TrainState) -> Bool {
        let next = level(carriage, in: state) + 1
        guard next <= 4, state.materials >= carriage.cost(for: next) else { return false }
        state.materials -= carriage.cost(for: next)
        state.carriageLevels[carriage.rawValue] = next
        return true
    }
    static func nextCruise(at now: Date, state: TrainState) -> Date? {
        state.lastCruiseAt?.addingTimeInterval(TimeInterval(24 - 2 * level(.sleeper, in: state)) * 3600)
    }
    static func distance(_ a:City,_ b:City)->Double {
        let d=Double.pi/180,lat=(b.latitude-a.latitude)*d,lon=(b.longitude-a.longitude)*d
        let h=pow(sin(lat/2),2)+cos(a.latitude*d)*cos(b.latitude*d)*pow(sin(lon/2),2)
        return 6371*2*asin(sqrt(min(1,max(0,h))))
    }
    static func prepare(_ state: inout TrainState, cities:[City]) {
        let available=cities.filter(validStation).sorted { $0.id<$1.id }
        if state.currentStation == nil {
            state.currentStation = (state.cruiseCount>0 ? available.first { $0.id==state.routeCityID } : nil) ?? available.first
        }
        guard state.journey?.completed != false else { return }
        if !available.contains(where:{ $0.id==state.routeCityID && $0.id != state.currentStation?.id }) {
            state.routeCityID=available.first { $0.id != state.currentStation?.id }?.id ?? ""
        }
    }
    static func depart(state: inout TrainState, destination: City, now: Date = Date()) -> Bool {
        guard state.journey?.completed != false,let origin=state.currentStation,
              validStation(origin),validStation(destination),origin.id != destination.id else { return false }
        let rewardAvailable = nextCruise(at:now,state:state).map({ $0<=now }) ?? true
        let duration=min(600,max(120,120+distance(origin,destination)/8))
        state.journey=TrainJourney(origin:origin,destination:destination,startedAt:now,
                                  arrivesAt:now.addingTimeInterval(duration),reward:rewardAvailable ? 2+level(.dining,in:state) : 0)
        if rewardAvailable { state.lastCruiseAt=now }
        state.routeCityID=destination.id
        return true
    }
    @discardableResult static func arrive(_ state: inout TrainState, now:Date = Date())->Bool {
        guard var j=state.journey,!j.completed,now>=j.arrivesAt else { return false }
        j.completed=true;state.journey=j;state.currentStation=j.destination
        let gained=min(j.reward,max(0,1_000_000-state.lifetimeMaterials))
        state.materials+=gained;state.lifetimeMaterials+=gained;state.cruiseCount=min(1_000_000,state.cruiseCount+1)
        return true
    }
}
