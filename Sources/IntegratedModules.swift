import SwiftUI
import RhythmHealth
import RhythmFootprints

/// A failed or unfinished cutover cannot instantiate a source store with defaults.
struct IntegrationAvailability<Content: View>: View {
    let content: () -> Content
    @State private var active = RhythmIntegrationPaths.isActive
    var body: some View {
        if active {
            content()
        } else {
            VStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                Text("资料整合尚未激活").font(.headline)
                Text("迁移和来源停写核验完成后才能打开。原资料保持原样，不会创建空白库替代。")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重新检查") { active = RhythmIntegrationPaths.isActive }
            }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct IntegratedHealthView: View {
    let section: RhythmSection
    let route: URL?
    let routeRevision: Int
    let onNavigate: (RhythmSection) -> Void
    var body: some View {
        IntegrationAvailability {
            HealthModuleView(page: section.healthPage ?? .overview, route: route, routeRevision: routeRevision,
                             onNavigate: { onNavigate(RhythmSection(healthPage: $0)) })
        }
    }
}

struct IntegratedFootprintsView: View {
    let section: RhythmSection
    let route: URL?
    let routeRevision: Int
    let onNavigate: (RhythmSection) -> Void
    var body: some View {
        IntegrationAvailability {
            FootprintsModuleView(page: section.footprintsPage ?? .map, route: route, routeRevision: routeRevision,
                                 onNavigate: { onNavigate(RhythmSection(footprintsPage: $0)) })
        }
    }
}

extension RhythmSection {
    var healthPage: HealthNavigationPage? {
        switch self {
        case .healthOverview: .overview
        case .healthRecords: .records
        case .healthEvents: .events
        case .healthWater: .water
        case .healthSleep: .sleep
        case .healthMeals: .meals
        case .healthExercise: .exercise
        case .healthWeight: .weight
        case .healthTrends: .trends
        case .healthIsland: .island
        default: nil
        }
    }

    init(healthPage: HealthNavigationPage) {
        self = switch healthPage {
        case .overview: .healthOverview
        case .records: .healthRecords
        case .events: .healthEvents
        case .water: .healthWater
        case .sleep: .healthSleep
        case .meals: .healthMeals
        case .exercise: .healthExercise
        case .weight: .healthWeight
        case .trends: .healthTrends
        case .island: .healthIsland
        }
    }

    var footprintsPage: FootprintsNavigationPage? {
        switch self {
        case .footprintsMap: .map
        case .footprintsTrips: .trips
        case .footprintsTimeline: .timeline
        case .footprintsResidentCity: .residentCity
        case .footprintsTrain: .train
        default: nil
        }
    }

    init(footprintsPage: FootprintsNavigationPage) {
        self = switch footprintsPage {
        case .map: .footprintsMap
        case .trips: .footprintsTrips
        case .timeline: .footprintsTimeline
        case .residentCity: .footprintsResidentCity
        case .train: .footprintsTrain
        }
    }
}
