import Foundation

/// 小组件快照：主 App 保存后写入 App Group 共享容器，WidgetKit 扩展只读。
/// 本文件是快照格式的单一事实源；WidgetExtension/WidgetSnapshot.swift 是构建期拷贝。
struct FootprintWidgetSnapshot: Codable, Equatable {
    struct RecentVisit: Codable, Equatable {
        var name: String
        var location: String
        var dateLabel: String
    }
    var schema: Int = 1
    var generatedAt: Date = Date()
    /// 业务资料时间，与渲染、读取或系统请求时间分开保存。
    var sourceModifiedAt: Date? = nil
    var cities: Int = 0
    var countries: Int = 0
    var china: Int = 0
    var chinaTotal: Int = 0
    var continents: Int = 0
    var visits: Int = 0
    var recent: [RecentVisit] = []
    /// Optional 字段允许升级后继续读取尚未刷新的旧版小组件缓存。
    var residentCityName: String? = nil
    var residentCountryID: String? = nil

    /// 从资料库与统计生成快照；最近足迹按日期新到旧排序，时间未详排在最后。
    static func make(_ journal: Journal, cities: [String: City], countries: [String: Country], chinaTotal: Int, now: Date = Date()) -> FootprintWidgetSnapshot {
        let metrics = Metrics.compute(journal, cities: cities)
        let recent = journal.visits
            .sorted { a, b in
                if (a.date.year == nil) != (b.date.year == nil) { return a.date.year != nil }
                if a.date.sortKey != b.date.sortKey { return a.date.sortKey > b.date.sortKey }
                return a.createdAt > b.createdAt
            }
            .prefix(3)
            .compactMap { visit -> RecentVisit? in
                guard let city = cities[visit.cityID] else { return nil }
                let country = countries[city.countryID]?.name ?? city.countryID
                let location = [country, city.province].filter { !$0.isEmpty }.joined(separator: " · ")
                return RecentVisit(name: city.name, location: location, dateLabel: visit.date.label)
            }
        return FootprintWidgetSnapshot(
            schema: 1, generatedAt: now, sourceModifiedAt: journal.footprintModifiedAt ?? journal.modifiedAt,
            cities: metrics.cities, countries: metrics.countries,
            china: metrics.china, chinaTotal: chinaTotal,
            continents: metrics.continents.count, visits: journal.visits.count,
            recent: Array(recent),
            residentCityName: journal.residentCityID.flatMap { cities[$0]?.name },
            residentCountryID: journal.residentCityID.flatMap { cities[$0]?.countryID }
        )
    }
}
