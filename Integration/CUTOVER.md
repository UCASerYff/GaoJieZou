# 搞节奏 4.10 / build 11：生产切换步骤

本文供总协调 Root 执行，不是停写、备份、迁移、安装或验收收据。实施会话只准备接收方；真实资料、前台、换装、来源退役均由 Root 统一安排。当前阶段不得照本文自行启动应用、请求权限或迁移。所有命令必须绑定当时核实的路径、候选摘要及事务；不使用昨晚已归还的构建租约。

## 1. 身份和路径先核对

以下为源码声明的预期位置，**不表示已经读取、存在或备份成功**。Root 应以实际用户会话逐项核实，并记录真实路径、BID、版本、签名、来源及最终清单。路径必须是绝对物理路径，所有层级无符号链接；打不开不能当成不存在。

|对象|精确身份 / 预期位置|用途|
|---|---|---|
|节奏正式宿主|`/Applications/搞节奏.app`；`com.gaojiezou.rhythm`；原安装 4.09/10|本轮唯一正式入口；目标 4.10/11，只增加一次|
|节奏原业务|`~/Library/Application Support/GaoSeries/Rhythm/`，其中 `library.json`；原 group `~/Library/Group Containers/5G96498KGJ.com.gaojiezou.rhythm/`|原 schema 11、原游戏、计时和资料不由迁移器覆盖|
|健康来源|`/Applications/搞健康.app`；`com.gaoseries.GaoJianKang`；基线 4.05/6|完整来源，只读保留；不可提前退役|
|`healthGroup`|`~/Library/Group Containers/5G96498KGJ.com.gaoseries.GaoJianKang/`|完整 `Health/` 与唯一旧 canonical `SharedSleep/`|
|`healthSupport`|`~/Library/Application Support/GaoSeries/Health/`|原用户文件：原档归档与活动 `ImportedSupport/` 两份用途|
|`healthRestore`|`~/Library/Application Support/GaoSeriesRestore/Health/`|旧 pending、staged、safety 全部归档，不执行旧绝对路径|
|足迹来源|`/Applications/搞足迹.app`；`com.gaoseries.GaoZuJi`；基线 4.03/4|完整来源，只读保留；不可提前退役|
|`footprintsSupport`|`~/Library/Application Support/GaoSeries/Footprints/`|完整原库、照片、快照、列车游戏和历史|
|`footprintsGroup`|`~/Library/Group Containers/5G96498KGJ.com.gaoseries.GaoZuJi/`|完整旧共享树，迁至足迹根的 `WidgetData/`|
|`footprintsRestore`|`~/Library/Application Support/GaoSeriesRestore/Footprints/`|旧待恢复实物归档，不自动重放|
|新唯一权威|节奏原 group 下 `Integration/authority.json`|只由 `activate` 最后提交；`Modules/Health`、`Modules/Footprints`、`SharedSleep` 固定布局|

来源配置的两个偏好文件必须是成功导出的二进制/合法 plist 包装，每份包含 `standard`、`module` 字典：健康原域 `com.gaoseries.GaoJianKang` 和 `com.gaoseries.GaoJianKang.Health`；足迹原域 `com.gaoseries.GaoZuJi` 和 `com.gaoseries.GaoZuJi.Footprints`。原域确认不存在和读取失败要区分，不能用 `?? [:]` 或空文件替代失败。完整原字节、书签及其他字段须保留。新独立偏好域为 `com.gaojiezou.rhythm.integrated.health` 与 `.footprints`；不整域覆盖节奏标准偏好，不导出钥匙串秘密。

只有 `healthSupport`、`healthRestore`、`footprintsRestore` 可显式缺失；配置须同时包含 `roots.<name>: null`、`explicitAbsences` 名称和 `absentPaths.<name>` 精确原路径。父目录必须可枚举且该原路径确实不存在；稍后出现会触发 CAS 拒绝。其余数据根、三份 canonical 数据库或照片引用缺失立即停止。

