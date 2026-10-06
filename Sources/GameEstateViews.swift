import AppKit
import SwiftUI
import Combine

// MARK: - Shared game-scene rendering

private enum GameAsset {
    static func image(_ name: String) -> NSImage? {
        guard let path = RhythmBundle.bundle.path(forResource: name, ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }
}

struct AtlasSprite: View {
    let asset: String
    let index: Int
    let columns: Int
    let rows: Int

    var body: some View {
        GeometryReader { proxy in
            if let image = GameAsset.image(asset) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: proxy.size.width * CGFloat(columns),
                        height: proxy.size.height * CGFloat(rows)
                    )
                    .offset(
                        x: -CGFloat(index % columns) * proxy.size.width,
                        y: -CGFloat(index / columns) * proxy.size.height
                    )
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct FishSprite: View {
    let fishID: String

    var body: some View {
        Group {
            if let image = GameAsset.image("Fish-\(fishID)-V15") {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "fish.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 装饰贴图：按 DecorationSprite 复用现有作物/动物图集格子或鱼类独立贴图。
struct DecorationArtwork: View {
    let sprite: DecorationSprite

    var body: some View {
        switch sprite {
        case .crop(let index):
            AtlasSprite(asset: "CropAtlasV15", index: index, columns: 6, rows: 4)
        case .animal(let index):
            AtlasSprite(asset: "AnimalAtlasV23", index: index, columns: 6, rows: 4)
        case .fish(let fishID):
            FishSprite(fishID: fishID)
        }
    }
}

private struct GameCanvas<Overlay: View>: View {
    let background: String
    var world: AnyView? = nil
    @ViewBuilder let overlay: (CGSize) -> Overlay

    var body: some View {
        GeometryReader { proxy in
            let ratio = CGFloat(1672.0 / 941.0)
            let width = min(proxy.size.width, proxy.size.height * ratio)
            let height = width / ratio

            ZStack {
                if let world {
                    world.frame(width: width, height: height)
                } else if let image = GameAsset.image(background) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(RhythmTheme.green.opacity(0.16))
                }
                overlay(CGSize(width: width, height: height))
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.38), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}

private struct GameHUDChip: View {
    let symbol: String
    let text: String
    var tint: Color = .white

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.22)))
    }
}

private struct GameToolButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 34, height: 26)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(RhythmTheme.orange, in: Capsule())
                            .offset(x: 10, y: -6)
                    }
                }
                Text(RhythmLocalization.text(title))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(minWidth: 62)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                selected ? AnyShapeStyle(RhythmTheme.orange.gradient) : AnyShapeStyle(.ultraThinMaterial),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(selected ? .white.opacity(0.45) : .white.opacity(0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(RhythmLocalization.text(title))
    }
}

private struct GameMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.black.opacity(0.5), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.25)))
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct FarmBedSurface: View {
    let selected: Bool
    let locked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    locked
                        ? Color(red: 0.33, green: 0.29, blue: 0.19).opacity(0.46)
                        : Color(red: 0.43, green: 0.24, blue: 0.12)
                )

            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(locked ? Color.white.opacity(0.08) : Color.black.opacity(0.15))
                        .frame(height: 3)
                }
            }
            .padding(.horizontal, 13)

            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(
                    selected ? Color(red: 1, green: 0.86, blue: 0.37) : Color.white.opacity(locked ? 0.18 : 0.34),
                    lineWidth: selected ? 3 : 1.2
                )
        }
        .shadow(color: .black.opacity(locked ? 0.08 : 0.23), radius: 4, y: 4)
    }
}

// MARK: - Farm game

private enum FarmTool: String, CaseIterable {
    case inspect
    case seed
    case water
    case fertilize
    case harvest
}

struct FarmGameView: View {
    @EnvironmentObject private var store: RhythmStore
    @State private var tool: FarmTool = .inspect
    @State private var selectedPlotID: String?
    @State private var showingSeeds = false
    @State private var showingDecorations = false
    @State private var message: String?
    @State private var worldYaw = 0.0
    @State private var worldZoom = 7.6

    private var worldItems: [GQWorldItem] {
        let season = (Calendar.current.component(.month, from: .now) + 9) % 12 / 3
        return [GQWorldItem(id: "season", title: "", kind: "__world", level: season, x: 0, z: 0, movable: false)]
            + (0..<25).map { index in
                let x = Double(index % 5 - 2) * 2.12
                let z = Double(index / 5 - 2) * 2.45
                guard index < store.farmPlots.count else {
                    return GQWorldItem(id: "plot:\(index)", title: index == store.farmPlots.count ? "开垦" : "", kind: index == store.farmPlots.count ? "unlock" : "locked", level: 0, x: x, z: z, movable: false,
                        status: index == store.farmPlots.count ? RhythmLocalization.format("%d 金币", store.nextPlotCost) : "")
                }
                let plot = store.farmPlots[index]
                let crop = RhythmCatalog.crop(plot.cropID)
                let progress = crop.map { plot.growthMinutes / max(1, $0.growthMinutes) } ?? 0
                return GQWorldItem(id: "plot:\(index)", title: crop?.displayName ?? "", kind: crop.map { "crop:\($0.id)" } ?? "plot", level: crop == nil ? 0 : min(3, max(1, Int(progress * 3) + 1)), x: x, z: z, movable: false, progress: crop == nil ? nil : progress, status: progress >= 1 ? "可收获" : "生长 \(Int(min(1, progress) * 100))%")
            }
    }

