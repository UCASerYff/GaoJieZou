import Foundation

/// 庄园经济事务引擎：农场/牧场/渔场/水族馆的买入、照料、收获与出售。
///
/// 与 Models.swift 里的 `RhythmEconomy`（数值常量表）分工：价格与参数查表在那边，
/// 状态事务在这里。引擎不持有任何状态，所有方法直接读写传入的 RhythmStore（门面），
/// 因此 SwiftUI 的刷新路径不变，视图层继续只用 `store.xxx`。
@MainActor
final class RhythmEstateEngine {

    /// 农场/牧场购买与照料操作的明确结果（与 DecorationResult 同模式）：
    /// 视图层据此映射文案，不再比较操作前后的 coins/数量推断成败。
    enum EstateActionResult: Equatable {
        /// 操作成功，cost 为实际消耗的金币。
        case success(cost: Int)
        /// 金币不足，cost 为本次操作所需金币。
        case insufficientFunds(cost: Int)
        /// 容量或数量已满（田地满 25 块、窝位满 25 个、无空余窝位）。
        case capacityFull
        /// 操作对象不可用（未知 ID、田地已种作物、田里暂无作物等）。
        case unavailable
    }

    // MARK: - 农场

    @discardableResult
    func plant(_ store: RhythmStore, cropID: String, in plotID: String) -> EstateActionResult {
        guard let crop = RhythmCatalog.crop(cropID),
              let index = store.farmPlots.firstIndex(where: { $0.id == plotID }),
              store.farmPlots[index].cropID == nil else { return .unavailable }
        guard store.coins >= crop.seedCost else { return .insufficientFunds(cost: crop.seedCost) }
        store.coins -= crop.seedCost
        store.farmPlots[index].cropID = crop.id
        store.farmPlots[index].growthMinutes = 0
        store.farmPlots[index].nextFocusBoost = 0
        store.farmPlots[index].plantedAt = Date()
        store.save()
        return .success(cost: crop.seedCost)
    }

    @discardableResult
    func buyFarmPlot(_ store: RhythmStore) -> EstateActionResult {
        let cost = nextPlotCost(of: store)
        guard store.farmPlots.count < 25 else { return .capacityFull }
        guard store.coins >= cost else { return .insufficientFunds(cost: cost) }
        store.coins -= cost
        store.farmPlots.append(FarmPlot(id: UUID().uuidString, cropID: nil, growthMinutes: 0, nextFocusBoost: 0, plantedAt: nil))
        store.save()
        return .success(cost: cost)
    }

    func nextPlotCost(of store: RhythmStore) -> Int {
        RhythmEconomy.farmPlotCost(existingCount: store.farmPlots.count)
    }

    @discardableResult
    func water(_ store: RhythmStore, plotID: String) -> EstateActionResult {
        guard let index = store.farmPlots.firstIndex(where: { $0.id == plotID }),
              store.farmPlots[index].cropID != nil else { return .unavailable }
        guard store.coins >= RhythmEconomy.waterCost else { return .insufficientFunds(cost: RhythmEconomy.waterCost) }
        store.coins -= RhythmEconomy.waterCost
        store.farmPlots[index].nextFocusBoost = min(
            RhythmEconomy.maximumFocusBoost,
            store.farmPlots[index].nextFocusBoost + RhythmEconomy.waterBoost
        )
        store.save()
        return .success(cost: RhythmEconomy.waterCost)
    }

    @discardableResult
    func fertilize(_ store: RhythmStore, plotID: String) -> EstateActionResult {
        guard let index = store.farmPlots.firstIndex(where: { $0.id == plotID }),
              store.farmPlots[index].cropID != nil else { return .unavailable }
        guard store.coins >= RhythmEconomy.fertilizerCost else { return .insufficientFunds(cost: RhythmEconomy.fertilizerCost) }
        store.coins -= RhythmEconomy.fertilizerCost
        store.farmPlots[index].nextFocusBoost = min(
            RhythmEconomy.maximumFocusBoost,
            store.farmPlots[index].nextFocusBoost + RhythmEconomy.fertilizerBoost
        )
        store.save()
        return .success(cost: RhythmEconomy.fertilizerCost)
    }

    func harvest(_ store: RhythmStore, plotID: String) {
        guard harvestInPlace(store, plotID: plotID) else { return }
        store.save()
    }