## 2. 候选及备份闸门

切换前必须取得本轮最终候选收据：三个 framework、三个 appex 和 Host 完整编译通过；所改足迹恢复、宿主完整恢复检查通过；版本均为 4.10/11。迁移 31 条、共同权威及健康已通过的未变检查沿用原收据，不为这次切换重跑无关套件。

签名 Team 为 `5G96498KGJ`，开发身份 `A15B2B2D22B018CBC842063C9A8A589946647524`。保留原 Host、`Rhythm.framework`、原 `GaoJieZouWidgets.appex` 完整 designated requirement 对照及全部最终 Mach-O 摘要、entitlements、嵌套库存。新框架/组件用目标命名空间。开发签名不是 Developer ID 或公证，也不等于旧 TCC 自动转授。

候选 `.app`、打包/解包暂存及恢复展开目录在创建前即位于 `.noindex` 容器。最终候选及发行包保持同一可追溯输入；脚本返回成功不能替代实际签名、库存或唯一入口核验。

Root 核验三应用全部真实资料、附件、历史、设置、游戏进度、初始化标记、待恢复任务、SQLite 主库及 WAL/SHM/journal；原程序、完整项目现物、Git 历史、远端发行物和钥匙串引用都有可恢复依据。Master 的预备备份只用于基线，最终冻结时仍须重核变动与恢复能力。备份放在来源之外的受限位置，不进仓库或公开 Release。

节奏升级快照的准确入口为 `python3 scripts/upgrade_data.py snapshot --version 4.10 --backup-root <Root已核实的私有备份父目录>`；必须由 Root 在停写后执行并保存其返回的实际 `backup` 路径。`verify-live <实际backup路径>` 用于逐项识别差异；激活后新增的 `Integration`、首次合法偏好导入和后续正常业务变化应逐项解释，不能因全量差异要求整库倒退。健康、足迹的完整来源及其原程序恢复依据另由 Root 统一保护，不能只备份节奏。

## 3. 停所有写者，再取得最后修订

Root 先持有 Master 前台租约，正常处理三个应用的在途工作。节奏 `activeFocus`、`activeSleep` 必须正常结束/保存并为 null；迁移器不会结算、取消或伪造会话。保留真实文档和未知未保存内容，不以关窗代替退出，不强退来凑冻结。

逐项记录当时路径、可执行文件、BID、PID 和停止结果。迁移器要求下列六个 BID 均在真实停写凭据中，但填列表不能证明已停止：

- `com.gaoseries.GaoJianKang`、`com.gaoseries.GaoJianKang.widgets`
- `com.gaoseries.GaoZuJi`、`com.gaoseries.GaoZuJi.widgets`
- `com.gaojiezou.rhythm`、`com.gaojiezou.rhythm.widgets`

足迹独立 headless widget publisher 没有独立 BID，必须按实际可执行路径/进程查明并停止；同时阻止旧 Widget/Intent 重新写入。若此前已有新健康/足迹组件，`com.gaojiezou.rhythm.health.widgets` 与 `.footprints.widgets` 也必须停止，不能只满足旧六项。不要停止系统 WidgetKit/NotificationCenter 或其他应用，不全局清登记。

Root 先记录旧桌面健康/足迹组件实例、kind、尺寸及位置，按安排正常替换/移除这两个来源的旧实例；保留其他应用和节奏原组件布局。必要时将已核实的旧来源启动对象可回滚地暂存到受限 `.noindex` 容器，并保留精确恢复位置/身份；这不是来源退役。旧 URL scheme、Widget 或 Intent 仍可唤起旧写者时不能签发 `oldWidgetsCannotWrite`。

完成停写后，重核最终完整备份、偏好导出和恢复收据，生成九根来源配置。可直接以已经冻结的原路径为迁移输入；若采用最终冻结副本，Root 须另保副本与真实原件最后清单/CAS一致、原件持续停写的证据，不能把旧备份本身当作当前真相。原源和目标不能成为两个可写权威。

