import Foundation
import SQLite3
import CryptoKit

struct BackupEnvelope: Codable {
    var version = 1
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.7"
    var createdAt = Date()
    var payload: Data
    var sha256: String
}
/// Storage layout: one core JSON blob (island, preferences, ledgers, templates…)
/// plus row-per-entry `records` / `events` tables so daily writes stay incremental.
/// PRAGMA user_version 0 = legacy single-blob layout, 1 = split layout.
final class HealthDatabase {
    static let groupID = "5G96498KGJ.com.gaojiezou.rhythm"
    static let changedNotification = Notification.Name("GaoSeries.rhythm.health.databaseChanged")
    enum Access { case application, readOnlyExisting, readWriteExisting, readOnlyMaintenance }
    struct Snapshot { var state: HealthState; var revision: String }
    let directory: URL
    private var db: OpaquePointer?
    private let access: Access
    private var isReadOnly: Bool { access == .readOnlyExisting || access == .readOnlyMaintenance }
    private let lock = NSRecursiveLock()
    /// Only the committed Rhythm migration can select the live authority.
    /// No legacy App Group fallback or environment-selected production database.
    static func location() throws -> URL {
        try RhythmIntegrationPaths.moduleDirectory("health")
    }
    private let requiresActiveAuthority: Bool
    private var openedIdentity: String?
    static func isLiveDirectory(_ directory: URL) -> Bool {
        guard let group = try? RhythmIntegrationPaths.groupDirectory() else { return false }
        return directory.standardizedFileURL == group.appendingPathComponent("Integration/Modules/Health", isDirectory: true).standardizedFileURL
    }
    private func fileIdentity() throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("health.sqlite").path)
        guard let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else { throw HealthError("Missing database file identity") }
        return "\(device):\(inode)"
    }
    private func withProductionLease<T>(_ body: () throws -> T) throws -> T {
        if requiresActiveAuthority { return try RhythmIntegrationPaths.withWriterLease(body) }
        return try body()
    }
    private func requireAuthority() throws {
        guard requiresActiveAuthority else { return }
        let active = try Self.location().standardizedFileURL
        guard active == directory.standardizedFileURL else { throw HealthError("健康资料权威已切换 / Health authority changed") }
        if let openedIdentity {
            guard openedIdentity == (try fileIdentity()) else { throw HealthError("健康资料连接已过期 / Health database connection is stale") }
        }
    }
    init(directory: URL? = nil, access: Access = .application) throws {
        self.directory = try directory ?? Self.location()
        self.requiresActiveAuthority = directory == nil || (Self.isLiveDirectory(self.directory) && access != .readOnlyMaintenance)
        self.access = access
        guard access != .readOnlyMaintenance || directory != nil else { throw HealthError("Maintenance validation requires an explicit directory") }
        try withProductionLease {
        try requireAuthority()
        let url = self.directory.appendingPathComponent("health.sqlite")
        let existed: Bool
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw HealthError("数据库路径无效 / Invalid database path") }
            existed = true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { existed = false }
        guard existed || (!requiresActiveAuthority && access == .application) else { throw HealthError("健康资料库缺失，未创建空白资料 / Health database missing; no empty replacement was created") }
        if !existed {
            // A missing database beside backups or an initialization marker is lost
            // data, not a first launch. Only a truly empty location may initialize.
            if FileManager.default.fileExists(atPath:self.directory.path) {
                guard try FileManager.default.contentsOfDirectory(atPath:self.directory.path).isEmpty else { throw HealthError("原健康资料库缺失，已停止写入以保护目录内容 / Existing health database missing; writes stopped to protect the directory") }
            }
            try FileManager.default.createDirectory(at:self.directory,withIntermediateDirectories:true)
        }
        let flags = (isReadOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX | (existed ? 0 : SQLITE_OPEN_CREATE)
        do {
            guard sqlite3_open_v2(url.path,&db,flags,nil)==SQLITE_OK else { throw HealthError("无法打开本地数据库 / Cannot open database") }
            sqlite3_busy_timeout(db,5000)
            openedIdentity = try fileIdentity()
            if !existed {
                try execute("PRAGMA journal_mode=WAL")
                try execute("PRAGMA synchronous=FULL")
                try execute("BEGIN IMMEDIATE")
                try execute("CREATE TABLE state (id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL)")
                try execute("CREATE TABLE records (id TEXT PRIMARY KEY, kind TEXT NOT NULL, occurred_at REAL NOT NULL, json BLOB NOT NULL)")
                try execute("CREATE TABLE events (id TEXT PRIMARY KEY, type_id TEXT NOT NULL, occurred_at REAL NOT NULL, json BLOB NOT NULL)")
                try write(HealthState())
                try execute("PRAGMA user_version = 1")
                try execute("COMMIT")
            } else {
                let version = try intPragma("user_version")
                guard (0...1).contains(version) else { throw HealthError("不支持此数据库版本，原资料已保留 / Unsupported database version; original retained") }
                // Validate the complete save before any migration or write pragma.
                _ = try readVersioned()
                if version == 0 && access == .readWriteExisting { throw HealthError("请先打开主 App 完成资料升级 / Open the main app to upgrade this database") }
                if version == 0 && access == .application {
                    try execute("BEGIN IMMEDIATE")
                    let legacy = try decodeState(readBlob())
                    try execute("CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, kind TEXT NOT NULL, occurred_at REAL NOT NULL, json BLOB NOT NULL)")
                    try execute("CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, type_id TEXT NOT NULL, occurred_at REAL NOT NULL, json BLOB NOT NULL)")
                    try syncRecords(old:[],new:legacy.records)
                    try syncEvents(old:[],new:legacy.events)
                    try writeBlob(core(legacy))
                    try execute("PRAGMA user_version = 1")
                    try execute("COMMIT")
                }
                if !isReadOnly { try execute("PRAGMA synchronous=FULL") }
            }
        } catch { if db != nil { try? execute("ROLLBACK"); sqlite3_close_v2(db); db = nil }; throw error }
        }
    }
    /// Recovery prepares an isolated replacement before an atomic directory move.
    /// Release every SQLite handle/sidecar first; never closes a live connection.
    func closeStagedConnection() throws {
        guard !requiresActiveAuthority else { throw HealthError("Cannot close a live Health connection for replacement") }
        guard db != nil else { return }
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        guard sqlite3_close(db) == SQLITE_OK else { throw error() }
        db = nil
    }
    deinit { sqlite3_close(db) }
    private func error() -> HealthError { HealthError("数据库操作失败 / Database error: \(String(cString:sqlite3_errmsg(db)))") }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else { throw error() } }
    private func intPragma(_ name: String) throws -> Int {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db,"PRAGMA \(name)",-1,&st,nil)==SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st)==SQLITE_ROW else { throw error() }
        return Int(sqlite3_column_int(st,0))
    }
    /// Core state = everything except the row-based collections.
    private func core(_ state: HealthState) -> HealthState { var c = state; c.records = []; c.events = []; return c }
    private func decodeState(_ data: Data) throws -> HealthState {
        do { return try JSONDecoder().decode(HealthState.self,from:data) }
        catch { throw HealthError("存档读取失败，原文件已保留，已停止写入。 / Save unreadable; original retained and writes stopped.\n\(error.localizedDescription)") }
    }
    private func readBlob() throws -> Data {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,"SELECT json FROM state WHERE id=1",-1,&statement,nil)==SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement)==SQLITE_ROW, let ptr = sqlite3_column_blob(statement,0) else { throw error() }
        return Data(bytes:ptr,count:Int(sqlite3_column_bytes(statement,0)))
    }
    private func writeBlob(_ state: HealthState) throws {
        let data = try JSONEncoder().encode(state)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,"INSERT OR REPLACE INTO state(id,json) VALUES(1,?)",-1,&statement,nil)==SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        let rc = data.withUnsafeBytes { sqlite3_bind_blob(statement,1,$0.baseAddress,Int32(data.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
        guard rc==SQLITE_OK && sqlite3_step(statement)==SQLITE_DONE else { throw error() }
    }
    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ text: String) { sqlite3_bind_text(statement,index,text,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ blob: Data) {
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement,index,$0.baseAddress,Int32(blob.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
    }
    private func loadRows(_ table: String) throws -> [Data] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,"SELECT json FROM \(table) ORDER BY id",-1,&statement,nil)==SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        var rows: [Data] = []
        var result = sqlite3_step(statement)
        while result==SQLITE_ROW {
            guard let ptr = sqlite3_column_blob(statement,0) else { throw error() }
            rows.append(Data(bytes:ptr,count:Int(sqlite3_column_bytes(statement,0))))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw error() }
        return rows
    }
    private func upsertRow(_ table: String, id: String, owner: String, occurredAt: Date, json: Data) throws {
        var statement: OpaquePointer?
        let ownerColumn = table == "records" ? "kind" : "type_id"
        guard sqlite3_prepare_v2(db,"INSERT OR REPLACE INTO \(table)(id,\(ownerColumn),occurred_at,json) VALUES(?,?,?,?)",-1,&statement,nil)==SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        bind(statement,1,id); bind(statement,2,owner)
        sqlite3_bind_double(statement,3,occurredAt.timeIntervalSince1970)
        bind(statement,4,json)
        guard sqlite3_step(statement)==SQLITE_DONE else { throw error() }
    }
    private func deleteRow(_ table: String, id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,"DELETE FROM \(table) WHERE id=?",-1,&statement,nil)==SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        bind(statement,1,id)
        guard sqlite3_step(statement)==SQLITE_DONE else { throw error() }
    }
    private func syncRecords(old: [HealthRecord], new: [HealthRecord]) throws {
        let previous = Dictionary(old.map { ($0.id,$0) }, uniquingKeysWith: { a,_ in a })
        let newIDs = Set(new.map(\.id))
        for record in new where previous[record.id] != record {
            try upsertRow("records",id:record.id.uuidString,owner:record.kind.rawValue,occurredAt:record.occurredAt,json:JSONEncoder().encode(record))
        }
        for record in old where !newIDs.contains(record.id) { try deleteRow("records",id:record.id.uuidString) }
    }
    private func syncEvents(old: [HealthEvent], new: [HealthEvent]) throws {
        let oldData = Dictionary(old.map { ($0.id,(try? JSONEncoder().encode($0)) ?? Data()) }, uniquingKeysWith: { a,_ in a })
        let newIDs = Set(new.map(\.id))
        for event in new {
            let data = try JSONEncoder().encode(event)
            if oldData[event.id] != data { try upsertRow("events",id:event.id.uuidString,owner:event.typeID.uuidString,occurredAt:event.occurredAt,json:data) }
        }
        for event in old where !newIDs.contains(event.id) { try deleteRow("events",id:event.id.uuidString) }
    }
    func read() throws -> HealthState { try readVersioned().state }
    func readVersioned() throws -> Snapshot {
        return try withProductionLease {
        try requireAuthority()
        lock.lock(); defer { lock.unlock() }
        let ownsTransaction = sqlite3_get_autocommit(db) != 0
        if ownsTransaction { try execute("BEGIN DEFERRED") }
        do {
            let version = try intPragma("user_version")
            guard (0...1).contains(version) else { throw HealthError("不支持此数据库版本 / Unsupported database version") }
            let blob = try readBlob()
            var state = try decodeState(blob)
            var chunks = [blob]
            if version == 1 {
                let records = try loadRows("records"), events = try loadRows("events")
                state.records = try records.map { try JSONDecoder().decode(HealthRecord.self,from:$0) }
                state.events = try events.map { try JSONDecoder().decode(HealthEvent.self,from:$0) }
                chunks += records + events
            }
            try Engine.validate(state)
            var digest = SHA256()
            for chunk in chunks { digest.update(data:Data("\(chunk.count):".utf8)); digest.update(data:chunk) }
            let revision = digest.finalize().map { String(format:"%02x",$0) }.joined()
            if ownsTransaction { try execute("COMMIT") }
            return Snapshot(state:state,revision:revision)
        } catch {
            if ownsTransaction { try? execute("ROLLBACK") }
            throw HealthError("存档读取失败，原文件已保留，已停止写入。 / Save unreadable; original retained and writes stopped.\n\(error.localizedDescription)")
        }
    
        }
    }
    private func write(_ state: HealthState, previous: HealthState? = nil) throws {
        try writeBlob(core(state))
        if previous == nil { try execute("DELETE FROM records"); try execute("DELETE FROM events") }
        try syncRecords(old:previous?.records ?? [],new:state.records)
        try syncEvents(old:previous?.events ?? [],new:state.events)
    }
    @discardableResult func transaction(request: String? = nil,now: Date = Date(),_ operation: (inout HealthState) throws -> Void) throws -> HealthState {
        return try withProductionLease {
        try requireAuthority()
        lock.lock(); defer { lock.unlock() }
        guard !isReadOnly else { throw HealthError("此连接只读 / This database connection is read only") }
        try execute("BEGIN IMMEDIATE")
        do {
            try requireAuthority()
            var state = try read()
            let previous = state
            if let request, state.requests.contains(request) { try execute("COMMIT"); return state }
            try operation(&state)
            if let request { state.requests.insert(request) }
            try Engine.validate(state)
            state.updatedAt = now
            try write(state,previous:previous); try execute("COMMIT")
            HealthWidgetData.databaseDidChange(directory:directory,now:now)
            return state
        } catch { try? execute("ROLLBACK"); throw error }
    
        }
    }
    func backupData(_ state: HealthState) throws -> Data {
        try requireAuthority()
        let payload = try JSONEncoder().encode(state)
        let hash = SHA256.hash(data:payload).map { String(format:"%02x",$0) }.joined()
        return try JSONEncoder().encode(BackupEnvelope(payload:payload,sha256:hash))
    }
    static func decodeBackup(_ data: Data) throws -> (HealthState,Date) {
        guard data.count<100_000_000 else { throw HealthError("备份文件过大 / Backup too large") }
        let backup = try JSONDecoder().decode(BackupEnvelope.self,from:data)
        let hash = SHA256.hash(data:backup.payload).map { String(format:"%02x",$0) }.joined()
        guard backup.version==1 && backup.sha256==hash else { throw HealthError("备份版本或校验不匹配 / Backup checksum or version mismatch") }
        let state = try JSONDecoder().decode(HealthState.self,from:backup.payload)
        try Engine.validate(state)
        return (state,backup.createdAt)
    }
    func restore(_ state: HealthState) throws {
        return try withProductionLease {
        try requireAuthority()
        lock.lock(); defer { lock.unlock() }
        guard !isReadOnly else { throw HealthError("此连接只读 / This database connection is read only") }
        try Engine.validate(state)
        try execute("BEGIN IMMEDIATE")
        do {
            try requireAuthority()
            // Preserve the original database even if its JSON cannot be decoded.
            let rescue = directory.appendingPathComponent("Backups",isDirectory:true)
            try FileManager.default.createDirectory(at:rescue,withIntermediateDirectories:true)
            if let current = try? read() {
                try backupData(current).write(to:rescue.appendingPathComponent("before-restore-\(UUID().uuidString).healthbackup"),options:.atomic)
            } else {
                let target = rescue.appendingPathComponent("unreadable-\(UUID().uuidString).sqlite")
                var destination: OpaquePointer?
                guard sqlite3_open(target.path,&destination)==SQLITE_OK else { throw error() }
                defer { sqlite3_close(destination) }
                guard let backup = sqlite3_backup_init(destination,"main",db,"main") else { throw error() }
                let code = sqlite3_backup_step(backup,-1); sqlite3_backup_finish(backup)
                guard code==SQLITE_DONE else { throw error() }
            }
            let current = try read()
            let restored = HealthRestoreSafety.retainingReceipts(incoming: state, current: current)
            try Engine.validate(restored)
            try write(restored,previous:current); try execute("COMMIT")
            HealthWidgetData.databaseDidChange(directory:directory,now:Date())
        } catch { try? execute("ROLLBACK"); throw error }
    
        }
    }
    func erase() throws {
        return try withProductionLease {
        try requireAuthority()
        lock.lock(); defer { lock.unlock() }
        guard !isReadOnly else { throw HealthError("此连接只读 / This database connection is read only") }
        try execute("BEGIN IMMEDIATE")
        do {
            try requireAuthority()
            let current = try read()
            let reset = HealthRestoreSafety.retainingReceipts(incoming: HealthState(), current: current)
            try writeBlob(core(reset))
            try execute("DELETE FROM records"); try execute("DELETE FROM events")
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        let backups = directory.appendingPathComponent("Backups")
        if FileManager.default.fileExists(atPath:backups.path) { try FileManager.default.removeItem(at:backups) }
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("VACUUM")
        HealthWidgetData.databaseDidChange(directory:directory,now:Date())
    
        }
    }
}

