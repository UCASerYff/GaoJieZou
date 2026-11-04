import Foundation
import AppKit

/// 只接受共享容器中完整且校验通过的同代统计与地图，不再拼接旧版分文件快照。
struct FootprintWidgetData {
    static let appGroupID = "5G96498KGJ.com.gaojiezou.rhythm"

    let snapshot: FootprintWidgetSnapshot?
    let chinaMap: NSImage?
    let worldMap: NSImage?
    var generationID: String? = nil
    var sourceDigest: String? = nil
    var sourceModifiedAt: Date? = nil
    var publishedAt: Date? = nil
    var requestedAt: Date? = nil
    var readAt: Date? = nil
    var readResult: String = "unavailable"
    var failureCode: String? = nil

    static let empty = FootprintWidgetData(snapshot: nil, chinaMap: nil, worldMap: nil)

    /// 只有这里决定显示范围；图片与点击链接使用同一个结果。
    var mapScope: String {
        let prefersChina: Bool
        if let country = snapshot?.residentCountryID { prefersChina = country == "CHN" }
        else { prefersChina = (snapshot?.china ?? 0) > 0 }
        if prefersChina { return chinaMap != nil ? "china" : "world" }
        return worldMap != nil ? "world" : "china"
    }

    var map: NSImage? { mapScope == "china" ? chinaMap : worldMap }
    var mapURL: URL? {
        URL(string: snapshot == nil ? "gaojiezou://footprints/map" : "gaojiezou://footprints/map?scope=\(mapScope)")
    }

    /// directory 参数只用于隔离测试；生产环境始终使用带 entitlement 的 App Group。
    static func load(from directory: URL, reason: String, family: String, requestedAt: Date = Date()) -> FootprintWidgetData {
        let data: FootprintWidgetData
        do {
            let result = try WidgetGenerationStore(root: directory).loadResult()
            let generation = result.generation
            guard let china = NSImage(data: generation.chinaPNG), let world = NSImage(data: generation.worldPNG) else {
                throw WidgetReadFailure.invalidImage
            }
            data = FootprintWidgetData(
                snapshot: generation.snapshot, chinaMap: china, worldMap: world,
                generationID: generation.generationID, sourceDigest: generation.sourceDigest,
                sourceModifiedAt: generation.sourceModifiedAt, publishedAt: generation.publishedAt, requestedAt: requestedAt,
                readAt: Date(), readResult: result.source,
                failureCode: result.fallbackReason
            )
        } catch {
            var unavailable = Self.empty
            unavailable.requestedAt = requestedAt
            unavailable.readAt = Date()
            unavailable.failureCode = (error as? WidgetGenerationError)?.code ?? (error is WidgetReadFailure ? "invalid_image" : "no_valid_generation")
            data = unavailable
        }
        WidgetReadReceipt.record(data: data, directory: directory, reason: reason, family: family, requestedAt: requestedAt)
        return data
    }

    static func load(reason: String = "timeline", family: String = "systemMedium", requestedAt: Date = Date()) -> FootprintWidgetData {
        guard let container = try? FootprintsIntegratedStorage.widgetDirectory() else {
            var unavailable = Self.empty
            unavailable.requestedAt = requestedAt
            unavailable.readAt = Date()
            unavailable.failureCode = "integration_not_active_or_unavailable"
            return unavailable
        }
        return load(from: container, reason: reason, family: family, requestedAt: requestedAt)
    }
}

private enum WidgetReadFailure: Error { case invalidImage }

/// 只表示扩展读取过这份资料，不能据此宣称桌面已经显示；每种调用上下文只保留一份。
/// 不记录城市名、足迹详情、容器路径等私人内容。
struct WidgetReadReceipt: Codable {
    var schema = 1
    let requestedAt: Date
    let readAt: Date
    let sourceModifiedAt: Date?
    let publishedAt: Date?
    let generationID: String?
    let sourceDigest: String?
    let reason: String
    let family: String
    let result: String
    let errorCode: String?
    let widgetVersion: String
    let widgetBuild: String

    static func record(data: FootprintWidgetData, directory: URL, reason: String, family: String, requestedAt: Date) {
        // Fixed filenames also bound storage if a future caller passes arbitrary reason/family values.
        let context = ["timeline", "snapshot", "preview"].contains(reason) ? reason : "other"
        let size = ["systemSmall", "systemMedium", "systemLarge", "systemExtraLarge"].contains(family) ? family : "other"
        let receipt = WidgetReadReceipt(
            requestedAt: requestedAt, readAt: data.readAt ?? Date(),
            sourceModifiedAt: data.sourceModifiedAt, publishedAt: data.publishedAt,
            generationID: data.generationID, sourceDigest: data.sourceDigest,
            reason: context, family: size, result: data.readResult, errorCode: data.failureCode,
            widgetVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            widgetBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        )
        // The new widget is a read-only consumer of migrated data. Diagnostics
        // go to the system log, never back into the authority's files.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        if let bytes = try? encoder.encode(receipt), let text = String(data: bytes, encoding: .utf8) {
            NSLog("RhythmFootprintsWidgetRead %@", text)
        }
    }
}
