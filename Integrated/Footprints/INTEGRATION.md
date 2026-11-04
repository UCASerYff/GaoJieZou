# 足迹原生模块整合

状态：生产接入源码与隔离检查源码已准备。未迁移真实资料，未启动 App/GUI，未安装、发布或退役来源。编译与合成执行由总协调的唯一重任务租约安排；本文件不把静态盘点当成实机验收。

来源基线为搞足迹 V4.03/build4，BID `com.gaoseries.GaoZuJi`，Git `fb7fbc76c419b7950325256e82210d6ef6d0bbf2`。全部运行和构建资源已经复制进本项目，本模块不链接来源项目目录，不唤起旧 App。

## 功能与资料覆盖

| 原功能/实物 | 本地实现 | 目标资料与保护 |
|---|---|---|
| 中国/世界离线地图、地点搜索、拼音与别名、自定义城市 | Sources/MapView、Shared/Models、Resources/Geography | 原 geography 版本与全部资源随框架；原自定义城市 ID、经纬度不变 |
| 点亮/编辑/删除足迹、未知/年/月/日精度、筛选、撤销 | Sources/Editors、Store、JournalViews | 原 `items.visit` 行、日期精度、时间戳、城市/旅行关联保留；仅正常用户操作修改 |
| 旅行及关联、时间轴、常住城市、统计 | Sources/JournalViews、ResidentCityView、Shared/Models | 原旅行/城市/常住元数据保留；常住城市不换算为访问奖励 |
| 照片导入、缩略图、查看、未保存暂存取消 | Store.importPhoto/discardStaged、Editors、TrainView | Photos 全目录与 attachment ID/文件名/大小/SHA；导入为正常文件选择授权，不声称旧沙箱书签转授 |
| 历史与删除后照片、恢复前副本 | Repository.dailySnapshot/restore、Photos、Snapshots | 原目录整体迁入，保留孤立照片/快照/恢复前文件；来源没有独立持久“回收站”表，删除撤销在内存，历史快照继续保留照片 |
| CSV、JSON、含照片的 .footprintsbackup 导入导出 | Repository/Store 原实现 | 旧 `GaoZuJi.backup` 格式与旧无列车字段摘要兼容；完整 ZIP 只对根 footprints.sqlite 做一致快照，历史/恢复目录内其他 SQLite/WAL/SHM 连同空目录、xattr/ACL 按原字节复制；迁移本身不调用恢复，不整库覆盖新资料 |
| 完整 ZIP 资料导出、完整恢复与下一次启动接续 | HostSupport/BackupIntegrity、AppBackupExport、AppBackupRestore | 新恢复任务落到 Rhythm support/IntegratedRecovery/Footprints；展开、准备与安全前身在 .noindex；支持旧完整备份 appID，输出新模块 appID；源 pending 旧绝对 URL 不执行 |
| 列车/车厢升级、拖动排列、路线、在途巡游、场景/照片回忆 | Shared/TrainEngine、Sources/Train*、GameWorld | TrainState 全字段、原物资及终身量、claimedVisit/City/Photo/Trip/Note IDs、journey 原样保留；不折算到节奏币，不因迁移结算 |
| 动画/音效/主人名称、语言/外观、观察车紧凑/自动巡游 | 新 suite 与 IntegratedPreferences | 来源原始偏好整体归档；仅映射已审定标量，target 已有键优先，SHA 标记避免重导，不写宿主 standard |
| 地图组件及常住城市/地图范围 | Widgets 独立 appex，Shared/WidgetGeneration | 原 medium map 尺寸完整保留；新 kind、BID 与新 group，仅消费目标完整 generation；损坏用最后有效完整代，不制造零值 |
| 无界面升级派生发布 | FootprintsModuleRuntime.publishSavedSnapshot | 同源主库只读，核全照片与 source fingerprint；公共原生 API 取代旧独立 helper，不运行 Store 或游戏结算 |
| 模块设置/完整资料页/外观页 | FootprintsSettingsView/DataSettingsView/AppearanceSettingsView | 供搞节奏设置页嵌入，无独立窗口或来源 App 依赖 |

## 固定路径与唯一权威

- 来源 Application Support 的完整 `GaoSeries/Footprints` → 节奏 App Group `Integration/Modules/Footprints`，内部 SQLite、Photos、Snapshots、恢复前文件、隐藏/未知资料仍由迁移器保真复制。
- 来源 App Group `5G96498KGJ.com.gaoseries.GaoZuJi` 全部 → `Integration/Modules/Footprints/WidgetData`，不与主数据平铺。
- 生产入口仅从共同 `IntegrationAuthority.swift` 的 active authority 解析路径；Store 在 authority、主库与 Preferences.plist 核对前不创建。空文件、缺失主库、坏 schema 不当新空库。
- 足迹 SQLite 生产写、照片导入/暂存清理、日快照和派生发布全程持共同 SH 写租约。Repository 同时核打开时 DB 的 device/inode；原目录被恢复替换后，旧连接不能继续写前身。
- 完整恢复持共同 EX 维护租约（owner `footprints`），Job 绑定 authority transactionID/原字节 SHA。租约内只使用已绑定 authority 的固定路径，不再进入 SH。异常保留 pending 和维护 marker；恢复失败/断电重进会保留部分新目录到安全 .noindex 再恢复前身。EX 内先保存 durable completed/recovered 阶段，通用 helper 成功清 marker 后才把 pending 移到 Completed.noindex；中间任一点崩溃都不会制造孤儿 marker 或重放已完成恢复。
- 新 widget 是只读消费者；其诊断改为无业务名称/路径的系统日志，不回写共享目录。旧来源 widget/独立 helper 必须由总协调精确停止并替换，旧桌面实例不能自动声称已转授到新 BID。

