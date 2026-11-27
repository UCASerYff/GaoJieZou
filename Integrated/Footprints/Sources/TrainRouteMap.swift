import SwiftUI

// Cached geographic paths keep one-second progress updates inexpensive and work offline.
private final class TrainMapGeometry {
    private static var cache:[String:TrainMapGeometry]=[:]
    static func cached(geography:Geography,origin:City?,destination:City?)->TrainMapGeometry {
        let key=[origin,destination].map { c in c.map { "\($0.id):\($0.countryID):\($0.longitude):\($0.latitude)" } ?? "nil" }.joined(separator:"|")+"|\(geography.world.count):\(geography.china.count)"
        if let geometry=cache[key] { return geometry }
        if cache.count>=8 { cache.removeAll() }
        let geometry=TrainMapGeometry(geography:geography,origin:origin,destination:destination);cache[key]=geometry;return geometry
    }
    let shapes:[MapShape]
    let bounds:CGRect
    let domestic:Bool
    let project:(Double,Double)->CGPoint
    init(geography:Geography,origin:City?,destination:City?) {
        domestic = origin != nil && destination != nil && origin?.countryID == destination?.countryID
        let country=origin?.countryID ?? ""
        if domestic && country == "CHN" {
            project=AtlasPaths.projectChina
            let regions=geography.china.isEmpty ? geography.world.filter { $0.countryID==country } : geography.china
            shapes=regions.map { AtlasPaths.make($0,projection:AtlasPaths.projectChina) }
        } else if domestic {
            // Recenter domestic maps around the departure longitude (Alaska/date-line safe).
            let center=origin?.longitude ?? 0, latitude=origin?.latitude ?? 0
            let projection:(Double,Double)->CGPoint = { lon,lat in
                let x=(lon-center+540).truncatingRemainder(dividingBy:360)-180
                return CGPoint(x:x*max(0.2,cos(latitude * .pi/180)),y:-lat)
            }
            project=projection
            shapes=geography.world.filter { $0.countryID==country }.map { AtlasPaths.make($0,projection:projection) }
        } else {
            project=AtlasPaths.project
            shapes=geography.world.map { AtlasPaths.make($0,projection:AtlasPaths.project) }
        }
        var rect=AtlasPaths.bounds(of:shapes)
        for city in [origin,destination].compactMap({$0}) { let p=project(city.longitude,city.latitude);rect=rect.union(CGRect(x:p.x,y:p.y,width:0.1,height:0.1)) }
        if rect.isNull || rect.width<0.01 || rect.height<0.01 { rect=CGRect(x:-10,y:-10,width:20,height:20) }
        if domestic,let origin,let destination {
            let a=project(origin.longitude,origin.latitude),b=project(destination.longitude,destination.latitude)
            let width=max(abs(a.x-b.x)*2.0,rect.width*0.50),height=max(abs(a.y-b.y)*1.8,rect.height*0.50)
            let focus=CGRect(x:(a.x+b.x-width)/2,y:(a.y+b.y-height)/2,width:width,height:height)
            let clipped=focus.intersection(rect)
            if !clipped.isNull { rect=clipped }
        }
        bounds=rect.insetBy(dx:-max(1,rect.width*0.06),dy:-max(1,rect.height*0.08))
    }
}

struct TrainRouteMap: View {
    let geography:Geography
    let origin:City?
    let destination:City?
    let journey:TrainJourney?
    let now:Date
    var body: some View {
        let geometry = TrainMapGeometry.cached(geography: geography, origin: origin, destination: destination)
        Canvas { context, size in
            drawMap(in: &context, size: size, geometry: geometry)
        }
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var accessibilitySummary: String {
        let progress: Double = journey?.progress(at: now) ?? 0
        let percent = Int(progress * 100)
        return "\(origin?.name ?? "") → \(destination?.name ?? "") · \(percent)%"
    }

    private func drawMap(in context: inout GraphicsContext, size: CGSize, geometry: TrainMapGeometry) {
        drawBackground(in: &context, size: size)

        let inset: CGFloat = 35
        let horizontalScale: CGFloat = (size.width - inset * 2) / geometry.bounds.width
        let verticalScale: CGFloat = (size.height - inset * 2) / geometry.bounds.height
        let scale = min(horizontalScale, verticalScale)
        let tx: CGFloat = size.width / 2 - geometry.bounds.midX * scale
        let ty: CGFloat = size.height / 2 - geometry.bounds.midY * scale
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)

        let visitedColor = Color(red: 0.35, green: 0.51, blue: 0.47)
        let regionColor = Color(red: 0.22, green: 0.36, blue: 0.39)
        let outline: GraphicsContext.Shading = .color(Color.white.opacity(0.25))
        for shape in geometry.shapes {
            let path = shape.path.applying(transform)
            let country = shape.region.countryID
            let visited = country == origin?.countryID || country == destination?.countryID
            let color: Color = visited ? visitedColor : regionColor
            context.fill(path, with: .color(color))
            context.stroke(path, with: outline, lineWidth: 0.55)
        }

        guard let origin, let destination else {
            let message = tF("添加两个不同城市的足迹，即可规划行程", "Record two cities to plan a journey")
            let label: Text = Text(message).font(.headline).foregroundColor(.white)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.draw(label, at: center)
            return
        }
        drawJourney(in: &context, size: size, geometry: geometry, transform: transform,
                    origin: origin, destination: destination)
    }

