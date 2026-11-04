# 健康原生模块整合说明

本目录是搞节奏持有的健康原生源码与资源，来源基线为搞健康 V4.05/build6、提交 `82bc1f93479c5d2c5109e7e1f067996915d7c7c0`。`SOURCE-MANIFEST.json`记录被复制文件的来源摘要。没有复制来源程序、构建产物、个人数据库、备份或凭据；来源项目保持只读。此文记录实现与验证边界，不代表真实迁移、安装或交付已经执行。

## 构建与宿主接口

- 框架模块：`RhythmHealth`。编入本目录 `Sources/*.swift`、`Shared/*.swift`、`GameWorld/*.swift`、`HostSupport/*.swift`、`Module.swift`及接收项目的 `Integration/Shared/IntegrationAuthority.swift`。不能引用搞健康来源文件夹。
- 资源：完整复制 `Resources/`，并将 `GameWorld/Resources/`合入框架 `Resources/`，与来源运行布局一致；保留健康图标、小岛画面、宠物和材质。
- 框架所需系统依赖沿用来源：SwiftUI、AppKit、WidgetKit、Charts、CryptoKit、AppIntents、SceneKit、WebKit、UniformTypeIdentifiers、Security、PDFKit、QuickLookUI、UserNotifications、Combine、CoreText、ImageIO、SQLite3。宿主没有增加硬件权限或隐私授权绕过。
- 原生视图：`HealthModuleView(route:routeRevision:)`、`HealthSettingsView()`、`HealthDataSettingsView()`、`HealthAppearanceSettingsView()`。前两者先经过权威/偏好激活检查，才构造健康 Store；未激活、损坏或缺失时展示失败及重试，不生成空白库。
- 宿主启动顺序：在任何业务 Store/组件发布器打开前调用 `try HealthModuleRuntime.applyPendingRestoreBeforeOpening()`；无 pending 直接返回，不初始化 Store。此 API只认新作用域恢复任务，不重演归档中的来源绝对路径任务。健康 Store 已打开后拒绝执行真正恢复。
- 睡眠协调：`HealthModuleRuntime.syncSleep()`只在权威有效且偏好迁移校验成功后初始化健康模块并同步。`exportModuleBackup()`、`restoreModuleBackup()`保留用户明确触发的兼容模块格式能力。
- 新深链：`gaojiezou://health/`；子路径 `sleep`、`events`、`water`、`meal`、`exercise`、`weight`、`export`、`import`。`routeRevision`守卫使同一明确路由只执行一次；`export/import`仅由菜单/链接触发备份面板，不自行打开窗口。

## 功能、资料与写者覆盖矩阵