    var overviewOnly = false
    @ViewBuilder var body: some View {
        if overviewOnly {
            GQWorldScene(mode:"farm",items:worldItems,selectedID:nil,yaw:worldYaw,zoom:worldZoom,observationOnly:true,onSelect:{_ in},onMove:{_,_,_ in})
        } else { interactiveBody }
    }
    private var interactiveBody: some View {
        GameCanvas(background: "FarmGameSceneV15", world: AnyView(
            GQWorldScene(mode: "farm", items: worldItems, selectedID: selectedPlotID.flatMap { id in
                store.farmPlots.firstIndex(where: { $0.id == id }).map { "plot:\($0)" }
            }, yaw: worldYaw, zoom: worldZoom, onSelect: { id in
                guard let id, id.hasPrefix("plot:"), let index = Int(id.dropFirst(5)) else { return }
                if index < store.farmPlots.count { handlePlot(index: index) }
                else if index == store.farmPlots.count {
                    switch store.buyFarmPlot() {
                    case .success: showMessage(RhythmLocalization.text("新农田已经开垦"))
                    case .insufficientFunds: showMessage(RhythmLocalization.text("金币不足，暂时无法开垦"))
                    case .capacityFull: showMessage(RhythmLocalization.text("农田数量已达上限"))
                    case .unavailable: showMessage(RhythmLocalization.text("当前无法执行这个操作"))
                    }
                }
            }, onMove: { _, _, _ in })
        )) { size in
            ZStack {
                decorationStrip(size: size)
                farmHUD(size: size)
                farmToolbar(size: size)
                if showingSeeds, let selectedPlotID {
                    seedDrawer(plotID: selectedPlotID, size: size)
                        .zIndex(10)
                }
                if showingDecorations {
                    decorationShop(size: size)
                        .zIndex(10)
                }
                if let message {
                    GameMessage(text: message)
                        .position(x: size.width / 2, y: 28)
                        .zIndex(20)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private func plotLayer(size: CGSize) -> some View {
        let tileWidth = min(90.0, size.width * 0.086)
        let tileHeight = tileWidth * 0.58
        let columnSpacing = size.width * 0.105
        let rowSpacing = size.height * 0.105
        ForEach(0..<25, id: \.self) { index in
            let row = index / 5
            let column = index % 5
            let x = size.width * 0.5 + (CGFloat(column) - 2) * columnSpacing
            let y = size.height * 0.30 + CGFloat(row) * rowSpacing

            if index < store.farmPlots.count {
                FarmPlotNode(
                    plot: store.farmPlots[index],
                    cropIndex: cropIndex(for: store.farmPlots[index].cropID),
                    selected: selectedPlotID == store.farmPlots[index].id,
                    width: tileWidth,
                    height: tileHeight
                ) {
                    handlePlot(index: index)
                }
                .position(x: x, y: y)
            } else {
                LockedFarmPlotNode(
                    cost: index == store.farmPlots.count ? store.nextPlotCost : nil,
                    width: tileWidth,
                    height: tileHeight
                ) {
                    guard index == store.farmPlots.count else { return }
                    switch store.buyFarmPlot() {
                    case .success:
                        showMessage(RhythmLocalization.text("新农田已经开垦"))
                    case .insufficientFunds:
                        showMessage(RhythmLocalization.text("金币不足，暂时无法开垦"))
                    case .capacityFull:
                        showMessage(RhythmLocalization.text("农田数量已达上限"))
                    case .unavailable:
                        showMessage(RhythmLocalization.text("当前无法执行这个操作"))
                    }
                }
                .position(x: x, y: y)
            }
        }
    }

    @ViewBuilder
    private func farmHUD(size: CGSize) -> some View {
        HStack(spacing: 8) {
            GameHUDChip(symbol: "circle.fill", text: "\(store.coins)", tint: Color(red: 1, green: 0.78, blue: 0.3))
            GameHUDChip(symbol: "square.grid.3x3.fill", text: "\(store.farmPlots.count)/25")
            GameHUDChip(symbol: "hammer.fill", text: store.farmPlots.count < 25
                ? RhythmLocalization.format("开垦农田 %d 金币", store.nextPlotCost)
                : RhythmLocalization.text("农田数量已达上限"))
            Spacer()
            GameHUDChip(
                symbol: "timer",
                text: RhythmLocalization.text(store.activeFocus == nil ? "专注时间推动成长" : "专注进行中 · 作物实时成长"),
                tint: Color(red: 0.72, green: 1, blue: 0.75)
            )
        }
        .padding(14)
        .frame(width: size.width)
        .position(x: size.width / 2, y: 26)
    }

    @ViewBuilder
    private func farmToolbar(size: CGSize) -> some View {
        HStack(spacing: 7) {
            GameToolButton(title: "查看", symbol: "hand.point.up.left.fill", selected: tool == .inspect) {
                tool = .inspect
                showingSeeds = false
                showingDecorations = false
            }
            GameToolButton(title: "播种", symbol: "leaf.fill", selected: tool == .seed) {
                tool = .seed
                showingDecorations = false
                if let selectedPlotID,
                   store.farmPlots.first(where: { $0.id == selectedPlotID })?.cropID == nil {
                    showingSeeds = true
                }
            }
            GameToolButton(title: "浇水", symbol: "drop.fill", selected: tool == .water, badge: "-\(RhythmEconomy.waterCost)") { tool = .water; showingSeeds = false; showingDecorations = false }
            GameToolButton(title: "施肥", symbol: "sparkles", selected: tool == .fertilize, badge: "-\(RhythmEconomy.fertilizerCost)") { tool = .fertilize; showingSeeds = false; showingDecorations = false }
            GameToolButton(title: "收获", symbol: "basket.fill", selected: tool == .harvest) { tool = .harvest; showingSeeds = false; showingDecorations = false }
            GameToolButton(title: "装饰商店", symbol: "laurel.leading", selected: showingDecorations, badge: store.decorations.isEmpty ? nil : "\(store.decorations.count)") {
                showingSeeds = false
                showingDecorations.toggle()
            }
            GameToolButton(title: "全部收获", symbol: "shippingbox.and.arrow.backward.fill", selected: false) {
                let count = store.harvestAll()
                showMessage(count > 0
                    ? RhythmLocalization.format("已收获 %d 块成熟作物", count)
                    : RhythmLocalization.text("目前没有成熟作物"))
            }
        }
        .padding(9)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
        .position(x: size.width / 2, y: size.height - 48)
    }

    /// 已购装饰沿农场场景左上边缘排成一行（HUD 下方空白区），点击升级。
    @ViewBuilder
    private func decorationStrip(size: CGSize) -> some View {
        if !store.decorations.isEmpty {
            HStack(spacing: 10) {
                ForEach(store.decorations) { decoration in
                    if let definition = RhythmCatalog.decoration(decoration.definitionID) {
                        Button {
                            handleDecorationTap(decoration, definition: definition)
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                DecorationArtwork(sprite: definition.sprite)
                                    .frame(width: 34, height: 38)
                                Text("Lv.\(decoration.level)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(RhythmTheme.purple.opacity(0.92), in: Capsule())
                                    .offset(x: 6, y: 4)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(RhythmLocalization.format("「%@」Lv.%d · 点击升级（%d 金币）", definition.displayName, decoration.level, definition.upgradePrice(currentLevel: decoration.level)))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.28), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.2)))
            .position(x: 30 + decorationStripWidth(size: size) / 2, y: 66)
        }
    }

    private func decorationStripWidth(size: CGSize) -> CGFloat {
        CGFloat(min(store.decorations.count, 12)) * 44 + 20
    }

    private func handleDecorationTap(_ decoration: OwnedDecoration, definition: DecorationDefinition) {
        switch store.upgradeDecoration(id: decoration.id) {
        case .upgraded(let level, let price):
            showMessage(RhythmLocalization.format("「%@」升到了 %d 级（-%d 金币）", definition.displayName, level, price))
        case .insufficientFunds(let price):
            showMessage(RhythmLocalization.format("金币不足，升级需要 %d 金币", price))
        default:
            showMessage(RhythmLocalization.text("这个装饰暂时不可用"))
        }
    }

    private func decorationShop(size: CGSize) -> some View {
        let drawerWidth = min(390.0, size.width * 0.44)
        return VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(RhythmLocalization.text("装饰商店")).font(.headline)
                    Text(RhythmLocalization.text("纯装饰无产出，购买后每种可无限升级"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingDecorations = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .font(.title3)
                    .accessibilityLabel(RhythmLocalization.text("关闭"))
            }

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                    ForEach(RhythmCatalog.decorations) { definition in
                        let status = store.decorationStatus(definitionID: definition.id)
                        decorationShopCell(definition: definition, owned: status?.owned, nextPrice: status?.nextPrice ?? definition.purchasePrice)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: drawerWidth, height: max(250, size.height - 126))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.65)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .position(x: size.width - drawerWidth / 2 - 16, y: size.height / 2 - 8)
    }

    private func decorationShopCell(definition: DecorationDefinition, owned: OwnedDecoration?, nextPrice: Int) -> some View {
        Button {
            if let owned {
                handleDecorationTap(owned, definition: definition)
            } else {
                switch store.purchaseDecoration(definitionID: definition.id) {
                case .purchased:
                    showMessage(RhythmLocalization.format("「%@」已摆放在农场", definition.displayName))
                case .insufficientFunds(let price):
                    showMessage(RhythmLocalization.format("金币不足，购买需要 %d 金币", price))
                default:
                    showMessage(RhythmLocalization.text("这个装饰暂时不可用"))
                }
            }
        } label: {
            VStack(spacing: 3) {
                DecorationArtwork(sprite: definition.sprite)
                    .frame(width: 44, height: 50)
                Text(definition.displayName).font(.caption2.weight(.semibold)).lineLimit(1)
                if let owned {
                    Text("Lv.\(owned.level)").font(.system(size: 9, weight: .bold)).foregroundStyle(RhythmTheme.purple)
                    Text(RhythmLocalization.format("升级 🪙 %d", nextPrice))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text(RhythmLocalization.text("未购买"))
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    Text("🪙 \(nextPrice)").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .opacity(store.coins < nextPrice ? 0.48 : 1)
        .accessibilityLabel(definition.displayName)
    }

    private func seedDrawer(plotID: String, size: CGSize) -> some View {
        let drawerWidth = min(380.0, size.width * 0.43)
        return VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(RhythmLocalization.text("种子背包")).font(.headline)
                    Text(RhythmLocalization.text("选择一种作物种到当前田地"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingSeeds = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .font(.title3)
                    .accessibilityLabel(RhythmLocalization.text("关闭"))
            }

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                    ForEach(Array(RhythmCatalog.crops.enumerated()), id: \.element.id) { index, crop in
                        Button {
                            switch store.plant(cropID: crop.id, in: plotID) {
                            case .success:
                                showingSeeds = false
                                tool = .inspect
                                showMessage(RhythmLocalization.format("已种下%@", crop.displayName))
                            case .insufficientFunds:
                                showMessage(RhythmLocalization.text("金币不足，无法购买种子"))
                            case .capacityFull, .unavailable:
                                showMessage(RhythmLocalization.text("这块田已经种有作物"))
                            }
                        } label: {
                            VStack(spacing: 3) {
                                AtlasSprite(asset: "CropAtlasV15", index: index, columns: 6, rows: 4)
                                    .frame(width: 42, height: 58)
                                Text(crop.displayName).font(.caption2.weight(.semibold)).lineLimit(1)
                                Text("🪙 \(crop.seedCost) → \(crop.sellPrice)").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 88)
                            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .opacity(store.coins < crop.seedCost ? 0.48 : 1)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: drawerWidth, height: max(250, size.height - 126))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.65)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .position(x: size.width - drawerWidth / 2 - 16, y: size.height / 2 - 8)
    }

    private func handlePlot(index: Int) {
        guard store.farmPlots.indices.contains(index) else { return }
        let plot = store.farmPlots[index]
        selectedPlotID = plot.id

        guard plot.cropID != nil else {
            tool = .seed
            showingSeeds = true
            showingDecorations = false
            return
        }

        showingSeeds = false
        showingDecorations = false
        switch tool {
        case .inspect:
            if let crop = RhythmCatalog.crop(plot.cropID) {
                let progress = store.farmGrowthProgress(for: plot)
                showMessage(progress >= 1
                    ? RhythmLocalization.format("%@ · 已成熟，可以收获", crop.displayName)
                    : RhythmLocalization.format("%@ · 成长 %d%% · %@ 后成熟", crop.displayName, Int(progress * 100), RhythmFormatters.duration(store.farmMaturityRemainingSeconds(for: plot))))
            }
        case .seed:
            showMessage(RhythmLocalization.text("这块田已经种有作物"))
        case .water:
            switch store.water(plotID: plot.id) {
            case .success:
                showMessage(RhythmLocalization.text("浇水完成，下一次专注成长加速"))
            case .insufficientFunds:
                showMessage(RhythmLocalization.text("金币不足，无法浇水"))
            case .capacityFull, .unavailable:
                showMessage(RhythmLocalization.text("当前无法执行这个操作"))
            }
        case .fertilize:
            switch store.fertilize(plotID: plot.id) {
            case .success:
                showMessage(RhythmLocalization.text("施肥完成，下一次专注成长大幅加速"))
            case .insufficientFunds:
                showMessage(RhythmLocalization.text("金币不足，无法施肥"))
            case .capacityFull, .unavailable:
                showMessage(RhythmLocalization.text("当前无法执行这个操作"))
            }
        case .harvest:
            let wasPlanted = plot.cropID != nil
            store.harvest(plotID: plot.id)
            let harvested = wasPlanted && store.farmPlots[index].cropID == nil
            showMessage(harvested ? RhythmLocalization.text("收获成功，金币已入账") : RhythmLocalization.text("作物还没有成熟"))
        }
    }

    private func cropIndex(for cropID: String?) -> Int? {
        guard let cropID else { return nil }
        return RhythmCatalog.crops.firstIndex { $0.id == cropID }
    }

    private func showMessage(_ text: String) {
        withAnimation { message = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if message == text { withAnimation { message = nil } }
        }
    }
}

private struct FarmPlotNode: View {
    @EnvironmentObject private var store: RhythmStore
    let plot: FarmPlot
    let cropIndex: Int?
    let selected: Bool
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    private var crop: CropDefinition? { RhythmCatalog.crop(plot.cropID) }

    var body: some View {
        Button(action: action) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                plotContents(progress: store.farmGrowthProgress(for: plot, at: context.date))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(crop?.displayName ?? RhythmLocalization.text("空农田"))
    }

    private func plotContents(progress: Double) -> some View {
        let ready = progress >= 1
        return ZStack {
            FarmBedSurface(selected: selected, locked: false)
                .frame(width: width, height: height)

            if let cropIndex {
                AtlasSprite(
                    asset: ready ? "CropAtlasV15" : "CropYoungAtlasV15",
                    index: cropIndex,
                    columns: 6,
                    rows: 4
                )
                    .frame(width: width * 0.5, height: width * 0.74)
                    .scaleEffect(ready ? 1 : 0.58 + CGFloat(progress) * 0.36, anchor: .bottom)
                    .offset(y: -height * 0.55)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 2)
                VStack(spacing: 2) {
                    ProgressView(value: progress)
                        .tint(ready ? .yellow : .green)
                        .frame(width: width * 0.56)
                        .animation(.linear(duration: 1), value: progress)
                    if ready {
                        Text(RhythmLocalization.text("可收获"))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(RhythmTheme.orange, in: Capsule())
                    } else {
                        Text(RhythmLocalization.format("%@ 后成熟", RhythmFormatters.duration(store.farmMaturityRemainingSeconds(for: plot))))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                    }
                }
                .offset(y: height * 0.28)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .frame(width: width, height: height)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct LockedFarmPlotNode: View {
    let cost: Int?
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                FarmBedSurface(selected: false, locked: true)
                    .frame(width: width, height: height)
                VStack(spacing: 2) {
                    Image(systemName: cost == nil ? "lock.fill" : "shovel.fill")
                    if let cost { Text("🪙 \(cost)").font(.system(size: 9, weight: .bold)) }
                }
                .foregroundStyle(.white)
            }
            .frame(width: width, height: height)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(cost == nil)
        .accessibilityLabel(cost == nil ? RhythmLocalization.text("尚未解锁") : RhythmLocalization.format("开垦农田 %d 金币", cost ?? 0))
    }
}

// MARK: - Pasture game

private enum PastureTool: String {
    case inspect
    case collect
    case build
}

private struct AnimalSceneInstance: Identifiable {
    let id: String
    let resident: PastureAnimal
    let animal: AnimalDefinition
    let animalIndex: Int

    var isAdult: Bool { resident.growthHours >= animal.maturitySleepHours }
    var growthProgress: Double { min(1, resident.growthHours / animal.maturitySleepHours) }
}

struct PastureGameView: View {
    @EnvironmentObject private var store: RhythmStore
    @EnvironmentObject private var settings: RhythmSettings
    @State private var tool: PastureTool = .inspect
    @State private var showingShop = false
    @State private var selectedInstanceID: String?
    @State private var draggingInstanceID: String?
    @State private var dragOffset: CGSize = .zero
    @State private var message: String?
    @State private var worldYaw = 0.0
    @State private var worldZoom = 7.6

    private var worldItems: [GQWorldItem] {
        let season = (Calendar.current.component(.month, from: .now) + 9) % 12 / 3
        return [GQWorldItem(id: "season", title: "", kind: "__world", level: season, x: 0, z: 0, movable: false)]
            + (0..<25).map { index in
                let x = Double(index % 5 - 2) * 2.12
                let z = Double(index / 5 - 2) * 2.45
                if index < instances.count {
                    let item = instances[index]
                    return GQWorldItem(id: "animal:\(item.id)", title: item.animal.displayName, kind: "animal:\(item.animal.id)", level: item.isAdult ? (item.resident.pendingProducts > 0 ? 3 : 2) : 1, x: x, z: z, movable: true,
                        progress: item.isAdult ? (item.resident.pendingProducts > 0 ? 1 : store.pastureProductionProgress(targetHours: settings.sleepTargetHours)) : item.growthProgress,
                        status: item.resident.pendingProducts > 0 ? "可收取 ×\(item.resident.pendingProducts)" : item.isAdult ? (store.activeSleep == nil ? "睡眠恢复产出" : "产出 \(Int(store.pastureProductionProgress(targetHours: settings.sleepTargetHours) * 100))%") : "成长 \(Int(item.growthProgress * 100))%")
                }
                return GQWorldItem(id: "shelter:\(index)", title: index == store.animalShelterCapacity ? "扩建" : "", kind: index == store.animalShelterCapacity ? "unlock" : "shelter", level: 0, x: x, z: z, movable: false,
                    status: index == store.animalShelterCapacity ? RhythmLocalization.format("%d 金币", store.nextAnimalShelterCost) : "")
            }
    }

    private var instances: [AnimalSceneInstance] {
        store.pastureAnimals.compactMap { resident in
            guard let animal = RhythmCatalog.animal(resident.animalID),
                  let animalIndex = RhythmCatalog.animals.firstIndex(where: { $0.id == animal.id }) else { return nil }
            return AnimalSceneInstance(id: resident.id, resident: resident, animal: animal, animalIndex: animalIndex)
        }
    }

    private var selectedInstance: AnimalSceneInstance? {
        instances.first { $0.id == selectedInstanceID }
    }

    var body: some View {
        GameCanvas(background: "PastureGameSceneV15", world: AnyView(
            GQWorldScene(mode: "pasture", items: worldItems, selectedID: selectedInstanceID.map { "animal:\($0)" }, yaw: worldYaw, zoom: worldZoom, onSelect: { id in
                guard let id else { return }
                if id.hasPrefix("animal:"), let item = instances.first(where: { $0.id == String(id.dropFirst(7)) }) { handleAnimal(item) }
                else if id.hasPrefix("shelter:"), let index = Int(id.dropFirst(8)) {
                    if index < store.animalShelterCapacity { showingShop = true }
                    else if index == store.animalShelterCapacity {
                        switch store.buildAnimalShelter() {
                        case .success: showMessage(RhythmLocalization.text("新的动物窝已经搭好"))
                        case .insufficientFunds: showMessage(RhythmLocalization.text("金币不足，暂时无法搭窝"))
                        case .capacityFull: showMessage(RhythmLocalization.text("动物窝数量已达上限"))
                        case .unavailable: showMessage(RhythmLocalization.text("当前无法执行这个操作"))
                        }
                    }
                }
            }, onMove: { id, x, z in
                guard id.hasPrefix("animal:") else { return }
                let column = min(4, max(0, Int(round(x / 2.12)) + 2))
                let row = min(4, max(0, Int(round(z / 2.45)) + 2))
                store.movePastureAnimal(fromID: String(id.dropFirst(7)), toIndex: min(row * 5 + column, max(0, instances.count - 1)))
            })
        )) { size in
            ZStack {
                pastureHUD(size: size)
                pastureToolbar(size: size)
                if showingShop {
                    animalShop(size: size)
                        .zIndex(10)
                } else if let selectedInstance {
                    selectedAnimalCard(selectedInstance, size: size)
                        .zIndex(8)
                }
                if let message {
                    GameMessage(text: message)
                        .position(x: size.width / 2, y: 28)
                        .zIndex(20)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private func shelterLayer(size: CGSize) -> some View {
        let spriteWidth = min(66.0, size.width * 0.066)
        let columnSpacing = size.width * 0.108
        let rowSpacing = size.height * 0.108
        ForEach(0..<25, id: \.self) { index in
            let row = index / 5
            let column = index % 5
            let x = size.width * 0.5 + (CGFloat(column) - 2) * columnSpacing
            let y = size.height * 0.29 + CGFloat(row) * rowSpacing

            if index < instances.count {
                let item = instances[index]
                AnimalNode(item: item, selected: selectedInstanceID == item.id, width: spriteWidth) {
                    handleAnimal(item)
                }
                .offset(draggingInstanceID == item.id ? dragOffset : .zero)
                .zIndex(draggingInstanceID == item.id ? 6 : 1)
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            draggingInstanceID = item.id
                            selectedInstanceID = nil
                            dragOffset = value.translation
                        }
                        .onEnded { value in
                            let targetColumn = max(0, min(4, Int(round(CGFloat(column) + value.translation.width / columnSpacing))))
                            let targetRow = max(0, min(4, Int(round(CGFloat(row) + value.translation.height / rowSpacing))))
                            let targetIndex = min(max(0, targetRow * 5 + targetColumn), max(0, instances.count - 1))
                            store.movePastureAnimal(fromID: item.id, toIndex: targetIndex)
                            withAnimation(.easeOut(duration: 0.16)) {
                                draggingInstanceID = nil
                                dragOffset = .zero
                            }
                        }
                )
                .position(x: x, y: y)
            } else if index < store.animalShelterCapacity {
                EmptyShelterNode(width: spriteWidth, highlighted: tool == .build) {
                    tool = .inspect
                    showingShop = true
                    showMessage(RhythmLocalization.text("这个窝位可以迎接一只新动物"))
                }
                .position(x: x, y: y)
            } else if index == store.animalShelterCapacity && index < 25 {
                BuildShelterNode(cost: store.nextAnimalShelterCost, width: spriteWidth, highlighted: tool == .build) {
                    switch store.buildAnimalShelter() {
                    case .success:
                        showMessage(RhythmLocalization.text("新的动物窝已经搭好"))
                    case .insufficientFunds:
                        showMessage(RhythmLocalization.text("金币不足，暂时无法搭窝"))
                    case .capacityFull:
                        showMessage(RhythmLocalization.text("动物窝数量已达上限"))
                    case .unavailable:
                        showMessage(RhythmLocalization.text("当前无法执行这个操作"))
                    }
                }
                .position(x: x, y: y)
            } else {
                LockedShelterNode(width: spriteWidth)
                    .position(x: x, y: y)
            }
        }
    }

    @ViewBuilder
    private func pastureHUD(size: CGSize) -> some View {
        HStack(spacing: 8) {
            GameHUDChip(symbol: "circle.fill", text: "\(store.coins)", tint: Color(red: 1, green: 0.78, blue: 0.3))
            GameHUDChip(symbol: "house.lodge.fill", text: "\(store.occupiedAnimalShelters)/\(store.animalShelterCapacity)")
            GameHUDChip(symbol: "hammer.fill", text: store.animalShelterCapacity < 25
                ? RhythmLocalization.format("搭建新窝 %d 金币", store.nextAnimalShelterCost)
                : RhythmLocalization.text("动物窝数量已达上限"))
            Spacer()
            GameHUDChip(
                symbol: "moon.stars.fill",
                text: RhythmLocalization.text(store.activeSleep == nil ? "睡眠时间推动幼崽成长" : "睡眠计时中 · 牧场实时成长与出产"),
                tint: Color(red: 0.78, green: 0.86, blue: 1)
            )
        }
        .padding(14)
        .frame(width: size.width)
        .position(x: size.width / 2, y: 26)
    }

    @ViewBuilder
    private func pastureToolbar(size: CGSize) -> some View {
        HStack(spacing: 7) {
            GameToolButton(title: "查看", symbol: "hand.point.up.left.fill", selected: tool == .inspect) { tool = .inspect; showingShop = false }
            GameToolButton(title: "动物商店", symbol: "cart.fill", selected: showingShop) { showingShop.toggle(); tool = .inspect }
            GameToolButton(title: "收取产物", symbol: "basket.fill", selected: tool == .collect) { tool = .collect; showingShop = false }
            GameToolButton(title: "全部收取", symbol: "shippingbox.and.arrow.backward.fill", selected: false) {
                let count = store.collectAllAnimalProducts()
                showMessage(count > 0 ? RhythmLocalization.format("已收取 %d 份牧场产物", count) : RhythmLocalization.text("目前没有可收取的产物"))
            }
            GameToolButton(title: "搭建新窝", symbol: "hammer.fill", selected: tool == .build, badge: store.animalShelterCapacity < 25 ? "\(store.nextAnimalShelterCost)" : nil) {
                tool = .build
                showingShop = false
                showMessage(RhythmLocalization.text("点击场景中的施工牌搭建新窝"))
            }
        }
        .padding(9)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
        .position(x: size.width / 2, y: size.height - 48)
    }

    private func animalShop(size: CGSize) -> some View {
        let drawerWidth = min(390.0, size.width * 0.44)
        return VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(RhythmLocalization.text("动物商店")).font(.headline)
                    Text(RhythmLocalization.format("剩余窝位 %d", store.availableAnimalShelters))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingShop = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).font(.title3)
                    .accessibilityLabel(RhythmLocalization.text("关闭"))
            }

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                    ForEach(Array(RhythmCatalog.animals.enumerated()), id: \.element.id) { index, animal in
                        Button {
                            switch store.buyAnimal(animal.id) {
                            case .success:
                                showMessage(RhythmLocalization.format("%@已经入住牧场", animal.displayName))
                            case .capacityFull:
                                showMessage(RhythmLocalization.text("请先搭建新的动物窝"))
                            case .insufficientFunds:
                                showMessage(RhythmLocalization.text("金币不足，无法购买动物"))
                            case .unavailable:
                                showMessage(RhythmLocalization.text("当前无法执行这个操作"))
                            }
                        } label: {
                            VStack(spacing: 3) {
                                AtlasSprite(asset: "AnimalYoungAtlasV23", index: index, columns: 6, rows: 4)
                                    .frame(width: 52, height: 62)
                                Text(animal.displayName).font(.caption2.weight(.semibold)).lineLimit(1)
                                Text("🪙 \(animal.buyCost)").font(.system(size: 9)).foregroundStyle(.secondary)
                                Text(RhythmLocalization.format("成长 %.0f 小时", animal.maturitySleepHours))
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                                Text(RhythmLocalization.format("每份产物 +%d", animal.productValue))
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 114)
                            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .opacity(store.coins < animal.buyCost || store.availableAnimalShelters == 0 ? 0.46 : 1)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: drawerWidth, height: max(250, size.height - 126))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.65)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .position(x: size.width - drawerWidth / 2 - 16, y: size.height / 2 - 8)
    }

    private func selectedAnimalCard(_ item: AnimalSceneInstance, size: CGSize) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let liveHours = store.pastureGrowthHours(for: item.resident, at: context.date)
            let liveProgress = store.pastureGrowthProgress(for: item.resident, at: context.date)
            let productionProgress = store.pastureProductionProgress(targetHours: settings.sleepTargetHours, at: context.date)
            let maturityRemaining = store.pastureMaturityRemainingSeconds(for: item.resident)
            let productionRemaining = store.pastureProductionRemainingSeconds(targetHours: settings.sleepTargetHours, at: context.date)
            HStack(spacing: 10) {
            AtlasSprite(
                asset: item.isAdult ? "AnimalAtlasV23" : "AnimalYoungAtlasV23",
                index: item.animalIndex,
                columns: 6,
                rows: 4
            )
            .frame(width: 52, height: 58)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.animal.displayName).font(.callout.bold())
                if item.isAdult {
                    Text(RhythmLocalization.format("成年 · 待收取 %d 份%@", item.resident.pendingProducts, item.animal.displayProduct))
                        .font(.caption).foregroundStyle(.secondary)
                    if store.activeSleep != nil {
                        ProgressView(value: productionProgress)
                            .tint(RhythmTheme.purple)
                            .frame(width: 150)
                            .animation(.linear(duration: 1), value: productionProgress)
                        Text(RhythmLocalization.format("本次睡眠产出进度 %d%%", Int(productionProgress * 100)))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        Text(productionRemaining > 0
                            ? RhythmLocalization.format("%@ 后出产", RhythmFormatters.duration(productionRemaining))
                            : RhythmLocalization.text("本次睡眠产出已完成"))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(RhythmTheme.purple)
                    }
                } else {
                    Text(RhythmLocalization.format("幼崽成长 %.1f/%.0f 小时", liveHours, item.animal.maturitySleepHours))
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: liveProgress)
                        .tint(RhythmTheme.orange)
                        .frame(width: 150)
                        .animation(.linear(duration: 1), value: liveProgress)
                    Text(maturityRemaining > 0
                        ? RhythmLocalization.format("%@ 后成年", RhythmFormatters.duration(maturityRemaining))
                        : RhythmLocalization.text("已成年"))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(RhythmTheme.blue)
                }
                Text(RhythmLocalization.text("可拖动动物调整场景顺序"))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }

            Button(RhythmLocalization.format("出售 %d🪙", store.animalSaleValue(item.resident))) {
                let value = store.sellPastureAnimal(id: item.id)
                selectedInstanceID = nil
                showMessage(RhythmLocalization.format("动物已出售，获得 %d 金币", value))
            }
            .buttonStyle(.borderedProminent)
            .tint(RhythmTheme.orange)

            Button { selectedInstanceID = nil } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(RhythmLocalization.text("关闭"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.65)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .position(x: size.width / 2, y: 92)
    }

    private func handleAnimal(_ item: AnimalSceneInstance) {
        selectedInstanceID = item.id
        guard let current = store.pastureAnimals.first(where: { $0.id == item.id }) else { return }
        if tool == .collect {
            guard item.isAdult else {
                showMessage(RhythmLocalization.format("%@还是幼崽，需要继续记录睡眠", item.animal.displayName))
                return
            }
            let products = current.pendingProducts
            store.collectAnimalProducts(current)
            showMessage(products > 0
                ? RhythmLocalization.format("已收取 %d 份%@", products, item.animal.displayProduct)
                : RhythmLocalization.text("这只动物目前没有产物"))
        } else if item.isAdult {
            showMessage(RhythmLocalization.format("%@ · 成年 · 待收取 %d 份%@", item.animal.displayName, current.pendingProducts, item.animal.displayProduct))
        } else {
            showMessage(RhythmLocalization.format("%@幼崽 · 已成长 %.1f/%.0f 小时", item.animal.displayName, current.growthHours, item.animal.maturitySleepHours))
        }
    }

    private func showMessage(_ text: String) {
        withAnimation { message = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if message == text { withAnimation { message = nil } }
        }
    }
}

private struct AnimalNode: View {
    @EnvironmentObject private var store: RhythmStore
    @EnvironmentObject private var settings: RhythmSettings
    let item: AnimalSceneInstance
    let selected: Bool
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            animalContents(
                growthProgress: store.pastureGrowthProgress(for: item.resident, at: context.date),
                productionProgress: store.pastureProductionProgress(targetHours: settings.sleepTargetHours, at: context.date),
                countdown: item.isAdult
                    ? store.pastureProductionRemainingSeconds(targetHours: settings.sleepTargetHours, at: context.date)
                    : store.pastureMaturityRemainingSeconds(for: item.resident)
            )
        }
        .frame(width: width, height: width * 1.18)
        .padding(4)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .animation(.easeOut(duration: 0.08), value: selected)
        .accessibilityAddTraits(.isButton)
        // 外层调用点挂了拖排序的 DragGesture，改用真 Button 会与之竞争；
        // 保留点按手势，补默认激活动作让 VoiceOver 可以触发同一逻辑。
        .accessibilityAction(.default, action)
        .accessibilityLabel(item.animal.displayName)
    }

    private func animalContents(growthProgress: Double, productionProgress: Double, countdown: TimeInterval) -> some View {
        ZStack(alignment: .topTrailing) {
            Ellipse()
                .fill(Color(red: 0.85, green: 0.68, blue: 0.36).opacity(0.45))
                .overlay(
                    Ellipse()
                        .stroke(selected ? Color(red: 1, green: 0.86, blue: 0.32) : Color.clear, lineWidth: 4)
                )
                .frame(width: width * (selected ? 1.02 : 0.9), height: width * (selected ? 0.36 : 0.30))
                .offset(y: width * 0.58)
                .shadow(color: selected ? Color.yellow.opacity(0.45) : Color.clear, radius: 7)
            AtlasSprite(
                asset: item.isAdult ? "AnimalAtlasV23" : "AnimalYoungAtlasV23",
                index: item.animalIndex,
                columns: 6,
                rows: 4
            )
                .frame(width: width, height: width * 1.18)
                .scaleEffect((item.isAdult ? 1 : 0.82) * (selected ? 1.06 : 1))
                .shadow(color: .black.opacity(0.24), radius: 3, y: 3)
            if item.resident.pendingProducts > 0 {
                Text("\(item.resident.pendingProducts)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(RhythmTheme.orange, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .offset(x: 3, y: -3)
            }
            if !item.isAdult {
                ProgressView(value: growthProgress)
                    .tint(.yellow)
                    .frame(width: width * 0.7)
                    .offset(y: width * 0.9)
                    .animation(.linear(duration: 1), value: growthProgress)
                Text(countdown > 0 ? RhythmFormatters.duration(countdown) : RhythmLocalization.text("已成年"))
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(RhythmTheme.blue.opacity(0.9), in: Capsule())
                    .offset(x: 2, y: width * 0.80)
            } else if store.activeSleep != nil {
                ProgressView(value: productionProgress)
                    .tint(RhythmTheme.purple)
                    .frame(width: width * 0.7)
                    .offset(y: width * 0.9)
                    .animation(.linear(duration: 1), value: productionProgress)
                Text(countdown > 0 ? RhythmFormatters.duration(countdown) : RhythmLocalization.text("已出产"))
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(RhythmTheme.purple.opacity(0.9), in: Capsule())
                    .offset(x: 2, y: width * 0.80)
            }
        }
        .frame(width: width, height: width * 1.18)
    }
}

private struct EmptyShelterNode: View {
    let width: CGFloat
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Ellipse()
                    .fill(Color(red: 0.72, green: 0.48, blue: 0.22).opacity(0.58))
                    .overlay(Ellipse().stroke(highlighted ? Color.yellow : Color.white.opacity(0.45), lineWidth: highlighted ? 3 : 1))
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: width * 0.86, height: width * 0.34)
        }
        .frame(width: width, height: width * 1.18)
        .buttonStyle(.plain)
        .accessibilityLabel(RhythmLocalization.text("空动物窝"))
    }
}

private struct BuildShelterNode: View {
    let cost: Int
    let width: CGFloat
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("🪙 \(cost)").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(width: width * 0.95, height: width * 0.68)
            .background(highlighted ? RhythmTheme.orange.opacity(0.94) : Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(highlighted ? Color.yellow : Color.white.opacity(0.4), lineWidth: highlighted ? 3 : 1))
        }
        .frame(width: width, height: width * 1.18)
        .buttonStyle(.plain)
        .accessibilityLabel(RhythmLocalization.format("搭建新窝 %d 金币", cost))
    }
}

private struct LockedShelterNode: View {
    let width: CGFloat

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.2))
                .overlay(Ellipse().stroke(.white.opacity(0.18), lineWidth: 1))
                .frame(width: width * 0.86, height: width * 0.34)
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(width: width, height: width * 1.18)
        .accessibilityLabel(RhythmLocalization.text("尚未解锁"))
    }
}

