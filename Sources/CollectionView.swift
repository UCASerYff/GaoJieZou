import SwiftUI

struct CollectionView: View {
    @EnvironmentObject private var store: RhythmStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                collectionPanel(title: RhythmLocalization.format("作物图鉴 · %d/%d", store.harvestedCrops.count, RhythmCatalog.crops.count)) {
                    ForEach(Array(RhythmCatalog.crops.enumerated()), id: \.element.id) { index, crop in
                        let count = store.harvestedCrops[crop.id, default: 0]
                        SpeciesCollectionCard(
                            asset: "CropAtlasV15",
                            index: index,
                            columns: 6,
                            rows: 4,
                            discovered: count > 0,
                            name: crop.displayName,
                            detail: RhythmLocalization.format("收获 %d 次", count)
                        )
                    }
                }

                collectionPanel(title: RhythmLocalization.format("牲畜图鉴 · %d/%d", store.ownedAnimals.count, RhythmCatalog.animals.count)) {
                    ForEach(Array(RhythmCatalog.animals.enumerated()), id: \.element.id) { index, animal in
                        let count = store.ownedAnimals.first(where: { $0.animalID == animal.id })?.count ?? 0
                        SpeciesCollectionCard(
                            asset: "AnimalAtlasV23",
                            index: index,
                            columns: 6,
                            rows: 4,
                            discovered: count > 0,
                            name: animal.displayName,
                            detail: RhythmLocalization.format("拥有 %d 只", count)
                        )
                    }
                }

                collectionPanel(title: RhythmLocalization.format("鱼类图鉴 · %d/%d", store.fishCaught.count, RhythmCatalog.fish.count)) {
                    ForEach(RhythmCatalog.fish, id: \.id) { fish in
                        let count = store.fishCaught[fish.id, default: 0]
                        SpeciesCollectionCard(
                            asset: "",
                            index: 0,
                            columns: 1,
                            rows: 1,
                            fishID: fish.id,
                            discovered: count > 0,
                            name: fish.displayName,
                            detail: RhythmLocalization.format("捕获 %d 次 · %@", count, String(repeating: "★", count: fish.rarity))
                        )
                    }
                }
            }
            .frame(maxWidth: 1120)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private func collectionPanel<Items: View>(title: String, @ViewBuilder items: () -> Items) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                items()
            }
        }
        .padding(16)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.07)))
    }
}

private struct SpeciesCollectionCard: View {
    let asset: String
    let index: Int
    let columns: Int
    let rows: Int
    var fishID: String? = nil
    let discovered: Bool
    let name: String
    let detail: String

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                if discovered {
                    if let fishID {
                        FishSprite(fishID: fishID)
                            .frame(width: 86, height: 66)
                    } else {
                        AtlasSprite(asset: asset, index: index, columns: columns, rows: rows)
                            .frame(width: 56, height: 66)
                    }
                } else {
                    Image(systemName: "lock.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 68)

            Text(discovered ? name : RhythmLocalization.text("尚未发现"))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(discovered ? detail : RhythmLocalization.text("继续行动来解锁"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 112)
        .background((discovered ? RhythmTheme.teal : Color.secondary).opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.055)))
    }
}
