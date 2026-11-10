import AppKit
import SwiftUI

struct ContentView: View {
    var route: URL? = nil
    var routeRevision: Int = 0
    @State private var handledRouteRevision = 0
    @EnvironmentObject private var store: RhythmStore
    @EnvironmentObject private var settings: RhythmSettings
    @Environment(\.colorScheme) private var colorScheme
    @SceneStorage("gqns.page.Rhythm") private var selection: RhythmSection = .today
    @SceneStorage("gqns.playgroundIndexVisible") private var showingPlaygroundIndex = true

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTopBar(selection: selection, onWorkspace: selectWorkspace, onRecord: selectRecord)
            if selection.workspace != .today && selection.workspace != .playground {
                WorkspaceTabBar(selection: $selection, sections: selection.workspace.tabs(for: selection))
            }
            if selection.workspace == .playground && !showingPlaygroundIndex {
                PlaygroundBackBar(showingIndex: $showingPlaygroundIndex)
            }
            ZStack {
                settings.canvasColor(for: colorScheme).ignoresSafeArea()
                detail.id(settings.language)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1040, minHeight: 700)
        .disabled(store.loadFailed)
        .alert(RhythmLocalization.text("提示"), isPresented: Binding(
            get: { store.notice != nil },
            set: { if !$0 { store.notice = nil } }
        )) {
            Button(RhythmLocalization.text("知道了")) { store.notice = nil }
        } message: {
            Text(store.notice ?? "")
        }
        .onAppear {
            updateWindowTitle()
            RhythmNotifications.rescheduleDailyHabitReminder(settings: settings, pendingCount: store.pendingHabitCountToday)
            if selection.workspace == .playground { showingPlaygroundIndex = true }
        }
        .onChange(of: settings.language) { _ in updateWindowTitle() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.health.sleepReward"))) { note in
            let energy = note.userInfo?["energy"] as? Double ?? 0
            store.notice = energy > 0
                ? "睡眠已保存 · 牧场收益已结算 · 健康活力 +\(Int(energy))（每日最多 +24）"
                : "睡眠已保存 · 牧场收益已结算 · 健康活力今日额度已满或该睡眠已结算"
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.rhythm.game"))) { _ in
            selection = .farm
            showingPlaygroundIndex = false
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.health.game"))) { _ in
            selection = .healthIsland
            showingPlaygroundIndex = false
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.footprints.game"))) { _ in
            selection = .footprintsTrain
            showingPlaygroundIndex = false
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.footprints.search"))) { _ in selection = .footprintsMap }
        .onReceive(NotificationCenter.default.publisher(for: .rhythmSelectSection)) { note in
            guard let rawValue = note.userInfo?["section"] as? String,
                  let section = RhythmSection(rawValue: rawValue) else { return }
            selection = section
            if section.workspace == .playground { showingPlaygroundIndex = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.rhythm.startFocus"))) { _ in
            store.startFocus(linkedActionID: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.rhythm.startSleep"))) { _ in
            store.startSleep(targetHours: settings.sleepTargetHours)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.rhythm.logSleep"))) { note in
            guard let durationMinutes = note.userInfo?["durationMinutes"] as? Int,
                  let night = note.userInfo?["night"] as? Date,
                  (30 ... 24 * 60).contains(durationMinutes) else { return }
            let interval = RhythmShared.manualSleepInterval(night: night, durationMinutes: durationMinutes)
            store.addManualSleep(start: interval.start, end: interval.end, targetHours: settings.sleepTargetHours)
        }
        .onAppear(perform: handleIntegratedRoute)
        .onChange(of: routeRevision) { _, _ in handleIntegratedRoute() }
    }

    private func selectWorkspace(_ workspace: RhythmWorkspace) {
        guard selection.workspace != workspace else {
            if workspace == .playground { showingPlaygroundIndex = true }
            return
        }
        selection = workspace.defaultSection
        showingPlaygroundIndex = workspace == .playground
    }

    private func selectRecord(_ section: RhythmSection) {
        selection = section
        showingPlaygroundIndex = false
    }

    private func handleIntegratedRoute() {
        guard routeRevision > handledRouteRevision, let route,
              ["gaojiezou", "gaojiankang", "gaozuji"].contains(route.scheme ?? "") else { return }
        handledRouteRevision = routeRevision
        selection = RhythmSection.destination(for: route)
        if selection.workspace == .playground { showingPlaygroundIndex = false }
    }

    @ViewBuilder
    private var detail: some View {
        if selection.workspace == .playground && showingPlaygroundIndex {
            PlaygroundIndex(selection: $selection, showingIndex: $showingPlaygroundIndex)
        } else {
            switch selection {
            case .today:
                TodayDashboard(selection: $selection)
            case .habits:
                HabitDashboard()
            case .chores:
                ChoreDashboard()
            case .focus:
                FocusDashboard()
            case .sleep:
                SleepDashboard()
            case .statistics:
                StatisticsDashboard()
            case .longGoals:
                LongGoalDashboard()
            case .shortActions:
                ShortActionDashboard()
            case .farm:
                FarmGameView()
            case .pasture:
                PastureGameView()
            case .fishing:
                FishingHubView()
            case .collection:
                CollectionView()
            case .healthOverview, .healthEvents, .healthWater, .healthSleep, .healthMeals,
                 .healthExercise, .healthWeight, .healthTrends, .healthIsland:
                IntegratedHealthView(section: selection, route: route, routeRevision: routeRevision) { selection = $0 }
            case .footprintsMap, .footprintsTrips, .footprintsTimeline, .footprintsResidentCity, .footprintsTrain:
                IntegratedFootprintsView(section: selection, route: route, routeRevision: routeRevision) { selection = $0 }
            }
        }
    }

    private func updateWindowTitle() {
        let title = RhythmAppInfo.windowTitle
        for window in NSApplication.shared.windows where window.title.contains("搞节奏") || window.title.contains("Rhythm") {
            window.title = title
        }
    }
}
