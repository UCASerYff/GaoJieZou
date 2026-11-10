import AppKit
import Foundation

enum RhythmBundle {
    static let bundle = Bundle.main
    static let defaults = UserDefaults(suiteName: "com.gaojiezou.rhythm.workspace-regression")!
}

@main
struct WorkspaceNavigationRegression {
    static func main() {
        for section in RhythmSection.allCases {
            let workspace = section.workspace
            assert(workspace.section(for: section) == section)
            assert(workspace.tabs(for: section).contains(where: { $0 == section }) || section.workspace == .health || section == .collection,
                   "Every legacy section must remain reachable: \(section.rawValue)")
        }
        assert(RhythmWorkspace.allCases.count == 5)
        assert(RhythmSection.healthWater.workspace == .health)
        assert(RhythmSection.footprintsTrain.workspace == .playground)
        assert(RhythmWorkspace.rhythm.tabs(for: .longGoals).contains(.longGoals))
        assert(RhythmWorkspace.health.tabs(for: .healthWater).contains(.healthOverview))
        assert(RhythmWorkspace.health.tabs(for: .healthOverview) == [.healthOverview, .healthRecords, .healthTrends, .healthEvents])
        assert(RhythmWorkspace.health.tabs(for: .healthWater).contains(.healthRecords))
        assert(RhythmSection.destination(for: URL(string: "gaojiezou://health/records")!) == .healthRecords)
        assert(RhythmSection.destination(for: URL(string: "gaojiezou://health/water")!) == .healthWater)
        assert(RhythmWorkspace.playground.tabs(for: .farm) == [.farm, .pasture, .fishing, .healthIsland, .footprintsTrain])
        assert(!RhythmWorkspace.playground.tabs(for: .farm).contains(.collection))
        assert(RhythmSection.collection.workspace == .playground)
        assert(RhythmSection.destination(for: URL(string: "gaojiezou://health/water")!).workspace == .health)
        assert(RhythmSection.destination(for: URL(string: "gaozuji://footprints/train")!).workspace == .playground)
        print("PASS Workspace: every legacy section and deep link remains reachable")
    }
}
