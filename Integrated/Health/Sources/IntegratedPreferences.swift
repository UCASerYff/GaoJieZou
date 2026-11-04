import Foundation
import CoreFoundation

/// Only the source health game's presentation Bool is imported. Host language,
/// appearance, bookmarks and privacy grants never transfer through this mapping.
enum HealthPreferences {
    static var suiteName: String { RestorePreferences.moduleDomain }
    static let defaults: UserDefaults = {
        guard let result = UserDefaults(suiteName: suiteName) else { preconditionFailure("Cannot construct fixed Health preferences domain") }
        return result
    }()
    static func prepare() throws {
        try RhythmIntegrationPaths.withWriterLease {
            let authority = try RhythmIntegrationPaths.authority()
            let file = try RhythmIntegrationPaths.moduleDirectory("health").appendingPathComponent("Preferences.plist")
            try RhythmIntegrationPaths.requireExisting(file, directory: false)
            let bytes = try Data(contentsOf: file)
            guard bytes.count <= 16 * 1024 * 1024,
                  let value = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any],
                  value["schema"] as? Int == 1, value["transactionID"] as? String == authority.transactionID,
                  let standard = value["standard"] as? [String: Any], value["module"] as? [String: Any] != nil else {
                throw HealthError("健康偏好迁移凭据损坏，未使用默认值覆盖 / Health preference migration receipt invalid")
            }
            let key = "gqns.home.compact"
            var compact: Bool?
            if let source = standard[key] {
                guard let number = source as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw HealthError("健康偏好类型无效 / Invalid health preference type") }
                compact = number.boolValue
            }
            let marker = "integration.preferences.transactionID"
            if defaults.string(forKey: marker) != authority.transactionID {
                if defaults.object(forKey: key) == nil, let compact { defaults.set(compact, forKey: key) }
                defaults.set(authority.transactionID, forKey: marker)
                guard defaults.synchronize(), defaults.string(forKey: marker) == authority.transactionID else { throw CocoaError(.fileWriteUnknown) }
            }
        }
    }
}
