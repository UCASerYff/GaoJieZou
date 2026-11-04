import Foundation

/// Shared by the app and the non-GUI upgrade publisher. Never writes business records.
enum WidgetPublisherCore {
    @discardableResult
    static func publish(journal: Journal, geography: Geography, root: URL,
                        appVersion: String, appBuild: String, now: Date = Date()) throws -> Bool {
        let fingerprint = try WidgetSourceFingerprint.make(journal: journal, geography: geography)
        let storage = WidgetGenerationStore(root: root)
        if let current = try? storage.loadResult(), current.source == "current",
           current.generation.sourceDigest == fingerprint,
           current.generation.appVersion == appVersion, current.generation.appBuild == appBuild { return false }
        let cities = Dictionary(uniqueKeysWithValues: (geography.cities + journal.customCities).map { ($0.id, $0) })
        let countries = Dictionary(uniqueKeysWithValues: geography.countries.map { ($0.id, $0) })
        let visited = Set(journal.visits.map(\.cityID)).sorted().compactMap { cities[$0] }
        let resident = journal.residentCityID.flatMap { cities[$0] }
        let snapshot = FootprintWidgetSnapshot.make(journal, cities: cities, countries: countries,
            chinaTotal: geography.cities.filter { $0.countryID == "CHN" }.count, now: now)
        let china = try WidgetMapRenderer.png(geography: geography, visited: visited, resident: resident, china: true)
        let world = try WidgetMapRenderer.png(geography: geography, visited: visited, resident: resident, china: false)
        let generation = try WidgetGeneration(sourceDigest: fingerprint,
            sourceModifiedAt: journal.footprintModifiedAt ?? journal.modifiedAt,
            appVersion: appVersion, appBuild: appBuild, snapshot: snapshot,
            chinaPNG: china, worldPNG: world, publishedAt: now)
        try storage.publish(generation)
        return true
    }
}
