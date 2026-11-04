import SwiftUI
import AppKit

struct TrainPage: View {
    @EnvironmentObject var store: Store
    @State private var selectedTripID = ""
    @State private var now = Date()

    private var train: TrainState { store.journal.train }
    private var visits: [Visit] {
        store.journal.visits.filter { selectedTripID.isEmpty || $0.tripID == selectedTripID }
            .sorted { a, b in
                if a.date.sortKey == b.date.sortKey { return a.createdAt < b.createdAt }
                if a.date.sortKey == 0 { return false }
                if b.date.sortKey == 0 { return true }
                return a.date.sortKey < b.date.sortKey
            }
    }
    private var stations: [(city: City, visits: [Visit])] {
        let grouped = Dictionary(grouping: visits, by: \.cityID)
        var seen = Set<String>()
        return visits.compactMap { visit in
            guard seen.insert(visit.cityID).inserted, let city = store.cityIndex[visit.cityID] else { return nil }
            return (city, grouped[visit.cityID] ?? [])
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack {
                    Heading(title: tF("旅行列车", "Travel Train"), subtitle: tF("真实足迹铺成线路，旅途回忆装满车厢。", "Real visits become routes; memories fill the carriages."))
                    Spacer()
                    Label("\(train.materials) " + tF("旅途物资", "supplies"), systemImage: "shippingbox.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(Theme.teal)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(Theme.teal.opacity(0.1), in: Capsule())
                }
                TrainWorldScene(train:train,visitedCityCount:store.allVisitedIDs.count,
                                cities:store.allVisitedIDs.compactMap { store.cityIndex[$0] }.sorted { $0.name < $1.name })
                HStack(alignment: .top, spacing: 16) {
                    cruisePanel.frame(maxWidth: .infinity)
                    progressPanel.frame(maxWidth: .infinity)
                }
                routePanel
                HStack { Text(tF("列车改装", "Upgrade your train")).font(.title3.weight(.semibold)); Spacer(); Text(tF("每节车厢可升至 4 级", "Each car has 4 levels")).font(.caption).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 265), spacing: 15)], spacing: 15) {
                    ForEach(TrainCarriage.allCases) { carriage in carriageCard(carriage) }
                }
                memoryPanel
                Text(tF("虚拟巡游只在已到访城市间行驶，不会新增足迹；补录旧旅行、照片和回忆同样会获得建设物资。", "Virtual cruises only visit recorded cities and never create footprints. Past trips, photos and notes earn supplies too."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 1300).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { store.syncTrain() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private var cruisePanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 11) {
                Label(tF("虚拟巡游", "Virtual cruise"), systemImage: "tram.fill").font(.headline)
                Text(tF("当前位置：", "Current station: ")+(train.currentStation?.name ?? "—")).font(.callout)
                Text(tF("选择已到访的另一座城市，列车将持续行驶，并在地图上同步推进。到站后领取物资，用于建造和升级车厢。", "Choose another recorded city. Follow the train and its map progress; arrival supplies build and upgrade carriages.")).font(.caption).foregroundStyle(.secondary)
                Text(tF("自由观光不限次数；奖励航次有间隔，卧铺车缩短奖励间隔，餐车增加奖励。", "Sleeper cars reduce departure cooldown; dining cars increase arrival supplies.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var progressPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 11) {
                Label(tF("旅途图鉴", "Travel collection"), systemImage: "ticket.fill").font(.headline)
                HStack {
                    trainMetric("mappin.circle.fill", "\(store.allVisitedIDs.count)", tF("车站", "stations"))
                    trainMetric("suitcase.rolling.fill", "\(train.claimedTripIDs.count)", tF("旅行册", "trips"))
                    trainMetric("photo.fill", "\(train.claimedPhotoIDs.count)", tF("照片", "photos"))
                    trainMetric("text.book.closed.fill", "\(train.claimedNoteIDs.count)", tF("回忆", "notes"))
                }
                Text(tF("累计获得 \(train.lifetimeMaterials) 份物资 · 巡游 \(train.cruiseCount) 次", "\(train.lifetimeMaterials) supplies earned · \(train.cruiseCount) cruises"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func trainMetric(_ symbol: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 4) { Image(systemName: symbol).foregroundStyle(Theme.teal); Text(value).font(.title3.weight(.semibold)); Text(label).font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
    }
    private var routePanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading) { Text(tF("沿途车站", "Stations on the route")).font(.headline); Text(tF("来自你的真实到访记录", "From recorded visits")).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Picker(tF("线路", "Route"), selection: $selectedTripID) {
                        Text(tF("全部足迹", "All visits")).tag("")
                        ForEach(store.journal.trips) { trip in Text(trip.name).tag(trip.id) }
                    }.frame(width: 180)
                }
                if stations.isEmpty {
                    Text(tF("添加第一条足迹后，列车就有第一座车站。", "Add a footprint to unlock your first station.")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 16)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(stations, id: \.city.id) { item in stationView(item.city, visits: item.visits) }
                        }.padding(.vertical, 7)
                    }
                }
            }
        }
    }
    private func stationView(_ city: City, visits: [Visit]) -> some View {
        let stage = min(3, visits.count)
        return VStack(spacing: 7) {
            Image(systemName: stage == 1 ? "mappin.circle.fill" : stage == 2 ? "building.2.fill" : "building.2.crop.circle.fill")
                .font(.system(size: 25)).foregroundStyle(Theme.teal)
                .frame(width: 55, height: 55).background(Theme.teal.opacity(0.12), in: Circle())
            Text(city.name).font(.callout.weight(.semibold)).lineLimit(1)
            Text(tF("\(visits.count) 次到访 · \(stage) 级站", "\(visits.count) visits · level \(stage)"))
                .font(.caption2).foregroundStyle(.secondary)
        }.frame(width: 140).contentShape(Rectangle()).onTapGesture {
            store.section = "地图"; store.selectedCity = city.id
        }.accessibilityAddTraits(.isButton)
        .overlay(alignment: .topTrailing) { if city.id != stations.last?.city.id { Rectangle().fill(Theme.teal.opacity(0.35)).frame(width: 36, height: 2).offset(x: 18, y: 26) } }
    }
    private func carriageCard(_ carriage: TrainCarriage) -> some View {
        let level = TrainEngine.level(carriage, in: train)
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Tile(symbol: carriage.symbol, color: level > 0 ? Theme.teal : .secondary)
                    VStack(alignment: .leading) { Text(carriage.name).font(.headline); Text(tF("等级 \(level) / 4", "Level \(level) / 4")).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }
                ProgressView(value: Double(level), total: 4).tint(Theme.teal)
                Text(carriage.effect).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(level == 4 ? tF("已满级", "Max level") : tF("需要 \(carriage.cost(for: level + 1)) 份物资", "Needs \(carriage.cost(for: level + 1)) supplies"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(level == 0 ? tF("建造", "Build") : tF("升级", "Upgrade")) { store.upgradeTrain(carriage) }
                        .disabled(level == 4 || train.materials < carriage.cost(for: level + 1))
                }
            }
        }
    }
    private var memoryPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Text(tF("车厢里的回忆", "Memories on board")).font(.headline)
                let photos = visits.flatMap(\.photoIDs).uniqued().prefix(8)
                if photos.isEmpty {
                    Text(tF("在足迹中添加照片，这里就会出现旅行照片墙。", "Attach photos to visits to fill the carriage photo wall."))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        ForEach(Array(photos), id: \.self) { id in
                            if let url = store.photoURL(id) {
                                Button { NSWorkspace.shared.open(url) } label: { PhotoTile(url: url, size: 86) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