SharedSleep 必须已有 `rhythm-library-v1` 历史 seed 凭据；原节奏每个睡眠 ID 均存在于 canonical 行或墓碑，时间、settlement、pending 与奖励额度一致。缺失时在备份保护下由旧兼容程序正常同步后重新冻结；不能删除记录、补造 seed key、重新导入历史、合并 ID 或补发奖励。健康岛屿与足迹列车各自货币/成长/奖励去重原值保留，不换算为节奏金币。

## 4. 四阶段命令（由 Root 填写实际输入后执行）

准确 JSON 结构见 [MIGRATION.md](MIGRATION.md)。不要复制示例的 `true` 字段作为成功证据。以下变量必须由 Root 在当前 shell 显式设置；脚本没有 live 路径默认值。私有输出须预选不存在的路径，事务只用 `[A-Za-z0-9_-]`，最长 128 字符。此块只规定命令参数，不自动取得前台/构建授权。

```sh
set -euo pipefail
set -o noclobber
umask 077
: "${RHYTHM_REPO:?Root must set the verified target repository path}"
: "${CUTOVER_CONFIG:?Root must set the final private source-config path}"
: "${CUTOVER_GROUP:?Root must set the verified existing production Rhythm group}"
: "${CUTOVER_TX:?Root must set this cutover transaction ID}"
: "${CUTOVER_PLAN:?Root must set a new private plan path}"
: "${CUTOVER_FREEZE:?Root must set the actual final freeze receipt path}"
: "${CUTOVER_PLAN_LOG:?Root must set a new private plan result path}"
: "${CUTOVER_APPLY_LOG:?Root must set a new private apply result path}"
: "${CUTOVER_VERIFY_LOG:?Root must set a new private strict verification result path}"
: "${CUTOVER_ACTIVATE_LOG:?Root must set a new private activation result path}"
cd "$RHYTHM_REPO"
test -f "$CUTOVER_CONFIG"
test -d "$CUTOVER_GROUP"
test ! -e "$CUTOVER_PLAN"
test ! -e "$CUTOVER_PLAN_LOG"
python3 scripts/integrate_sources.py plan \
  --source-config "$CUTOVER_CONFIG" \
  --target-group "$CUTOVER_GROUP" \
  --transaction "$CUTOVER_TX" \
  --output "$CUTOVER_PLAN" > "$CUTOVER_PLAN_LOG"
```

此时只完成只读计划。Root 核对实际 `planned_read_only`、事务和九项 `sourceRevisions`，再依据已完成的停止/备份/恢复核验生成冻结收据。收据须含 schemaVersion 1、相同 transactionID、planSHA256、全部九项相同 sourceRevisions、真实 sourcesFrozen/stoppedWriterBundleIDs/footprintsPublisherStopped/oldWidgetsCannotWrite/backupsVerified/rollbackVerified、实际 UTC verifiedAt 和非空 evidence 路径。**`planSHA256` 是 CLI 返回的排序紧凑 JSON 摘要，不是带缩进计划文件的直接 `shasum`。**

```sh
test -f "$CUTOVER_FREEZE"
test ! -e "$CUTOVER_APPLY_LOG"
python3 scripts/integrate_sources.py apply \
  --plan "$CUTOVER_PLAN" \
  --freeze-receipt "$CUTOVER_FREEZE" > "$CUTOVER_APPLY_LOG"

test ! -e "$CUTOVER_VERIFY_LOG"
python3 scripts/integrate_sources.py verify \
  --plan "$CUTOVER_PLAN" --strict-import > "$CUTOVER_VERIFY_LOG"

test ! -e "$CUTOVER_ACTIVATE_LOG"
python3 scripts/integrate_sources.py activate \
  --plan "$CUTOVER_PLAN" \
  --freeze-receipt "$CUTOVER_FREEZE" > "$CUTOVER_ACTIVATE_LOG"
```

