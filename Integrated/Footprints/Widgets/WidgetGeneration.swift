import Foundation
import CryptoKit
import ImageIO
import CoreGraphics
import Darwin

/// Error codes are safe to record in diagnostics: no paths, cities or records.
enum WidgetGenerationError: String, Error, LocalizedError {
    case missing, unreadable, invalidJSON, unsupportedSchema, oversized
    case invalidIdentity, invalidDate, invalidSnapshot, invalidPNG, digestMismatch
    case writeFailed, outOfSpace, cancelled
    var code: String { rawValue }
    var errorDescription: String? { "widget_generation_" + rawValue }

    static func code(for error: Error) -> String { normalized(error).code }
    static func normalized(_ error: Error) -> WidgetGenerationError {
        if let error = error as? WidgetGenerationError { return error }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return .outOfSpace }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return .outOfSpace }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error,
           normalized(underlying) == .outOfSpace { return .outOfSpace }
        return .writeFailed
    }
}

/// Statistics and both maps are encoded into one immutable publication unit.
struct WidgetGeneration: Codable {
    var schema = 1
    var generationID: String
    var sourceDigest: String
    var sourceModifiedAt: Date
    var publishedAt: Date
    var appVersion: String
    var appBuild: String
    var snapshot: FootprintWidgetSnapshot
    var chinaPNG: Data
    var worldPNG: Data
    var snapshotDigest: String
    var chinaDigest: String
    var worldDigest: String

    init(sourceDigest: String, sourceModifiedAt: Date, appVersion: String, appBuild: String,
         snapshot: FootprintWidgetSnapshot, chinaPNG: Data, worldPNG: Data,
         publishedAt: Date = Date()) throws {
        generationID = UUID().uuidString
        self.sourceDigest = sourceDigest
        self.sourceModifiedAt = sourceModifiedAt
        self.publishedAt = publishedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.snapshot = snapshot
        self.chinaPNG = chinaPNG
        self.worldPNG = worldPNG
        do { snapshotDigest = Self.digest(try Self.makeEncoder().encode(snapshot)) }
        catch { throw WidgetGenerationError.invalidSnapshot }
        chinaDigest = Self.digest(chinaPNG)
        worldDigest = Self.digest(worldPNG)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Bounds before decoding images keep corrupt input from allocating huge rasters.
    func validate() throws {
        guard schema == 1, snapshot.schema == 1 else { throw WidgetGenerationError.unsupportedSchema }
        func isDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard UUID(uuidString: generationID) != nil, isDigest(sourceDigest),
              !appVersion.isEmpty, appVersion.utf8.count <= 32,
              !appBuild.isEmpty, appBuild.utf8.count <= 32 else { throw WidgetGenerationError.invalidIdentity }
        guard sourceModifiedAt.timeIntervalSince1970.isFinite,
              publishedAt.timeIntervalSince1970.isFinite,
              snapshot.generatedAt.timeIntervalSince1970.isFinite,
              let snapshotSourceDate = snapshot.sourceModifiedAt,
              snapshotSourceDate.timeIntervalSince1970.isFinite,
              snapshotSourceDate == sourceModifiedAt else { throw WidgetGenerationError.invalidDate }
        let values = [snapshot.cities, snapshot.countries, snapshot.china, snapshot.chinaTotal,
                      snapshot.continents, snapshot.visits]
        guard values.allSatisfy({ (0...10_000_000).contains($0) }),
              snapshot.china <= snapshot.cities, snapshot.china <= snapshot.chinaTotal,
              snapshot.countries <= snapshot.cities, snapshot.cities <= snapshot.visits,
              snapshot.continents <= 7, snapshot.continents <= snapshot.countries,
              snapshot.recent.count <= min(3, snapshot.visits),
              (snapshot.residentCityName == nil) == (snapshot.residentCountryID == nil),
              snapshot.residentCityName.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true,
              snapshot.residentCountryID.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true,
              snapshot.recent.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 1024 &&
                  $0.location.utf8.count <= 2048 && $0.dateLabel.utf8.count <= 256 })
        else { throw WidgetGenerationError.invalidSnapshot }
        let snapshotBytes: Data
        do { snapshotBytes = try Self.makeEncoder().encode(snapshot) }
        catch { throw WidgetGenerationError.invalidSnapshot }
        guard isDigest(snapshotDigest), isDigest(chinaDigest), isDigest(worldDigest),
              snapshotDigest == Self.digest(snapshotBytes), chinaDigest == Self.digest(chinaPNG),
              worldDigest == Self.digest(worldPNG) else { throw WidgetGenerationError.digestMismatch }
        try Self.validatePNG(chinaPNG)
        try Self.validatePNG(worldPNG)
    }

    private static func validatePNG(_ bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= WidgetGenerationStore.maximumBytes,
              bytes.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 1_000_000, height <= 1_000_000,
              width <= 1_000_000 / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw WidgetGenerationError.invalidPNG }
        // Force raster decoding without creating a window or using AppKit.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

