import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

enum WidgetMapFailure: Error { case invalidGeography, imageEncoding }

/// No window, NSApplication or SwiftUI hosting view is needed to create widget maps.
enum WidgetMapRenderer {
    static func png(geography: Geography, visited: [City], resident: City?, china: Bool) throws -> Data {
        let regions = china ? geography.china : geography.world
        guard !regions.isEmpty else { throw WidgetMapFailure.invalidGeography }
        guard regions.allSatisfy({ region in
            !region.rings.isEmpty && region.rings.allSatisfy { ring in
                ring.count >= 3 && ring.allSatisfy { point in
                    point.count >= 2 && point[0].isFinite && point[1].isFinite &&
                    (-180...180).contains(point[0]) && (-90...90).contains(point[1])
                }
            }
        }), (visited + (resident.map { [$0] } ?? [])).allSatisfy({
            $0.longitude.isFinite && $0.latitude.isFinite &&
            (-180...180).contains($0.longitude) && (-90...90).contains($0.latitude)
        }) else { throw WidgetMapFailure.invalidGeography }
        let shapes: [(GeoRegion, CGPath)] = regions.map { region in
            let path = CGMutablePath()
            for ring in region.rings {
                guard let first = ring.first, first.count >= 2 else { continue }
                path.move(to: project(first[0], first[1], china: china))
                var longitude = first[0]
                for point in ring.dropFirst() where point.count >= 2 {
                    let next = project(point[0], point[1], china: china)
                    if abs(point[0] - longitude) > 180 { path.move(to: next) }
                    else { path.addLine(to: next) }
                    longitude = point[0]
                }
                path.closeSubpath()
            }
            return (region, path)
        }
        let bounds = shapes.reduce(CGRect.null) { $0.union($1.1.boundingBoxOfPath) }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0,
              bounds.width.isFinite, bounds.height.isFinite else { throw WidgetMapFailure.invalidGeography }
        let width = 920, height = 600
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WidgetMapFailure.imageEncoding }
        ctx.setFillColor(color(0.92, 0.87, 0.74)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 2, y: -2)
        let scale = min(420 / bounds.width, 260 / bounds.height)
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                          tx: 230 - bounds.midX * scale, ty: 150 - bounds.midY * scale)
        let visitedIDs = Set(visited.map(\.id)), countries = Set(visited.map(\.countryID))
        for (region, path) in shapes {
            guard let mapped = path.copy(using: &transform) else { throw WidgetMapFailure.invalidGeography }
            let lit = china ? visitedIDs.contains(region.cityID) : countries.contains(region.countryID)
            ctx.addPath(mapped)
            ctx.setFillColor(lit ? color(0.69, 0.42, 0.23) : color(0.85, 0.81, 0.69))
            ctx.setStrokeColor(color(0.52, 0.46, 0.37, 0.55)); ctx.setLineWidth(china ? 0.4 : 0.5)
            ctx.drawPath(using: .eoFillStroke)
        }
        for city in visited where city.id != resident?.id && (!china || city.countryID == "CHN") {
            let point = project(city.longitude, city.latitude, china: china).applying(transform)
            ctx.setFillColor(color(0.40, 0.23, 0.12))
            ctx.fillEllipse(in: CGRect(x: point.x - 2.5, y: point.y - 3.5, width: 5, height: 5))
        }
        if let city = resident, !china || city.countryID == "CHN" {
            let p = project(city.longitude, city.latitude, china: china).applying(transform)
            ctx.setFillColor(color(0.17, 0.39, 0.36)); ctx.setStrokeColor(color(0.99, 0.98, 0.94)); ctx.setLineWidth(1)
            ctx.addEllipse(in: CGRect(x: p.x - 7, y: p.y - 12, width: 14, height: 14)); ctx.drawPath(using: .fillStroke)
            let house = CGMutablePath()
            house.move(to: CGPoint(x: p.x - 4, y: p.y - 5)); house.addLine(to: CGPoint(x: p.x, y: p.y - 9))
            house.addLine(to: CGPoint(x: p.x + 4, y: p.y - 5)); house.addLine(to: CGPoint(x: p.x + 3, y: p.y - 5))
            house.addLine(to: CGPoint(x: p.x + 3, y: p.y - 1)); house.addLine(to: CGPoint(x: p.x - 3, y: p.y - 1))
            house.addLine(to: CGPoint(x: p.x - 3, y: p.y - 5)); house.closeSubpath()
            ctx.addPath(house); ctx.setFillColor(color(1, 1, 1)); ctx.fillPath()
        }
        guard let image = ctx.makeImage() else { throw WidgetMapFailure.imageEncoding }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw WidgetMapFailure.imageEncoding }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WidgetMapFailure.imageEncoding }
        return output as Data
    }

    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }
    private static func project(_ lon: Double, _ lat: Double, china: Bool) -> CGPoint {
        if china {
            let d = Double.pi / 180, n = (sin(25 * Double.pi / 180) + sin(47 * Double.pi / 180)) / 2
            let c = pow(cos(25 * d), 2) + 2 * n * sin(25 * d)
            let r = sqrt(max(c - 2 * n * sin(lat * d), 0)) / n
            let r0 = sqrt(max(c - 2 * n * sin(18 * d), 0)) / n
            return CGPoint(x: r * sin(n * (lon - 105) * d) * 100, y: -(r0 - r * cos(n * (lon - 105) * d)) * 100)
        }
        let phi = lat * .pi / 180, p2 = phi * phi, p4 = p2 * p2
        return CGPoint(x: lon * (0.8707 - 0.131979 * p2 + p4 * (-0.013791 + p4 * (0.003971 * p2 - 0.001529 * p4))),
                       y: -lat * (1.007226 + p2 * (0.015085 + p4 * (-0.044475 + 0.028874 * p2 - 0.005916 * p4))))
    }
}

enum WidgetSourceFingerprint {
    /// Ignore train-only updates and array retrieval order. Geography is part of the content contract.
    static func make(journal: Journal, geography: Geography) throws -> String {
        var normalized = journal
        normalized.modifiedAt = Date(timeIntervalSince1970: 0)
        normalized.footprintModifiedAt = nil
        normalized.train = TrainState()
        normalized.visits.sort { $0.id < $1.id }; normalized.trips.sort { $0.id < $1.id }
        normalized.customCities.sort { $0.id < $1.id }; normalized.attachments.sort { $0.id < $1.id }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601
        var bytes = try e.encode(normalized); bytes.append(try e.encode(geography))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