// MARK: - Fishing game

private enum FishingDestination {
    case lake
    case aquarium
}

struct FishingHubView: View {
    @State private var destination: FishingDestination = .lake

    var body: some View {
        Group {
            switch destination {
            case .lake:
                FishingGameView {
                    withAnimation(.easeInOut(duration: 0.22)) { destination = .aquarium }
                }
                .transition(.opacity)
            case .aquarium:
                AquariumGameView {
                    withAnimation(.easeInOut(duration: 0.22)) { destination = .lake }
                }
                .transition(.opacity)
            }
        }
    }
}

struct FishingGameView: View {
    @EnvironmentObject private var store: RhythmStore
    var openAquarium: () -> Void = {}
    @State private var showingInventory = false
    @State private var lastCaught: FishDefinition?
    @State private var session = FishingSession()
    @State private var fishingSpot = 1
    @State private var message: String?
    private let fishingClock = Timer.publish(every:0.1,on:.main,in:.common).autoconnect()
    private var isCasting: Bool { session.phase != .idle }
    private var spot: (name:String,x:Double,z:Double) {
        [("芦苇湾",-0.8,3.3),("湖心",2.0,0.8),("静水岸",5.4,3.7)][fishingSpot]
    }
    private var phaseTitle: String {
        switch session.phase {
        case .idle: return "选好钓点，抛竿试试"
        case .casting: return "鱼线划过水面…"
        case .waiting: return "静候咬钩 · 留意浮漂"
        case .bite: return "咬钩了！指针在绿色区域时提竿"
        }
    }
    private var worldItems: [GQWorldItem] {
        [GQWorldItem(id:"bobber",title:"",kind:"bobber",level:session.phase == .idle ? 0 : session.phase == .casting ? 1 : session.phase == .bite ? 3 : 2,x:spot.x,z:spot.z,movable:false)]
    }