struct WidgetGenerationLoadResult {
    let generation: WidgetGeneration
    let source: String
    let fallbackReason: String?
}

enum WidgetGenerationPublishStage { case beforeStaging, afterStaging, beforeCommit }

struct WidgetGenerationStore {
    static let maximumBytes = 8 * 1024 * 1024
    static let currentFilename = "widget-generation.json"
    static let previousFilename = "widget-generation.previous.json"
    let root: URL
    var faultInjector: ((WidgetGenerationPublishStage) throws -> Void)? = nil

    func load() throws -> WidgetGeneration { try loadResult().generation }

    func loadResult() throws -> WidgetGenerationLoadResult {
        do {
            return WidgetGenerationLoadResult(generation: try read(root.appendingPathComponent(Self.currentFilename)),
                                              source: "current", fallbackReason: nil)
        } catch {
            let currentError = error as? WidgetGenerationError ?? .unreadable
            do {
                return WidgetGenerationLoadResult(generation: try read(root.appendingPathComponent(Self.previousFilename)),
                                                  source: "previous", fallbackReason: currentError.code)
            } catch { throw currentError }
        }
    }

    private func read(_ url: URL) throws -> WidgetGeneration {
        let size: Int
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let length = values.fileSize else { throw WidgetGenerationError.unreadable }
            size = length
        } catch let error as WidgetGenerationError { throw error }
        catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError) {
                throw WidgetGenerationError.missing
            }
            throw WidgetGenerationError.unreadable
        }
        guard size > 0 else { throw WidgetGenerationError.invalidJSON }
        guard size <= Self.maximumBytes else { throw WidgetGenerationError.oversized }
        let bytes: Data
        do { bytes = try Data(contentsOf: url) } catch { throw WidgetGenerationError.unreadable }
        guard bytes.count <= Self.maximumBytes else { throw WidgetGenerationError.oversized }
        let generation: WidgetGeneration
        do { generation = try WidgetGeneration.makeDecoder().decode(WidgetGeneration.self, from: bytes) }
        catch { throw WidgetGenerationError.invalidJSON }
        try generation.validate()
        return generation
    }

    func publish(_ generation: WidgetGeneration) throws {
        do {
            try generation.validate()
            let bytes = try WidgetGeneration.makeEncoder().encode(generation)
            guard bytes.count <= Self.maximumBytes else { throw WidgetGenerationError.oversized }
            try checkCancellation()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // Serialize writers; readers require no lock because the single current file is renamed atomically.
            let lock = Darwin.open(root.appendingPathComponent(".widget-generation.lock").path,
                                   O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard lock >= 0 else { throw posixError() }
            defer { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }
            guard flock(lock, LOCK_EX) == 0 else { throw posixError() }
            try checkCancellation()
            try faultInjector?(.beforeStaging)
            let staged = root.appendingPathComponent(".widget-generation-" + UUID().uuidString + ".tmp")
            defer { try? FileManager.default.removeItem(at: staged) }
            try writeAndSync(bytes, to: staged)
            // Re-read the durable staging file before changing either retained generation.
            _ = try read(staged)
            try checkCancellation()
            try faultInjector?(.afterStaging)
            let current = root.appendingPathComponent(Self.currentFilename)
            if let valid = try? read(current) {
                let previousBytes = try WidgetGeneration.makeEncoder().encode(valid)
                let stagedPrevious = root.appendingPathComponent(".widget-generation-previous-" + UUID().uuidString + ".tmp")
                defer { try? FileManager.default.removeItem(at: stagedPrevious) }
                try writeAndSync(previousBytes, to: stagedPrevious)
                try checkCancellation()
                guard Darwin.rename(stagedPrevious.path, root.appendingPathComponent(Self.previousFilename).path) == 0
                else { throw posixError() }
            }
            // An invalid current never overwrites a previously validated fallback.
            try checkCancellation()
            try faultInjector?(.beforeCommit)
            guard Darwin.rename(staged.path, current.path) == 0 else { throw posixError() }
            // After rename the new generation is committed. A directory sync cannot undo it.
            let directory = Darwin.open(root.path, O_RDONLY)
            if directory >= 0 { _ = fsync(directory); _ = Darwin.close(directory) }
        } catch { throw WidgetGenerationError.normalized(error) }
    }

    private func checkCancellation() throws {
        if Task<Never, Never>.isCancelled { throw WidgetGenerationError.cancelled }
    }

    private func writeAndSync(_ bytes: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw posixError() }
        defer { _ = Darwin.close(fd) }
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw WidgetGenerationError.writeFailed }
            var offset = 0
            while offset < buffer.count {
                let amount = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw posixError() }
                offset += amount
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
    }

    private func posixError() -> WidgetGenerationError { errno == ENOSPC ? .outOfSpace : .writeFailed }
}
