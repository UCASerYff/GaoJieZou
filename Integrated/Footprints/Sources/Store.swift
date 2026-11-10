import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

@MainActor final class Store: ObservableObject {
    @Published var journal = Journal()
    @Published var error: String?
    @Published var toast: String?
    @Published var celebration: String?
    @Published var section = "地图"
    @Published var search = ""
    @Published var selectedCity: String?
    @Published var cityNavigationRevision = 0
    @Published var widgetMapNavigationRevision = 0
    var widgetMapScope: String?
    @Published var year = 0
    @Published var tripFilter = ""
    @Published var editor: EditorRequest?
    @Published var tripEditor: Trip?
    @Published var customEditor = false
    @Published var ready = false
    @Published var undoAvailable = false
    @Published var busy = false
    @Published var widgetSyncStatus = ""
    /// 离线地图资源（Geography.json）读取失败时的可恢复错误态；非 nil 时界面展示错误与重试入口。
    @Published var resourceError: String?
    private(set) var geography = Geography(countries: [], cities: [], world: [], china: [])
    private(set) var repo: Repository?
    private var undoState: Journal?
    private var keys: [String: String] = [:]
    var cityIndex: [String: City] = [:]
    private(set) var countries: [String: Country] = [:]
    @AppStorage("animationEnabled", store: FootprintsBundle.defaults) var animationEnabled = true
    @AppStorage("soundEnabled", store: FootprintsBundle.defaults) var soundEnabled = false
    @AppStorage("ownerName", store: FootprintsBundle.defaults) var ownerName = ""
    init() {
        loadResources()
        do {
            let root = try FootprintsIntegratedStorage.dataDirectory()
            repo = try RhythmIntegrationPaths.withWriterLease { try Repository(root: root, requiresIntegrationAuthority: true) }
            if resourceError == nil {
                let loaded = try repo!.load()
                try repo!.validate(loaded, geography: geography)
                journal = loaded
                ready = true
            }
        } catch { self.error = tF("资料库未能安全打开，已停止写入。","The library could not be opened safely; writing has been stopped.") + "\n\(error.localizedDescription)" }
        rebuildIndex()
        WidgetExporter.start(store: self)
    }
    /// 读取内置离线地图资源。失败不闪退：进入 resourceError 错误态，界面给重试入口。
    private func loadResources() {
        do {
            guard let file = FootprintsBundle.bundle.url(forResource: "Geography", withExtension: "json") else { throw AppFailure(tF("缺少离线地图资源，请重新安装。","Offline map resource missing; please reinstall.")) }
            geography = try JSONDecoder().decode(Geography.self, from: Data(contentsOf: file))
            countries = Dictionary(uniqueKeysWithValues: geography.countries.map { ($0.id,$0) })
            resourceError = nil
        } catch {
            geography = Geography(countries: [], cities: [], world: [], china: [])
            countries = [:]
            resourceError = tF("离线地图资源读取失败：","Failed to read offline map resource: ") + "\(error.localizedDescription)"
        }
    }
    /// 错误态重试：重新读取离线资源；成功后若资料库尚未就绪则补加载。
    func retryResourceLoad() {
        loadResources()
        rebuildIndex()
        guard resourceError == nil, let repo, !ready else { return }
        do {
            let loaded = try repo.load()
            try repo.validate(loaded, geography: geography)
            journal = loaded
            rebuildIndex()
            ready = true
            self.error = nil
            WidgetExporter.publish(store: self)
        } catch { self.error = tF("资料库未能安全打开，已停止写入。","The library could not be opened safely; writing has been stopped.") + "\n\(error.localizedDescription)" }
    }
    func retryLibraryLoad() {
        guard !ready else { return }
        do {
            let root = try FootprintsIntegratedStorage.dataDirectory()
            let reopened = try RhythmIntegrationPaths.withWriterLease { try Repository(root: root, requiresIntegrationAuthority: true) }
            let loaded = try reopened.load()
            try reopened.validate(loaded, geography: geography)
            repo = reopened; journal = loaded; rebuildIndex(); ready = true; error = nil
            WidgetExporter.publish(store: self)
        } catch { self.error = tF("资料库未能安全打开，已停止写入。", "The library could not be opened safely; writing is stopped.") + "\n" + error.localizedDescription }
    }
    func rebuildIndex() {
        cityIndex = Dictionary(uniqueKeysWithValues: (geography.cities + journal.customCities).map { ($0.id,$0) })
        for city in cityIndex.values where keys[city.id] == nil {
            let pinyin = city.countryID == "CHN" ? (city.name.applyingTransform(.toLatin, reverse: false) ?? "") : ""
            let simple = city.name.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? city.name
            keys[city.id] = "\(city.name) \(simple) \(city.english) \(pinyin) \(city.aliases) \(city.province) \(countries[city.countryID]?.name ?? "")".searchKey
        }
    }
    var allCities: [City] { geography.cities + journal.customCities }
    var residentCity: City? { journal.residentCityID.flatMap { cityIndex[$0] } }
    func showCity(_ cityID: String) {
        selectedCity = cityID
        search = ""
        section = "地图"
        cityNavigationRevision &+= 1
    }
    @discardableResult func setResidentCity(_ cityID: String?) -> Bool {
        guard cityID != journal.residentCityID else { return true }
        var next = journal
        next.residentCityID = cityID
        return commit(next, message: cityID == nil
            ? tF("已清除常驻城市，原有足迹保留，可撤销", "Home city cleared; footprints kept, undo available")
            : tF("常驻城市已更新，可撤销", "Home city updated; undo available"), settleTrainRewards: false)
    }
    var filteredVisits: [Visit] { journal.visits.filter { (year == 0 || $0.date.year == year) && (tripFilter.isEmpty || $0.tripID == tripFilter) } }
    var visitedIDs: Set<String> { Set(filteredVisits.map(\.cityID)) }
    var allVisitedIDs: Set<String> { Set(journal.visits.map(\.cityID)) }
    var metrics: Metrics { Metrics.compute(journal, cities: cityIndex, year: year == 0 ? nil : year, tripID: tripFilter.isEmpty ? nil : tripFilter) }
    var years: [Int] { Array(Set(journal.visits.compactMap(\.date.year))).sorted(by: >) }
    var chinaTotal: Int { geography.cities.filter { $0.countryID == "CHN" }.count }
    func countryName(_ city: City) -> String { countries[city.countryID]?.name ?? city.countryID }
    func location(_ city: City) -> String { [countryName(city),city.province].filter { !$0.isEmpty }.joined(separator: " · ") }
    func results(_ query: String, country: String? = nil, limit: Int = 80) -> [City] {
        let q = query.searchKey
        let candidates = allCities.filter { (country == nil || $0.countryID == country) && (q.isEmpty || (keys[$0.id] ?? "").contains(q)) }
        return Array(candidates.sorted { a,b in
            if !q.isEmpty {
                let ae = a.name.searchKey == q || a.english.searchKey == q, be = b.name.searchKey == q || b.english.searchKey == q
                if ae != be { return ae }
                let ap = a.name.searchKey.hasPrefix(q), bp = b.name.searchKey.hasPrefix(q)
                if ap != bp { return ap }
            }
            if a.countryID != b.countryID { return a.countryID == "CHN" || (b.countryID != "CHN" && a.countryID < b.countryID) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }.prefix(limit))
    }
    @discardableResult func commit(_ next: Journal, message: String, settleTrainRewards: Bool = true) -> Bool {
        guard ready, let repo else { error = tF("资料库不可写，请先修复打开错误。","The library is not writable; please fix the opening error first."); return false }
        do {
            var next = next
            var before = journal, after = next
            forCurrentContent(&before); forCurrentContent(&after)
            next.footprintModifiedAt = before == after ? (journal.footprintModifiedAt ?? journal.modifiedAt) : Date()
            next.modifiedAt = Date()
            if settleTrainRewards { _ = TrainEngine.settle(&next.train, journal: next) }
            try repo.validate(next, geography: geography)
            for photo in next.attachments where next.visits.contains(where: { $0.photoIDs.contains(photo.id) }) {
                guard FileManager.default.fileExists(atPath: repo.photoURL(photo).path) else { throw AppFailure(tF("照片文件缺失，未保存。","A photo file is missing; not saved.")) }
            }
            try repo.save(next)
            let previousCountries = Set(journal.visits.compactMap { cityIndex[$0.cityID]?.countryID })
            let newIndex = Dictionary(uniqueKeysWithValues: (geography.cities + next.customCities).map { ($0.id,$0) })
            let newCountries = Set(next.visits.compactMap { newIndex[$0.cityID]?.countryID }).subtracting(previousCountries).filter { $0 != "ATA" }.sorted()
            undoState = journal; undoAvailable = true; journal = next; rebuildIndex(); toast = message
            if let first = newCountries.first { celebration = countries[first]?.name ?? first }
            WidgetExporter.publish(store: self)
            if soundEnabled { NSSound(named: "Pop")?.play() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func forCurrentContent(_ value: inout Journal) {
        value.modifiedAt = Date(timeIntervalSince1970: 0)
        value.footprintModifiedAt = nil
        value.train = TrainState()
    }
    func undo() {
        guard let previous = undoState else { return }
        var restored = previous
        restored.train = journal.train
        if commit(restored, message: tF("已撤销上一次修改","Last change undone"), settleTrainRewards: false) { undoState = nil; undoAvailable = false }
    }
    @discardableResult private func saveTrain(_ next: TrainState) -> Bool {
        guard ready, let repo else { error = tF("足迹资料库尚未就绪。", "Footprints library is not ready."); return false }
        do {
            var copy = journal
            copy.footprintModifiedAt = journal.footprintModifiedAt ?? journal.modifiedAt
            copy.train = next; copy.modifiedAt = Date()
            try repo.validate(copy, geography: geography)
            try repo.save(copy)
            journal = copy
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func syncTrain() {
        var next = journal.train
        TrainEngine.settle(&next, journal: journal)
        TrainEngine.arrive(&next)
        TrainEngine.prepare(&next,cities:allVisitedIDs.compactMap { cityIndex[$0] })
        if next != journal.train { saveTrain(next) }
    }
    func upgradeTrain(_ carriage: TrainCarriage) {
        syncTrain()
        var next = journal.train
        guard TrainEngine.upgrade(carriage, state: &next) else { return }
        saveTrain(next)
    }
    @discardableResult func cruiseTrain() -> Bool {
        syncTrain()
        var next = journal.train
        guard allVisitedIDs.contains(next.routeCityID), let destination=cityIndex[next.routeCityID], TrainEngine.depart(state:&next,destination:destination) else { return false }
        return saveTrain(next)
    }
    func setTrainRoute(_ cityID: String) {
        guard journal.train.journey?.completed != false, cityID.isEmpty || (allVisitedIDs.contains(cityID) && cityID != journal.train.currentStation?.id) else { return }
        var next = journal.train
        next.routeCityID = cityID
        saveTrain(next)
    }
    func reorderTrainCarriage(_ id: String, toX x: Double) {
        guard let moved = TrainCarriage(rawValue: id), TrainEngine.level(moved, in: journal.train) > 0 else { return }
        var next = journal.train
        var order = next.carriageOrder.compactMap(TrainCarriage.init(rawValue:))
        for carriage in TrainCarriage.allCases where TrainEngine.level(carriage, in: next) > 0 && !order.contains(carriage) {
            order.append(carriage)
        }
        order.removeAll { $0 == moved }
        let slot = min(order.count, max(0, Int(((x + 3.1) / 2.25).rounded())))
        order.insert(moved, at: slot)
        next.carriageOrder = order.map(\.rawValue)
        saveTrain(next)
    }
    func remove(_ visit: Visit) { var next = journal; next.visits.removeAll { $0.id == visit.id }; _ = commit(next, message: tF("已删除足迹，可撤销","Footprint deleted; undo available")) }
    func deleteTrip(_ trip: Trip) {
        var next = journal; next.trips.removeAll { $0.id == trip.id }
        for i in next.visits.indices where next.visits[i].tripID == trip.id { next.visits[i].tripID = nil }
        if tripFilter == trip.id { tripFilter = "" }
        _ = commit(next, message: tF("旅行已删除，足迹全部保留","Trip deleted; all footprints kept"))
    }
    func photoURL(_ id: String) -> URL? { journal.attachments.first { $0.id == id }.flatMap { repo?.photoURL($0) } }
    func importPhoto(_ url: URL) throws -> Attachment {
        guard let repo else { throw AppFailure(tF("资料库不可用。","The library is unavailable.")) }
        return try repo.withWriteAccess {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.fileSizeKey]); guard let size = info.fileSize, size <= 30 * 1024 * 1024 else { throw AppFailure(tF("单张照片不能超过 30 MB。","A single photo cannot exceed 30 MB.")) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceThumbnailMaxPixelSize:2400, kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { throw AppFailure(tF("无法读取此照片，请使用 JPEG、PNG 或 HEIC。","Cannot read this photo; please use JPEG, PNG or HEIC.")) }
        let bytes = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw AppFailure(tF("无法处理照片。","Cannot process the photo.")) }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality:0.88] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw AppFailure(tF("照片转换失败。","Photo conversion failed.")) }
        let data = bytes as Data, id = UUID().uuidString
        let attachment = Attachment(id:id,filename:id+".jpg",sha256:digest(data),size:data.count)
        try data.write(to: repo.photoURL(attachment), options: .atomic)
        return attachment
        }
    }
    func discardStaged(_ attachments: [Attachment]) {
        guard let repo else { return }
        try? repo.withWriteAccess {
            for a in attachments where !journal.attachments.contains(where: { $0.id == a.id }) { try? FileManager.default.removeItem(at: repo.photoURL(a)) }
        }
    }
    func saveFile(name: String, type: UTType, data: () throws -> Data) {
        guard ready else { error = tF("资料库尚未安全读取，停止导出。", "The library is not safely loaded; export stopped."); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.allowedContentTypes = [type]; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do { try data().write(to: url, options: .atomic); toast = tF("已导出：","Exported: ") + "\(url.lastPathComponent)" } catch { self.error = error.localizedDescription }
        }
    }
    func alertDelete(_ action: () -> Void, title: String, detail: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = detail; a.addButton(withTitle:tF("删除","Delete")); a.addButton(withTitle:tF("取消","Cancel"))
        if a.runModal() == .alertFirstButtonReturn { action() }
    }
}
struct EditorRequest: Identifiable { var id = UUID(); var visit: Visit?; var cityID: String?; var tripID: String? }
