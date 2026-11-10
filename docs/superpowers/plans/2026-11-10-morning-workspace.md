# 搞节奏晨光工作台 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本会话由用户明确禁止使用子代理，因此只采用 Inline Execution。

**Goal:** 将搞节奏 4.10 的长侧栏与分散记录入口重构为五个「晨光工作台」，统一视觉和编辑组件，并在不改动业务数据的前提下发布 4.11/build 12。

**Architecture:** 保留 `RhythmSection`、三个现有 Store、模块 Engine 和深链枚举，新增纯映射 `RhythmWorkspace` 与 SwiftUI 主壳。二级导航只改变展示状态，保存仍走原业务链路；共享主题与记录容器负责新视觉，旧页面逐步嵌入而不复制业务逻辑。

**Tech Stack:** macOS 14+、Swift 5、SwiftUI、AppKit、SQLite、现有 zsh 构建脚本、Python 3 回归测试、GitHub Releases。

## Global Constraints

- 只修改 `/Users/yufeifan/Desktop/搞app/搞节奏`，不使用子代理。
- 版本从 `4.10/11` 升为 `4.11/12`，使用 `scripts/build.sh` 和既定 Apple Development 签名。
- 新 `.app` 只能先生成于 `build.noindex` 等 `.noindex` 容器。
- 不改变数据格式、资料路径、共享睡眠协议、奖励去重、游戏货币、钥匙串或组件协议，不执行迁移/激活。
- 不运行 `snapshot`、`test_backup.sh` 或任何预更新备份；不创建恢复副本。
- 删除自动备份入口和既有备份，但保留现用记录、设置、附件、数据库、游戏进度与钥匙串。
- 测试窗口随用随关；正式入口只能是 `/Applications/搞节奏.app`。
- GitHub 只发布源码、最新版 ZIP 和 SHA-256，不上传用户资料、备份或凭据。

---

### Task 1: 稳定的工作台映射与导航回归

**Files:**
- Create: `Sources/WorkspaceNavigation.swift`
- Create: `Tests/WorkspaceNavigationRegression.swift`
- Create: `scripts/test_workspace_navigation.sh`
- Test: `Tests/WorkspaceNavigationRegression.swift`

**Interfaces:**
- Consumes: 现有 `RhythmSection.allCases`、`RhythmSection.destination(for:)`。
- Produces: `RhythmWorkspace.today/rhythm/health/footprints/playground`、`RhythmWorkspace.section(for:)`、`RhythmWorkspace.tabs(for:)`、`RhythmSection.workspace`。

- [ ] **Step 1: 写失败测试，覆盖全部旧入口不丢失**

```swift
import Foundation
@main struct WorkspaceNavigationRegression {
    static func main() {
        for section in RhythmSection.allCases {
            let workspace = section.workspace
            assert(workspace.section(for: section) == section)
        }
        assert(RhythmSection.healthWater.workspace == .health)
        assert(RhythmSection.footprintsTrain.workspace == .playground)
        assert(RhythmWorkspace.rhythm.tabs(for: .longGoals).contains(.longGoals))
        assert(RhythmWorkspace.health.tabs(for: .healthWater).contains(.healthOverview))
        assert(RhythmWorkspace.playground.tabs(for: .farm).count == 6)
        print("PASS Workspace: every legacy section remains reachable")
    }
}
```

- [ ] **Step 2: 编译并确认因符号缺失而失败**

Run: `zsh scripts/test_workspace_navigation.sh`  
Expected: FAIL，`cannot find 'RhythmWorkspace' in scope`。

- [ ] **Step 3: 实现纯映射，不改旧 rawValue**

```swift
import Foundation

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

    func section(for selection: RhythmSection) -> RhythmSection { selection }

    func tabs(for selection: RhythmSection) -> [RhythmSection] {
        switch self {
        case .today: [.today]
        case .rhythm: [.focus, .sleep, .habits, .chores, .longGoals, .shortActions, .statistics]
        case .health: [.healthOverview, .healthEvents, .healthTrends]
        case .footprints: [.footprintsMap, .footprintsTrips, .footprintsTimeline]
        case .playground: RhythmSection.rewardPages
        }
    }
}

extension RhythmSection {
    var workspace: RhythmWorkspace {
        if self == .today { return .today }
        if Self.healthPages.contains(self) { return .health }
        if Self.travelPages.contains(self) { return .footprints }
        if Self.rewardPages.contains(self) { return .playground }
        return .rhythm
    }
}
```

- [ ] **Step 4: 用与现有回归一致的编译参数运行测试**

`test_workspace_navigation.sh` 使用 `mktemp -d` 和 EXIT 清理，编译 `AppLanguage.swift`、`AppTheme.swift`、`Models.swift`、`WorkspaceNavigation.swift` 与测试；测试不得访问真实 UserDefaults 或资料目录。

