import SwiftUI
import SceneKit
import Combine

struct TrainWorldScene: View {
    @EnvironmentObject private var store: Store
    let train: TrainState
    let visitedCityCount: Int
    let cities: [City]
    @AppStorage("gqns.train.autoTour", store: FootprintsBundle.defaults) private var autoTour=false
    @State private var selectedID: String?
    private let yaw = 34.0
    @State private var mapMode = false
    @State private var showInterior = false
    @State private var clockNow = Date()
    private let clock = Timer.publish(every:1,on:.main,in:.common).autoconnect()
    private var order: [TrainCarriage] {
        var result = train.carriageOrder.compactMap(TrainCarriage.init(rawValue:))
        for carriage in TrainCarriage.allCases where TrainEngine.level(carriage,in:train)>0 && !result.contains(carriage) {
            result.append(carriage)
        }
        return result.filter { TrainEngine.level($0,in:train)>0 }
    }
    private var items: [GQWorldItem] {
        [GQWorldItem(id:"__world",title:"",kind:"__world",level:routeStage,x:0,z:0,movable:false),
         GQWorldItem(id:"engine",title:tF("车头","Locomotive"),kind:"engine",level:1,x:-5.5,z:0,movable:false)] +
        order.enumerated().map { index,carriage in
            GQWorldItem(id:carriage.rawValue,title:carriage.name,kind:carriage.rawValue,
                        level:TrainEngine.level(carriage,in:train),x:Double(index)*2.25-3.25,z:0,movable:false)
        } + TrainCarriage.allCases.filter { TrainEngine.level($0,in:train)==0 && !travelling }.enumerated().map { index,carriage in
            GQWorldItem(id:"ghost:\(carriage.rawValue)",title:carriage.name,kind:"ghost",
                        level:0,x:Double(order.count+index)*2.25-3.1,z:0,movable:false)
        }
    }
    private var routeStage: Int {
        guard let city=cities.first(where:{ $0.id == train.routeCityID }) else { return 0 }
        return abs(city.latitude)>45 ? 2 : abs(city.latitude)<22 ? 1 : 0
    }
    private var selectedCarriage: TrainCarriage? { selectedID.flatMap(TrainCarriage.init(rawValue:)) }
    private var selectedBlueprint: TrainCarriage? {
        guard let selectedID, selectedID.hasPrefix("ghost:") else { return nil }
        return TrainCarriage(rawValue:String(selectedID.dropFirst(6)))
    }
    private var ready: Bool {
        train.journey?.completed != false && !train.routeCityID.isEmpty && train.routeCityID != train.currentStation?.id
    }
    private var travelling:Bool { train.journey.map { !$0.completed && (!overviewOnly || clockNow < $0.arrivesAt) } ?? false }
    private var shownJourney:TrainJourney? { travelling ? train.journey : nil }
    private var origin:City? { shownJourney?.origin ?? train.currentStation }
    private var destination:City? { shownJourney?.destination ?? cities.first { $0.id==train.routeCityID } }
    private var mapTitle:String {
        if let a=origin,let b=destination,a.countryID==b.countryID { return store.countryName(a)+tF("地图"," map") }
        return tF("世界地图","World map")
    }
    var overviewOnly = false
    @ViewBuilder var body: some View {
        if overviewOnly {
            GQWorldScene(mode:"train",items:items,selectedID:nil,yaw:yaw,zoom:8.5,trainTravelling:travelling,observationOnly:true,onSelect:{_ in},onMove:{_,_,_ in}).onReceive(clock) { clockNow=$0 }
        } else { interactiveBody }
    }
    private var interactiveBody: some View {
        ZStack {
            if mapMode {
                TrainRouteMap(geography:store.geography,origin:origin,destination:destination,journey:shownJourney,now:clockNow)
                    .padding(.top,76).padding(.bottom,115).background(Color(red:0.07,green:0.17,blue:0.23))
            } else {
                GQWorldScene(mode:"train",items:items,selectedID:selectedID,yaw:yaw,zoom:8.5,
                             trainTravelling:travelling,onSelect:{ selectedID=$0 },onMove:{ _,_,_ in })
            }
            VStack {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:5) {
                        Text(tF("旅行列车","TRAVEL TRAIN")).font(.system(size:12,weight:.bold,design:.monospaced)).tracking(2)
                        Text(mapMode ? mapTitle : (travelling ? tF("列车行驶中","On the move") : tF("列车停靠中","At the station"))).font(.title2.weight(.bold))
                        Text(mapMode ? tF(travelling ? "正在行驶 · 地图同步当前位置" : "计划路线 · 等待发车",travelling ? "Live route progress" : "Planned route · ready to depart") : tF("整列连挂 · 点击车厢查看内部","Coupled train · click cars to look inside"))
                            .font(.caption).foregroundStyle(.white.opacity(0.84))
                    }.foregroundStyle(.white).shadow(color:.black,radius:8)
                    Spacer()
                    Picker(tF("视图","View"),selection:$mapMode) {
                        Text(tF("列车视图","Train")).tag(false)
                        Text(tF("地图行程","Route map")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width:210).padding(5).background(Color(nsColor:.controlBackgroundColor).opacity(0.96),in:RoundedRectangle(cornerRadius:10))
                }.buttonStyle(.bordered).padding(18)
                Spacer()
                if !mapMode, let carriage=selectedCarriage {
                    let level=TrainEngine.level(carriage,in:train)
                    HStack(spacing:10) {
                        Label(carriage.name + " · Lv.\(level)",systemImage:carriage.symbol)
                        Spacer()
                        Button(tF("查看内部","Interior")) { showInterior=true }
                        Button(level>=4 ? tF("已满级","Max level") : tF("升级 · \(carriage.cost(for:level+1)) 物资","Upgrade · \(carriage.cost(for:level+1)) supplies")) { store.upgradeTrain(carriage) }
                            .disabled(level>=4 || train.materials<carriage.cost(for:level+1))
                    }.font(.callout.weight(.semibold)).padding(12)
                        .background(Color(nsColor:.controlBackgroundColor).opacity(0.96),in:RoundedRectangle(cornerRadius:14))
                        .padding(.horizontal,15).padding(.bottom,8)
                }
                if !mapMode, let carriage=selectedBlueprint {
                    HStack(spacing:10) {
                        Label(carriage.name + " · " + tF("施工蓝图","Blueprint"),systemImage:carriage.symbol)
                        Spacer()
                        Text("\(carriage.cost(for:1)) " + tF("旅途物资","supplies"))
                        Button(tF("建造","Build")) {
                            store.upgradeTrain(carriage)
                            selectedID=carriage.rawValue
                        }.disabled(train.materials<carriage.cost(for:1))
                    }.font(.callout.weight(.semibold)).padding(12)
                        .background(Color(nsColor:.controlBackgroundColor).opacity(0.96),in:RoundedRectangle(cornerRadius:14))
                        .padding(.horizontal,15).padding(.bottom,8)
                }
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        Text((origin?.name ?? tF("未设车站","No station"))+" → "+(destination?.name ?? tF("请选择目的地","Choose a destination"))).font(.callout.weight(.semibold))
                        Spacer()
                        if let j=shownJourney {
                            Text("\(Int(j.progress(at:clockNow)*100))%").monospacedDigit()
                            Text(j.arrivesAt,style:.timer).monospacedDigit()
                            Text(j.reward == 0 ? tF("自由观光 · 不消耗物资","Sightseeing · no supply cost") : tF("到站 +\(j.reward) 物资","Arrival +\(j.reward) supplies"))
                        } else if let j=train.journey,j.completed {
                            Text(tF("已抵达 \(j.destination.name) · 物资已结算","Arrived at \(j.destination.name) · supplies settled"))
                        }
                    }
                    if let j=shownJourney { ProgressView(value:j.progress(at:clockNow)).tint(.teal) }
                    else { Text(tF("虚拟行程约 2–10 分钟；离线继续推进，不新增真实足迹","Virtual journeys take 2–10 minutes and continue offline; no real visits are added")).font(.caption2).foregroundStyle(.secondary) }
                }.font(.caption).padding(12).background(Color(nsColor:.controlBackgroundColor).opacity(0.96),in:RoundedRectangle(cornerRadius:12)).padding(.horizontal,15)
                HStack(spacing:9) {
                    Menu {
                        ForEach(TrainCarriage.allCases) { carriage in
                            let level=TrainEngine.level(carriage,in:train)
                            Button(carriage.name + " · \(level)/4") {
                                store.upgradeTrain(carriage); selectedID=carriage.rawValue
                            }.disabled(level>=4 || train.materials<carriage.cost(for:level+1))
                        }
                    } label:{ Label(tF("建造车厢","Build cars"),systemImage:"hammer.fill") }
                    Picker(tF("目的地","Destination"),selection:Binding(
                        get:{ train.routeCityID },set:{ store.setTrainRoute($0) })) {
                            Text(tF("选择目的地","Choose destination")).tag("")
                            ForEach(cities.filter { $0.id != train.currentStation?.id }) { city in Text(city.name).tag(city.id) }
                        }.frame(width:190).disabled(travelling)
                    Button { _ = store.cruiseTrain();clockNow=Date() } label:{ Label(tF("列车出发","Depart"),systemImage:"tram.fill") }
                        .disabled(!ready)
                    if !travelling, let next=TrainEngine.nextCruise(at:clockNow,state:train), next>clockNow {
                        Text(next,style:.timer).monospacedDigit().help(tF("距下次奖励；现在仍可自由观光","Until next reward; sightseeing remains available"))
                    }
                    Toggle(tF("连续观光","Auto tour"),isOn:$autoTour).toggleStyle(.switch).controlSize(.mini)
                    Spacer()
                    Label("\(visitedCityCount)",systemImage:"mappin.circle.fill")
                    Label("\(train.materials)",systemImage:"shippingbox.fill")
                }.font(.caption.weight(.semibold)).buttonStyle(.bordered)
                    .padding(12).background(Color(nsColor:.controlBackgroundColor).opacity(0.96),in:RoundedRectangle(cornerRadius:15))
                    .padding([.horizontal,.bottom],15)
            }
        }.frame(height:510).clipShape(RoundedRectangle(cornerRadius:22))
            .onReceive(clock) { clockNow=$0;if let j=train.journey,!j.completed,$0>=j.arrivesAt { store.syncTrain();if autoTour { _ = store.cruiseTrain() } } }
            .sheet(isPresented:$showInterior) {
                if let carriage=selectedCarriage {
                    CarriageInterior(carriage:carriage,level:TrainEngine.level(carriage,in:train))
                        .environmentObject(store)
                }
            }
    }
}

private struct CarriageInterior: View {
    @EnvironmentObject private var store: Store
    let carriage: TrainCarriage
    let level: Int
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Label(carriage.name + " · Lv.\(level)",systemImage:carriage.symbol).font(.title2.weight(.bold))
                Spacer()
                Button(tF("关闭","Close")) { dismiss() }
            }
            GQWorldScene(mode:"interior",items:[GQWorldItem(id:carriage.rawValue,title:carriage.name,
                           kind:carriage.rawValue,level:level,x:0,z:0,movable:false)],
                           selectedID:nil,yaw:30,zoom:6.8,onSelect:{ _ in },onMove:{ _,_,_ in })
                .frame(height:310).clipShape(RoundedRectangle(cornerRadius:20))
            Text(carriage.effect).font(.callout).foregroundStyle(.secondary)
            let photos=store.journal.visits.flatMap(\.photoIDs).prefix(5)
            if !photos.isEmpty {
                HStack(spacing:9) {
                    ForEach(Array(photos),id:\.self) { id in
                        if let url=store.photoURL(id) {
                            Button { NSWorkspace.shared.open(url) } label:{ PhotoTile(url:url,size:82) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }.padding(24).frame(width:620)
    }
}
