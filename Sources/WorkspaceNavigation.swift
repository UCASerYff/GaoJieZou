import Foundation

/// The five visible workspaces are presentation-only. Legacy leaf identifiers stay
/// unchanged so scene storage, notifications and external links keep working.
enum RhythmWorkspace: String, CaseIterable, Identifiable {
    case today, rhythm, health, footprints, playground

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: RhythmLocalization.text("今天")
        case .rhythm: RhythmLocalization.text("节奏")
        case .health: RhythmLocalization.text("健康")
        case .footprints: RhythmLocalization.text("足迹")
        case .playground: RhythmLocalization.text("乐园")
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max.fill"
        case .rhythm: "timer"
        case .health: "heart.fill"
        case .footprints: "map.fill"
        case .playground: "leaf.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .today: RhythmLocalization.text("把今天，过成自己的节奏。")
        case .rhythm: RhythmLocalization.text("专注、习惯与每一个小目标")
        case .health: RhythmLocalization.text("照顾身体，不必成为负担。")
        case .footprints: RhythmLocalization.text("走过的地方，都有故事。")
        case .playground: RhythmLocalization.text("认真生活，也尽情生长。")
        }
    }

    var defaultSection: RhythmSection {
        switch self {
        case .today: .today
        case .rhythm: .focus
        case .health: .healthOverview
        case .footprints: .footprintsMap
        case .playground: .farm
        }
    }

    func section(for selection: RhythmSection) -> RhythmSection { selection }

    func tabs(for selection: RhythmSection) -> [RhythmSection] {
        switch self {
        case .today:
            return [.today]
        case .rhythm:
            return [.focus, .sleep, .habits, .chores, .longGoals, .shortActions, .statistics]
        case .health:
            return [.healthOverview, .healthRecords, .healthTrends, .healthEvents]
        case .footprints:
            var pages: [RhythmSection] = [.footprintsMap, .footprintsTrips, .footprintsTimeline]
            if selection == .footprintsResidentCity { pages.append(.footprintsResidentCity) }
            return pages
        case .playground:
            return RhythmSection.rewardPages
        }
    }
}

extension RhythmSection {
    var workspace: RhythmWorkspace {
        if self == .today { return .today }
        if Self.healthPages.contains(self) { return .health }
        if Self.travelPages.contains(self) { return .footprints }
        if Self.rewardPages.contains(self) || self == .collection { return .playground }
        return .rhythm
    }
}