Run: `zsh scripts/test_workspace_navigation.sh`  
Expected: `PASS Workspace: every legacy section remains reachable`。

- [ ] **Step 5: 提交**

```bash
git add Sources/WorkspaceNavigation.swift Tests/WorkspaceNavigationRegression.swift scripts/test_workspace_navigation.sh
git commit -m "增加晨光工作台导航映射"
```

### Task 2: 晨光主题、顶部主壳和乐园索引

**Files:**
- Modify: `Sources/AppTheme.swift`
- Modify: `Sources/ContentView.swift`
- Create: `Sources/WorkspaceViews.swift`
- Modify: `Sources/DashboardViews.swift`

**Interfaces:**
- Consumes: Task 1 的 `RhythmWorkspace`、`RhythmSection.workspace`。
- Produces: `WorkspaceTopBar(selection:onSelect:)`、`WorkspaceTabBar(selection:sections:)`、`PlaygroundIndex(selection:)`、`MorningCard<Content: View>`。

- [ ] **Step 1: 扩展主题回归断言**

在 `WorkspaceNavigationRegression.swift` 断言五个工作台的标题、图标非空，并断言 `RhythmTheme.morningGreen != RhythmTheme.morningClay`，防止主操作色与导航色失去层级。

- [ ] **Step 2: 实现可复用主题和卡片**

```swift
struct MorningCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(RhythmTheme.cardBorder, lineWidth: 1))
            .shadow(color: RhythmTheme.cardShadow, radius: 12, y: 5)
    }
}
```

在 `RhythmTheme` 增加 `morningGreen = #365C4D`、`morningClay = #C97657`、`morningSage = #DCE5D5`、`cardBorder`、`cardShadow`，将 `blue` 保留为兼容别名但指向新主色；`canvasColor` 浅色基色改为 `#F4F0E8`、深色基色改为暖炭灰。

- [ ] **Step 3: 用顶部主壳替换侧栏**

`ContentView` 保留 `selection: RhythmSection` 的 SceneStorage 和全部通知处理，删除 `sidebarHidden`、侧栏行、状态底卡及侧栏工具栏空容器。主体改为：

```swift
VStack(spacing: 0) {
    WorkspaceTopBar(selection: $selection) { selection = $0 }
    if selection.workspace != .today && selection.workspace != .playground {
        WorkspaceTabBar(selection: $selection,
                        sections: selection.workspace.tabs(for: selection))
    }
    detail.id(settings.language)
}
.frame(minWidth: 1040, minHeight: 700)
.background(settings.canvasColor(for: colorScheme).ignoresSafeArea())
```

顶部选中工作台时，当前业务页不属于该工作台的可见标签，则进入该工作台首个标签；深链和通知仍直接写 `selection`，不增加第二套路由状态。

- [ ] **Step 4: 增加乐园索引**

`PlaygroundIndex` 使用 `RhythmSection.rewardPages` 和 `count(for:)` 的真实计数生成六张卡片。只有选中具体游戏后才渲染既有游戏视图，并提供“返回乐园”按钮；用 `@SceneStorage("gqns.playgroundIndexVisible")` 保存索引状态，深链进入游戏时自动关闭索引。

- [ ] **Step 5: 重排今天首页并复用真实业务**

`TodayDashboard` 保留月历、习惯完成、短期行动、健康卡和奖励；顶部改为晨光问候、当前专注/睡眠 hero、习惯与睡眠摘要，按钮仍写 `selection`。不得新增计时、睡眠或奖励计算。

- [ ] **Step 6: 构建并验证**

Run: `./scripts/build.sh`  
Expected: 输出 `Built /Users/yufeifan/Desktop/搞app/搞节奏/build.noindex/搞节奏.app`，`codesign --verify --deep --strict` 成功。

- [ ] **Step 7: 提交**

```bash
git add Sources/AppTheme.swift Sources/ContentView.swift Sources/WorkspaceViews.swift Sources/DashboardViews.swift Tests/WorkspaceNavigationRegression.swift
git commit -m "实现晨光工作台主壳与乐园索引"
```

### Task 3: 二级页面与统一记录界面

**Files:**
- Modify: `Sources/FocusSleepViews.swift`
- Modify: `Sources/GoalViews.swift`
- Modify: `Sources/ChoreViews.swift`
- Modify: `Integrated/Health/Sources/RecordEditor.swift`
- Modify: `Integrated/Health/Sources/TodayRecords.swift`
- Modify: `Integrated/Footprints/Sources/Editors.swift`
- Create: `Sources/RecordChrome.swift`