enum HealthCSV {
    // Legacy files cannot distinguish an inserted guard from a literal apostrophe.
    private static let textEscapeColumn = "text_escape_v1"

    static let fileNames = RecordKind.allCases.map { "\($0.rawValue).csv" } + ["custom-events.csv"]

    static func document(header: [String], rows: [[String]]) -> String {
        func quote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "\"\"", options: .literal) + "\""
        }
        let headerLine = (header + [textEscapeColumn]).map(quote).joined(separator: ",")
        let nameIndex = header.firstIndex(of: "name")
        let noteIndex = header.firstIndex(of: "note")
        let lines = rows.map { row -> String in
            var flags = 0
            let cells = row.enumerated().map { index, value -> String in
                let first = value.unicodeScalars.first { !CharacterSet.whitespacesAndNewlines.contains($0) }
                guard let first, "=+-@".unicodeScalars.contains(first) else { return quote(value) }
                if index == nameIndex { flags |= 1 }
                if index == noteIndex { flags |= 2 }
                return quote("'" + value)
            }
            return (cells + [quote(String(flags))]).joined(separator: ",")
        }
        return "\u{FEFF}" + ([headerLine] + lines).joined(separator: "\r\n")
    }

    static func export(_ kind: RecordKind,_ records: [HealthRecord]) -> String {
        let header = ["id","occurred_at","timezone","type","name","amount","unit","kcal","protein_g","carbs_g","fat_g","meal_slot","note","source","meal_source","fullness_percent"]
        var rows: [[String]] = []
        let formatter = ISO8601DateFormatter()
        func value(_ n: Double?) -> String { n.map { String($0) } ?? "" }
        for r in records.filter({ $0.kind==kind }).sorted(by:{ $0.occurredAt<$1.occurredAt }) {
            rows.append([r.id.uuidString,formatter.string(from:r.occurredAt),r.timezone,r.kind.rawValue,r.title,String(r.amount),r.kind == .meal ? r.foodUnit : r.kind.unit,value(r.calories),value(r.protein),value(r.carbs),value(r.fat),r.kind == .meal ? String(r.slot) : "",r.note,r.source,r.mealSource?.rawValue ?? "",r.fullnessPercent.map(String.init) ?? ""])
        }
        return document(header: header, rows: rows)
    }

    /// Minimal CSV reader for our own export format: BOM tolerant, quoted cells, escaped quotes, LF/CRLF.
    private static func parse(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var closedQuote = false
        let input = text.unicodeScalars
        var i = input.startIndex
        if i < input.endIndex && input[i] == "\u{FEFF}" { i = input.index(after: i) }
        func endField() { row.append(field); field = ""; closedQuote = false }
        func endRow() { endField(); rows.append(row); row = [] }
        while i < input.endIndex {
            let ch = input[i]
            if quoted {
                if ch == "\"" {
                    let next = input.index(after: i)
                    if next < input.endIndex && input[next] == "\"" {
                        field.append("\""); i = next
                    } else {
                        quoted = false; closedQuote = true
                    }
                } else { field.unicodeScalars.append(ch) }
            } else if ch == "," {
                endField()
            } else if ch == "\r" || ch == "\n" {
                endRow()
                let next = input.index(after: i)
                if ch == "\r", next < input.endIndex, input[next] == "\n" { i = next }
            } else if closedQuote {
                throw HealthError("健康 CSV 引号格式无效 / Invalid quoting in health CSV")
            } else if ch == "\"" && field.isEmpty {
                quoted = true
            } else {
                field.unicodeScalars.append(ch)
            }
            i = input.index(after: i)
        }
        guard !quoted else { throw HealthError("健康 CSV 引号格式无效 / Invalid quoting in health CSV") }
        if !field.isEmpty || !row.isEmpty || closedQuote { endRow() }
        return rows
    }
    private struct Row {
        let columns: [String: Int]
        let cells: [String]

        subscript(_ column: String) -> String? {
            guard let index = columns[column], cells.indices.contains(index) else { return nil }
            return cells[index]
        }

        var freeText: (name: String, note: String)? {
            let name = self["name"] ?? ""
            let note = self["note"] ?? ""
            guard columns[HealthCSV.textEscapeColumn] != nil else { return (name, note) }
            guard let flags = self[HealthCSV.textEscapeColumn], ["0", "1", "2", "3"].contains(flags),
                  let mask = Int(flags) else { return nil }
            if (mask & 1 != 0 && name.utf8.first != 0x27) || (mask & 2 != 0 && note.utf8.first != 0x27) { return nil }
            return (mask & 1 == 0 ? name : String(decoding: name.utf8.dropFirst(), as: UTF8.self),
                    mask & 2 == 0 ? note : String(decoding: note.utf8.dropFirst(), as: UTF8.self))
        }
    }

    private static let instantShape = try! NSRegularExpression(
        pattern: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):?[0-5][0-9])\z"#
    )

    private static func read<Entry>(_ input: String, entry: (Row, Date, String, String) -> Entry?) throws
        -> (entries: [Entry], invalid: Int) {
        let rows = try parse(input)
        guard let header = rows.first, header.contains("id"), header.contains("occurred_at") else {
            throw HealthError("健康 CSV 缺少 id 或 occurred_at 列 / Health CSV is missing id or occurred_at")
        }
        let columns = Dictionary(header.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let formatter = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0)!

        var entries: [Entry] = []
        var invalid = 0
        for cells in rows.dropFirst() where cells != [""] {
            let row = Row(columns: columns, cells: cells)
            guard cells.count <= header.count,
                  let stamp = row["occurred_at"],
                  instantShape.firstMatch(in: stamp, range: NSRange(stamp.startIndex..<stamp.endIndex, in: stamp)) != nil,
                  let year = Int(stamp.prefix(4)), year > 0,
                  let month = Int(stamp.dropFirst(5).prefix(2)), let day = Int(stamp.dropFirst(8).prefix(2)),
                  DateComponents(year: year, month: month, day: day).isValidDate(in: gregorian),
                  let date = fractional.date(from: stamp) ?? formatter.date(from: stamp),
                  let text = row.freeText, let value = entry(row, date, text.name, text.note) else {
                invalid += 1
                continue
            }
            entries.append(value)
        }
        return (entries, invalid)
    }

    private static func records(_ kind: RecordKind, _ text: String, now: Date) throws
        -> (entries: [HealthRecord], invalid: Int) {
        try read(text) { row, date, name, note in
            guard let rawID = row["id"], let id = UUID(uuidString: rawID) else { return nil }
            var record = HealthRecord(kind:kind)
            record.id = id
            record.occurredAt = date
            if let timezone = row["timezone"], TimeZone(identifier: timezone) != nil { record.timezone = timezone }
            record.title = name
            if let amount = row["amount"].flatMap({ Double($0) }) { record.amount = amount }
            if let unit = row["unit"], kind == .meal, ["serving", "g"].contains(unit) { record.foodUnit = unit }
            record.calories = row["kcal"].flatMap { Double($0) }
            record.protein = row["protein_g"].flatMap { Double($0) }
            record.carbs = row["carbs_g"].flatMap { Double($0) }
            record.fat = row["fat_g"].flatMap { Double($0) }
            if kind == .meal {
                record.slot = row["meal_slot"].flatMap { Int($0) } ?? record.slot
                record.mealSource = row["meal_source"].flatMap(MealSource.init(rawValue:))
                record.fullnessPercent = row["fullness_percent"].flatMap { Int($0) }
            }
            record.note = note
            record.source = "import"
            record.rewardEligible = false
            guard (try? Engine.validateRecord(record, now: now)) != nil else { return nil }
            return record
        }
    }

    private static func events(_ text: String, types: [HealthEventType], now: Date) throws
        -> (entries: [HealthEvent], invalid: Int) {
        try read(text) { row, date, name, note in
            guard let rawID = row["id"], let id = UUID(uuidString: rawID),
                  let count = row["count"].flatMap({ Int($0) }), (1...999).contains(count),
                  date <= now.addingTimeInterval(60), note.count <= 2000 else { return nil }
            let candidate = row["type_id"].flatMap(UUID.init(uuidString:))
            let match = types.first { $0.id == candidate }
                ?? types.first { !name.isEmpty && ($0.name == name || $0.englishName == name) }
            guard let match else { return nil }
            var event = HealthEvent(typeID: match.id)
            event.id = id
            event.occurredAt = date
            event.count = count
            event.note = note
            event.source = "import"
            return event
        }
    }

    /// Called in a single database transaction so structural failures roll back the selection.
    static func importFiles(_ files: [String: String], into state: inout HealthState, now: Date)
        throws -> (added: Int, skipped: Int, invalid: Int) {
        var report = (added: 0, skipped: 0, invalid: 0)
        var recordIDs = Set(state.records.map(\.id))
        for kind in RecordKind.allCases {
            guard let text = files["\(kind.rawValue).csv"] else { continue }
            let parsed = try records(kind, text, now: now)
            report.invalid += parsed.invalid
            for record in parsed.entries {
                if recordIDs.insert(record.id).inserted { state.records.append(record); report.added += 1 }
                else { report.skipped += 1 }
            }
        }
        if let text = files["custom-events.csv"] {
            let parsed = try events(text, types: state.eventTypes, now: now)
            var eventIDs = Set(state.events.map(\.id))
            report.invalid += parsed.invalid
            for event in parsed.entries {
                if eventIDs.insert(event.id).inserted { state.events.append(event); report.added += 1 }
                else { report.skipped += 1 }
            }
        }
        return report
    }
}
