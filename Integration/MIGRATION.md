# 健康、足迹并入搞节奏：生产迁移契约

此文件说明生产入口及其保护条件，不是实际迁移、停写或交付收据。本阶段只实现迁移器与合成检查；未读取或迁移真实用户资料、未启动应用、未安装发布，未运行通用冒烟。来源源码不构成新宿主的运行或构建依赖。

## 唯一权威与目录

`--target-group` 必须显式指向已存在的搞节奏 App Group 根。主节奏 `library.json`、游戏与计时仍留在原路径，不由本迁移器覆盖。整合数据位于其 `Integration/`：

| 目标路径 | 精确来源及处理 |
|---|---|
|`Modules/Health/`|来源健康 App Group 的 `Health/` 整树；`health.sqlite`、自动备份、初始化标记、快照/dirty状态和其余文件全部保留。|
|`Modules/Health/ImportedSupport/`|来源健康通用 Application Support 非缺失时再整树保真复制，供健康模块日常打开原文件。文档、照片、空目录、元数据及任意 SQLite/WAL/SHM 文件均不解释、不改写；明确缺失时不新建空目录，原健康库已有同名路径则拒绝，不覆盖。原始来源仍另留 `SourceArchives/Health/ApplicationSupport/`。|
|`Modules/Footprints/`|来源足迹 Application Support 的完整根；`footprints.sqlite`、`Photos/`、`Snapshots/`、恢复前备份、列车存档等原布局不变。|
|`Modules/Footprints/WidgetData/`|来源足迹 App Group 整树；不和主足迹目录混平。如来源主目录已有同名 `WidgetData` 则拒绝，交协调者明确处置。|
|`SharedSleep/`|来源健康 App Group 的 `SharedSleep/` 整树。睡眠主键、删除墓碑、元数据、历史迁移 key、奖励记账原样保留。健康和节奏新模块均只指向这一处。|
|`Modules/{Health,Footprints}/Preferences.plist`|新包装 `{schema:1,transactionID,standard,module}`；两域内容来自明确提供的原始导出。足迹模块只导入自己的三个偏好及语言到新独立 suite，已有目标键优先；原节奏标准偏好不整域覆盖。|
|`SourceArchives/Health/`|`AppGroup/`、`ApplicationSupport/`、`PendingRestore/`、原字节 `Preferences.plist`。|
|`SourceArchives/Footprints/`|`ApplicationSupport/`、`AppGroup/`、`PendingRestore/`、原字节 `Preferences.plist`。|
|`SourceArchives/Rhythm/library.json`|冻结时节奏原库的只读存档，用于睡眠兼容核验与追溯，不替换运行库。|
|`SourceArchives/explicit-absences.json`|来源缺失的精确路径及明确缺失声明；读取失败不能登记为缺失。|
|`Transactions.noindex/<transaction>/`|计划摘要、冻结依据、组件清单、准备收据和保留的中断尝试。永不覆盖未知事务或用户新资料。|

运行数据的三份 SQLite 使用私有副本的 SQLite backup API 生成一致、自包含快照，核对全部 schema、表、行和 BLOB 摘要；覆盖 WAL 中已提交的资料。源文件不被 SQLite 打开，避免源 SHM 读标记写入。源的数据库、WAL、SHM、journal 及全部原始资料另保真归档。准备态数据库使用 DELETE 日志模式，避免只读验收创建旁文件；正常生产模块可在打开后切回 WAL。

文件/空目录、模式、UID/GID、BSD flags、修改时间、扩展属性及 macOS ACL 纳入清单；macOS 使用 `ditto --rsrc --extattr --acl` 复制并逐项复核。新逻辑 SQLite 的 ACL、stat、xattr 另复制核验。文件权限、旧书签、通知、钥匙串访问控制或 TCC 许可不等同于向新宿主转授权限。

## 显式来源配置

`source-config.json` 为协调者在最终冻结时生成的私有输入，所有路径必须绝对、无符号链接；没有任何真实用户路径默认值。`healthPreferences` 和 `footprintsPreferences` 是**已确认成功导出的文件**，内部必须有 `standard`、`module` 两个字典。域经确认原本不存在时可导出空字典；读取失败禁止伪造空字典。原导出中其余字段/二进制书签原字节归档。