    /// 收获内核：只修改内存状态，不落盘，供单田收获与批量收获复用。
    @discardableResult
    private func harvestInPlace(_ store: RhythmStore, plotID: String) -> Bool {
        guard let index = store.farmPlots.firstIndex(where: { $0.id == plotID }),
              let crop = RhythmCatalog.crop(store.farmPlots[index].cropID),
              store.farmPlots[index].growthMinutes >= crop.growthMinutes else { return false }
        store.coins += crop.sellPrice
        store.harvestedCrops[crop.id, default: 0] += 1
        store.farmPlots[index] = FarmPlot(id: store.farmPlots[index].id, cropID: nil, growthMinutes: 0, nextFocusBoost: 0, plantedAt: nil)
        store.addReward(
            title: RhythmLocalization.format("收获并出售%@", crop.displayName),
            detail: RhythmLocalization.format("成熟作物售出后获得 %d 金币。", crop.sellPrice),
            coins: crop.sellPrice,
            symbol: "leaf.fill"
        )
        return true
    }

    @discardableResult
    func harvestAll(_ store: RhythmStore) -> Int {
        let readyPlotIDs = store.farmPlots.compactMap { plot -> String? in
            guard let crop = RhythmCatalog.crop(plot.cropID),
                  plot.growthMinutes >= crop.growthMinutes else { return nil }
            return plot.id
        }
        // 批量收获只落盘一次，避免 25 块田触发 25 次全量写盘。
        var harvestedCount = 0
        for plotID in readyPlotIDs where harvestInPlace(store, plotID: plotID) {
            harvestedCount += 1
        }
        if harvestedCount > 0 { store.save() }
        return harvestedCount
    }

    // MARK: - 牧场

    func occupiedAnimalShelters(of store: RhythmStore) -> Int {
        store.pastureAnimals.count
    }

    func availableAnimalShelters(of store: RhythmStore) -> Int {
        max(0, store.animalShelterCapacity - occupiedAnimalShelters(of: store))
    }

    func nextAnimalShelterCost(of store: RhythmStore) -> Int {
        RhythmEconomy.animalShelterCost(existingCapacity: store.animalShelterCapacity)
    }

    @discardableResult
    func buildAnimalShelter(_ store: RhythmStore) -> EstateActionResult {
        let cost = nextAnimalShelterCost(of: store)
        guard store.animalShelterCapacity < 25 else { return .capacityFull }
        guard store.coins >= cost else { return .insufficientFunds(cost: cost) }
        store.coins -= cost
        store.animalShelterCapacity += 1
        store.save()
        return .success(cost: cost)
    }

    @discardableResult
    func buyAnimal(_ store: RhythmStore, _ animalID: String) -> EstateActionResult {
        guard let animal = RhythmCatalog.animal(animalID) else { return .unavailable }
        guard availableAnimalShelters(of: store) > 0 else { return .capacityFull }
        guard store.coins >= animal.buyCost else { return .insufficientFunds(cost: animal.buyCost) }
        store.coins -= animal.buyCost
        store.pastureAnimals.append(PastureAnimal(
            id: UUID().uuidString,
            animalID: animalID,
            growthHours: 0,
            pendingProducts: 0,
            acquiredAt: Date()
        ))
        store.synchronizeAnimalSummaries()
        store.save()
        return .success(cost: animal.buyCost)
    }

    func collectAnimalProducts(_ store: RhythmStore, _ resident: PastureAnimal) {
        guard let index = store.pastureAnimals.firstIndex(where: { $0.id == resident.id }),
              let animal = RhythmCatalog.animal(resident.animalID),
              store.pastureAnimals[index].pendingProducts > 0 else { return }
        let count = store.pastureAnimals[index].pendingProducts
        let value = count * animal.productValue
        store.pastureAnimals[index].pendingProducts = 0
        store.coins += value
        store.synchronizeAnimalSummaries()
        store.addReward(
            title: RhythmLocalization.format("出售%@", animal.displayProduct),
            detail: RhythmLocalization.format("售出 %d 份%@，获得 %d 金币。", count, animal.displayProduct, value),
            coins: value,
            symbol: "pawprint.fill"
        )
        store.save()
    }

    @discardableResult
    func collectAllAnimalProducts(_ store: RhythmStore) -> Int {
        var productCount = 0
        var value = 0
        for index in store.pastureAnimals.indices where store.pastureAnimals[index].pendingProducts > 0 {
            guard let animal = RhythmCatalog.animal(store.pastureAnimals[index].animalID) else { continue }
            let count = store.pastureAnimals[index].pendingProducts
            productCount += count
            value += count * animal.productValue
            store.pastureAnimals[index].pendingProducts = 0
        }
        guard productCount > 0 else { return 0 }
        store.coins += value
        store.synchronizeAnimalSummaries()
        store.addReward(
            title: RhythmLocalization.text("出售全部牧场产物"),
            detail: RhythmLocalization.format("售出 %d 份产品，获得 %d 金币。", productCount, value),
            coins: value,
            symbol: "pawprint.fill"
        )
        store.save()
        return productCount
    }

