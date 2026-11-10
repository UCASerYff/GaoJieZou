import SwiftUI
import AppKit

/// One health function inside the merged host. The host owns the only sidebar,
/// brand header and sidebar toggle; the existing page title and actions remain.
struct ContentView: View {
    let page: HealthNavigationPage
    @EnvironmentObject var store: AppStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(spacing: 0) {
            if let fatal = store.fatalError {
                VStack(spacing: 16) {
                    EmptyCard(symbol: "externaldrive.badge.exclamationmark",
                              title: store.t("暂时无法读取数据", "Data unavailable"), detail: fatal)
                    Button(store.t("重试", "Retry")) { store.reload() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        selectedContent
                    }
                    .padding(28)
                    .frame(maxWidth: 1250)
                    .frame(maxWidth: .infinity)
                }.id(page)
            }
            if let notice = store.notice {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                    Text(notice).font(.caption)
                    Spacer()
                    if store.undoRecord != nil || store.undoEvent != nil {
                        Button(store.t("撤销", "Undo")) { store.undo() }.buttonStyle(.link)
                    }
                    Button { store.notice = nil; store.undoRecord = nil; store.undoEvent = nil } label: {
                        Image(systemName: "xmark")
                    }.buttonStyle(.plain).help(store.t("关闭提示", "Dismiss"))
                }
                .padding(.horizontal, 24).padding(.vertical, 10)
                .background(Theme.teal.opacity(0.07))
            }
        }
        .background(Theme.background(scheme == .dark, store.state.preferences.backgroundHex))
        .toolbar {
            toolbarItemNoChrome(.primaryAction) {
                HStack(spacing: 12) {
                    Menu {
                        Button(store.t("睡眠记录", "Sleep")) { store.newSleep() }
                        ForEach(RecordKind.allCases) { kind in
                            Button(kind.title(store.en)) { store.new(kind) }
                        }
                    } label: { Label(store.t("记一笔", "Record"), systemImage: "plus") }
                    BackfillRecordMenu()
                }.frame(width: 360, alignment: .trailing)
            }
        }
        .sheet(isPresented: $store.sleepEditor) { SleepRecordEditor().environmentObject(store) }
        .sheet(item: $store.editor) { record in RecordEditor(record: record).environmentObject(store) }
        .alert(store.t("操作未完成", "Action failed"), isPresented: Binding(
            get: { store.message != nil }, set: { if !$0 { store.message = nil } }
        )) {
            Button(store.t("好", "OK")) { store.message = nil }
        } message: { Text(store.message ?? "") }
        .onChange(of: phase) { _, value in if value == .active { store.reload() } }
        .onChange(of: store.selectedTab) { _, tab in
            if tab != HealthNavigationPage.island.selectedTab { store.reload() }
        }
        .onChange(of: store.notice) { _, current in
            guard let current else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                if store.notice == current { store.notice = nil; store.undoRecord = nil; store.undoEvent = nil }
            }
        }
    }

    @ViewBuilder private var selectedContent: some View {
        switch page {
        case .overview: TodayView()
        case .records: AllHealthRecordsView()
        case .events: QuickEventsView()
        case .water: AllHealthRecordsView(initialFilter: .water)
        case .sleep: SleepRecordsView()
        case .meals: AllHealthRecordsView(initialFilter: .meals)
        case .exercise: AllHealthRecordsView(initialFilter: .exercise)
        case .weight:
            if store.state.preferences.hideWeight {
                SectionTitle(title: store.t("体重记录", "Weight records"),
                             subtitle: store.t("体重记录已在健康设置中隐藏。", "Weight records are hidden in Health settings."))
                EmptyCard(symbol: "eye.slash", title: store.t("体重记录已隐藏", "Weight records hidden"),
                          detail: store.t("原记录仍保留，可在健康设置中重新显示。", "Existing records are retained. Show them again in Health settings."))
            } else { AllHealthRecordsView(initialFilter: .weight) }
        case .trends: TrendsView()
        case .island: IslandView()
        }
    }
}

@ToolbarContentBuilder
private func toolbarItemNoChrome<Content: View>(
    _ placement: ToolbarItemPlacement,
    @ViewBuilder content: @escaping () -> Content
) -> some ToolbarContent {
    if #available(macOS 26.0, *) {
        ToolbarItem(placement: placement, content: content).sharedBackgroundVisibility(.hidden)
    } else {
        ToolbarItem(placement: placement, content: content)
    }
}