## 偏好契约

迁移器生成 `Modules/Footprints/Preferences.plist`：`{schema:1, standard:{...}, module:{...}}`。这不是读失败后的空默认：缺文件、坏类型/schema 全部拒绝；来源域本来不存在须由迁移器显式记录 absence。完整原始源 plist 另归档。

- 新 suite：`com.gaojiezou.rhythm.integrated.footprints`。
- 来源 module suite `com.gaoseries.GaoZuJi.Footprints`：animationEnabled、soundEnabled、ownerName。
- 来源 standard `com.gaoseries.GaoZuJi`：gqns.language、gqns.appearance、gqns.home.compact、gqns.train.autoTour。
- 只导入上述标量，先完整类型校验再写；已有目标键优先，用原迁移偏好文件 SHA 标记。缺省源键保持未设置。模块语言/外观只作用模块，不覆盖节奏宿主语言/外观或原庄园设置。
- 原通知、沙箱书签、隐私授权及钥匙串不被自动转授；足迹本身不持钥匙串业务凭据，完整原偏好作为恢复依据保留。

## 编译选源及 API

框架模块名 `RhythmFootprints`：本目录 Sources、Shared、GameWorld、HostSupport 的 `*.swift`，加 Module.swift 与根 `Integration/Shared/IntegrationAuthority.swift`。Tools、Widgets、Tests 不进入 framework glob。Resources 和 GameWorld/Resources 均复制到 framework Resources。

依赖与来源一致：SwiftUI/AppKit/WidgetKit/Charts/CryptoKit/AppIntents/SceneKit/WebKit/UniformTypeIdentifiers/Security/PDFKit/QuickLookUI/UserNotifications/Combine/CoreText/ImageIO，以及 SQLite3。

独立组件工程 `Widgets/RhythmFootprintsWidgets.xcodeproj`，target/product/executable `RhythmFootprintsWidgets`；产物 `RhythmFootprintsWidgets.appex`，BID `com.gaojiezou.rhythm.footprints.widgets`，4.10/build11。只节奏 group entitlement；工程引用本地源及根共同 authority，保留独立 @main。kind `com.gaojiezou.rhythm.footprints.map`，支持 systemMedium；其他尺寸不是原有功能，未虚增。

公共 API：`FootprintsModuleView(route:routeRevision:)`、`FootprintsSettingsView`、`FootprintsDataSettingsView`、`FootprintsAppearanceSettingsView`、`FootprintsModuleRuntime.applyPendingRestoreBeforeOpening()`、`FootprintsModuleRuntime.publishSavedSnapshot(requireHostStopped:)`。

Root 在任何 Store 前无条件调用 applyPendingRestoreBeforeOpening；无 pending 时直接 return，不触发 authority 或 singleton 初始化。首次视图 ActivationGate 另做偏好与主库核对。公共派生 publisher 默认要求新 host 已退出；Root 的正常运行调度若明确同进程，可传 false，仍有 SH 与只读源校验。

URL 为 `gaojiezou://footprints/{map,train,trips,timeline,new,search,undo,export,import}`。map 支持 `?scope=china|world`；routeRevision 在模块 runtime 中只消费一次，切出再切回不会重放旧 action；export/import 仅用户菜单/链接显式触发。旧 gaozuji URL 不再由本模块当写入口；旧调用者与桌面实例由总协调改指。

## 必要隔离验证准备与待验

已做文件/路径/工程/plist 静态核对；未做新候选编译、合成执行或 GUI 验收。Tests/IntegrationCoreRegression.swift 只用合成文件与内存偏好 provider，准备覆盖偏好缺失/类型错/幂等、目标已有设置优先、旧 SQLite inode 拒绝、完整恢复暂存损坏重试及主目录缺失的中断回滚；编译时必须 `INTEGRATION_PATH_TEST`，所有恢复 jobs 留在合成 group/TestApplicationSupport，不触及用户 support。

切换前仍须：Root 完整源/目标备份与一致 SQLite/WAL/附件摘要、原恢复队列和偏好盘点、所有旧写者冻结；候选编译及必要合成检查通过；权限/主要业务/原游戏和受影响组件有边界实机核对；安装发布/公开下载/唯一入口确认。外接设备范围“不做（用户取消）”，不计通过。来源项目/App/GitHub 的退役仅 Root 在全部闸门满足后执行。
