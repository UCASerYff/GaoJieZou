import Foundation
import CoreFoundation

/// Explicit absence is kept separately from an intentionally empty domain.
/// The receipt is durable before any live directory or preference is replaced.
enum RestorePreferences {
    private struct Domain: Codable { var key: String; var value: Data? }
    private struct Receipt: Codable { var version = 1; var domains: [Domain] }
    static var moduleDomain: String {
        #if INTEGRATION_PATH_TEST
        return "com.gaojiezou.rhythm.integrated.health.tests.\(ProcessInfo.processInfo.processIdentifier)"
        #else
        return "com.gaojiezou.rhythm.integrated.health"
        #endif
    }
    private static var names: [String: String] { ["module": moduleDomain] }
    static func incoming(_ staged: URL) throws -> [String: [String: Any]] {
        let file = staged.appendingPathComponent("preferences.plist")
        do { _ = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return [:] // A legacy archive without preferences does not clear them.
        }
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), options: [], format: nil)
        guard let domains = value as? [String: [String: Any]], Set(domains.keys).isSubset(of: Set(["standard", "module"])) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Only this module's presentation Bool transfers from legacy standard;
        // the complete original dictionaries remain in the retained archive.
        let key = "gqns.home.compact"
        let source = domains["module"]?[key] ?? domains["standard"]?[key]
        guard let source else { return domains["module"] == nil ? [:] : ["module": [:]] }
        guard let number = source as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw CocoaError(.fileReadCorruptFile) }
        return ["module": [key: number.boolValue]]
    }
    static func capture(to file: URL) throws {
        let domains = try names.keys.sorted().map { key -> Domain in
            let current = UserDefaults.standard.persistentDomain(forName: names[key]!)
            let value = try current.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
            return Domain(key: key, value: value)
        }
        try JSONEncoder().encode(Receipt(domains: domains)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func apply(_ domains: [String: [String: Any]]) throws {
        for key in domains.keys.sorted() {
            let name = names[key]!
            var merged = UserDefaults.standard.persistentDomain(forName: name) ?? [:]
            for (setting, value) in domains[key]! { merged[setting] = value }
            try write(merged, name: name)
        }
    }
    static func restore(from file: URL) throws {
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: file))
        guard receipt.version == 1, receipt.domains.count == names.count,
              Set(receipt.domains.map(\.key)) == Set(names.keys) else { throw CocoaError(.fileReadCorruptFile) }
        // Decode every domain before changing any of them.
        let domains = try receipt.domains.map { domain -> (String, [String: Any]?) in
            guard let data = domain.value else { return (domain.key, nil) }
            guard let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (domain.key, value)
        }
        for (key, value) in domains { try write(value, name: names[key]!) }
    }
    private static func write(_ value: [String: Any]?, name: String) throws {
        if let value { UserDefaults.standard.setPersistentDomain(value, forName: name) }
        else { UserDefaults.standard.removePersistentDomain(forName: name) }
        guard UserDefaults.standard.synchronize() else { throw CocoaError(.fileWriteUnknown) }
        let actual = UserDefaults.standard.persistentDomain(forName: name)
        guard (actual == nil) == (value == nil),
              NSDictionary(dictionary: actual ?? [:]).isEqual(to: value ?? [:]) else { throw CocoaError(.fileWriteUnknown) }
    }
}
