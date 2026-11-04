import SwiftUI
import UniformTypeIdentifiers

struct VisitEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let request: EditorRequest
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var precision: DatePrecision = .unknown
    @State private var year = String(Calendar.current.component(.year,from:Date()))
    @State private var month = "1"
    @State private var day = "1"
    @State private var tripID = ""
    @State private var newTrip = ""
    @State private var note = ""
    @State private var photos: [String] = []
    @State private var staged: [Attachment] = []
    @State private var localError: String?
    @State private var initialized = false
    @State private var saved = false
    @State private var dirty = false
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Heading(title:request.visit == nil ? tF("记下这一次到访","Record This Visit") : tF("编辑这段足迹","Edit This Footprint")); Spacer(); Image(systemName:"mappin.and.ellipse").font(.system(size:28,weight:.light)).foregroundStyle(Theme.teal) }
            HStack(alignment:.top,spacing:22) {
                VStack(alignment:.leading,spacing:10) {
                    Text(request.visit == nil ? tF("选择城市 · 可多选","Choose cities · multiple allowed") : tF("选择城市","Choose a city")).font(.headline)
                    TextField(tF("城市名 / 英文 / 拼音","Name / English / Pinyin"),text:$query).textFieldStyle(.roundedBorder)
                    ScrollView { LazyVStack(spacing:3) { ForEach(store.results(query,limit:100)) { city in
                        Button {
                            dirty=true
                            if request.visit != nil { selected=[city.id] }
                            else if selected.contains(city.id) { selected.remove(city.id) } else { selected.insert(city.id) }
                        } label:{ HStack(alignment:.center) { Image(systemName:selected.contains(city.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(city.id) ? Theme.teal : Color.secondary.opacity(0.5)); VStack(alignment:.leading,spacing:3) { Text(city.name).font(.system(size:13)); Text(store.location(city)).font(.system(size:10)).foregroundStyle(.secondary) }; Spacer(); if store.allVisitedIDs.contains(city.id) { Text(tF("去过","Visited")).font(.system(size:9)).foregroundStyle(.green) } }.padding(8).background(selected.contains(city.id) ? Theme.teal.opacity(0.08) : Color.clear,in:RoundedRectangle(cornerRadius:6)) }.buttonStyle(.plain)
                    } } }.frame(height:300).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                    Text(tF("已选 \(selected.count) 个城市","\(selected.count) selected")).font(.caption).foregroundStyle(Theme.teal)
                    ScrollView(.horizontal) { HStack { ForEach(selected.sorted(),id:\.self) { id in Button { selected.remove(id); dirty=true } label:{ Label(store.cityIndex[id]?.name ?? id,systemImage:"xmark.circle").font(.caption) }.buttonStyle(.bordered) } } }.frame(height:32)
                }.frame(width:280)
                VStack(alignment:.leading,spacing:14) {
                    Text(tF("什么时候去过？","When were you there?")).font(.headline)
                    Picker(tF("日期精度","Date precision"),selection:$precision) { ForEach(DatePrecision.allCases) { Text($0.title).tag($0) } }.labelsHidden().onChange(of:precision){ _, _ in dirty=true }
                    if precision != .unknown {
                        HStack { TextField(tF("年","YYYY"),text:$year).frame(width:65); Text(tF("年","")); if precision != .year { TextField(tF("月","MM"),text:$month).frame(width:38); Text(tF("月","")) }; if precision == .day { TextField(tF("日","DD"),text:$day).frame(width:38); Text(tF("日","")) } }.textFieldStyle(.roundedBorder).font(.system(size:12))
                    } else { Text(tF("日期不必准确，回忆可以慢慢补全。","The date doesn't have to be exact; memories can be filled in later.")).font(.caption).foregroundStyle(.secondary) }
                    Picker(tF("归入旅行","Assign to trip"),selection:$tripID) { Text(tF("独立足迹","Standalone")).tag(""); ForEach(store.journal.trips) { Text($0.name).tag($0.id) }; Text(tF("＋ 新建旅行","＋ New Trip")).tag("new") }.onChange(of:tripID){ _, _ in dirty=true }
                    if tripID == "new" { TextField(tF("旅行名称，例如：2024 关西","Trip name, e.g. 2024 Kansai"),text:$newTrip).textFieldStyle(.roundedBorder) }
                    Text(tF("给回忆留一句话","Leave a line for the memory")).font(.headline)
                    TextEditor(text:$note).font(.system(size:13)).scrollContentBackground(.hidden).padding(6).frame(height:94).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.12))).onChange(of:note){ _, _ in if initialized { dirty=true } }
                    HStack { Text(tF("照片 \(photos.count) / 20","Photos \(photos.count) / 20")).font(.caption); Spacer(); Button(tF("添加照片","Add Photos")){ addPhotos() }.font(.caption) }
                    ScrollView(.horizontal) { HStack(spacing:8) { ForEach(photos,id:\.self) { id in VStack(spacing:4) { PhotoTile(url:photoURL(id),size:60); Button(tF("移除","Remove")){photos.removeAll{$0==id};dirty=true}.buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary) } } } }.frame(height:85)
                    Text(tF("照片复制到资料库，不读取定位信息。多城市保存时，共享此次笔记和照片。","Photos are copied into the library without reading location data. When saving multiple cities, they share this note and these photos.")).font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }.frame(width:330)
            }
            if let localError { Text(localError).foregroundStyle(.red).font(.caption).fixedSize(horizontal:false,vertical:true) }
            Divider()
            HStack { Button(tF("取消","Cancel")) { cancel() }.keyboardShortcut(.cancelAction); Spacer(); Text(tF("只有亲身到过的地方，才点亮。","Only places you've truly been to get lit up.")).font(.caption).foregroundStyle(.secondary); Button(request.visit == nil ? tF("保存足迹","Save Footprint") : tF("保存修改","Save Changes")) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selected.isEmpty || !store.ready) }
        }.padding(26).background(Color(nsColor:.windowBackgroundColor))
        .onAppear { guard !initialized else { return }; if let v=request.visit { selected=[v.cityID]; precision=v.date.precision; year=v.date.year.map(String.init) ?? year; month=v.date.month.map(String.init) ?? "1"; day=v.date.day.map(String.init) ?? "1"; tripID=v.tripID ?? ""; note=v.note; photos=v.photoIDs; query=store.cityIndex[v.cityID]?.name ?? "" } else { if let id=request.cityID { selected=[id]; query=store.cityIndex[id]?.name ?? "" }; tripID=request.tripID ?? "" }; initialized=true; dirty=false }
        .onDisappear { if !saved { store.discardStaged(staged) } }
        .onChange(of:year) { _, _ in if initialized { dirty=true } }
        .onChange(of:month) { _, _ in if initialized { dirty=true } }
        .onChange(of:day) { _, _ in if initialized { dirty=true } }
        .onChange(of:newTrip) { _, _ in if initialized { dirty=true } }
        .interactiveDismissDisabled()
    }
    func photoURL(_ id: String) -> URL? { staged.first{$0.id==id}.flatMap{store.repo?.photoURL($0)} ?? store.photoURL(id) }
    func cancel() {
        if dirty || !staged.isEmpty {
            let alert=NSAlert();alert.messageText=tF("放弃未保存的修改？","Discard unsaved changes?");alert.informativeText=tF("已保存的足迹不会受到影响。","Saved footprints will not be affected.");alert.addButton(withTitle:tF("放弃修改","Discard"));alert.addButton(withTitle:tF("继续编辑","Keep Editing"));if alert.runModal() != .alertFirstButtonReturn { return }
        }; dismiss()
    }
    func addPhotos() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.jpeg,.png,.heic];panel.allowsMultipleSelection=true;panel.canChooseDirectories=false
        guard panel.runModal() == .OK else { return }
        guard photos.count+panel.urls.count<=20 else {localError=tF("每条足迹最多 20 张照片。","Each footprint allows at most 20 photos.");return}
        var imported:[Attachment]=[]
        do { for url in panel.urls { imported.append(try store.importPhoto(url)) };staged += imported; photos += imported.map(\.id);dirty=true;localError=nil }
        catch {store.discardStaged(imported);localError=error.localizedDescription}
    }
    func save() {
        let date=VisitDate(precision:precision,year:precision == .unknown ? nil : Int(year),month:[.month,.day].contains(precision) ? Int(month) : nil,day:precision == .day ? Int(day) : nil)
        do { try date.validate() } catch {localError=error.localizedDescription;return}
        if tripID == "new" && newTrip.trimmed.isEmpty {localError=tF("请填写旅行名称。","Please enter a trip name.");return}
        var next=store.journal;var actualTrip=tripID.isEmpty ? nil : tripID
        if tripID == "new" {let t=Trip(name:newTrip.trimmed);next.trips.append(t);actualTrip=t.id}
        let duplicates=next.visits.filter{selected.contains($0.cityID) && $0.date == date && $0.tripID == actualTrip && $0.id != request.visit?.id}
        if !duplicates.isEmpty {let a=NSAlert();a.messageText=tF("有 \(duplicates.count) 条相似足迹","\(duplicates.count) similar footprint(s) found");a.informativeText=tF("相同城市、日期和旅行已有记录。确定仍要保存这次到访吗？","A record with the same city, date and trip already exists. Save this visit anyway?");a.addButton(withTitle:tF("仍然保存","Save Anyway"));a.addButton(withTitle:tF("返回检查","Go Back"));if a.runModal() != .alertFirstButtonReturn {return}}
        next.attachments += staged.filter{photos.contains($0.id)}
        if var v=request.visit, let id=selected.first {v.cityID=id;v.date=date;v.tripID=actualTrip;v.note=note.trimmed;v.photoIDs=photos;v.modifiedAt=Date();if let i=next.visits.firstIndex(where:{$0.id==v.id}){next.visits[i]=v}}
        else {for id in selected.sorted(){next.visits.append(Visit(cityID:id,date:date,tripID:actualTrip,note:note.trimmed,photoIDs:photos))}}
        if store.commit(next,message:request.visit == nil ? tF("已记下 \(selected.count) 个地方，足迹已保存","\(selected.count) place(s) recorded, footprint saved") : tF("足迹已更新","Footprint updated")) {store.discardStaged(staged.filter{!photos.contains($0.id)});saved=true;store.selectedCity=selected.sorted().first;dismiss()}
        else {localError=store.error}
    }
}
struct CityDetail: View {
    @EnvironmentObject var store: Store
    let city: City
    var visits:[Visit]{store.journal.visits.filter{$0.cityID==city.id}.sorted{$0.date.sortKey>$1.date.sortKey}}
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:16) {
            HStack { Text(tF("城市档案","City Profile")).font(.caption).foregroundStyle(.secondary); Spacer();Button{store.selectedCity=nil}label:{Image(systemName:"xmark")}.buttonStyle(.plain) }
            Text(city.name).font(.system(size:22,weight:.semibold)); Text(store.location(city)).font(.caption).foregroundStyle(.secondary)
            if !city.english.isEmpty {Text(city.english).font(.caption).foregroundStyle(.secondary)}
            Label(visits.isEmpty ? tF("还没有留下足迹","No footprints yet") : tF("已到访 \(visits.count) 次","Visited \(visits.count) time(s)"),systemImage:visits.isEmpty ? "mappin" : "checkmark.seal.fill").font(.caption).foregroundStyle(Theme.teal)
            if store.journal.residentCityID == city.id {
                Label(tF("常驻城市", "Home city"), systemImage: "house.fill").font(.caption).foregroundStyle(Theme.teal)
                Button(tF("清除常驻城市", "Clear Home City")) { store.setResidentCity(nil) }.disabled(!store.ready)
            } else {
                Button { store.setResidentCity(city.id) } label: {
                    Label(tF("设为常驻城市", "Set as Home City"), systemImage: "house")
                }.disabled(!store.ready)
            }
            Button(visits.isEmpty ? tF("我去过这里","I've Been Here") : tF("记录又一次到访","Record Another Visit")){store.editor=EditorRequest(cityID:city.id)}.buttonStyle(.borderedProminent)
            ForEach(visits){v in
                Divider();Text(v.date.label).font(.system(size:13,weight:.medium));if let tid=v.tripID,let trip=store.journal.trips.first(where:{$0.id==tid}){Text(trip.name).font(.caption).foregroundStyle(Theme.teal)}
                if !v.note.isEmpty{Text(v.note).font(.system(size:12)).lineSpacing(4).textSelection(.enabled)}
                if !v.photoIDs.isEmpty{ScrollView(.horizontal){HStack{ForEach(v.photoIDs,id:\.self){id in Button{if let url=store.photoURL(id){NSWorkspace.shared.open(url)}}label:{PhotoTile(url:store.photoURL(id),size:68)}.buttonStyle(.plain)}}}}
                HStack { Button(tF("编辑","Edit")){store.editor=EditorRequest(visit:v)};Spacer();Button(tF("删除","Delete")){store.alertDelete({store.remove(v)},title:tF("删除这条足迹？","Delete this footprint?"),detail:tF("若这是最后一次到访，该城市将熄灭。删除后可撤销。","If this is the last visit, the city will dim. Deletion can be undone."))}.foregroundStyle(.secondary) }.buttonStyle(.plain).font(.caption)
            }
        }.padding(18) }.frame(maxHeight:.infinity).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:13)).overlay(RoundedRectangle(cornerRadius:13).stroke(Color.primary.opacity(0.07)))
    }
}
struct TripEditor: View {
    @EnvironmentObject var store:Store
    @Environment(\.dismiss) var dismiss
    let trip:Trip
    @State var name=""
    @State var note=""
    var body:some View{VStack(alignment:.leading,spacing:20){Text(tF("旅行手记","Trip Journal")).font(.title2);TextField(tF("旅行名称","Trip name"),text:$name).textFieldStyle(.roundedBorder);Text(tF("旅行备注","Trip notes")).font(.caption);TextEditor(text:$note).frame(height:100);Text(tF("旅行日期由关联足迹自动汇总；不必为了创建旅行先填准确时间。","Trip dates are summarized automatically from linked footprints; no need to set exact dates first.")).font(.caption).foregroundStyle(.secondary);HStack{Button(tF("取消","Cancel")){dismiss()};Spacer();Button(tF("保存旅行","Save Trip")){var next=store.journal;var t=trip;t.name=name.trimmed;t.note=note.trimmed;if let i=next.trips.firstIndex(where:{$0.id==t.id}){next.trips[i]=t}else{next.trips.append(t)};if store.commit(next,message:tF("旅行已保存","Trip saved")){dismiss()}}.buttonStyle(.borderedProminent).disabled(name.trimmed.isEmpty)}}.padding(26).frame(width:430).background(Color(nsColor:.windowBackgroundColor)).onAppear{name=trip.name;note=trip.note}}
}
struct CustomCityEditor:View{
    @EnvironmentObject var store:Store
    @Environment(\.dismiss) var dismiss
    let paths:AtlasPaths
    @State var name=""
    @State var country="JPN"
    @State var province=""
    @State var lon=""
    @State var lat=""
    @State var error:String?
    var previewCity:[City]{if let x=Double(lon),let y=Double(lat){return [City(id:"preview",name:name,english:"",aliases:"",countryID:country,provinceID:"",province:province,continent:"",longitude:x,latitude:y,isCustom:true)]};return []}
    var body:some View{VStack(alignment:.leading,spacing:16){Text(tF("添加一个海外地点","Add an Overseas Place")).font(.title2);Text(tF("国内请搜索所属地级市；县区和景点不单独增加城市数。南极请在地区中选择南极洲。","For China, search for its prefecture-level city; districts and attractions don't add to the city count. For Antarctica, choose Antarctica in the region list.")).font(.caption).foregroundStyle(.secondary);HStack{TextField(tF("城市名称","City name"),text:$name);Picker(tF("国家 / 地区","Country / Region"),selection:$country){ForEach(store.geography.countries.filter{$0.id != "CHN"}.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}){Text($0.name).tag($0.id)}}}.textFieldStyle(.roundedBorder);TextField(tF("省 / 州（可选）","Province / State (optional)"),text:$province).textFieldStyle(.roundedBorder)
        GeometryReader{geo in AtlasCanvas(paths:paths,china:false,cities:previewCity,selected:nil).onTapGesture{p in let t=MapTransform(size:geo.size,bounds:paths.worldBounds,china:false,zoom:1,pan:.zero);let projected=t.inverse(p);var latitude = -projected.y;for _ in 0..<12{let py=AtlasPaths.project(0,latitude).y;let derivative=(AtlasPaths.project(0,latitude+0.001).y-py)/0.001;latitude -= (py-projected.y)/derivative};let factor=AtlasPaths.project(1,latitude).x;let longitude=projected.x/factor;if (-90...90).contains(latitude) && (-180...180).contains(longitude){lat=String(format:"%.4f",latitude);lon=String(format:"%.4f",longitude)}}}.frame(height:250).clipShape(RoundedRectangle(cornerRadius:10))
        HStack{Text(tF("经度","Longitude"));TextField("−180…180",text:$lon);Text(tF("纬度","Latitude"));TextField("−90…90",text:$lat)}.textFieldStyle(.roundedBorder);Text(tF("点击地图落点，或输入坐标；请核对地点所属国家 / 地区。","Tap the map to drop a pin, or enter coordinates; please verify the country / region of the place.")).font(.caption).foregroundStyle(.secondary)
        if let error{Text(error).foregroundStyle(.red).font(.caption)};HStack{Button(tF("取消","Cancel")){dismiss()};Spacer();Button(tF("保存地点","Save Place")){save()}.buttonStyle(.borderedProminent).disabled(name.trimmed.isEmpty)}}.padding(24).frame(width:660).background(Color(nsColor:.windowBackgroundColor))}
    func save(){guard let x=Double(lon),let y=Double(lat),x.isFinite,y.isFinite,(-180...180).contains(x),(-90...90).contains(y),let c=store.countries[country] else{error=tF("请在地图落点或填写有效经纬度。","Drop a pin on the map or enter valid coordinates.");return};if let existing=store.allCities.first(where:{$0.countryID==country && $0.name.searchKey==name.searchKey}){store.selectedCity=existing.id;store.toast=tF("已找到同名地点，请使用已有记录","Found an existing place with the same name; please use it");dismiss();return};let city=City(id:"custom-"+UUID().uuidString,name:name.trimmed,english:"",aliases:"",countryID:country,provinceID:"",province:province.trimmed,continent:c.continent,longitude:x,latitude:y,isCustom:true);var next=store.journal;next.customCities.append(city);if store.commit(next,message:tF("地点已添加，点击“我去过这里”记录到访","Place added — tap \"I've Been Here\" to record a visit")){store.selectedCity=city.id;store.search="";dismiss()}}
}