| 来源功能 | 搞节奏内实现 | 资料与保全 | 写者/边界 |
|---|---|---|---|
| 今日概览与记录列表 | `Sources/App.swift`、`TodayRecords.swift` | 原饮水、饮食、运动、体重记录 ID、发生/创建/修改时间、时区、备注、来源、历史营养字段不变 | `AppStore`→`HealthDatabase`原事务逻辑 |
| 新增、编辑、删除、补记与撤销 | `RecordEditor.swift`、`Store.swift` | 保留回溯时间、原 ID、模板与撤销行为；不以导入生成新记录 | 真正 CRUD；未重新执行旧实机全套 |
| 用餐来源与饱食、历史热量模型 | `Shared/Models.swift`、`Engine.swift`、`RecordEditor.swift` | 新旧字段完整复制，未把旧营养字段丢弃或虚构为新记录 | 原保存校验与每日奖励额度保持 |
| 常用模板与 CSV | `SettingsView.swift`、`Database.swift` | 模板 ID/使用次数、CSV 的 ID 去重保留；CSV 导入不补发岛屿奖励 | 用户选择文件/目录后操作；无来源 App 调用 |
| 自定义快速事项与月历 | `QuickEventsView.swift`、`EventLog` | 事项类型归档状态、widget 选择、事件 ID/计数/备注/来源全部保留 | 主模块与新事项 Intent 均写同一健康库 |
| 趋势与统计 | `TrendsView.swift` | 按原记录、时区、日期计算 | 真正原生 Charts/视图，不拼接来源截图 |
| 手动睡眠、补记、共同删除 | `SleepRecordsView.swift`、`HealthSleepImport.swift` | 原 `SharedSleepEntry`结构、原 ID、手动/健康来源、结算计数不变 | 只接收新共同睡眠权威；不再从旧库运行时 seed |
| 小岛经营、暂停、劳作、建造、升级、扩建、布局、补给、收获、泡茶、日志 | `IslandView.swift`、`IslandScene.swift`、完整 `GameWorld/`、原 `Engine` | 水分、饱食、活力、库存、工具、建筑/等级/位置、扩建、日期账本、睡眠奖励 ID、请求去重和所有日志完整保留 | 没有换算为节奏金币/鱼饵，没有删除原游戏，没有重新发放迁移奖励 |
| 游戏观察卡与材质/宠物资源 | `GameObservation.swift`及原资源 | 原 `gqns.home.compact`受控迁入健康独立 suite；不覆盖节奏同名键 | 健康 suite 与节奏/足迹独立；UI 语言/外观按宿主原设置 |
| 设置、隐藏指标、记录计划、模板、岛屿启停 | 原 `Preferences`与设置视图 | 完整业务设置仍在健康主 blob；初始化/onboarding、计划生效日与最后结算锚点保留 | 来源 standard/module 全量另有原始档案；旧权限不自动转授 |
| 自动健康备份、兼容 `.healthbackup`、手动恢复 | `HealthDatabase`、`Store` | 原格式和校验继续可用；恢复前保留安全副本；保留请求/睡眠奖励 ID、已消费额度及不再发奖标记 | 仅健康库，不覆盖共同睡眠；明确重置也保留必要去重标记并在确认中说明 |
| 完整 ZIP 备份与下次启动恢复 | 完整 `HostSupport/`原生服务及新作用域实现 | 健康树、共同睡眠快照、来源档案、健康独立偏好均导出并核验；恢复只替换健康树/自有偏好 | 原始来源档案不替换；共同睡眠若需恢复，使用宿主完整整合备份统一恢复 |
| 原来源 AppSupport 内通用附件/文档、原备份与待恢复实物 | 生产迁移契约的 `SourceArchives/Health`与健康资料页“原健康文件”入口 | AppSupport完整活动副本位于 `Modules/Health/ImportedSupport`；同时保留不可变来源树、原偏好 plist和旧 `GaoSeriesRestore/Health`的 pending/staged/safety | 入口只打开已存在的活动副本；明确 absence须核绑定事务的缺失声明，不创建空目录、不执行旧 pending、不开放原档案作为可写工作目录；实际附件验收仍待切换后进行 |
| 原桌面日常/小岛组件及三尺寸 | `Widgets/HealthWidgets.swift`独立新 appex | 同原业务投影、来源时间、生成/读取时间、验证缓存及最后有效版本 | 新 kind、同一新权威；原来源组件需根切换时冻结/替换 |
| 原事项配置与交互 Intent | `EventTypeQuery`、`LogHealthEventIntent`、`QuickWaterIntent`、刷新 Intent | 原事务请求去重集合随存档保留；类型实体按真实库读取 | 新扩展只接收新宿主 group，不写旧库；多实例操作沿原产品语义 |
| 语言、外观、数据位置、隐私授权 | 新宿主设置与本模块设置视图 | 原源偏好保留原字节，不整域覆盖节奏；书签/通知/隐私授权不视为迁移成功 | 需要的新系统授权由用户正常处理；不申请外接/蓝牙硬件权限 |

## 权威、迁移与一致性

唯一新 App Group 为 `5G96498KGJ.com.gaojiezou.rhythm`。健康路径由共同 `RhythmIntegrationPaths.moduleDirectory("health")`返回 `Integration/Modules/Health`，其内部直接包含 `health.sqlite`、`Backups`、组件封装/诊断、发布待重试标记及原其他实物。默认打开要求现有数据库，不因空目录而初始化。显式非生产目录只服务隔离 fixture、归档检查和恢复暂存，不作为运行时备用资料源。

共同睡眠由 `sharedSleepDirectory()`解析到 `Integration/SharedSleep`。`SharedSleepEntry` wire format、`sleep_records`全部字段与 tombstone、`sleep_metadata`、`sleep_migrations`及历史 seed 标记保持。迁移器在激活前处理原 Rhythm legacy/pending/奖励映射；健康运行时 `migrateLegacy`仅核验新权威，不再读取旧主库或重复 seed。

原健康数据库的 SQLite `user_version` 0/1、`HealthState.schemaVersion` 2及原 Engine 保留。主 blob、逐记录 `records`、逐事项 `events`、请求集合、奖励 ID和岛屿账本按原结构使用，没有合并或换算两款游戏的货币。