    var body: some View {
        GameCanvas(background: "FishingGameSceneV15", world: AnyView(
            GQWorldScene(mode:"fishing",items:worldItems,selectedID:nil,yaw:0,zoom:8.2,
                         onSelect:{ id in if id == "bobber" && session.phase == .bite { reelLine() } },
                         onMove:{ _,_,_ in })
        )) { size in
            ZStack {
                fishingHUD(size:size)
                VStack(spacing:10) {
                    Text("湖畔垂钓").font(.title2.weight(.semibold))
                    HStack(spacing:6) {
                        ForEach(0..<3,id: \.self) { index in
                            Button(["芦苇湾","湖心","静水岸"][index]) { fishingSpot=index }
                                .buttonStyle(.bordered).tint(fishingSpot == index ? .mint : .gray)
                                .disabled(isCasting)
                        }
                    }
                }.foregroundStyle(.white).shadow(color:.black.opacity(0.35),radius:3)
                    .position(x:size.width/2,y:91)
                fishingActionPanel(size:size)
                fishingToolbar(size:size)
                if showingInventory { inventoryDrawer(size:size).zIndex(10) }
                if let lastCaught { caughtCard(fish:lastCaught,size:size).zIndex(11) }
                if let message { GameMessage(text:message).position(x:size.width/2,y:150).zIndex(12) }
            }
        }
        .padding(.horizontal,20).padding(.bottom,20)
        .onReceive(fishingClock) { date in
            if session.advance(at:date) { showMessage("鱼儿游走了，调整时机再试 · 未消耗鱼饵") }
        }
        .onDisappear { session.cancel() }
    }

