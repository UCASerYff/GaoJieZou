// 小组件使用的轻量模型；对应字段需与 Shared/Models.swift 保持兼容，不依赖主程序游戏模型。
import Foundation

struct AppFailure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct Country: Codable, Identifiable, Hashable { var id: String; var name: String; var english: String; var continent: String }
struct City: Codable, Identifiable, Hashable {
    var id: String; var name: String; var english: String; var aliases: String
    var countryID: String; var provinceID: String; var province: String; var continent: String
    var longitude: Double; var latitude: Double; var isCustom: Bool
}
struct GeoRegion: Codable, Identifiable {
    var id: String; var name: String; var countryID: String; var provinceID: String; var cityID: String
    var rings: [[[Double]]]
}
struct Geography: Codable { var countries: [Country]; var cities: [City]; var world: [GeoRegion]; var china: [GeoRegion] }

enum DatePrecision: String, Codable, CaseIterable, Identifiable {
    case unknown, year, month, day
    var id: String { rawValue }
    var title: String { switch self { case .unknown: return "记不清"; case .year: return "只记得年份"; case .month: return "记得月份"; case .day: return "具体日期" } }
}
struct VisitDate: Codable, Hashable {
    var precision: DatePrecision = .unknown
    var year: Int?; var month: Int?; var day: Int?
    static var unknown: VisitDate { VisitDate() }
    var label: String {
        guard let y = year, precision != .unknown else { return "时间未详" }
        if precision == .year { return "\(y) 年" }
        if precision == .month { return "\(y) 年 \(month ?? 1) 月" }
        return "\(y) 年 \(month ?? 1) 月 \(day ?? 1) 日"
    }
    var sortKey: Int { (year ?? 0) * 10000 + (month ?? 0) * 100 + (day ?? 0) }
    func validate(now: Date = Date()) throws {
        if precision == .unknown {
            guard year == nil && month == nil && day == nil else { throw AppFailure("未知日期不应包含年月日。") }; return
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        guard let y = year, (1...(today.year ?? 2026)).contains(y) else { throw AppFailure("年份无效或位于未来。") }
        if precision == .year { guard month == nil && day == nil else { throw AppFailure("仅年份的记录不能包含月日。") }; return }
        guard let m = month, (1...12).contains(m) else { throw AppFailure("月份必须为 1–12。") }
        if y == today.year && m > (today.month ?? 1) { throw AppFailure("不能把未来的旅行标记为去过。") }
        if precision == .month { guard day == nil else { throw AppFailure("仅月份的记录不能包含日。") }; return }
        guard let d = day, let date = calendar.date(from: DateComponents(year: y, month: m, day: d)), calendar.component(.month, from: date) == m, calendar.component(.day, from: date) == d, d > 0 else { throw AppFailure("日期不存在，请检查月份和天数。") }
        guard date <= now else { throw AppFailure("不能记录未来到访。") }
    }
}
struct Visit: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var cityID: String
    var date: VisitDate = .unknown
    var tripID: String?
    var note: String = ""
    var photoIDs: [String] = []
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
}
struct Trip: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var note: String = ""
    var createdAt: Date = Date()
}
struct Attachment: Codable, Identifiable, Hashable { var id: String; var filename: String; var sha256: String; var size: Int }
struct Journal: Codable, Equatable {
    var schema: Int = 1
    var datasetVersion: String = "2026-09-21.1"
    var visits: [Visit] = []
    var trips: [Trip] = []
    var customCities: [City] = []
    var attachments: [Attachment] = []
    var modifiedAt: Date = Date()
    var residentCityID: String? = nil
    var footprintModifiedAt: Date? = nil
}
struct Metrics {
    var cities: Int; var countries: Int; var china: Int; var visits: Int; var trips: Int
    var continents: Set<String>; var newCities: Int; var newCountries: Int; var revisits: Int
    static func compute(_ data: Journal, cities: [String: City], year: Int? = nil, tripID: String? = nil) -> Metrics {
        let selected = data.visits.filter { (year == nil || $0.date.year == year) && (tripID == nil || $0.tripID == tripID) }
        let ids = Set(selected.map(\.cityID)); let found = ids.compactMap { cities[$0] }
        let countries = Set(found.map(\.countryID).filter { $0 != "ATA" })
        let grouped = Dictionary(grouping: data.visits, by: \.cityID)
        let fresh = ids.filter { id in
            let visits = grouped[id] ?? []
            return !visits.contains(where: { $0.date.year == nil }) && (year == nil || visits.compactMap(\.date.year).min() == year)
        }
        let byCountry = Dictionary(grouping: data.visits, by: { cities[$0.cityID]?.countryID ?? "" })
        let newCountries = countries.filter { id in
            let visits = byCountry[id] ?? []
            return !visits.contains(where: { $0.date.year == nil }) && (year == nil || visits.compactMap(\.date.year).min() == year)
        }
        // The earliest deterministic record is the first visit; further records are revisits.
        var revisitIDs = Set<String>()
        for visits in grouped.values {
            let ordered = visits.sorted { a,b in a.date.sortKey == b.date.sortKey ? a.createdAt < b.createdAt : a.date.sortKey < b.date.sortKey }
            revisitIDs.formUnion(ordered.dropFirst().map(\.id))
        }
        return Metrics(cities: found.filter { $0.countryID != "ATA" }.count, countries: countries.count, china: found.filter { $0.countryID == "CHN" }.count, visits: selected.count, trips: Set(selected.compactMap(\.tripID)).count, continents: Set(found.map(\.continent).filter { $0 != "南极洲" && $0 != "其他" }), newCities: fresh.filter { cities[$0]?.countryID != "ATA" }.count, newCountries: newCountries.count, revisits: selected.filter { revisitIDs.contains($0.id) }.count)
    }
}
extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var searchKey: String { folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_CN")).lowercased().replacingOccurrences(of: " ", with: "") }
}