```json
{
  "schemaVersion": 1,
  "roots": {
    "healthGroup": "/absolute/frozen/HealthAppGroup",
    "healthSupport": "/absolute/frozen/HealthApplicationSupport",
    "healthRestore": "/absolute/frozen/GaoSeriesRestore/Health",
    "healthPreferences": "/absolute/frozen/health-preferences.plist",
    "footprintsSupport": "/absolute/frozen/FootprintsApplicationSupport",
    "footprintsGroup": "/absolute/frozen/FootprintsAppGroup",
    "footprintsRestore": null,
    "footprintsPreferences": "/absolute/frozen/footprints-preferences.plist",
    "rhythmLibrary": "/absolute/frozen/Rhythm/library.json"
  },
  "explicitAbsences": ["footprintsRestore"],
  "absentPaths": {"footprintsRestore":"/absolute/original/GaoSeriesRestore/Footprints"}
}
```

仅 `healthSupport`、`healthRestore`、`footprintsRestore` 允许明确缺失；必须同时列出缺失名字和精确原路径，且此路径确实不存在、父目录可枚举。之后该路径出现会使 CAS 拒绝。其他数据根或数据库缺失、不规则、空白、不可读一律停止。

源内文件、目录和 target 不得互相包含；不能把目标写进来源，不能通过 symlink 或事务 ID 路径穿越逃出目标。计划输出也不能写回来源。

## 四阶段命令

以下只是参数示例，不能直接当成实际冻结凭据。计划、来源配置和冻结收据须放在受限的私有位置，不进 GitHub。

```sh
python3 scripts/integrate_sources.py plan \
  --source-config /absolute/private/source-config.json \
  --target-group /absolute/RhythmAppGroup \
  --transaction rhythm-health-footprints-20261102 \
  --output /absolute/private/plan.json

python3 scripts/integrate_sources.py apply \
  --plan /absolute/private/plan.json \
  --freeze-receipt /absolute/private/freeze.json

python3 scripts/integrate_sources.py verify \
  --plan /absolute/private/plan.json --strict-import

python3 scripts/integrate_sources.py activate \
  --plan /absolute/private/plan.json \
  --freeze-receipt /absolute/private/freeze.json
```

`plan` 仅生成明确请求的计划，不建立目标 Integration，不修改来源或目标资料。它核对完整文件树和三份数据库逻辑内容。`apply` 在独占迁移锁下复核来源 CAS，准备所有组件和完整来源归档；全部准备收据落盘后逐组件原子移动到固定运行位置，仍没有 active 权威。任何不属于该事务的已存在运行目录都拒绝，不覆盖。

`activate` 再次核对准备态完整摘要、原来源 CAS 与冻结凭据，最后以不覆盖现物的原子提交创建 `authority.json`。正常主程序/小组件只在这一文件有效并为 active 后访问新模块资料。

激活后 `verify` 允许正常业务/游戏存档变化，仍验证不可变来源归档和当前数据库可读、schema、照片引用。`--strict-import` 仅用于首次激活前或尚未发生业务修改时的全量原样核对，不能拿其不通过要求整库回滚新进度。激活后的 `apply`、`activate` 同事务重放只核验并返回 `already_active`，不会重新导入或发奖励，来源已退役也不要求重新读取它。

## 冻结收据

迁移器不自行声称已关闭程序、停止 widget 或完成备份；这些字段只能由协调者在真实核验后填写。收据 `planSHA256` 是计划的排序紧凑 UTF-8 JSON SHA256（`plan` 命令也打印此摘要），`sourceRevisions` 必须与计划逐项一致。