**Interfaces:**
- Consumes: 原 Store 绑定、校验和保存函数。
- Produces: `RecordSection(title:content:)`、`RecordField(title:content:)`、`RecordActionBar(cancelTitle:saveTitle:onCancel:onSave:)`。

- [ ] **Step 1: 先运行现有受影响业务回归作为基线**

Run: `zsh scripts/test_habit_backfill.sh && zsh scripts/test_sleep_sync.sh && zsh scripts/test_shared_sleep.sh`  
Expected: 三个脚本均 PASS；若基线失败，停止 UI 修改并记录实际失败。

- [ ] **Step 2: 实现共享记录容器**

```swift
struct RecordSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .padding(18)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(RhythmTheme.cardBorder))
    }
}
```

`RecordField` 使用 12pt 次级标题、12px 圆角输入背景、明确焦点边框；`RecordActionBar` 保留取消在左、主操作在右、ESC/回车快捷键及禁用状态。

- [ ] **Step 3: 改造健康 RecordEditor，不改 submit**

将顶部、时间、类型字段、备注、校验和底部操作分别嵌入共享组件；`submit()`、`parse()`、`Engine.validateRecord` 和 `store.save(record:template:)` 原样保留。补记和编辑模式不得改变 `occurredAt` 规则。

- [ ] **Step 4: 改造旅行与节奏编辑器**

`VisitEditor` 改为顶部标题、城市搜索列表、日期/旅行/备注/照片分组与固定底部操作；`TripEditor`、习惯、琐事、目标、睡眠手动录入采用相同间距和操作条。所有原 `save()`、草稿初始化、未保存确认、照片暂存清理与附件导入保持调用关系。

- [ ] **Step 5: 健康记录流与筛选**

健康二级页“今日/全部记录/统计趋势/快速事项”中，“全部记录”使用现有 `TodayRecords` 的记录数据源和编辑/撤销动作，增加类型筛选 chips；筛选项映射回 `.healthWater`、`.healthSleep`、`.healthMeals`、`.healthExercise`、`.healthWeight`，保证旧深链仍打开对应类型并显示筛选状态，不创建新数据库查询权威。

- [ ] **Step 6: 运行回归和完整构建**

Run: `zsh scripts/test_workspace_navigation.sh && zsh scripts/test_habit_backfill.sh && zsh scripts/test_sleep_sync.sh && zsh scripts/test_shared_sleep.sh && ./scripts/build.sh`  
Expected: 全部 PASS，签名构建成功。

- [ ] **Step 7: 提交**

```bash
git add Sources/RecordChrome.swift Sources/FocusSleepViews.swift Sources/GoalViews.swift Sources/ChoreViews.swift Integrated/Health/Sources/RecordEditor.swift Integrated/Health/Sources/TodayRecords.swift Integrated/Footprints/Sources/Editors.swift
git commit -m "统一晨光记录界面与健康记录流"
```

### Task 4: 移除备份功能并保护现用资料