    private func fishingActionPanel(size:CGSize) -> some View {
        VStack(spacing:8) {
            Text(phaseTitle).font(.callout.weight(.semibold))
            if session.phase == .bite {
                TimelineView(.animation(minimumInterval:1.0/30)) { context in
                    ZStack(alignment:.leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule().fill(Color.mint.opacity(0.85)).frame(width:230*0.64).offset(x:230*0.18)
                        Capsule().fill(.white).frame(width:5,height:22).offset(x:225*session.marker(at:context.date))
                    }.frame(width:230,height:12)
                }
            }
            HStack(spacing:10) {
                Button(action:{ session.phase == .idle ? castLine() : reelLine() }) {
                    Label(session.phase == .idle ? "抛竿" : session.phase == .bite ? "提竿！" : "收竿",systemImage:"figure.fishing")
                        .font(.headline).frame(minWidth:100).padding(.vertical,5)
                }.buttonStyle(.borderedProminent).tint(session.phase == .bite ? .mint : RhythmTheme.green)
                    .keyboardShortcut(.space,modifiers:[]).disabled(session.phase == .casting || lastCaught != nil || showingInventory)
                Text("空格键操作").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Text("成功钓获消耗 1 鱼饵 · 提前收竿或错过咬钩可免费重试")
                .font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white).padding(14)
        .background(Color(red:0.04,green:0.16,blue:0.18).opacity(0.88),in:RoundedRectangle(cornerRadius:18))
        .overlay(RoundedRectangle(cornerRadius:18).stroke(.white.opacity(0.18)))
        .position(x:size.width/2,y:size.height-161)
    }

    @ViewBuilder
    private func fishingHUD(size: CGSize) -> some View {
        HStack(spacing: 8) {
            GameHUDChip(symbol: "fish.fill", text: "\(store.bait)", tint: Color(red: 0.72, green: 0.9, blue: 1))
            GameHUDChip(symbol: "shippingbox.fill", text: "\(store.fishInventory.values.reduce(0, +))")
            Spacer()
            GameHUDChip(symbol: "flag.checkered", text: RhythmLocalization.text("完成目标获得鱼饵"), tint: Color(red: 1, green: 0.82, blue: 0.54))
        }
        .padding(14)
        .frame(width: size.width)
        .position(x: size.width / 2, y: 26)
    }

    @ViewBuilder
    private func fishingToolbar(size: CGSize) -> some View {
        HStack(spacing: 7) {
            GameToolButton(title: "鱼篓", symbol: "basket.fill", selected: showingInventory, badge: "\(store.fishInventory.values.reduce(0, +))") {
                session.cancel()
                showingInventory.toggle()
                lastCaught = nil
            }
            GameToolButton(title: "出售全部", symbol: "banknote.fill", selected: false) {
                let earned = store.sellAllFish()
                showMessage(earned > 0 ? RhythmLocalization.format("渔获已出售，获得 %d 金币", earned) : RhythmLocalization.text("鱼篓目前是空的"))
            }
            GameToolButton(title: "水族馆", symbol: "water.waves", selected: false, badge: "\(store.aquariumFish.count)") {
                showingInventory = false
                lastCaught = nil
                session.cancel()
                openAquarium()
            }
            GameToolButton(title: "庄园图鉴", symbol: "books.vertical.fill", selected: false) {
                showMessage(RhythmLocalization.format("已发现 %d/%d 种鱼", store.fishCaught.count, RhythmCatalog.fish.count))
            }
        }
        .padding(9)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
        .position(x: size.width / 2, y: size.height - 48)
    }

    private func caughtCard(fish: FishDefinition, size: CGSize) -> some View {
        return VStack(spacing: 8) {
            Text(RhythmLocalization.text("钓获！")).font(.title3.bold())
            FishSprite(fishID: fish.id)
                .frame(width: 150, height: 96)
            Text(fish.displayName).font(.headline)
            Text(String(repeating: "★", count: fish.rarity)).foregroundStyle(RhythmTheme.orange)
            HStack {
                Button(RhythmLocalization.text("放入鱼篓")) { withAnimation { lastCaught = nil } }
                    .buttonStyle(.borderedProminent)
                Button(RhythmLocalization.text("放入水族馆")) {
                    let moved = store.moveFishToAquarium(fish.id)
                    withAnimation { lastCaught = nil }
                    showMessage(moved ? RhythmLocalization.text("鱼儿已经住进水族馆") : RhythmLocalization.text("水族馆已满"))
                }
                .buttonStyle(.bordered)
            }
            Button(RhythmLocalization.format("出售 %d🪙", fish.sellPrice)) {
                store.sellFish(fish.id)
                withAnimation { lastCaught = nil }
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .frame(width: 250)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.7)))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .position(x: size.width * 0.65, y: size.height * 0.48)
    }