```json
{
  "schemaVersion": 1,
  "transactionID": "rhythm-health-footprints-20261102",
  "planSHA256": "<64 lowercase hex>",
  "sourceRevisions": {"<each of nine roots>":"<64 lowercase hex>"},
  "sourcesFrozen": true,
  "stoppedWriterBundleIDs": [
    "com.gaoseries.GaoJianKang", "com.gaoseries.GaoJianKang.widgets",
    "com.gaoseries.GaoZuJi", "com.gaoseries.GaoZuJi.widgets",
    "com.gaojiezou.rhythm", "com.gaojiezou.rhythm.widgets"
  ],
  "footprintsPublisherStopped": true,
  "oldWidgetsCannotWrite": true,
  "backupsVerified": true,
  "rollbackVerified": true,
  "verifiedAt": "<actual UTC time>",
  "evidence": ["<actual stop/final backup/recovery receipt references>"]
}
```

只关闭主窗口不足以签发。足迹无 Bundle ID 的 headless publisher 也必须单独查明并停止。旧宿主、旧 widget、新接收者在切换期间均不能成为并发写者。计划后、复制后、准备后及激活前均复核源文件树；任何变动拒绝提交，准备副本与旧数据保留。

节奏 `library.json` 必须是 schema/version 11，原 activeFocus/activeSleep 在协调步骤中正常处理后才切换。本工具不结算、取消或伪造会话。SharedSleep 必须已存在 `rhythm-library-v1` 历史种子凭据，原节奏每条睡眠 ID 必须存在于 canonical 行或删除墓碑；时间内容和结算额度不得有未同步差异。迁移不再 seed，也不合并重复时间段、更换 ID、换算游戏货币或补发奖励。若此条件未满足，应在旧兼容程序与完整备份保护下恢复/同步，再重新冻结，不能用删除记录或补造 key 凑通过。

## authority 运行协议

```json
{
  "schemaVersion": 1,
  "state": "active",
  "transactionID": "rhythm-health-footprints-20261102",
  "modulePaths": {"health":"Modules/Health","footprints":"Modules/Footprints"},
  "sharedSleepPath": "SharedSleep",
  "sourceRevisions": {"<each root>":"<64 lowercase hex>"},
  "planSHA256": "<64 lowercase hex>",
  "activatedAt": "<actual UTC time>",
  "freezeReceiptSHA256": "<64 lowercase hex>",
  "permissionsTransferred": false,
  "noRewardReplay": true
}
```

`IntegrationAuthority.swift` 对 schema/state/事务字符集、固定路径、摘要及路径无 symlink 作严格检查，不会替迁移器创建空目录。旧来源路径不成为新模块的运行备用路径。

## 中断与冲突

- 准备中断：保留对应 `Payload-*` 尝试，再次 apply 创建新尝试，不删除未知现物。
- 组件移动中断：只根据同一计划已落盘收据核验已移动目录；完全一致才续传尚未移动的组件。
- 同事务已激活：只核验，不覆写新记录/游戏进度。
- 不同事务 authority、来源 CAS 变动、现有目录不符、归档损坏、数据缺失：停止并保留，不自动整库恢复，不默默覆盖。
- 迁移锁只由当前进程持有，关闭文件描述符正常释放；不强抢其他迁移进程。

来源旧 pending restore 的 staged/safety/pending.json 是完整实物归档；此工具不执行旧 job。新宿主的模块恢复必须由新路径和新事务显式驱动，不能把源端绝对路径直接重放到新权威。

## 针对性验证与边界

`python3 Tests/test_integrate_sources.py -q` 使用 `.noindex` 临时目录，仅创建合成资料：WAL 一致读取、主键/游戏/奖励键、墓碑/seed、照片、偏好/书签原字节、待恢复归档、完整源不变、计划序列化、准备/激活幂等、新进度不回滚、未停写与备份未验拒绝、CAS变动、阶段中断恢复、未知目标、未知authority、未来schema、主库丢失、照片缺失、pending不一致、路径穿越/symlink、明确缺失来源出现及激活后损坏拒绝。

`ImportedSupport` 属于可访问的用户文件树，不是三份 canonical 数据库；整合备份和恢复同样须按原始文件树保留其内容及旁文件，不能根据 `.sqlite` 后缀自动 VACUUM 或删除 WAL/SHM。

这些检查不等于真实用户迁移、实际业务/组件验证、权限转授或来源退役。真实切换、GUI验收、安装发布与退役由 Root 按 Master 统一安排；外接设备相关项继续“不做（用户取消）”，不计通过。

