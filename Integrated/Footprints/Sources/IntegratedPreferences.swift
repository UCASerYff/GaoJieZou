import Foundation
import CoreFoundation
import CryptoKit

/// The original domains remain archived; only explicit module-owned values are
/// copied into a new domain after the authority has become active.
enum FootprintsPreferences {
    static let suiteName = "com.gaojiezou.rhythm.integrated.footprints"
    private static let importMarker = "integration.preferences.sourceSHA256"

    static func prepare() throws {
        try RhythmIntegrationPaths.withWriterLease { try prepareUnderLease() }
    }
    private static func prepareUnderLease() throws {
        let root = try FootprintsIntegratedStorage.dataDirectory()
        let file = root.appendingPathComponent("Preferences.plist")
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 16 * 1024 * 1024 else {
            throw AppFailure("足迹偏好迁移清单缺失或不可读，未以默认设置覆盖。")
        }
        let bytes = try Data(contentsOf: file)
        guard let plist = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any],
              let schema = plist["schema"] as? Int, schema == 1,
              let transaction = plist["transactionID"] as? String,
              transaction == (try RhythmIntegrationPaths.authority().transactionID),
              let standard = plist["standard"] as? [String: Any],
              let module = plist["module"] as? [String: Any] else {
            throw AppFailure("不支持的足迹偏好迁移清单，原设置保持不变。")
        }
        let sourceHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let defaults = FootprintsBundle.defaults
        if defaults.string(forKey: importMarker) == sourceHash { return }
        let selected = try validatedValues(standard: standard, module: module)
        let existing = defaults.persistentDomain(forName: suiteName) ?? [:]
        // A second cutover or an interrupted first import must preserve any
        // preferences already chosen in the new host.
        for (key, value) in selected where existing[key] == nil { defaults.set(value, forKey: key) }
        defaults.set(sourceHash, forKey: importMarker)
    }

    static func validateRestoreDomains(_ data: Data) throws -> [String: [String: Any]] {
        guard let domains = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: [String: Any]],
              let standard = domains["standard"], let module = domains["module"] else {
            throw AppFailure("足迹备份偏好缺失或类型无效。")
        }
        _ = try validatedValues(standard: standard, module: module)
        return domains
    }

    static func restoreOwnValues(standard: [String: Any], module: [String: Any]) throws {
        let selected = try validatedValues(standard: standard, module: module)
        // Only the restore coordinator invokes this while holding the exclusive
        // maintenance lease; an active path lookup would reject its own marker.
        for (key, value) in selected { FootprintsBundle.defaults.set(value, forKey: key) }
    }

    static func exportDomains() -> [String: [String: Any]] {
        let own = FootprintsBundle.defaults.persistentDomain(forName: suiteName) ?? [:]
        let standardKeys = ["gqns.language", "gqns.appearance", "gqns.home.compact", "gqns.train.autoTour"]
        let moduleKeys = ["animationEnabled", "soundEnabled", "ownerName"]
        return ["standard": own.filter { standardKeys.contains($0.key) },
                "module": own.filter { moduleKeys.contains($0.key) }]
    }

    private static func validatedValues(standard: [String: Any], module: [String: Any]) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["animationEnabled", "soundEnabled"] {
            if let value = module[key] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw AppFailure("足迹偏好类型无效：\(key)")
                }
                result[key] = number.boolValue
            }
        }
        if let value = module["ownerName"] {
            guard let name = value as? String, name.utf8.count <= 64 * 1024 else { throw AppFailure("足迹主人名称偏好无效。") }
            result["ownerName"] = name
        }
        for (key, accepted) in [("gqns.language", ["system", "zh-Hans", "en"]),
                                ("gqns.appearance", ["system", "light", "dark"])] {
            if let value = standard[key] {
                guard let value = value as? String, accepted.contains(value) else { throw AppFailure("足迹偏好无效：\(key)") }
                result[key] = value
            }
        }
        for key in ["gqns.home.compact", "gqns.train.autoTour"] {
            if let value = standard[key] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw AppFailure("足迹偏好类型无效：\(key)")
                }
                result[key] = number.boolValue
            }
        }
        return result
    }
}