    private func inventoryDrawer(size: CGSize) -> some View {
        let drawerWidth = min(390.0, size.width * 0.44)
        let inventory = RhythmCatalog.fish.enumerated().filter { store.fishInventory[$0.element.id, default: 0] > 0 }
        return VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(RhythmLocalization.text("我的鱼篓")).font(.headline)
                    Text(RhythmLocalization.format("%d 种鱼 · 共 %d 条", inventory.count, store.fishInventory.values.reduce(0, +)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingInventory = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).font(.title3)
                    .accessibilityLabel(RhythmLocalization.text("关闭"))
            }

            if inventory.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "fish").font(.largeTitle).foregroundStyle(.secondary)
                    Text(RhythmLocalization.text("鱼篓还是空的，点击水面抛竿吧"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 2), spacing: 7) {
                        ForEach(inventory, id: \.element.id) { _, fish in
                            VStack(spacing: 4) {
                                FishSprite(fishID: fish.id)
                                    .frame(width: 82, height: 54)
                                Text(fish.displayName).font(.caption.weight(.semibold))
                                Text("×\(store.fishInventory[fish.id, default: 0]) · " + String(repeating: "★", count: fish.rarity))
                                    .font(.caption2).foregroundStyle(.secondary)
                                Button(RhythmLocalization.format("出售 %d🪙", fish.sellPrice)) {
                                    store.sellFish(fish.id)
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .contentShape(Rectangle())
                                    .zIndex(2)
                                Button(RhythmLocalization.format("入馆 +%d/天", fish.dailyIncome)) {
                                    let moved = store.moveFishToAquarium(fish.id)
                                    showMessage(moved ? RhythmLocalization.text("鱼儿已经住进水族馆") : RhythmLocalization.text("水族馆已满"))
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(store.aquariumFish.count >= store.aquariumCapacity)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, minHeight: 116)
                            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: drawerWidth, height: max(250, size.height - 126))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.65)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .position(x: size.width - drawerWidth / 2 - 16, y: size.height / 2 - 8)
    }

    private func castLine() {
        guard !isCasting else { return }
        guard store.bait > 0 else {
            showMessage(RhythmLocalization.text("鱼饵不足，完成长期或短期目标可获得鱼饵")); return
        }
        showingInventory=false;lastCaught=nil;message=nil
        session.cast(at:.now,wait:Double.random(in:1.8...3.8))
    }
    private func reelLine() {
        switch session.reel(at:.now) {
        case .hooked:
            lastCaught=store.goFishing()
            if lastCaught == nil { showMessage("鱼饵不足，无法完成本次钓获") }
        case .early: showMessage("还没有咬钩，已收回鱼线 · 未消耗鱼饵")
        case .missed: showMessage("提竿时机偏了，下次等指针进入绿色区域 · 未消耗鱼饵")
        case .noLine: break
        }
    }

    private func showMessage(_ text: String) {
        withAnimation { message = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if message == text { withAnimation { message = nil } }
        }
    }
}

// MARK: - Aquarium game

struct AquariumGameView: View {
    @EnvironmentObject private var store: RhythmStore
    var returnToFishing: () -> Void = {}
    @State private var showingBasket = false
    @State private var selectedResidentID: String?
    @State private var message: String?
    @State private var immersive = false
    @State private var worldYaw = 0.0
    @State private var worldZoom = 5.9