本轮实现验证（2026-11-02）：此前合成检查共 28 条通过，包含本机 macOS 二进制/空扩展属性与非默认 ACL 的原始归档及 SQLite 快照保留；Python AST 与空白检查通过。未执行真实数据迁移、应用启动、编译、安装或冒烟测试。

新增覆盖：健康通用资料同时原样归档并复制到 active `ImportedSupport`，明确缺失不建空目录，既有同名路径拒绝；新增 3 条必要检查后，最终同组合成检查共 31 条通过（2026-11-02），未访问真实资料。


## 2026-11-03 验收后来源退役策略覆盖

本人最新要求：10个退役来源在各自迁移验收后，旧件、旧资料及专属备份由Root精确删除，不另留可恢复旧副本。本文“原档保留”描述验收前保护和迁移时事实，不再承诺验收后长期保留。Modules/Health（含ImportedSupport）、Modules/Footprints（含Photos/列车/WidgetData）及当前SharedSleep是接收方现用资料，必须保留；SourceArchives/Health、Footprints为纯旧恢复副本。SourceArchives/explicit-absences.json是不可恢复的事务/缺失事实，当前ImportedSupport缺失分支会读取，删整个SourceArchives前须搬出该事实并改读点；SourceArchives/Rhythm是接收方备份，不扩大到两个来源清理。

新增`verify --plan <实际计划> --runtime-only`仅允许有效active权威，且不能与`--strict-import`组合。它仍核权威和三个活动库/照片，但不要求旧SourceArchives；默认verify与首次严格准备、apply/activate仍核原归档。安装器使用runtime-only。命令不删除任何东西，也不自证已验收；Root仍负责最终验收与精确旧副本清理。

## Darwin 原生元数据显式政策

`apply` 可显式携带 `--native-metadata-policy`；未提供时仍严格比较全部原始元数据。政策须绑定本次计划摘要及实际诊断证据，只允许原三条精确转换：provenance 的 11B A1DB→11B F2CA、缺席→11B F2CA，以及仅 `footprintsGroup/widget-diagnostics` 目录的 quarantine 29B→15B。源 key、相对子树及所有复制映射均来自冻结计划；来源 CAS 始终严格，不修改来源或全局规范化 inventory。节点、内容、时间、权限、ACL、flags 及其他 xattr 的差异仍拒绝。

原始 xattr escrow 按所属来源保存在 `NativeMetadata.noindex`，收据绑定政策、诊断及原始/实际副本树摘要。`receipt.components` 记录实际准备好的 native 树。三份 canonical 数据库的 coherent 转换仅对 `health.sqlite`、`footprints.sqlite`、`sleep-records.sqlite` 独立核 metadata，SQL 逻辑证明及 journal 自包含要求不变；ImportedSupport 等其他文件不进入此转换。

这三份 SQL 临时数据库先通过 `O_EXCL|O_NOFOLLOW` 创建并持续持有 FD。元数据复制若改变 quarantine，只在原副本与新临时 FD 的初始 flags 原字节完全相同时，向这个新 FD 恢复原 quarantine 全字节并严格回读；双边缺席或原字节已相同则不写。缺失不一致、flags 不同或未知格式均停止，不移除属性、不降低 flags、不写来源 FD，也不增加 quarantine 差异豁免。最终数据库仍核完整元数据，并绑定原复制品、准备态组件与临时 FD 的同 inode 证明。

组件移动时只接受政策明确允许的组件根 provenance 事件，追加同 inode 的 `NativeMoves` 收据，保留原 `receipt.components` 基线，不重写旧收据。普通及 strict 核验继续核 SourceArchives；`--runtime-only` 仍仅按既有 active 契约跳过纯旧档案。出现 `fullNativeExact=false` 时，须分别说明原始属性已 escrow 和 native 转换已核验，不能宣称所有属性与来源逐字节相同。

生产实现使用项目内的纯策略模块，不依赖 Reports 中的代码或用户数据。此迁移脚本修正不改变 App 二进制，无需为其重编 App；真实切换、激活、安装与验收仍按各自闸门执行。
