import SwiftUI
import UniformTypeIdentifiers

struct MapShape {
    var region: GeoRegion
    var path: Path
}
final class AtlasPaths {
    let world: [MapShape]
    let china: [MapShape]
    let worldBounds: CGRect
    let chinaBounds: CGRect
    /// Mainland-only bounds (rings entirely south of 17.8°N excluded);
    /// the far-south islands are shown in the inset box instead.
    let chinaMainBounds: CGRect
    /// South-sea bounds (Hainan + 南海诸岛) for the inset box.
    let chinaSouthBounds: CGRect
    init(_ geography: Geography) {
        world = geography.world.map { Self.make($0, projection: Self.project) }
        china = geography.china.map { Self.make($0, projection: Self.projectChina) }
        worldBounds = Self.bounds(of: world)
        chinaBounds = Self.bounds(of: china)
        chinaMainBounds = Self.bounds(of: geography.china, minLat: 17.8, projection: Self.projectChina)
        chinaSouthBounds = Self.southBounds(of: geography.china, maxLat: 20.5, projection: Self.projectChina)
    }
    // Robinson compromise projection for the world map.
    static func project(_ lon: Double, _ lat: Double) -> CGPoint {
        let phi = lat * .pi / 180, p2 = phi * phi, p4 = p2*p2
        let x = lon * (0.8707 - 0.131979*p2 + p4*(-0.013791 + p4*(0.003971*p2 - 0.001529*p4)))
        let y = lat * (1.007226 + p2*(0.015085 + p4*(-0.044475 + 0.028874*p2 - 0.005916*p4)))
        return CGPoint(x:x,y:-y)
    }
    // Albers equal-area conic for the China map: central meridian 105°E,
    // standard parallels 25°N / 47°N. The world projection tilts China
    // sideways; this one keeps the mainland upright.
    static func projectChina(_ lon: Double, _ lat: Double) -> CGPoint {
        let d = Double.pi / 180
        let p1 = 25*d, p2 = 47*d, l0 = 105*d, p0 = 18*d
        let n = (sin(p1)+sin(p2))/2
        let c = cos(p1)*cos(p1) + 2*n*sin(p1)
        func rho(_ phi: Double) -> Double { sqrt(max(c-2*n*sin(phi),0))/n }
        let r = rho(lat*d), r0 = rho(p0), theta = n*(lon*d-l0)
        return CGPoint(x:r*sin(theta)*100, y:-(r0-r*cos(theta))*100)
    }
    static func make(_ region: GeoRegion, projection: (Double, Double) -> CGPoint) -> MapShape {
        var path = Path()
        for ring in region.rings {
            guard let first = ring.first, first.count>=2 else { continue }
            path.move(to:projection(first[0],first[1]))
            var last = first[0]
            for point in ring.dropFirst() where point.count>=2 {
                if abs(point[0]-last)>180 { path.move(to:projection(point[0],point[1])) } else { path.addLine(to:projection(point[0],point[1])) }; last=point[0]
            }
            path.closeSubpath()
        }
        return MapShape(region:region,path:path)
    }
    static func bounds(of shapes: [MapShape]) -> CGRect {
        shapes.reduce(into: CGRect.null) { $0 = $0.union($1.path.boundingRect) }
    }
    /// Bounds over raw regions, keeping only rings that reach minLat.
    static func bounds(of regions: [GeoRegion], minLat: Double, projection: (Double, Double) -> CGPoint) -> CGRect {
        var rect = CGRect.null
        for region in regions {
            for ring in region.rings where ring.contains(where: { $0.count >= 2 && $0[1] >= minLat }) {
                for point in ring where point.count >= 2 {
                    let p = projection(point[0], point[1])
                    rect = rect.union(CGRect(x: p.x, y: p.y, width: 0, height: 0))
                }
            }
        }
        return rect
    }
    /// Bounds over rings that lie entirely south of maxLat (for the inset).
    static func southBounds(of regions: [GeoRegion], maxLat: Double, projection: (Double, Double) -> CGPoint) -> CGRect {
        var rect = CGRect.null
        for region in regions {
            for ring in region.rings where ring.allSatisfy({ $0.count >= 2 && $0[1] <= maxLat }) && !ring.isEmpty {
                for point in ring where point.count >= 2 {
                    let p = projection(point[0], point[1])
                    rect = rect.union(CGRect(x: p.x, y: p.y, width: 0, height: 0))
                }
            }
        }
        return rect
    }
}
struct MapTransform {
    let scale: CGFloat; let tx: CGFloat; let ty: CGFloat
    let china: Bool
    init(size: CGSize, bounds: CGRect, china: Bool, zoom: CGFloat, pan: CGSize) {
        self.china = china
        scale = min((size.width-40)/bounds.width,(size.height-40)/bounds.height)*zoom
        tx=size.width/2-bounds.midX*scale+pan.width; ty=size.height/2-bounds.midY*scale+pan.height
    }
    var affine: CGAffineTransform { CGAffineTransform(a:scale,b:0,c:0,d:scale,tx:tx,ty:ty) }
    func point(_ c: City) -> CGPoint { (china ? AtlasPaths.projectChina : AtlasPaths.project)(c.longitude,c.latitude).applying(affine) }
    func inverse(_ p: CGPoint) -> CGPoint { p.applying(affine.inverted()) }
}
struct AtlasCanvas: View {
    let paths: AtlasPaths; let china: Bool; let cities: [City]; let selected: String?
    var selectedCountry: String? = nil
    var zoom: CGFloat = 1; var pan: CGSize = .zero
    var showLabels = true
    /// 紧凑中国模式（小组件迷你地图）：用含南海的完整取景框，不画左下角小图，
    /// 远南单元图钉直接画在主画布上，避免小组件统计面板遮挡小图。
    var compactChina = false
    /// 常驻地点只是地图参照，不参与已到访区域着色与足迹统计。
    var residentCity: City? = nil
    /// Bottom-left inset box showing the South China Sea islands at small scale.
    static func chinaInset(size: CGSize) -> CGRect {
        CGRect(x: 14, y: size.height-132, width: 152, height: 118)
    }
    static func drawResidentPin(_ ctx: inout GraphicsContext, at point: CGPoint, selected: Bool, scale: CGFloat = 1) {
        let center = CGPoint(x: point.x, y: point.y - 7 * scale)
        let circle = Path(ellipseIn: CGRect(x: center.x - 10 * scale, y: center.y - 10 * scale, width: 20 * scale, height: 20 * scale))
        var tail = Path()
        tail.move(to: CGPoint(x: point.x - 5 * scale, y: point.y))
        tail.addLine(to: CGPoint(x: point.x, y: point.y + 7 * scale))
        tail.addLine(to: CGPoint(x: point.x + 5 * scale, y: point.y))
        tail.closeSubpath()
        let color = Color(red: 0.17, green: 0.39, blue: 0.36)
        ctx.fill(tail, with: .color(color))
        ctx.fill(circle, with: .color(color))
        ctx.stroke(circle, with: .color(selected ? Ink.ochre : Ink.panel), lineWidth: selected ? 2.5 : 1.4)
        ctx.draw(Text(Image(systemName: "house.fill")).font(.system(size: 11 * scale, weight: .semibold)).foregroundColor(.white), at: center)
    }
    var body: some View {
        // 3.37④：Canvas 本体对 VoiceOver 是一块未知元素——叠加一层按同一投影摆放的
        // 透明可聚焦热点（城市名 + 已到访状态），不参与命中测试，视觉与交互不变。
        GeometryReader { geo in
            Canvas { ctx,size in
            let chinaBounds = compactChina ? paths.chinaBounds : paths.chinaMainBounds
            let t=MapTransform(size:size,bounds:china ? chinaBounds : paths.worldBounds,china:china,zoom:zoom,pan:pan)
            let filledCountries=Set(cities.map(\.countryID)), filledCities=Set(cities.map(\.id))
            ctx.fill(Path(CGRect(origin:.zero,size:size)),with:.color(Color(red:0.92,green:0.87,blue:0.74)))
            // Deterministic paper grain, no bitmap or network dependency.
            for i in 0..<1000 {
                let x=CGFloat((i*7919)%10007)/10007*size.width, y=CGFloat((i*3571)%10009)/10009*size.height
                ctx.fill(Path(ellipseIn:CGRect(x:x,y:y,width:1.1,height:1.1)),with:.color(Ink.muted.opacity(0.09)))
            }
            // Graticule follows the active projection, so the China view is not skewed.
            let proj:(Double,Double)->CGPoint = china ? AtlasPaths.projectChina : AtlasPaths.project
            if china {
                for lon in stride(from:80,through:130,by:10) {
                    var line=Path()
                    for lat in stride(from:15,through:55,by:2) {
                        let p=proj(Double(lon),Double(lat)).applying(t.affine)
                        if lat == 15 { line.move(to:p) } else { line.addLine(to:p) }
                    }
                    ctx.stroke(line,with:.color(Ink.muted.opacity(0.13)),style:StrokeStyle(lineWidth:0.6,dash:[3,5]))
                }
                for lat in stride(from:20,through:50,by:10) {
                    var line=Path()
                    for lon in stride(from:70,through:140,by:2) {
                        let p=proj(Double(lon),Double(lat)).applying(t.affine)
                        if lon == 70 { line.move(to:p) } else { line.addLine(to:p) }
                    }
                    ctx.stroke(line,with:.color(Ink.muted.opacity(0.13)),style:StrokeStyle(lineWidth:0.6,dash:[3,5]))
                }
            } else {
                for lon in stride(from:-180,through:180,by:30) {
                    var line=Path()
                    for lat in stride(from:-80,through:80,by:4) {
                        let p=AtlasPaths.project(Double(lon),Double(lat)).applying(t.affine)
                        if lat == -80 { line.move(to:p) } else { line.addLine(to:p) }
                    }
                    ctx.stroke(line,with:.color(Ink.muted.opacity(0.13)),style:StrokeStyle(lineWidth:0.6,dash:[3,5]))
                }
                for lat in stride(from:-60,through:60,by:30) {
                    var line=Path(); line.move(to:proj(-180,Double(lat)).applying(t.affine)); line.addLine(to:proj(180,Double(lat)).applying(t.affine))
                    ctx.stroke(line,with:.color(Ink.muted.opacity(0.13)),style:StrokeStyle(lineWidth:0.6,dash:[3,5]))
                }
            }
            let shapes=china ? paths.china.filter{ !$0.region.cityID.isEmpty } : paths.world
            for shape in shapes {
                let lit=china ? filledCities.contains(shape.region.cityID) : filledCountries.contains(shape.region.countryID)
                let chosen=(selected == shape.region.cityID && !shape.region.cityID.isEmpty) || (!china && selectedCountry == shape.region.countryID)
                let path=shape.path.applying(t.affine)
                let count=cities.filter{ $0.countryID == shape.region.countryID }.count
                let base=Color(red:0.85,green:0.81,blue:0.69)
                ctx.fill(path,with:.color(lit ? Color(red:0.69,green:0.42,blue:0.23).opacity(min(0.55+Double(count)*0.025,0.86)) : base),style:FillStyle(eoFill:true))
                ctx.stroke(path,with:.color(chosen ? Ink.ochre : Ink.muted.opacity(0.5)),lineWidth:chosen ? 1.8 : 0.65)
            }
            if china {
                for shape in paths.china where shape.region.cityID.isEmpty {
                    ctx.stroke(shape.path.applying(t.affine),with:.color(Ink.text.opacity(0.48)),lineWidth:1.1)
                }
            }
            // One pin per visible collection unit, labels use collision suppression.
            // In China mode, far-south units (e.g. 三沙) live in the inset instead.
            var labelRects:[CGRect]=[]
            if let city = residentCity, !china || (city.countryID == "CHN" && (compactChina || city.latitude >= 17.8)) {
                let point = t.point(city)
                if point.x > -10 && point.x < size.width + 10 && point.y > -10 && point.y < size.height + 10 {
                    Self.drawResidentPin(&ctx, at: point, selected: city.id == selected)
                    // 先预留常驻标记及名称的位置，避免周围到访标签遮挡它。
                    labelRects.append(CGRect(x: point.x - 13, y: point.y - 20, width: 26, height: 30))
                    if showLabels {
                        let title = "\(city.name) · 常驻"
                        let width = CGFloat(title.count) * 11 + 10
                        let candidates = [CGRect(x: point.x + 15, y: point.y - 18, width: width, height: 20), CGRect(x: point.x - width - 15, y: point.y - 18, width: width, height: 20)]
                        if let rect = candidates.first(where: { CGRect(origin: .zero, size: size).contains($0) }) {
                            ctx.fill(Path(roundedRect: rect.insetBy(dx: -2, dy: 1), cornerRadius: 3), with: .color(Ink.panel.opacity(0.92)))
                            ctx.draw(Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(Ink.text), at: CGPoint(x: rect.minX, y: rect.midY), anchor: .leading)
                            labelRects.append(rect)
                        }
                    }
                }
            }
            for c in cities.sorted(by:{ a,b in a.id == selected ? true : b.id == selected ? false : a.id < b.id }) where c.id != residentCity?.id && (!china || (c.countryID == "CHN" && (compactChina || c.latitude >= 17.8))) {
                let p=t.point(c); guard p.x > -10 && p.x < size.width+10 && p.y > -10 && p.y < size.height+10 else { continue }
                ctx.fill(Path(ellipseIn:CGRect(x:p.x-5,y:p.y-4,width:12,height:12)),with:.color(.black.opacity(0.12)))
                ctx.fill(Path(ellipseIn:CGRect(x:p.x-4,y:p.y-6,width:8,height:8)),with:.color(Color(red:0.40,green:0.23,blue:0.12)))
                ctx.fill(Path(ellipseIn:CGRect(x:p.x-2,y:p.y-5,width:3,height:3)),with:.color(Color(red:0.95,green:0.78,blue:0.45)))
                let width=CGFloat(c.name.count)*11+10
                let candidates=[CGRect(x:p.x+9,y:p.y-10,width:width,height:20),CGRect(x:p.x-width-9,y:p.y-10,width:width,height:20),CGRect(x:p.x-width/2,y:p.y-29,width:width,height:20),CGRect(x:p.x-width/2,y:p.y+9,width:width,height:20)]
                if showLabels,let rect=candidates.first(where: { r in CGRect(origin:.zero,size:size).contains(r) && !labelRects.contains(where:{$0.insetBy(dx:-4,dy:-2).intersects(r)}) }) {
                    ctx.fill(Path(roundedRect:rect.insetBy(dx:-2,dy:1),cornerRadius:3),with:.color(Ink.panel.opacity(0.80)))
                    ctx.draw(Text(c.name).font(.system(size:10,weight:c.id==selected ? .bold : .medium)).foregroundColor(Ink.text),at:CGPoint(x:rect.minX,y:rect.midY),anchor:.leading);labelRects.append(rect)
                }
            }
            // South China Sea islands inset (bottom-left), standard practice for China maps.
            if china && !compactChina {
                let inset=AtlasCanvas.chinaInset(size:size)
                ctx.fill(Path(roundedRect:inset,cornerRadius:6),with:.color(Ink.panel.opacity(0.88)))
                ctx.stroke(Path(roundedRect:inset,cornerRadius:6),with:.color(Ink.muted.opacity(0.5)),lineWidth:0.8)
                let inner=inset.insetBy(dx:10,dy:14)
                let it=MapTransform(size:inner.size,bounds:paths.chinaSouthBounds,china:true,zoom:1,pan:.zero)
                let shift=CGAffineTransform(translationX:inner.minX,y:inner.minY)
                let iaffine=it.affine.concatenating(shift)
                var insetCtx=ctx
                insetCtx.clip(to:Path(roundedRect:inset,cornerRadius:6))
                for shape in paths.china {
                    let outlineOnly=shape.region.cityID.isEmpty
                    let lit = !outlineOnly && filledCities.contains(shape.region.cityID)
                    let path=shape.path.applying(iaffine)
                    insetCtx.fill(path,with:.color(lit ? Color(red:0.69,green:0.42,blue:0.23).opacity(0.75) : Color(red:0.85,green:0.81,blue:0.69)),style:FillStyle(eoFill:true))
                    insetCtx.stroke(path,with:.color(Ink.muted.opacity(outlineOnly ? 0.55 : 0.45)),lineWidth:outlineOnly ? 0.5 : 0.3)
                }
                for c in cities where c.id != residentCity?.id && c.countryID == "CHN" && c.latitude < 17.8 {
                    let p=AtlasPaths.projectChina(c.longitude,c.latitude).applying(iaffine)
                    guard inset.contains(p) else { continue }
                    insetCtx.fill(Path(ellipseIn:CGRect(x:p.x-2.4,y:p.y-3.2,width:4.8,height:4.8)),with:.color(Color(red:0.40,green:0.23,blue:0.12)))
                }
                if let city = residentCity, city.countryID == "CHN", city.latitude < 17.8 {
                    let point = AtlasPaths.projectChina(city.longitude, city.latitude).applying(iaffine)
                    if inset.contains(point) { Self.drawResidentPin(&insetCtx, at: point, selected: city.id == selected, scale: 0.65) }
                }
                ctx.draw(Text("南海诸岛").font(.system(size:7)).foregroundColor(Ink.muted),at:CGPoint(x:inset.minX+8,y:inset.maxY-9),anchor:.leading)
            }
            // Engraved compass in the ocean margin.
            let center=CGPoint(x:size.width-51,y:size.height-53)
            var cross=Path(); cross.move(to:CGPoint(x:center.x,y:center.y-24)); cross.addLine(to:CGPoint(x:center.x,y:center.y+24)); cross.move(to:CGPoint(x:center.x-24,y:center.y)); cross.addLine(to:CGPoint(x:center.x+24,y:center.y))
            ctx.stroke(cross,with:.color(Ink.muted.opacity(0.55)),lineWidth:0.8)
            ctx.stroke(Path(ellipseIn:CGRect(x:center.x-15,y:center.y-15,width:30,height:30)),with:.color(Ink.muted.opacity(0.55)),lineWidth:0.8)
            var north=Path(); north.move(to:CGPoint(x:center.x,y:center.y-22)); north.addLine(to:CGPoint(x:center.x-5,y:center.y+8)); north.addLine(to:CGPoint(x:center.x,y:center.y+4)); north.addLine(to:CGPoint(x:center.x+5,y:center.y+8)); north.closeSubpath()
            ctx.fill(north,with:.color(Ink.ochre.opacity(0.8)))
            ctx.draw(Text("N").font(.system(size:9,design:.serif)).foregroundColor(Ink.muted),at:CGPoint(x:center.x,y:center.y-33))
        }
        .accessibilityLabel(china ? "中国足迹地图" : "世界足迹地图")
        // 3.37④：每个已到访城市一个可聚焦热点（名称 + 状态），位置与画布图钉同一投影。
        .overlay {
            let t = MapTransform(size: geo.size,
                                 bounds: china ? (compactChina ? paths.chinaBounds : paths.chinaMainBounds) : paths.worldBounds,
                                 china: china, zoom: zoom, pan: pan)
            let accessibleCities = cities.filter { $0.id != residentCity?.id } + (residentCity.map { [$0] } ?? [])
            ForEach(accessibleCities.sorted(by: { $0.id < $1.id })) { city in
                let p = accessibilityPoint(city, transform: t, size: geo.size)
                if (!china || city.countryID == "CHN") && p.x > -10 && p.x < geo.size.width + 10 && p.y > -10 && p.y < geo.size.height + 10 {
                    Color.clear
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .position(p)
                        .accessibilityElement()
                        .accessibilityLabel(city.id == residentCity?.id ? tF("\(city.name)，常驻城市", "\(city.name), home city") : tF("\(city.name)，已到访", "\(city.name), visited"))
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .allowsHitTesting(false)
        }
        }
    }
    private func accessibilityPoint(_ city: City, transform: MapTransform, size: CGSize) -> CGPoint {
        guard china && !compactChina && city.latitude < 17.8 else { return transform.point(city) }
        let inner = Self.chinaInset(size: size).insetBy(dx: 10, dy: 14)
        let inset = MapTransform(size: inner.size, bounds: paths.chinaSouthBounds, china: true, zoom: 1, pan: .zero)
        return AtlasPaths.projectChina(city.longitude, city.latitude).applying(inset.affine.concatenating(CGAffineTransform(translationX: inner.minX, y: inner.minY)))
    }
}
struct MapPage: View {
    @EnvironmentObject var store: Store
    let paths: AtlasPaths
    @State private var china = true
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var selectedCountry: String?
    @State private var exporting = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment:.leading,spacing:17) {
            HStack(alignment:.top) {
                Heading(title:"走过的地方，都算数。",subtitle:"不赶路，不打卡。把记忆，一点一点留在地图上。")
                Spacer()
                Button { store.editor=EditorRequest() } label: { Label("点亮一个地方",systemImage:"plus") }.buttonStyle(.borderedProminent).controlSize(.large)
            }
            HStack(spacing:0) { StatItem(value:String(store.metrics.cities),label:"座城市"); StatItem(value:String(store.metrics.countries),label:"个国家 / 地区"); StatItem(value:"\(store.metrics.china) / \(store.chinaTotal)",label:"中国城市收集"); StatItem(value:String(store.metrics.continents.count),label:"个大洲 · 不含南极") }.padding(.vertical,8)
            HStack(spacing:12) {
                Picker("地图范围",selection:$china) { Text("中国").tag(true); Text("世界").tag(false) }.pickerStyle(.segmented).frame(width:160).onChange(of:china){ _, _ in reset(); selectedCountry=nil }
                HStack { Image(systemName:"magnifyingglass").foregroundStyle(.secondary); TextField("搜索城市、中英文或拼音",text:$store.search).textFieldStyle(.plain).focused($searchFocused); if !store.search.isEmpty { Button { store.search="" } label:{ Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain) } }.padding(9).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:8)).frame(maxWidth:290)
                Picker("年份",selection:$store.year) { Text("一生足迹").tag(0); ForEach(store.years,id:\.self){ Text(String($0)+" 年").tag($0) } }.labelsHidden().frame(width:115)
                if store.year != 0 || !store.tripFilter.isEmpty { Button("清除筛选"){ store.year=0; store.tripFilter="" }.font(.caption) }
                Spacer(minLength:0)
                Button { exporting=true } label:{ Image(systemName:"square.and.arrow.up") }.help("导出地图图片")
            }
            HStack(alignment:.top,spacing:16) {
                GeometryReader { geo in
                    ZStack(alignment:.topLeading) {
                        AtlasCanvas(paths:paths,china:china,cities:visibleCities,selected:store.selectedCity,selectedCountry:selectedCountry,zoom:zoom,pan:pan,residentCity:store.residentCity)
                            .gesture(DragGesture(minimumDistance:5).onChanged { value in pan=CGSize(width:dragStart.width+value.translation.width,height:dragStart.height+value.translation.height) }.onEnded { _ in dragStart=pan })
                            .simultaneousGesture(MagnificationGesture().onChanged { factor in zoom=min(max(baseZoom*factor,1),8) }.onEnded { _ in baseZoom=zoom })
                            .simultaneousGesture(SpatialTapGesture().onEnded { value in select(at:value.location,size:geo.size) })
                        VStack(alignment:.leading,spacing:4) { Text(china ? "神州行记" : "世界航海志").font(.system(size:20,weight:.regular,design:.serif)); Text(china ? "A PERSONAL ATLAS · CHINA" : "A PERSONAL ATLAS · WORLD").font(.system(size:8,design:.monospaced)).tracking(2) }.foregroundStyle(Ink.text.opacity(0.7)).padding(20).allowsHitTesting(false)
                        VStack { Spacer(); HStack(spacing:8) { Circle().fill(Ink.ochre).frame(width:6,height:6); Text("去过"); Circle().fill(Ink.muted.opacity(0.4)).frame(width:6,height:6); Text("尚未留下足迹"); if store.residentCity != nil { Image(systemName:"house.fill").foregroundStyle(Theme.teal); Text("常驻城市") }; Spacer() }.font(.system(size:9)).foregroundStyle(Ink.muted).padding(16) }.allowsHitTesting(false)
                        VStack { HStack { Spacer(); VStack(spacing:0) { Button { zoom=min(zoom*1.4,8); baseZoom=zoom } label:{ Image(systemName:"plus").frame(width:28,height:28) }; Divider(); Button { zoom=max(zoom/1.4,1); baseZoom=zoom } label:{ Image(systemName:"minus").frame(width:28,height:28) }; Divider(); Button { reset() } label:{ Image(systemName:"arrow.up.left.and.arrow.down.right").frame(width:28,height:28) } }.buttonStyle(.plain).frame(width:30).background(Ink.panel.opacity(0.92),in:RoundedRectangle(cornerRadius:7)).padding(.top,16).padding(.trailing,16) }; Spacer() }
                    }.clipShape(RoundedRectangle(cornerRadius:13)).overlay(RoundedRectangle(cornerRadius:13).stroke(Ink.line,lineWidth:1))
                }
                mapSide.frame(width:244)
            }.frame(maxHeight:.infinity)
            HStack { Image(systemName:"lock.shield"); Text("只属于你的地图 · 所有资料保存在这台 Mac"); Spacer(); Text("拖动平移 · 双指缩放 · 点击区域查看") }.font(.system(size:10)).foregroundStyle(.secondary)
        }.padding(28)
        .onChange(of:store.selectedCity) { _, id in if let id, let city=store.cityIndex[id] { let target=city.countryID == "CHN"; if china != target { china=target; reset() } } }
        .onChange(of:store.cityNavigationRevision) { _, _ in revealSelectedCity() }
        .onChange(of:store.widgetMapNavigationRevision) { _, _ in revealWidgetScope() }
        .onAppear { revealSelectedCity(); revealWidgetScope() }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocused=true }
        .sheet(isPresented:$exporting) { MapExport(paths:paths,china:china).environmentObject(store) }
    }
    var visibleCities: [City] { store.visitedIDs.compactMap{store.cityIndex[$0]} }
    @ViewBuilder var mapSide: some View {
        if !store.search.isEmpty || selectedCountry != nil {
            VStack(alignment:.leading,spacing:12) {
                HStack { Text(selectedCountry.flatMap{store.countries[$0]?.name} ?? "寻找一个地方").font(.headline); Spacer(); if selectedCountry != nil { Button { selectedCountry=nil } label:{ Image(systemName:"xmark") }.buttonStyle(.plain) } }
                ScrollView { LazyVStack(spacing:3) { ForEach(store.results(store.search,country:selectedCountry)) { city in
                    Button { store.selectedCity=city.id; selectedCountry=nil; store.search="" } label:{ HStack { VStack(alignment:.leading,spacing:3) { Text(city.name).font(.system(size:13)); Text(store.location(city)).font(.system(size:10)).foregroundStyle(.secondary) }; Spacer(); if store.allVisitedIDs.contains(city.id) { Image(systemName:"checkmark.seal.fill").foregroundStyle(Theme.teal) } }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:7)) }.buttonStyle(.plain)
                } } }
                Text("显示前 80 个结果，输入更多文字可缩小范围。").font(.caption2).foregroundStyle(.secondary)
                Button("找不到？添加海外地点") { store.customEditor=true }.font(.caption)
            }
        } else if let id=store.selectedCity, let city=store.cityIndex[id] {
            CityDetail(city:city)
        } else {
            VStack(alignment:.leading,spacing:18) {
                Text("田野笔记").font(.caption).foregroundStyle(.secondary)
                Text(store.journal.visits.isEmpty ? "第一颗图钉，\n留给哪里？" : "每颗图钉，\n都有一段故事。").font(.system(size:20,weight:.semibold)).lineSpacing(6)
                Text("可以是出发的城市，\n也可以是十年前的一次远行。\n记不清日期，也没关系。").font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(7)
                Divider()
                if store.journal.visits.isEmpty {
                    Button("写下第一个足迹") { store.editor=EditorRequest() }.buttonStyle(.bordered)
                } else {
                    Text("最近记下").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(store.journal.visits.sorted{$0.createdAt > $1.createdAt}.prefix(4))) { visit in
                        if let city=store.cityIndex[visit.cityID] { Button { store.selectedCity=city.id } label:{ HStack { Image(systemName:"mappin").foregroundStyle(Theme.teal); VStack(alignment:.leading,spacing:4){Text(city.name);Text(visit.date.label).font(.caption2).foregroundStyle(.secondary)};Spacer() } }.buttonStyle(.plain) }
                    }
                }
                Spacer()
                Text("“我们走过的路，\n最终成为我们的一部分。”").font(.system(size:12)).italic().foregroundStyle(.secondary).lineSpacing(6)
            }.padding(19).frame(maxHeight:.infinity).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:13)).overlay(RoundedRectangle(cornerRadius:13).stroke(Color.primary.opacity(0.07),lineWidth:1))
        }
    }
    func reset() { zoom=1; baseZoom=1; pan = .zero; dragStart = .zero }
    func revealWidgetScope() {
        guard let scope = store.widgetMapScope else { return }
        china = scope == "china"; selectedCountry = nil; reset()
        store.widgetMapScope = nil
    }
    func revealSelectedCity() {
        selectedCountry=nil
        guard let id=store.selectedCity, let city=store.cityIndex[id] else { return }
        china=city.countryID == "CHN"
        reset()
    }
    func select(at point: CGPoint,size: CGSize) {
        if china && AtlasCanvas.chinaInset(size:size).contains(point) {
            if let city = store.residentCity, city.countryID == "CHN", city.latitude < 17.8 {
                let inner = AtlasCanvas.chinaInset(size:size).insetBy(dx:10,dy:14)
                let inset = MapTransform(size:inner.size,bounds:paths.chinaSouthBounds,china:true,zoom:1,pan:.zero)
                let pin = inset.point(city).applying(CGAffineTransform(translationX:inner.minX,y:inner.minY))
                if hypot(pin.x-point.x,pin.y-point.y)<16 { store.selectedCity=city.id; selectedCountry=nil; store.search="" }
            }
            return
        }
        let t=MapTransform(size:size,bounds:china ? paths.chinaMainBounds : paths.worldBounds,china:china,zoom:zoom,pan:pan)
        if let city = store.residentCity, !china || (city.countryID == "CHN" && city.latitude >= 17.8), hypot(t.point(city).x-point.x,t.point(city).y-7-point.y)<18 { store.selectedCity=city.id; selectedCountry=nil; store.search=""; return }
        if let city=visibleCities.filter({!china || $0.countryID=="CHN"}).min(by:{hypot(t.point($0).x-point.x,t.point($0).y-point.y)<hypot(t.point($1).x-point.x,t.point($1).y-point.y)}), hypot(t.point(city).x-point.x,t.point(city).y-point.y)<12 { store.selectedCity=city.id; selectedCountry=nil; store.search=""; return }
        let p=t.inverse(point)
        if china, let shape=paths.china.last(where:{ !$0.region.cityID.isEmpty && $0.path.contains(p,eoFill:true) }) { store.selectedCity=shape.region.cityID; selectedCountry=nil; store.search="" }
        else if !china, let shape=paths.world.first(where:{ $0.path.contains(p,eoFill:true) }) { selectedCountry=shape.region.countryID; store.selectedCity=nil; store.search="" }
    }
}
struct MapExport: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let paths: AtlasPaths; let china: Bool
    @State var labels = false
    @State var name = false
    var preview: some View {
        VStack(spacing:0) {
            HStack { VStack(alignment:.leading,spacing:6) { Text("我的足迹 · \(china ? "神州行记" : "世界航海志")").font(.system(size:25,design:.serif)); Text("\(store.metrics.cities) 座城市 · \(store.metrics.countries) 个国家 / 地区\(store.year == 0 ? "" : " · \(store.year) 年")").font(.system(size:12)) }; Spacer(); if name && !store.ownerName.isEmpty { Text(store.ownerName).font(.system(size:16,design:.serif)) } }.padding(25)
            AtlasCanvas(paths:paths,china:china,cities:store.visitedIDs.compactMap{store.cityIndex[$0]},selected:nil,showLabels:labels,residentCity:store.residentCity)
            Text("搞足迹  /  THE ATLAS OF YOUR LIFE").font(.system(size:9,design:.monospaced)).tracking(3).padding(14)
        }.foregroundStyle(Ink.text).background(Ink.paper)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) { Text("导出这张地图").font(.title2); preview.frame(width:760,height:465).clipShape(RoundedRectangle(cornerRadius:8)); HStack { Toggle("显示城市名称",isOn:$labels); Toggle("显示个人铭牌",isOn:$name); Spacer(); Text("PNG · 2280 × 1395").font(.caption).foregroundStyle(Ink.muted) }; HStack { Button("取消"){dismiss()}; Spacer(); Button("保存 PNG") {
            let renderer=ImageRenderer(content:preview.frame(width:760,height:465)); renderer.scale=3
            guard let image=renderer.nsImage, let tiff=image.tiffRepresentation, let rep=NSBitmapImageRep(data:tiff), let png=rep.representation(using:.png,properties:[:]) else { store.error="图片生成失败。"; return }
            store.saveFile(name:"我的足迹.png",type:.png){png}
        }.buttonStyle(.borderedProminent).tint(Ink.ochre) } }.padding(24).background(Ink.paper)
    }
}
extension Notification.Name { static let focusSearch = Notification.Name("Rhythm.Footprints.focusSearch") }