依次核对 `prepared_not_active`（尚无 authority）、严格准备态验证和最后 `active`；保持所有旧/新写者停止直到换装完成。`apply`、`activate` 会多次重读源 CAS，变动、冲突或归档损坏必须停止调查，不能放宽校验。保留计划、freeze、全部阶段输出、目标事务目录和原件，不把 stderr 私人路径/资料带入公开日志。

激活后使用 `python3 scripts/integrate_sources.py verify --plan "$CUTOVER_PLAN"` 验证当前可读状态和不可变来源归档。业务开始后不再以 `--strict-import` 强求运行库等于首次副本；同事务 `apply/activate` 的 `already_active` 仅作核验，不会再导入或发奖。

## 5. 安装门与真实验收

Root 将实际 plan 交给安装器，准确入口为：

```sh
GAO_RHYTHM_INTEGRATION_PLAN="$CUTOVER_PLAN" scripts/install.sh
```

只有最终候选/发行包已核实、旧节奏已退出、正式路径非 symlink、原 Host/原 Widget 完整 DR 相同且上述切换成功才执行。4.10 安装器要求计划 `targetGroup` 为当前用户真正的 `~/Library/Group Containers/5G96498KGJ.com.gaojiezou.rhythm`，有效 active authority/事务/sourceRevisions/freezeReceiptSHA256，且没有维护 marker；fixture plan 不能授权换装。安装器自己 `verify` 不代表 Root 停写事实自动成立。

安装器在 `dist/GaoJieZou-4.10.zip` 与其 `.sha256` 同时存在时优先解包发行 ZIP，即使 `build.noindex/搞节奏.app` 也存在。Root 须核定**实际选择的 ZIP/候选**与最终编译收据一致，不能只验 build 后误装旧的同版本发行物；未知既存 4.10 包先查明来源，不能直接覆盖或当作最终包。

安装器会在 `rollback.noindex` 创建旧程序压缩归档、SHA 和恢复收据，展开核验仅在 `.noindex`，只注册 `/Applications/搞节奏.app` 和其三个 appex。它不启动应用，也不迁移用户资料。其自动程序回滚不等于资料回滚，见下一节。不要把安装退出码单独当成主要业务、小组件或唯一入口已通过。

Root 安排有边界的真实验收，必要系统授权由本人正常确认；不运行通用冒烟，不复用旧无关 GUI/录制/断网授权。每步只留必需窗口，用完关闭自己的窗口。

|范围|最少需要绑定本次最终候选的真实证据|
|---|---|
|原节奏|原业务/游戏、附件、在途保存状态未损；本轮没有把新迁入奖励记到节奏原账本|
|健康|原记录/事项/体重/饮食/饮水/运动/睡眠/趋势、岛屿进度与货币，ImportedSupport 文件可访问；来源原件/归档不改写|
|足迹|地图/搜索/自定义城市/点亮/旅行/时间轴/常住城市、所有照片及引用、列车/线路/奖励去重原值|
|共同睡眠|两模块仅写新 `Integration/SharedSleep`，原 ID/墓碑/seed/结算与睡眠奖励去重一致；旧源不再写入|
|恢复/备份|按下节正确范围，确认完整导出、自己的模块恢复、失败 pending/marker 与下次启动恢复可控；不拿用户新进度做破坏性试验|
|组件|原节奏 kinds 保留；新健康 daily/events 原尺寸/Intent、新足迹 map medium；旧实例正常替换，其他布局不变，新旧写者不并行|
|链接/消费者|新 `gaojiezou://health/...`、`gaojiezou://footprints/...` 正确；旧 `gaojiankang://`/`gaozuji://` 由新 Host 处理，不打开旧程序；所有实际调用方改指|

外接设备/外接显示器/蓝牙等继续“不做（用户取消）”，不计通过。旧书签、通知、照片等系统许可不自动跨 BID 转授，不绕过权限。

## 6. 中断、回滚与恢复范围