**Files:**
- Modify: `Host/AppMain.swift`
- Modify: `Host/Settings.swift`
- Modify: `Module.swift`
- Modify: `Integrated/Health/Module.swift`
- Modify: `Integrated/Footprints/Module.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: 原通知和设置入口。
- Produces: 仅保留“打开数据目录/小组件共享目录”的 `DataSettings`；菜单不再出现任何备份或恢复动作。

- [ ] **Step 1: 写静态回归，确认失败**

新增 `Tests/test_no_backup_ui.py`，读取上述 Swift 文件，断言 `导出完整资料`、`恢复`、`导出模块备份`、`完整资料备份与恢复` 不存在于可执行 UI 字符串和菜单；先运行应 FAIL。

- [ ] **Step 2: 移除入口和启动恢复**

删除 App `CommandMenu("数据")` 中全部备份/恢复菜单、设置中的完整资料和模块格式 Section、模块导出/恢复通知监听，以及启动时自动应用待恢复任务的调用。保留旧备份解析源码仅供历史测试不参与运行，避免扩大底层删改；新应用没有创建备份或安排恢复的可达路径。

- [ ] **Step 3: 保留数据目录入口并更新隐私说明**

`DataSettings` 只显示两个目录按钮，不主动创建缺失目录后才打开；目录缺失时显示“资料目录尚未创建”，避免把缺失当作空白库创建。README 删除备份恢复教程，明确 V4.11 不再提供或生成备份。

- [ ] **Step 4: 运行静态测试和构建**

Run: `python3 Tests/test_no_backup_ui.py && ./scripts/build.sh`  
Expected: `PASS: no backup or restore UI entry` 和构建成功。

- [ ] **Step 5: 提交**

```bash
git add Host/AppMain.swift Host/Settings.swift Module.swift Integrated/Health/Module.swift Integrated/Footprints/Module.swift Tests/test_no_backup_ui.py README.md
git commit -m "移除搞节奏备份与恢复入口"
```

### Task 5: 版本、真实界面验收、无备份安装清理

**Files:**
- Modify: `Info.plist`
- Modify: `README.md`
- Create: `docs/V4.11-morning-workspace.md`
- Modify: `scripts/install.sh` only if static inspection finds backup/snapshot invocation or indexed staging `.app`

**Interfaces:**
- Consumes: 前四项任务的可构建主壳。
- Produces: 已签名的 4.11/build 12 APP、`dist/GaoJieZou-4.11.zip` 和 `.sha256`。

- [ ] **Step 1: 核验资料且不生成备份**

用 Python 只读遍历 `~/Library/Application Support/GaoSeries/Rhythm` 和 App Group，输出相对路径、文件大小和 SHA-256 到 stdout，不写入项目；检查 SQLite 表数与记录计数。运行前退出搞节奏，禁止 `upgrade_data.py snapshot`。

- [ ] **Step 2: 更新版本并构建发行包**

`Info.plist` 仅改 `CFBundleShortVersionString=4.11` 和 `CFBundleVersion=12`。静态检查 build/package/install 的 APP 输出均在 `.noindex`，安装脚本无 snapshot 和备份命令。

Run: `./scripts/build.sh && ./scripts/package.sh`  
Expected: 生成 `dist/GaoJieZou-4.11.zip` 和同名 `.sha256`，签名校验成功。

- [ ] **Step 3: 运行受影响回归**

Run: `zsh scripts/test_workspace_navigation.sh && zsh scripts/test_habit_backfill.sh && zsh scripts/test_sleep_sync.sh && zsh scripts/test_shared_sleep.sh && zsh scripts/test_widget_sync.sh && python3 Tests/test_no_backup_ui.py`  
Expected: 全部 PASS。

- [ ] **Step 4: 安装并验收真实界面**

使用现有安装脚本但提供已激活现状所需的参数，不执行新迁移。依次验证五个工作台、所有二级标签、健康筛选、主要记录编辑器的取消保存、六个游戏入口、旧深链和三个组件；新增测试记录使用明确的测试标题，验证后按原业务删除，不触碰既有记录。每个窗口用完立即关闭。

- [ ] **Step 5: 核验数据并精确清理**

再次计算现用资料摘要并对比，确认业务文件未因替换程序丢失。删除 `build.noindex`、旧 ZIP、`.release.noindex`、`.install.noindex`、`rollback*`、项目内已识别备份以及搞节奏专属旧备份；不得删除现用数据目录或 App Group。用 `mdfind` 和 LaunchServices 打印真实路径，只有 `/Applications/搞节奏.app` 才能通过唯一性验收。

- [ ] **Step 6: 提交发布文档**

```bash
git add Info.plist README.md docs/V4.11-morning-workspace.md scripts/install.sh
git commit -m "发布搞节奏 V4.11 晨光工作台"
```

### Task 6: GitHub 源码与 Release

**Files:**
- Modify: none beyond release metadata if verification requires it
- Test: `git status --short`、ZIP SHA-256、Release 附件列表

**Interfaces:**
- Consumes: Task 5 的最新 ZIP、SHA-256 和已提交源码。
- Produces: `origin/main` 与 `v4.11` Release。

- [ ] **Step 1: 检查公开内容**

Run: `git status --short && git diff --check && git ls-files | python3 -c 'import sys; bad=[x.strip() for x in sys.stdin if any(k in x.lower() for k in ("backup","rollback","accounts.json","library.json",".sqlite",".env"))]; print("\n".join(bad)); raise SystemExit(bool(bad))'`  
Expected: 工作区只含被忽略的 latest dist，敏感/备份路径列表为空。

- [ ] **Step 2: 推送源码**

Run: `git push origin main`  
Expected: GitHub `main` 包含全部 V4.11 提交。

- [ ] **Step 3: 创建 Release 并上传两个附件**

Run: `gh release create v4.11 dist/GaoJieZou-4.11.zip dist/GaoJieZou-4.11.zip.sha256 --repo UCASerYff/GaoJieZou --title "搞节奏 V4.11 · 晨光工作台" --notes-file docs/V4.11-morning-workspace.md`  
Expected: Release 创建成功且仅有两个二进制附件，源码由 GitHub 自动提供。

- [ ] **Step 4: 最终复核**

Run: `gh release view v4.11 --repo UCASerYff/GaoJieZou --json tagName,assets,url` 和 `shasum -a 256 -c dist/GaoJieZou-4.11.zip.sha256`  
Expected: 标签、附件和本机校验一致；本机版本 4.11/build12、唯一安装入口和用户资料核验均通过。