每个健康/共同睡眠生产读写连接在使用前复核当前权威和打开文件的 device/inode；原目录被原子替换后，旧连接拒绝继续访问。生产事务从 BEGIN 至 COMMIT 持共同 `withWriterLease` 的 SH，并在 BEGIN 后再次复核。组件缓存、诊断、待重试写入亦参加 SH，避免恢复 EX 期间派生文件继续写。新数据库通知为 `GaoSeries.rhythm.health.databaseChanged`；新睡眠通知为 `GaoSeries.rhythm.integration.sleep.changed`。通知不授予旧程序写权威的能力。

健康新偏好 suite 为 `com.gaojiezou.rhythm.integrated.health`。`HealthPreferences.prepare`严格核对 `Modules/Health/Preferences.plist`的 schema1、当前 transactionID及完整域结构，仅将健康来源 standard 的 `gqns.home.compact` Bool迁入未有目标值的键，并保留一次性事务标记。源语言/外观保持归档，宿主保留节奏原值；不导入书签或授权。

## 备份与恢复边界

新健康 ZIP 格式 appID 为 `com.gaojiezou.rhythm.health`、format2。导出时健康和共同睡眠的 canonical 数据库使用一致 SQLite 快照；其他备份/来源 `.sqlite`是原始物件，不被打开、VACUUM或改写。来源档案用 `ditto --rsrc --extattr --acl`复制，比较前后文件摘要与空目录集合，保留 raw WAL。ZIP 解压后逐文件 SHA-256核验。单靠元数据复制命令成功不声称完整实机 ACL/xattr 验收已经完成。

兼容读取来源搞健康 format1完整 ZIP；其原 standard偏好与所有其他档案保留供追溯，仅健康的 compact Bool受控映射到新 suite。旧 archive 自带的共同睡眠只校验和留存，不能通过健康入口倒回节奏的新睡眠/奖励。

新恢复任务位于节奏 AppSupport 的 `GaoSeries/Rhythm/IntegratedRecovery/Health`；接收、解压和原子替换暂存预先使用 `.noindex`容器。旧源 pending 不能被新任务 decoder接收。任务绑定当前 authority 文件完整 SHA，健康目标固定为本事务路径；不接受外来绝对目标路径。复制、校验、保留原激活 Preferences.plist、合并当前奖励/请求去重收据后，才持 owner `health`的共同 EX原子替换健康树。当前健康不可读取时拒绝将其理解为无奖励历史。恢复时保留当前游戏请求、已计睡眠 ID、已消费每日额度和记录不再发奖标记，防较旧健康备份对当前共同睡眠重复结算。

pending 的 `completed`先在 EX内持久化，再由共同 API清 marker并释放 EX，最后归档 pending。此窗口崩溃时下一次只完成归档，不重放业务。失败保留 pending/统一 marker及原始数据，启动恢复先于任何 Store。原健康资料、导入 ZIP展开物、导入旧偏好、操作收据保留为恢复依据。任何目标摘要不符时拒绝盲目回滚覆盖用户新资料。

## 当前验证与待验项目

- 已做轻量 Swift syntax parse、shell syntax、plist解码、PBX本地源路径核对及旧宿主/group/深链引用搜索；来源工作树仍干净。
- 未得到重编译排队 GO前没有重编译；没有启动应用、GUI、浏览器或执行真实数据迁移、安装、发布和权限请求。没有通用冒烟。
- `Tests/run_integrated_health.sh`与合成 `IntegratedHealthRegression.swift`已准备。调用者必须先持根协调分配的唯一 build lease，并明确设置测试编译 GO。测试仅用 `INTEGRATION_PATH_TEST`隔离目录和独立 test suite，抑制系统组件通知；覆盖缺失权威、原 ID/tombstone/seed、请求幂等、睡眠奖励去重、raw 来源 SQLite/WAL/空目录 ZIP、健康范围恢复、共同睡眠及来源不变、旧 inode拒绝、坏 pending保留 marker。准备不是已通过，执行结果由根构建收据记录。
- 待根在分配的编译槽完成候选语义编译/签名与必要合成检查；再统一安排真实切换、业务/附件/组件、旧写者冻结与唯一入口验证。来源健康退役、真实数据停写/最终 CAS及旧组件替换只由总协调执行。
- 外接设备及蓝牙硬件范围继续“不做（用户取消）”，不计通过。旧第7/10/11实际验收不会作为本次新整合通过的依据，也不无关重跑。
