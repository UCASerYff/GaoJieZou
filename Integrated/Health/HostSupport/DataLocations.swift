import Foundation

enum AppDataLocations {
    static var appSupport: URL? { try? RhythmIntegrationPaths.moduleDirectory("health") }
    static var groupContainer: URL? { try? RhythmIntegrationPaths.sharedSleepDirectory() }
    /// Owner-specific maintenance access still validates the immutable authority receipt.
    static func integrationRoot() throws -> URL {
        try RhythmIntegrationPaths.authority(allowMaintenanceOwner: "health").root
    }
    static func sourceArchive() throws -> URL { try integrationRoot().appendingPathComponent("SourceArchives/Health", isDirectory: true) }
    static func importedSupport() throws -> URL? {
        let directory = try RhythmIntegrationPaths.moduleDirectory("health").appendingPathComponent("ImportedSupport", isDirectory: true)
        do {
            try RhythmIntegrationPaths.requireExisting(directory, directory: true)
            return directory
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            let authority = try RhythmIntegrationPaths.authority()
            let file = authority.root.appendingPathComponent("SourceArchives/explicit-absences.json")
            try RhythmIntegrationPaths.requireExisting(file, directory: false)
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  value["schemaVersion"] as? Int == 1, value["transactionID"] as? String == authority.transactionID,
                  let missing = value["explicitAbsences"] as? [String], missing.contains("healthSupport") else {
                throw HealthError("原健康文件活动副本缺失，迁移收据未声明缺失；未创建空目录。")
            }
            return nil
        }
    }
}

