import AppKit
import SwiftUI

struct MorningCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(RhythmTheme.cardBorder))
            .shadow(color: RhythmTheme.cardShadow, radius: 12, y: 5)
    }
}

struct WorkspaceTopBar: View {
    let selection: RhythmSection
    let onWorkspace: (RhythmWorkspace) -> Void
    let onRecord: (RhythmSection) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 10) {
                if let url = RhythmBundle.bundle.url(forResource: "GaoJieZouIcon", withExtension: "png"),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                }
                Text(RhythmLocalization.text("搞节奏"))
                    .font(.system(size: 18, weight: .semibold, design: .serif))
            }
            .frame(minWidth: 128, alignment: .leading)

            HStack(spacing: 4) {
                ForEach(RhythmWorkspace.allCases) { workspace in
                    Button { onWorkspace(workspace) } label: {
                        Label(workspace.title, systemImage: workspace.symbol)
                            .font(.callout.weight(selection.workspace == workspace ? .semibold : .regular))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 13)
                            .frame(minHeight: 34)
                            .foregroundStyle(selection.workspace == workspace ? Color.white : Color.primary)
                            .background {
                                if selection.workspace == workspace {
                                    Capsule().fill(RhythmTheme.morningGreen)
                                        .shadow(color: RhythmTheme.morningGreen.opacity(colorScheme == .dark ? 0.35 : 0.2), radius: 6, y: 3)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection.workspace == workspace ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)

            Menu {
                Button(RhythmLocalization.text("开始专注")) { onRecord(.focus) }
                Button(RhythmLocalization.text("记录睡眠")) { onRecord(.sleep) }
                Button(RhythmLocalization.text("日常打卡")) { onRecord(.habits) }
                Divider()
                Button(RhythmLocalization.text("健康记录")) { onRecord(.healthOverview) }
                Button(RhythmLocalization.text("记下足迹")) { onRecord(.footprintsMap) }
            } label: {
                Label(RhythmLocalization.text("记录"), systemImage: "plus")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(RhythmTheme.morningClay.opacity(0.12), in: Capsule())
                    .foregroundStyle(RhythmTheme.morningClay)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(RhythmTheme.barBackground)
    }
}

struct WorkspaceTabBar<Trailing: View>: View {
    @Binding var selection: RhythmSection
    let sections: [RhythmSection]
    var onBack: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    init(selection: Binding<RhythmSection>, sections: [RhythmSection], onBack: (() -> Void)? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self._selection = selection
        self.sections = sections
        self.onBack = onBack
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            if let onBack {
                Button(action: onBack) {
                    Label(RhythmLocalization.text("乐园"), systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RhythmTheme.morningGreen)
                }
                .buttonStyle(.plain)
                .padding(.leading, 22)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sections) { section in
                        Button { selection = section } label: {
                            HStack(spacing: 7) {
                                Image(systemName: section.symbol)
                                Text(tabTitle(for: section))
                            }
                            .font(.caption.weight(selection == section ? .semibold : .medium))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .foregroundStyle(selection == section ? RhythmTheme.morningGreen : Color.secondary)
                            .background(selection == section ? RhythmTheme.morningGreen.opacity(0.11) : Color.clear,
                                        in: Capsule())
                            .overlay(Capsule().stroke(selection == section ? RhythmTheme.morningGreen.opacity(0.2) : RhythmTheme.cardBorder))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, onBack == nil ? 26 : 12)
                .padding(.vertical, 8)
            }
            trailing
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .background(RhythmTheme.barBackground.opacity(0.72))
    }

    private func tabTitle(for section: RhythmSection) -> String {
        switch section {
        case .longGoals, .shortActions: section == .longGoals ? RhythmLocalization.text("长期目标") : RhythmLocalization.text("短期行动")
        case .healthOverview: RhythmLocalization.text("今日")
        case .healthEvents: RhythmLocalization.text("快速事项")
        default: section.title
        }
    }
}

extension WorkspaceTabBar where Trailing == EmptyView {
    init(selection: Binding<RhythmSection>, sections: [RhythmSection], onBack: (() -> Void)? = nil) {
        self.init(selection: selection, sections: sections, onBack: onBack) { EmptyView() }
    }
}

struct WorkspacePageHeader: View {
    let workspace: RhythmWorkspace
    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text(workspace.title)
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                Text(workspace.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 6)
    }
}

struct PlaygroundIndex: View {
    @EnvironmentObject private var store: RhythmStore
    @Binding var selection: RhythmSection
    @Binding var showingIndex: Bool

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 18, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WorkspacePageHeader(workspace: .playground)
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(RhythmSection.rewardPages) { section in
                        Button {
                            selection = section
                            showingIndex = false
                        } label: {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Image(systemName: section.symbol)
                                        .font(.system(size: 22, weight: .medium))
                                        .foregroundStyle(color(for: section))
                                        .frame(width: 48, height: 48)
                                        .background(color(for: section).opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.callout)
                                        .foregroundStyle(.tertiary)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(section.title).font(.title3.weight(.semibold))
                                    Text(section.subtitle).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                        .frame(minHeight: 32, alignment: .top)
                                }
                                HStack {
                                    Text(status(for: section))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(color(for: section))
                                    Spacer()
                                    Text(RhythmLocalization.text("进入"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(RhythmTheme.cardBorder))
                            .shadow(color: RhythmTheme.cardShadow, radius: 12, y: 5)
                            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 30)
            }
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
    }

    private func color(for section: RhythmSection) -> Color {
        switch section {
        case .farm: RhythmTheme.green
        case .pasture: RhythmTheme.morningClay
        case .fishing: RhythmTheme.teal
        case .collection: RhythmTheme.purple
        case .healthIsland: RhythmTheme.morningGreen
        case .footprintsTrain: RhythmTheme.orange
        default: RhythmTheme.morningGreen
        }
    }

    private func status(for section: RhythmSection) -> String {
        switch section {
        case .farm: RhythmLocalization.format("%d 块农田生长中", store.farmPlots.filter { $0.cropID != nil }.count)
        case .pasture: RhythmLocalization.format("%d 只牲畜", store.ownedAnimals.reduce(0) { $0 + $1.count })
        case .fishing: RhythmLocalization.format("已发现 %d 种鱼", store.fishCaught.count)
        case .collection: RhythmLocalization.format("已收获 %d 种作物", store.harvestedCrops.count)
        case .healthIsland: RhythmLocalization.text("活力、物资与小岛建设")
        case .footprintsTrain: RhythmLocalization.text("线路、车厢与旅行物资")
        default: ""
        }
    }
}

struct PlaygroundBackBar: View {
    @Binding var showingIndex: Bool
    var body: some View {
        HStack {
            Button { showingIndex = true } label: {
                Label(RhythmLocalization.text("返回乐园"), systemImage: "chevron.left")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(RhythmTheme.morningGreen)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(RhythmTheme.barBackground.opacity(0.75))
    }
}
