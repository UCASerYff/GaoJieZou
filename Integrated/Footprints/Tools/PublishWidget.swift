import Foundation
import RhythmFootprints

/// Optional new-host utility: no old application, absolute source path or old
/// helper executable is needed. Root can call the same public API directly.
@main struct PublishIntegratedFootprintsWidget {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 1 else {
            throw NSError(domain: "Rhythm.Footprints", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No source path arguments are accepted; the committed integration authority decides all paths."])
        }
        let result = try FootprintsModuleRuntime.publishSavedSnapshot()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
}