    func animalSaleValue(_ store: RhythmStore, _ resident: PastureAnimal) -> Int {
        guard let animal = RhythmCatalog.animal(resident.animalID) else { return 0 }
        let mature = resident.growthHours >= animal.maturitySleepHours
        return (mature ? animal.adultSellPrice : animal.juvenileSellPrice)
            + resident.pendingProducts * animal.productValue
    }

    @discardableResult
    func sellPastureAnimal(_ store: RhythmStore, id: String) -> Int {
        guard let index = store.pastureAnimals.firstIndex(where: { $0.id == id }),
              let animal = RhythmCatalog.animal(store.pastureAnimals[index].animalID) else { return 0 }
        let resident = store.pastureAnimals.remove(at: index)
        let value = animalSaleValue(store, resident)
        store.coins += value
        store.synchronizeAnimalSummaries()
        store.addReward(
            title: RhythmLocalization.format("出售%@", animal.displayName),
            detail: RhythmLocalization.format("动物与未收产物合计获得 %d 金币。", value),
            coins: value,
            symbol: "pawprint.fill"
        )
        store.save()
        return value
    }

    func movePastureAnimal(_ store: RhythmStore, fromID: String, beforeID: String) {
        guard fromID != beforeID,
              let sourceIndex = store.pastureAnimals.firstIndex(where: { $0.id == fromID }),
              let destinationIndex = store.pastureAnimals.firstIndex(where: { $0.id == beforeID }) else { return }
        let animal = store.pastureAnimals.remove(at: sourceIndex)
        let adjustedDestination = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        store.pastureAnimals.insert(animal, at: adjustedDestination)
        store.synchronizeAnimalSummaries()
        store.save()
    }

    func movePastureAnimal(_ store: RhythmStore, fromID: String, toIndex: Int) {
        guard let sourceIndex = store.pastureAnimals.firstIndex(where: { $0.id == fromID }) else { return }
        let animal = store.pastureAnimals.remove(at: sourceIndex)
        store.pastureAnimals.insert(animal, at: max(0, min(toIndex, store.pastureAnimals.count)))
        store.synchronizeAnimalSummaries()
        store.save()
    }

    // MARK: - 渔场

    @discardableResult
    func goFishing(_ store: RhythmStore) -> FishDefinition? {
        guard store.bait > 0 else { return nil }
        store.bait -= 1
        let roll = Int.random(in: 1...100)
        let rarity = RhythmEconomy.fishingRarity(for: roll)
        let pool = RhythmCatalog.fish.filter { $0.rarity == rarity }
        let caught = (pool.isEmpty ? RhythmCatalog.fish : pool).randomElement()!
        store.fishInventory[caught.id, default: 0] += 1
        store.fishCaught[caught.id, default: 0] += 1
        store.addReward(
            title: RhythmLocalization.format("钓到%@", caught.displayName),
            detail: RhythmLocalization.format("稀有度 %@，可收藏或出售。", String(repeating: "★", count: caught.rarity)),
            coins: 0,
            symbol: "fish.fill"
        )
        store.save()
        return caught
    }

    func sellFish(_ store: RhythmStore, _ fishID: String) {
        guard let fish = RhythmCatalog.fish(fishID), store.fishInventory[fishID, default: 0] > 0 else { return }
        store.fishInventory[fishID, default: 0] -= 1
        if store.fishInventory[fishID] == 0 { store.fishInventory.removeValue(forKey: fishID) }
        store.coins += fish.sellPrice
        store.addReward(
            title: RhythmLocalization.format("出售%@", fish.displayName),
            detail: RhythmLocalization.format("获得 %d 金币。", fish.sellPrice),
            coins: fish.sellPrice,
            symbol: "fish.fill"
        )
        store.save()
    }

    /// 出售全部渔获，返回实际入账金币（0 表示鱼篓为空），与 collectAllAnimalProducts 同模式。
    @discardableResult
    func sellAllFish(_ store: RhythmStore) -> Int {
        var total = 0
        for (fishID, count) in store.fishInventory where count > 0 {
            if let fish = RhythmCatalog.fish(fishID) {
                total += fish.sellPrice * count
            }
        }
        guard total > 0 else { return 0 }
        store.fishInventory = [:]
        store.coins += total
        store.addReward(
            title: RhythmLocalization.text("出售全部渔获"),
            detail: RhythmLocalization.format("本次共获得 %d 金币。", total),
            coins: total,
            symbol: "fish.fill"
        )
        store.save()
        return total
    }

    // MARK: - 水族馆

