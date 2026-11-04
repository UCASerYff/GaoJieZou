import SwiftUI

struct ResidentCitySummary: View {
    @EnvironmentObject var store: Store
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(tF("常驻城市", "Home City"), systemImage: "house.fill")
                    .font(.caption).foregroundStyle(Theme.teal)
                Spacer()
                Button(store.residentCity == nil ? tF("设置", "Set") : tF("更换", "Change"), action: edit)
                    .buttonStyle(.link).font(.caption).disabled(!store.ready)
            }
            if let city = store.residentCity {
                Button {
                    store.showCity(city.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(city.name).font(.headline).foregroundStyle(.primary)
                        Text(store.location(city)).font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help(tF("查看城市档案", "View City Profile"))
            } else {
                Text(tF("在地图上标记日常生活的城市。", "Mark the city you call home on your map."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Theme.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ResidentCityEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?
    @State private var initialized = false
    @State private var saveError: String?

    private var suggestions: [City] {
        guard query.trimmed.isEmpty else { return store.results(query, limit: 100) }
        let familiar = ([store.residentCity].compactMap { $0 } + store.allVisitedIDs.compactMap { store.cityIndex[$0] })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var seen = Set<String>()
        return Array((familiar + store.results("", limit: 100)).filter { seen.insert($0.id).inserted }.prefix(100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading(title: tF("设置常驻城市", "Set Your Home City"),
                    subtitle: tF("给日常生活留一个坐标。", "A place for everyday life on your map."))
            Text(tF("可选择一个常驻城市，搬家后随时更换。常驻标记不增加到访次数、旅行统计或列车奖励；已有足迹始终保留。", "Choose one home city and change it whenever you move. The home marker does not add visits, travel statistics or train rewards; existing footprints are kept."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(tF("城市名 / 英文 / 拼音", "Name / English / Pinyin"), text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 4) {
                    if suggestions.isEmpty {
                        Text(tF("未找到城市，请尝试其他名称；海外地点可先在地图页添加。", "No cities found. Try another name, or add an overseas place from the map first."))
                            .font(.caption).foregroundStyle(.secondary).padding(20)
                    }
                    ForEach(suggestions) { city in
                        Button { selection = city.id; saveError = nil } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selection == city.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection == city.id ? Theme.teal : Color.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(city.name).font(.system(size: 13)).foregroundStyle(.primary)
                                    Text(store.location(city)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.journal.residentCityID == city.id {
                                    Label(tF("当前常驻", "Current home"), systemImage: "house.fill")
                                        .font(.caption2).foregroundStyle(Theme.teal)
                                }
                            }.padding(10).contentShape(Rectangle())
                                .background(selection == city.id ? Theme.teal.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: .infinity)
            if let selection, let city = store.cityIndex[selection] {
                Label(tF("已选：\(city.name)", "Selected: \(city.name)"), systemImage: "house.fill")
                    .font(.caption).foregroundStyle(Theme.teal)
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            HStack {
                if store.residentCity != nil {
                    Button(tF("清除常驻城市", "Clear Home City")) { save(nil) }.disabled(!store.ready)
                }
                Spacer()
                Button(tF("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tF("保存", "Save")) { save(selection) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || !store.ready)
            }
        }.padding(24).frame(width: 560, height: 620)
            .onAppear { if !initialized { selection = store.journal.residentCityID; initialized = true } }
    }

    private func save(_ cityID: String?) {
        if store.setResidentCity(cityID) { dismiss() }
        else { saveError = store.error }
    }
}
