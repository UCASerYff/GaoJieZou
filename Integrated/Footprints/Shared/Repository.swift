import Foundation
import SQLite3
import CryptoKit

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
struct PhotoPayload: Codable { var attachment: Attachment; var data: Data }
struct Backup: Codable {
    var format = "GaoZuJi.backup"; var version = 1; var appVersion = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.7"; var createdAt = Date()
    var journal: Journal; var journalDigest: String; var photos: [PhotoPayload]
}
/// 3.46 及更早的完整备份没有列车字段；校验其原始摘要时必须保持旧编码形状。
private struct LegacyJournal: Encodable {
    var schema: Int
    var datasetVersion: String
    var visits: [Visit]
    var trips: [Trip]
    var customCities: [City]
    var attachments: [Attachment]
    var modifiedAt: Date
    init(_ journal: Journal) {
        schema = journal.schema; datasetVersion = journal.datasetVersion
        visits = journal.visits; trips = journal.trips; customCities = journal.customCities
        attachments = journal.attachments; modifiedAt = journal.modifiedAt
    }
}
final class Repository {
    let root: URL
    private let readOnly: Bool
    private let requiresIntegrationAuthority: Bool
    private var db: OpaquePointer?
    private var openedDevice: UInt64?
    private var openedInode: UInt64?
    var photos: URL { root.appendingPathComponent("Photos", isDirectory: true) }
    init(root: URL, readOnly: Bool = false, requiresIntegrationAuthority: Bool = false) throws {
        self.root = root
        self.readOnly = readOnly
        self.requiresIntegrationAuthority = requiresIntegrationAuthority
        let fm = FileManager.default
        let database = root.appendingPathComponent("footprints.sqlite")
        let existing = fm.fileExists(atPath: database.path)
        guard !requiresIntegrationAuthority || existing else { throw AppFailure("迁入的主库缺失，生产模块不能初始化空库。") }
        guard !readOnly || existing else { throw AppFailure("只读资料库的主文件缺失，未创建新资料库。") }
        if existing {
            let values = try database.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
                throw AppFailure("足迹主库为空或类型无效，已停止写入以保护原资料。")
            }
        } else if fm.fileExists(atPath: root.path) {
            guard try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty else {
                throw AppFailure("资料目录已有内容但足迹主库缺失，不能当作新资料库覆盖。请保留原资料并恢复主库。")
            }
        }
        if !existing { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX | (existing ? 0 : SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(database.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil
            throw AppFailure("无法打开足迹资料库。")
        }
        do {
            sqlite3_busy_timeout(db, 5000)
            if existing {
                // Read and validate before applying any writable pragmas or adding directories.
                try checkIntegrity()
                _ = try load()
            } else {
                try sql("CREATE TABLE items (kind TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(kind,id));")
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO items(kind,id,payload) VALUES('meta','main',?)", -1, &statement, nil) == SQLITE_OK else { throw AppFailure("不能初始化新资料库。") }
                defer { sqlite3_finalize(statement) }
                let bytes = try encoder.encode(Journal())
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                let bound = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(bytes.count), transient) }
                guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw AppFailure("不能初始化新资料库。") }
            }
            if !readOnly {
                try sql("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
                try fm.createDirectory(at: photos, withIntermediateDirectories: true)
            }
            let attributes = try fm.attributesOfItem(atPath: database.path)
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else { throw AppFailure("无法记录足迹资料库身份。") }
            openedDevice = device.uint64Value; openedInode = inode.uint64Value
        } catch {
            sqlite3_close(db); db = nil
            throw error
        }
    }
    deinit { sqlite3_close(db) }
    private func sql(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AppFailure("资料库写入失败：\(String(cString: sqlite3_errmsg(db)))") }
    }
    private func checkIntegrity() throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else { throw AppFailure("无法校验足迹资料库。") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let result = sqlite3_column_text(statement, 0),
              String(cString: result) == "ok", sqlite3_step(statement) == SQLITE_DONE else {
            throw AppFailure("足迹资料库完整性校验失败，已停止写入以保护原资料。")
        }
    }
    func load() throws -> Journal {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT kind,id,payload FROM items", -1, &statement, nil) == SQLITE_OK else { throw AppFailure("无法读取资料库，所需数据表可能缺失。") }
        defer { sqlite3_finalize(statement) }
        var data = Journal()
        var foundMeta = false
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let key = sqlite3_column_text(statement, 0), let rowID = sqlite3_column_text(statement, 1), let blob = sqlite3_column_blob(statement, 2) else { throw AppFailure("资料库内容损坏，停止写入以保护数据。") }
            let bytes = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 2)))
            switch String(cString: key) {
            case "visit": data.visits.append(try decoder.decode(Visit.self, from: bytes))
            case "trip": data.trips.append(try decoder.decode(Trip.self, from: bytes))
            case "city": data.customCities.append(try decoder.decode(City.self, from: bytes))
            case "photo": data.attachments.append(try decoder.decode(Attachment.self, from: bytes))
            case "meta":
                guard !foundMeta, String(cString: rowID) == "main" else { throw AppFailure("资料库元数据重复或标识无效，已停止写入。") }
                foundMeta = true
                let meta = try decoder.decode(Journal.self, from: bytes)
                guard meta.schema == 1 else { throw AppFailure("此存档来自不支持的版本，请升级应用。") }
                data.schema = meta.schema; data.datasetVersion = meta.datasetVersion; data.modifiedAt = meta.modifiedAt; data.train = meta.train
                data.residentCityID = meta.residentCityID
                data.footprintModifiedAt = meta.footprintModifiedAt
            default: throw AppFailure("发现无法识别的存档类型，请使用兼容版本打开。")
            }
        }
        guard foundMeta else { throw AppFailure("资料库元数据缺失，不能将原资料当作空白覆盖。") }
        return data
    }
    func requireWritableAuthority() throws {
        guard !readOnly else { throw AppFailure("资料库以只读方式打开，不能写入。") }
        if requiresIntegrationAuthority {
            let identity = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("footprints.sqlite").path)
            guard let device = identity[.systemNumber] as? NSNumber,
                  let inode = identity[.systemFileNumber] as? NSNumber,
                  openedDevice == device.uint64Value, openedInode == inode.uint64Value else {
                throw AppFailure("足迹资料库已被恢复或替换，旧连接已停止写入，请重新打开模块。")
            }
            guard try FootprintsIntegratedStorage.dataDirectory().standardizedFileURL == root.standardizedFileURL else {
                throw AppFailure("足迹资料权威已切换，未继续写入旧路径。")
            }
        }
    }
    func withWriteAccess<T>(_ operation: () throws -> T) throws -> T {
        if requiresIntegrationAuthority {
            return try RhythmIntegrationPaths.withWriterLease {
                try requireWritableAuthority()
                return try operation()
            }
        }
        try requireWritableAuthority()
        return try operation()
    }
    func save(_ journal: Journal) throws {
        try withWriteAccess { try saveValidated(journal) }
    }
    private func saveValidated(_ journal: Journal) throws {
        guard !readOnly else { throw AppFailure("资料库以只读方式打开，不能保存。") }
        guard journal.schema == 1 else { throw AppFailure("不支持此存档版本，未保存。") }
        var rows: [(String,String,Data)] = []
        for x in journal.visits { rows.append(("visit", x.id, try encoder.encode(x))) }
        for x in journal.trips { rows.append(("trip", x.id, try encoder.encode(x))) }
        for x in journal.customCities { rows.append(("city", x.id, try encoder.encode(x))) }
        for x in journal.attachments { rows.append(("photo", x.id, try encoder.encode(x))) }
        var meta = journal; meta.visits=[]; meta.trips=[]; meta.customCities=[]; meta.attachments=[]
        rows.append(("meta","main",try encoder.encode(meta)))
        try sql("BEGIN IMMEDIATE")
        do {
            // A database may have been replaced or changed after opening; fail closed.
            _ = try load()
            try sql("DELETE FROM items")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO items(kind,id,payload) VALUES(?,?,?)", -1, &stmt, nil) == SQLITE_OK else { throw AppFailure("不能准备保存。") }
            defer { sqlite3_finalize(stmt) }
            for (kind,id,bytes) in rows {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(stmt, 1, kind, -1, transient); sqlite3_bind_text(stmt, 2, id, -1, transient)
                _ = bytes.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(bytes.count), transient) }
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw AppFailure("保存失败，已保留原数据。") }
            }
            try sql("COMMIT")
        } catch { try? sql("ROLLBACK"); throw error }
    }
    func photoURL(_ attachment: Attachment) -> URL { photos.appendingPathComponent(attachment.filename) }
    func validate(_ data: Journal, geography: Geography) throws {
        guard data.schema == 1 else { throw AppFailure("不支持此存档版本。") }
        try TrainEngine.validate(data.train)
        func unique(_ ids: [String]) -> Bool { ids.count == Set(ids).count && ids.allSatisfy { !$0.isEmpty && $0.count < 200 } }
        guard unique(data.visits.map(\.id)), unique(data.trips.map(\.id)), unique(data.customCities.map(\.id)), unique(data.attachments.map(\.id)) else { throw AppFailure("记录 ID 缺失或重复。") }
        let builtIn = Set(geography.cities.map(\.id)), countries = Set(geography.countries.map(\.id))
        for c in data.customCities {
            guard !builtIn.contains(c.id), c.isCustom, !c.name.trimmed.isEmpty, c.countryID != "CHN", countries.contains(c.countryID), c.latitude.isFinite, c.longitude.isFinite, (-90...90).contains(c.latitude), (-180...180).contains(c.longitude) else { throw AppFailure("自定义地点无效或与内置城市冲突。") }
        }
        let cityIDs = builtIn.union(data.customCities.map(\.id)), tripIDs = Set(data.trips.map(\.id)), photoIDs = Set(data.attachments.map(\.id))
        if let residentCityID = data.residentCityID, !cityIDs.contains(residentCityID) {
            throw AppFailure(tF("常驻城市不存在，请重新选择。", "The resident city does not exist; choose it again."))
        }
        guard data.trips.allSatisfy({ !$0.name.trimmed.isEmpty }) else { throw AppFailure("旅行名称不能为空。") }
        for v in data.visits {
            try v.date.validate()
            guard cityIDs.contains(v.cityID), v.tripID == nil || tripIDs.contains(v.tripID!), v.photoIDs.count <= 20, Set(v.photoIDs).count == v.photoIDs.count, Set(v.photoIDs).isSubset(of: photoIDs) else { throw AppFailure("足迹引用的城市、旅行或照片不存在。") }
        }
        for a in data.attachments {
            guard UUID(uuidString: a.id) != nil, a.filename == a.id + ".jpg", a.size > 0, a.size <= 30 * 1024 * 1024, a.sha256.count == 64 else { throw AppFailure("照片清单包含无效文件名或大小。") }
        }
    }
    func makeBackup(_ data: Journal) throws -> Data {
        let ids = Set(data.visits.flatMap(\.photoIDs))
        var clean = data; clean.attachments = data.attachments.filter { ids.contains($0.id) }
        var payloads: [PhotoPayload] = []; var size = 0
        for a in clean.attachments {
            let bytes = try Data(contentsOf: photoURL(a)); size += bytes.count
            guard size <= 350 * 1024 * 1024 else { throw AppFailure("此版单次备份照片总量上限为 350 MB，请先导出并整理照片。") }
            guard digest(bytes) == a.sha256, bytes.count == a.size else { throw AppFailure("照片缺失或校验失败，备份未完成。") }
            payloads.append(PhotoPayload(attachment: a, data: bytes))
        }
        return try encoder.encode(Backup(journal: clean, journalDigest: digest(try encoder.encode(clean)), photos: payloads))
    }
    func inspectBackup(_ url: URL, geography: Geography) throws -> Backup {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size > 0, size <= 500 * 1024 * 1024 else { throw AppFailure("备份为空或超过本版 500 MB 文件上限。") }
        let b = try decoder.decode(Backup.self, from: Data(contentsOf: url))
        let currentDigest = digest(try encoder.encode(b.journal))
        // Legacy digests omit newer metadata and train state, so they are only
        // eligible when every omitted field has its original empty value.
        let legacyDigest: String? = b.journal.train == TrainState() && b.journal.residentCityID == nil && b.journal.footprintModifiedAt == nil ? digest(try encoder.encode(LegacyJournal(b.journal))) : nil
        guard b.format == "GaoZuJi.backup", b.version == 1,
              b.journalDigest == currentDigest || b.journalDigest == legacyDigest else { throw AppFailure("备份版本不支持或记录校验失败。") }
        try validate(b.journal, geography: geography)
        guard b.photos.count == b.journal.attachments.count, Set(b.photos.map { $0.attachment.id }).count == b.photos.count else { throw AppFailure("照片清单重复或不完整。") }
        let attachments = Dictionary(uniqueKeysWithValues: b.journal.attachments.map { ($0.id,$0) })
        for p in b.photos {
            guard attachments[p.attachment.id] == p.attachment, p.data.count == p.attachment.size, digest(p.data) == p.attachment.sha256 else { throw AppFailure("备份照片校验失败。") }
        }
        return b
    }
    func restore(_ backup: Backup, current: Journal) throws {
        try withWriteAccess { try restoreValidated(backup, current: current) }
    }
    private func restoreValidated(_ backup: Backup, current: Journal) throws {
        guard !readOnly else { throw AppFailure("资料库以只读方式打开，不能恢复。") }
        // A full pre-restore backup is separate from automatic metadata snapshots.
        let before = try makeBackup(current)
        let name = "恢复前-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).footprintsbackup"
        try before.write(to: root.appendingPathComponent(name), options: .atomic)
        var created: [URL] = []
        do {
            for p in backup.photos {
                let url = photoURL(p.attachment)
                if FileManager.default.fileExists(atPath: url.path) {
                    guard digest(try Data(contentsOf: url)) == p.attachment.sha256 else { throw AppFailure("现有照片与备份 ID 冲突，已停止恢复。") }
                } else { try p.data.write(to: url, options: .atomic); created.append(url) }
            }
            try save(backup.journal)
        } catch { for url in created { try? FileManager.default.removeItem(at: url) }; throw error }
    }
    static func csv(_ journal: Journal, cities: [String: City]) -> String {
        func escape(_ value: String) -> String {
            var value = value
            if let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first, "=+-@".contains(first) || value.hasPrefix("\t") || value.hasPrefix("\r") { value = "'" + value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let trips = Dictionary(uniqueKeysWithValues: journal.trips.map { ($0.id,$0.name) })
        let header = "记录ID,城市,国家或地区代码,日期精度,年份,月份,日期,旅行,笔记,照片数\r\n"
        return "\u{FEFF}" + header + journal.visits.map { v in
            [v.id, cities[v.cityID]?.name ?? v.cityID, cities[v.cityID]?.countryID ?? "", v.date.precision.rawValue, v.date.year.map(String.init) ?? "", v.date.month.map(String.init) ?? "", v.date.day.map(String.init) ?? "", v.tripID.flatMap { trips[$0] } ?? "", v.note, String(v.photoIDs.count)].map(escape).joined(separator: ",")
        }.joined(separator: "\r\n")
    }
}