- 准备中断保留 `Transactions.noindex/<事务>/Payload-*`、receipt 和已移动组件；仅用相同计划续传。未知目标、不同 authority 或源 CAS 变化不覆盖、不删现物重来。迁移器没有生产 `rollback` 子命令，不能虚构命令或删 authority 来强行绕过。
- 激活后尚未启动新写者：若安装失败，安装器按已核压缩归档恢复旧正式程序；Root 仍须确认旧来源停写状态、保留 Integration 和全部收据，再决定恢复哪组旧写者。不要因旧程序恢复就把迁移状态记为撤销。
- 新版本已有业务/游戏进展：先停新写者并完整保护新状态；不得整库还原预切换快照或直接重新开放旧健康/足迹库。由 Root 基于实际新旧差异安排可核验恢复/协调；原始档案和新记录都保留。
- 普通健康模块恢复仅更换健康模块/自己的偏好，保留当前共同睡眠、sleep 奖励去重与不可变 SourceArchives；普通足迹模块恢复仅更换足迹根和 WidgetData/自己的偏好，保留当前 authority 来源凭据，不重放旧 pending 的绝对路径。
- 只有新宿主完整、同事务兼容的整体备份可一致恢复节奏原业务、两模块与 SharedSleep；四偏好域一并捕获/回滚。稳定 group-root `.rhythm-integration-writers.lock`、`.rhythm-integration-maintenance.json` 及当前不可变 `Integration/SourceArchives` 不搬走/替换。纯SourceArchives恢复副本不再是现用资料恢复的前提，存在或验收后清除均不进入替换操作；旧ZIP不会重建它。同事务权威与三个活动库校验保持。
- 模块和宿主恢复在 store 打开前执行，SH 写者与 EX 维护互斥。失败时 pending、维护 marker、恢复前原始数据和日志保留；只在同 owner 正常恢复/完成后清 marker，不能手工删除它来恢复写入。完成态重入应仅收尾，不再次覆盖新进度。来源旧 pending 只归档，不作为新启动任务。

## 7. 交付与退役最后闸门

Root 取得本次实际资料保全/迁移、业务/原游戏/附件/小组件、权限与调用者结果后，才安装发布收尾。仅发布程序和源码到 `UCASerYff/GaoJieZou` 及对应 4.10 Release；私有计划、freeze、资料、照片、偏好、备份和凭据不上传。公开回下载核最终发行包 SHA。包发布和来源退役各有独立收据，不混作同一步成功。

安装、回滚及最后清理都要检查本应用实际副本、Spotlight 和 LaunchServices/PluginKit 精确路径。必须在真实用户会话得到含 `/Applications/搞节奏.app` 的有效正结果；空结果、沙箱拒绝、或命令成功不能算唯一性通过。展开候选/安装暂存核完清除，旧程序仅保压缩归档或 `.noindex` 容器及可用恢复指针；不全局清索引、不动其他应用。

健康/足迹来源退役只由 Root 在完整备份/恢复、目标交付、所有消费者改指、旧组件停写与精确仓库身份/远端闸门全部满足后执行。本文不授权实施会话删除来源项目、App、仓库、用户资料或安全备份。未过项继续标记未完成；昨晚基线和新候选编译不能替代本次实机验收。


2026-11-03最新保留策略覆盖：各来源完成迁移验收后，Root删除旧件、旧资料和专属备份，不保留可恢复旧副本；验收前临时保护仍有效。Health/Footprints的SourceArchives子树为纯旧副本，不能把Modules/Health/ImportedSupport、岛屿、Modules/Footprints/Photos/列车、现用WidgetData或SharedSleep误删。最小不可恢复事实收据explicit-absences.json仍有缺失分支读者；删整个SourceArchives前先移出并改读。退役后的现用检查可显式用`verify --plan <实际计划> --runtime-only`，不能与strict-import组合或用于未active阶段；命令不执行退役或删除。
