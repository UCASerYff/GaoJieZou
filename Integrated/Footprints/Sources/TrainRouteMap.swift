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
    var body:some View {
        let g=TrainMapGeometry.cached(geography:geography,origin:origin,destination:destination)
        Canvas { ctx,size in
            ctx.fill(Path(CGRect(origin:.zero,size:size)),with:.linearGradient(Gradient(colors:[Color(red:0.07,green:0.17,blue:0.23),Color(red:0.12,green:0.29,blue:0.34)]),startPoint:.zero,endPoint:CGPoint(x:size.width,y:size.height)))
            let inset:CGFloat=35,scale=min((size.width-inset*2)/g.bounds.width,(size.height-inset*2)/g.bounds.height)
            let transform=CGAffineTransform(a:scale,b:0,c:0,d:scale,tx:size.width/2-g.bounds.midX*scale,ty:size.height/2-g.bounds.midY*scale)
            for x in stride(from:CGFloat(0),through:size.width,by:40) { var p=Path();p.move(to:CGPoint(x:x,y:0));p.addLine(to:CGPoint(x:x,y:size.height));ctx.stroke(p,with:.color(.white.opacity(0.035)),lineWidth:1) }
            for y in stride(from:CGFloat(0),through:size.height,by:40) { var p=Path();p.move(to:CGPoint(x:0,y:y));p.addLine(to:CGPoint(x:size.width,y:y));ctx.stroke(p,with:.color(.white.opacity(0.035)),lineWidth:1) }
            for shape in g.shapes {
                let path=shape.path.applying(transform)
                let visited=shape.region.countryID==origin?.countryID || shape.region.countryID==destination?.countryID
                ctx.fill(path,with:.color(visited ? Color(red:0.35,green:0.51,blue:0.47):Color(red:0.22,green:0.36,blue:0.39)))
                ctx.stroke(path,with:.color(.white.opacity(0.25)),lineWidth:0.55)
            }
            guard let a=origin,let b=destination else {
                ctx.draw(Text(tF("添加两个不同城市的足迹，即可规划行程","Record two cities to plan a journey")).font(.headline).foregroundColor(.white),at:CGPoint(x:size.width/2,y:size.height/2));return
            }
            let j=journey ?? TrainJourney(origin:a,destination:b,startedAt:now,arrivesAt:now.addingTimeInterval(120),reward:2)
            let progress=journey?.progress(at:now) ?? 0
            func point(_ t:Double)->CGPoint { let c=j.coordinate(at:t);return g.project(c.lon,c.lat).applying(transform) }
            func line(_ end:Double)->Path {
                var path=Path();var previous:CGPoint?
                for i in 0...160 { let p=point(Double(i)/160*end)
                    if let previous,abs(previous.x-p.x)<size.width*0.45 { path.addLine(to:p) } else { path.move(to:p) };previous=p
                };return path
            }
            ctx.stroke(line(1),with:.color(.white.opacity(0.40)),style:StrokeStyle(lineWidth:2,dash:[5,6]))
            if progress>0 { ctx.stroke(line(progress),with:.color(Color(red:0.35,green:0.94,blue:0.83)),style:StrokeStyle(lineWidth:3,lineCap:.round)) }
            for (index,city) in [a,b].enumerated() {
                let p=g.project(city.longitude,city.latitude).applying(transform)
                ctx.fill(Path(ellipseIn:CGRect(x:p.x-5,y:p.y-5,width:10,height:10)),with:.color(index==0 ? .white:.orange))
                let other=g.project(index==0 ? b.longitude:a.longitude,index==0 ? b.latitude:a.latitude).applying(transform)
                let offset:CGFloat=p.y<=other.y ? -24:24
                let close=hypot(p.x-other.x,p.y-other.y)<130
                let label=CGPoint(x:min(size.width-75,max(75,p.x)),y:min(size.height-16,max(16,p.y+(close ? offset:-23))))
                ctx.draw(Text(city.name).font(.system(size:12,weight:.semibold)).foregroundColor(.white),at:label)
            }
            let current=point(progress)
            ctx.fill(Path(ellipseIn:CGRect(x:current.x-13,y:current.y-13,width:26,height:26)),with:.color(Color(red:0.22,green:0.81,blue:0.68)))
            var trainIcon=ctx.resolve(Image(systemName:"tram.fill"));trainIcon.shading = .color(.white)
            ctx.draw(trainIcon,in:CGRect(x:current.x-7,y:current.y-8,width:14,height:16))
        }
        .accessibilityLabel(Text((origin?.name ?? "")+" → "+(destination?.name ?? "")+" · "+String(Int((journey?.progress(at:now) ?? 0)*100))+"%"))
    }
}
