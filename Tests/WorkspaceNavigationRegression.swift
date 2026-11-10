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
            assert(workspace.tabs(for: section).contains(where: { $0 == section }) || section.workspace == .health,
                   "Every legacy section must remain reachable: \(section.rawValue)")
        }
        assert(RhythmWorkspace.allCases.count == 5)
        assert(RhythmSection.healthWater.workspace == .health)
        assert(RhythmSection.footprintsTrain.workspace == .playground)
        assert(RhythmWorkspace.rhythm.tabs(for: .longGoals).contains(.longGoals))
        assert(RhythmWorkspace.health.tabs(for: .healthWater).contains(.healthOverview))
        assert(RhythmWorkspace.playground.tabs(for: .farm).count == 6)
        assert(RhythmSection.destination(for: URL(string: "gaojiezou://health/water")!).workspace == .health)
        assert(RhythmSection.destination(for: URL(string: "gaozuji://footprints/train")!).workspace == .playground)
        print("PASS Workspace: every legacy section and deep link remains reachable")
    }
}