    private var worldItems: [GQWorldItem] {
        Array(store.aquariumFish.prefix(store.aquariumCapacity).enumerated()).map { index, resident in
            let fish = RhythmCatalog.fish(resident.fishID)
            return GQWorldItem(id: resident.id, title: fish?.displayName ?? "", kind: "fish:\(resident.fishID)", level: fish?.rarity ?? 1, x: Double(index % 5 - 2) * 2.1, z: Double(index / 5 - 1) * 1.6, movable: false)
        }
    }

    private var selectedResident: AquariumFish? {
        store.aquariumFish.first { $0.id == selectedResidentID }
    }

    var body: some View {
        GameCanvas(background: "AquariumGameSceneV15", world: AnyView(
            GQWorldScene(mode: "aquarium", items: worldItems, selectedID: selectedResidentID, yaw: worldYaw, zoom: worldZoom,
                         onSelect: { id in selectedResidentID = id; showingBasket = false }, onMove: { _, _, _ in },
                         onZoom: nil, onRotate: nil)
        )) { size in
            ZStack {
                if !immersive {
                VStack(spacing:4) {
                    Text("水下花园").font(.title2.weight(.medium))
                    Text("自由巡游 · 点击鱼儿查看档案").font(.caption)
                }.foregroundStyle(.white).shadow(color:.black.opacity(0.4),radius:4)
                    .position(x:size.width/2,y:85).allowsHitTesting(false)
                aquariumHUD(size: size)
                aquariumToolbar(size: size)
                } else {
                    Button("退出观赏") { immersive=false }.buttonStyle(.bordered)
                        .position(x:size.width-66,y:30)
                }
                if store.aquariumFish.isEmpty {
                    Text("从鱼篓邀请第一位住客，让水下花园热闹起来")
                        .font(.callout).foregroundStyle(.white).padding(14)
                        .background(.black.opacity(0.4),in:Capsule())
                        .position(x:size.width/2,y:size.height/2)
                }
                if showingBasket {
                    basketDrawer(size: size).zIndex(12)
                } else if let resident = selectedResident,
                          let fish = RhythmCatalog.fish(resident.fishID) {
                    residentCard(resident: resident, fish: fish, size: size).zIndex(10)
                }
                if let message {
                    GameMessage(text: message)
                        .position(x: size.width / 2, y: 28)
                        .zIndex(20)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private func aquariumFishLayer(size: CGSize) -> some View {
        ForEach(Array(store.aquariumFish.prefix(store.aquariumCapacity).enumerated()), id: \.element.id) { index, resident in
            let row = index / 5
            let column = index % 5
            AquariumResidentNode(
                resident: resident,
                selected: resident.id == selectedResidentID,
                index: index,
                width: min(104, size.width * 0.09)
            ) {
                selectedResidentID = resident.id
                showingBasket = false
            }
            .position(
                x: size.width * (0.22 + CGFloat(column) * 0.14),
                y: size.height * (0.24 + CGFloat(row) * 0.115)
            )
        }
    }

    @ViewBuilder
    private func aquariumHUD(size: CGSize) -> some View {
        HStack(spacing: 8) {
            GameHUDChip(symbol: "circle.fill", text: "\(store.coins)", tint: Color(red: 1, green: 0.78, blue: 0.3))
            GameHUDChip(symbol: "fish.fill", text: "\(store.aquariumFish.count)/\(store.aquariumCapacity)", tint: Color(red: 0.72, green: 0.93, blue: 1))
            Spacer()
            GameHUDChip(
                symbol: "sun.max.fill",
                text: RhythmLocalization.format("待领取 %d 金币", store.aquariumPendingIncome()),
                tint: Color(red: 1, green: 0.86, blue: 0.5)
            )
        }
        .padding(14)
        .frame(width: size.width)
        .position(x: size.width / 2, y: 26)
    }

    @ViewBuilder
    private func aquariumToolbar(size: CGSize) -> some View {
        HStack(spacing: 7) {
            GameToolButton(title: "返回渔场", symbol: "arrow.left", selected: false) {
                showingBasket = false
                selectedResidentID = nil
                returnToFishing()
            }
            GameToolButton(title: "鱼篓入馆", symbol: "basket.fill", selected: showingBasket, badge: "\(store.fishInventory.values.reduce(0, +))") {
                showingBasket.toggle()
                selectedResidentID = nil
            }
            GameToolButton(title: "领取收益", symbol: "banknote.fill", selected: false, badge: "+\(store.aquariumPendingIncome())") {
                let earned = store.collectAquariumIncome()
                showMessage(earned > 0
                    ? RhythmLocalization.format("已领取 %d 金币", earned)
                    : RhythmLocalization.text("暂时没有收益，鱼儿从入住后的下一天开始产出"))
            }
            GameToolButton(title:"沉浸观赏",symbol:"sparkles.tv",selected:immersive) {
                showingBasket=false;selectedResidentID=nil;immersive=true
            }
            GameToolButton(title: "水族馆说明", symbol: "info.circle.fill", selected: false) {
                showMessage(RhythmLocalization.format("每条鱼每天产生少量金币，收益最多累计 %d 天；可随时取回鱼篓", RhythmEconomy.aquariumOfflineDayCap))
            }
        }
        .padding(9)
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 18))
        .position(x: size.width / 2, y: size.height - 48)
    }

    private func basketDrawer(size: CGSize) -> some View {
        let drawerWidth = min(390.0, size.width * 0.44)
        let inventory = RhythmCatalog.fish.filter { store.fishInventory[$0.id, default: 0] > 0 }
        return VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(RhythmLocalization.text("从鱼篓放入水族馆")).font(.headline)
                    Text(RhythmLocalization.format("馆内 %d/%d · 鱼篓 %d 条", store.aquariumFish.count, store.aquariumCapacity, store.fishInventory.values.reduce(0, +)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingBasket = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).font(.title3)
                    .accessibilityLabel(RhythmLocalization.text("关闭"))
            }

            if inventory.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "fish").font(.largeTitle).foregroundStyle(.secondary)
                    Text(RhythmLocalization.text("鱼篓还是空的，先去渔场钓鱼吧"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 2), spacing: 7) {
                        ForEach(inventory) { fish in
                            VStack(spacing: 4) {
                                FishSprite(fishID: fish.id)
                                    .frame(width: 92, height: 58)
                                Text(fish.displayName).font(.caption.weight(.semibold))
                                Text(RhythmLocalization.format("×%d · 每天 +%d", store.fishInventory[fish.id, default: 0], fish.dailyIncome))
                                    .font(.caption2).foregroundStyle(.secondary)
                                Button(RhythmLocalization.text("放入水族馆")) {
                                    let moved = store.moveFishToAquarium(fish.id)
                                    showMessage(moved ? RhythmLocalization.text("鱼儿已经住进水族馆") : RhythmLocalization.text("水族馆已满"))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(store.aquariumFish.count >= store.aquariumCapacity)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, minHeight: 126)
                            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: drawerWidth, height: max(250, size.height - 126))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.65)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .position(x: size.width - drawerWidth / 2 - 16, y: size.height / 2 - 8)
    }

    private func residentCard(resident: AquariumFish, fish: FishDefinition, size: CGSize) -> some View {
        HStack(spacing: 10) {
            FishSprite(fishID: fish.id)
                .frame(width: 88, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(fish.displayName).font(.callout.bold())
                Text(RhythmLocalization.format("每天产生 %d 金币", fish.dailyIncome))
                    .font(.caption).foregroundStyle(.secondary)
                Text(RhythmLocalization.format("入住于 %@", RhythmFormatters.shortDate.string(from: resident.addedAt)))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Button(RhythmLocalization.text("取回鱼篓")) {
                _ = store.returnAquariumFish(id: resident.id)
                selectedResidentID = nil
                showMessage(RhythmLocalization.text("鱼儿已取回鱼篓"))
            }
            .buttonStyle(.borderedProminent)
            .tint(RhythmTheme.blue)
            Button { selectedResidentID = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .accessibilityLabel(RhythmLocalization.text("关闭"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.65)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .position(x: size.width / 2, y: 88)
    }

    private func showMessage(_ text: String) {
        withAnimation { message = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if message == text { withAnimation { message = nil } }
        }
    }
}

private struct AquariumResidentNode: View {
    let resident: AquariumFish
    let selected: Bool
    let index: Int
    let width: CGFloat
    let action: () -> Void

    private var phase: Double {
        Double(resident.id.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 997 }) / 997 * .pi * 2
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let x = sin(time * 0.42 + phase) * 14
            let y = cos(time * 0.68 + phase) * 6
            Button(action: action) {
                ZStack {
                    if selected {
                        Capsule()
                            .fill(Color.cyan.opacity(0.18))
                            .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 2))
                            .frame(width: width * 1.18, height: width * 0.72)
                    }
                    FishSprite(fishID: resident.fishID)
                        .frame(width: width, height: width * 0.66)
                        .scaleEffect(x: index.isMultiple(of: 2) ? 1 : -1, y: 1)
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                }
                .offset(x: x, y: y)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(RhythmCatalog.fish(resident.fishID)?.displayName ?? RhythmLocalization.text("水族馆鱼类"))
        }
    }
}