    @discardableResult
    func moveFishToAquarium(_ store: RhythmStore, _ fishID: String, at date: Date = Date()) -> Bool {
        guard store.aquariumFish.count < store.aquariumCapacity,
              RhythmCatalog.fish(fishID) != nil,
              store.fishInventory[fishID, default: 0] > 0 else { return false }
        store.fishInventory[fishID, default: 0] -= 1
        if store.fishInventory[fishID] == 0 { store.fishInventory.removeValue(forKey: fishID) }
        store.aquariumFish.append(AquariumFish(
            id: UUID().uuidString,
            fishID: fishID,
            addedAt: date,
            lastIncomeDate: Calendar.current.startOfDay(for: date)
        ))
        store.save()
        return true
    }

    @discardableResult
    func returnAquariumFish(_ store: RhythmStore, id: String) -> Bool {
        guard let index = store.aquariumFish.firstIndex(where: { $0.id == id }) else { return false }
        let resident = store.aquariumFish.remove(at: index)
        store.fishInventory[resident.fishID, default: 0] += 1
        store.save()
        return true
    }

    func aquariumPendingIncome(_ store: RhythmStore, at date: Date = Date()) -> Int {
        store.aquariumFish.reduce(0) { total, resident in
            guard let fish = RhythmCatalog.fish(resident.fishID) else { return total }
            let days = aquariumIncomeDays(for: resident, at: date)
            return total + days * fish.dailyIncome
        }
    }

    @discardableResult
    func collectAquariumIncome(_ store: RhythmStore, at date: Date = Date()) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        var earned = 0
        for index in store.aquariumFish.indices {
            guard let fish = RhythmCatalog.fish(store.aquariumFish[index].fishID) else { continue }
            let days = aquariumIncomeDays(for: store.aquariumFish[index], at: date)
            guard days > 0 else { continue }
            earned += days * fish.dailyIncome
            store.aquariumFish[index].lastIncomeDate = today
        }
        guard earned > 0 else { return 0 }
        store.coins += earned
        store.addReward(
            title: RhythmLocalization.text("领取水族馆收益"),
            detail: RhythmLocalization.format("水族馆今日带来了 %d 金币。", earned),
            coins: earned,
            symbol: "water.waves"
        )
        store.save()
        return earned
    }

    private func aquariumIncomeDays(for resident: AquariumFish, at date: Date) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: resident.lastIncomeDate)
        let end = calendar.startOfDay(for: date)
        return max(0, min(RhythmEconomy.aquariumOfflineDayCap, calendar.dateComponents([.day], from: start, to: end).day ?? 0))
    }

    // MARK: - 庄园装饰

    /// 装饰购买/升级的明确结果，视图层据此映射文案，不再比较 coins 前后推断成败。
    enum DecorationResult: Equatable {
        case purchased(price: Int)
        case upgraded(level: Int, price: Int)
        case insufficientFunds(price: Int)
        case unavailable
    }

    /// 某种装饰的当前状态：未拥有（购买价）或已拥有（当前等级与升级价）。
    func decorationStatus(of store: RhythmStore, definitionID: String) -> (owned: OwnedDecoration?, nextPrice: Int)? {
        guard let definition = RhythmCatalog.decoration(definitionID) else { return nil }
        let owned = store.decorations.first { $0.definitionID == definitionID }
        return (owned, definition.upgradePrice(currentLevel: owned?.level ?? 0))
    }

    /// 购买装饰（每种限购一件，获得 level 1）。已拥有时应走 upgradeDecoration。
    @discardableResult
    func purchaseDecoration(_ store: RhythmStore, definitionID: String) -> DecorationResult {
        guard let definition = RhythmCatalog.decoration(definitionID) else { return .unavailable }
        guard !store.decorations.contains(where: { $0.definitionID == definitionID }) else { return .unavailable }
        let price = definition.purchasePrice
        guard store.coins >= price else { return .insufficientFunds(price: price) }
        store.coins -= price
        store.decorations.append(OwnedDecoration(
            id: UUID().uuidString,
            definitionID: definition.id,
            level: 1,
            placedAt: Date()
        ))
        store.save()
        return .purchased(price: price)
    }

    /// 升级已购装饰，无上限（永续水槽）。
    @discardableResult
    func upgradeDecoration(_ store: RhythmStore, id: String) -> DecorationResult {
        guard let index = store.decorations.firstIndex(where: { $0.id == id }),
              let definition = RhythmCatalog.decoration(store.decorations[index].definitionID) else { return .unavailable }
        let price = definition.upgradePrice(currentLevel: store.decorations[index].level)
        guard store.coins >= price else { return .insufficientFunds(price: price) }
        store.coins -= price
        store.decorations[index].level += 1
        store.save()
        return .upgraded(level: store.decorations[index].level, price: price)
    }
}