    private func drawBackground(in context: inout GraphicsContext, size: CGSize) {
        let gradient = Gradient(colors: [
            Color(red: 0.07, green: 0.17, blue: 0.23),
            Color(red: 0.12, green: 0.29, blue: 0.34),
        ])
        let farCorner = CGPoint(x: size.width, y: size.height)
        let background: GraphicsContext.Shading = .linearGradient(gradient, startPoint: .zero, endPoint: farCorner)
        context.fill(Path(CGRect(origin: .zero, size: size)), with: background)
        let grid: GraphicsContext.Shading = .color(Color.white.opacity(0.035))
        for x in stride(from: CGFloat.zero, through: size.width, by: 40) {
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: grid, lineWidth: 1)
        }
        for y in stride(from: CGFloat.zero, through: size.height, by: 40) {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: grid, lineWidth: 1)
        }
    }

    private func drawJourney(
        in context: inout GraphicsContext, size: CGSize, geometry: TrainMapGeometry,
        transform: CGAffineTransform, origin: City, destination: City
    ) {
        let route = journey ?? TrainJourney(origin: origin, destination: destination, startedAt: now,
                                            arrivesAt: now.addingTimeInterval(120), reward: 2)
        let progress: Double = journey?.progress(at: now) ?? 0
        let seamThreshold: CGFloat = size.width * 0.45

        func point(_ fraction: Double) -> CGPoint {
            let coordinate = route.coordinate(at: fraction)
            return geometry.project(coordinate.lon, coordinate.lat).applying(transform)
        }

        func line(_ end: Double) -> Path {
            var path = Path()
            var previous: CGPoint?
            for index in 0...160 {
                let fraction: Double = Double(index) / 160 * end
                let position = point(fraction)
                if let previous, abs(previous.x - position.x) < seamThreshold {
                    path.addLine(to: position)
                } else {
                    path.move(to: position)
                }
                previous = position
            }
            return path
        }

        let routeStyle = StrokeStyle(lineWidth: 2, dash: [5, 6])
        context.stroke(line(1), with: .color(Color.white.opacity(0.40)), style: routeStyle)
        if progress > 0 {
            let progressColor = Color(red: 0.35, green: 0.94, blue: 0.83)
            let progressStyle = StrokeStyle(lineWidth: 3, lineCap: .round)
            context.stroke(line(progress), with: .color(progressColor), style: progressStyle)
        }
        let departure = geometry.project(origin.longitude, origin.latitude).applying(transform)
        let arrival = geometry.project(destination.longitude, destination.latitude).applying(transform)
        drawStation(in: &context, name: origin.name, position: departure, other: arrival, color: .white, size: size)
        drawStation(in: &context, name: destination.name, position: arrival, other: departure, color: .orange, size: size)

        let current = point(progress)
        let marker = CGRect(x: current.x - 13, y: current.y - 13, width: 26, height: 26)
        let markerColor = Color(red: 0.22, green: 0.81, blue: 0.68)
        context.fill(Path(ellipseIn: marker), with: .color(markerColor))
        var trainIcon = context.resolve(Image(systemName: "tram.fill"))
        trainIcon.shading = .color(.white)
        context.draw(trainIcon, in: CGRect(x: current.x - 7, y: current.y - 8, width: 14, height: 16))
    }

    private func drawStation(
        in context: inout GraphicsContext, name: String, position: CGPoint, other: CGPoint,
        color: Color, size: CGSize
    ) {
        let pin = CGRect(x: position.x - 5, y: position.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: pin), with: .color(color))
        let offset: CGFloat = position.y <= other.y ? -24 : 24
        let distance: CGFloat = hypot(position.x - other.x, position.y - other.y)
        let labelY: CGFloat = position.y + (distance < 130 ? offset : -23)
        let x: CGFloat = min(size.width - 75, max(75, position.x))
        let y: CGFloat = min(size.height - 16, max(16, labelY))
        let label: Text = Text(name).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
        context.draw(label, at: CGPoint(x: x, y: y))
    }
}
