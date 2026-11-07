# 接收方白名单灾备导出与隔离恢复

本工具只服务搞节奏接收方的当前资料。它按显式白名单把叶项写入新的私有包，并且只允许再展开到名称以 `.noindex` 结尾的隔离目录。它不写入正在使用的 App Group、Application Support、偏好或钥匙串，也不执行 apply、activate、回滚或删除来源。

这一阶段的通过只说明合成夹具上的结构行为。`rootActualCurrentRecoveryFields` 的 25 个字段保持准备说明里的初值：`status` 为 `NOT_EXECUTED`，三个 performed/rolledBack 字段为 false，其余为 null。合成测试不能把它们写成 true。`productionPlanFileSHA256` 作为规格固定为 `333685220a4be4e773f9b10f8c1c6e904b363d10799a79489b413758346599e6`，`productionPlanByteHashVerified` 仍是 null。

Info.plist 仍是 4.10 / build 11。本阶段按范围要求不构建、不签名、不安装、不增版本号。

## 命令

```sh
python3 scripts/receiver_whitelist_recovery.py export \
  --group /绝对路径/夹具Group \
  --app-support /绝对路径/夹具Rhythm \
  --preferences-dir /绝对路径/偏好夹具 \
  --plan /绝对路径/未改动的migration-plan.json \
  --output /绝对路径/receiver-package.noindex

python3 scripts/receiver_whitelist_recovery.py restore \
  --package /绝对路径/receiver-package.noindex \
  --target /绝对路径/隔离沙盒.noindex

python3 scripts/receiver_whitelist_recovery.py verify \
  --package /绝对路径/receiver-package.noindex \
  --plan /绝对路径/未改动的migration-plan.json \
  --restored /绝对路径/隔离沙盒.noindex \
  --source-group /绝对路径/夹具Group
```

`--source-group` 只有在它正好等于计划里的 `targetGroup` 时，才会只读调用 `integrate_sources.py verify --plan … --runtime-only`。隔离沙盒不会改写计划，因此不会把 runtime-only 说成对沙盒的验收。沙盒使用同一套健康、足迹、睡眠和节奏库读取器做等价检查。

标准输出只含状态、计数和哈希。不打印偏好值、行内容或 rawBase64 原值。

## 代码里已核实的契约

- 四个偏好域的完整名字是 `com.gaojiezou.rhythm`、`com.gaojiezou.rhythm.Rhythm`、`com.gaojiezou.rhythm.integrated.health`、`com.gaojiezou.rhythm.integrated.footprints`（`Host/AppBackupRestore.swift`）。附件里只写后缀的两个名字不能直接使用。
- 节奏自身业务档案是 Application Support `GaoSeries/Rhythm/library.json`。Group 根上的接收方文件是 `library.json`、`widget-snapshot.json` 和 `widget-snapshot.previous.json`。
- 三个现用库是 `Integration/Modules/Health/health.sqlite`、`Integration/Modules/Footprints/footprints.sqlite`、`Integration/SharedSleep/sleep-records.sqlite`。
- 现用 Host 导出会复制整个 Group，`allowedIntegrationName` 只排除 `SourceArchives` 和两个恢复标记，不排除 `Transactions.noindex`。本工具不调用该入口，也不生成它能接续的 ZIP。
- `authority.json` 的 `planSHA256` 必须等于原计划 canonical JSON 的 SHA-256。`owner.json` 与 `receipt.json` 按原字节进入包内，工具不改写它们。
- `integrate_sources.py verify --runtime-only` 仍要求同一事务、原 plan SHA 和四个 component 键；它跳过 SourceArchives 的清单比对。不能和 strict-import 一起用。

## 白名单与排除

导出先给每条路径一个决定，再只复制决定为 include 的叶项。不会先复制整组再删除。

纳入：

- `Integration/Modules/Health/`、`Integration/Modules/Footprints/`、`Integration/SharedSleep/` 的现用树，含 ImportedSupport、照片、列车、WidgetData、进度和附件。
- 三个现用库的一致快照。源文件先连同实际存在的 `-wal`、`-shm`、`-journal` 复制到私有临时目录，再用 SQLite backup API 折叠成 `journal_mode=DELETE` 的自包含库。逻辑行摘要必须一致。包内不放这些 sidecar。
- `authority.json`、当前事务的 `owner.json` 与 `receipt.json`、`SourceArchives/Rhythm/library.json`、`SourceArchives/explicit-absences.json`。
- Application Support 中的 `library.json`，以及代码里已有名字的 `library.json.widget-pending`、`library.json.tmp`、`library.corrupted-YYYYMMDD-HHMMSS.json`。
- `IntegratedRecovery/Health` 与 `IntegratedRecovery/Footprints`。这是接收方自己的恢复隔离，不是来源归档；缺席会写进白名单清单，未知同级目录仍失败。可选的小组件快照若缺席，也显式记录，不静默漏掉。
- 上面四个偏好域的原始 plist 字节。

排除并写入排除清单（只记路径、原因、哈希和 JSON 指针，不记原值）：

- `SourceArchives/Health/` 与 `SourceArchives/Footprints/`，包括 `NativeMetadata.noindex`。
- 事务 Payload 里的来源叶项。`SourceArchives/Rhythm/library.json` 必须与现用归档逐字节相同才按重复叶项排除；不一致就失败，不整目录丢掉。
- `NativeMoves.noindex` 的 intent/observed。`Modules-Health` 与 `Modules-Footprints` 按来源元数据托管排除。`SharedSleep` 与 `SourceArchives` 只允许 `rootProvenance.rawBase64` 和 `changes/*/source|native.rawBase64` 这两个技术指针；其它 `rawBase64` 指针直接失败。不生成删字段后的替身文件。
- 其它事务、协调锁、迁移锁。锁只被识别，不会去占用 `.rhythm-integration-writers.lock`、维护标记、build lease 或 foreground lease。

`Modules/`、`SharedSleep/`、Application Support 和 `SourceArchives/Rhythm/library.json` 里恰巧叫 `rawBase64` 的字段视为接收方业务，原字节保留。权威、收据、owner 和 explicit-absences 若出现该键则失败，不删字段。读失败或必填路径缺失都失败，不当成空数据。

## 元数据政策

这是提交给后续 Root 审核的规则，不是已经在真实 Mac 上验收过的保真证明。

包到隔离恢复必须一致的项目：类型、mode、mtimeNs、大小、SHA-256，以及当前平台能够读回的扩展属性。

唯一允许的源到包差异：三个现用库把 WAL 折叠进快照。源 sidecar 不跟着恢复到快照旁边。

明确不做、也不算通过的项目：

- 符号链接权限差异。安装包 umask 造成的符号链接现象不套用到数据包；数据包里的符号链接直接拒绝。
- 删除或降低 quarantine。本阶段不调用 `chflags`，也不恢复 ACL。BSD flags 与 ACL 在收据里保持 `UNVERIFIED`。
- 改 uid/gid，或允许 mtime 漂移。
- 把 Linux 上能保存的 `user.*` 扩展属性说成 macOS quarantine 保真。没有观察到 `com.apple.quarantine` 时，`macosQuarantineFidelity` 为 `UNVERIFIED`。非 macOS 上 Apple 元数据为 `SKIP`。

## Root 收据和合成观测

包内收据同时放两块，不能混用：

- `preparationContract`：准备说明里的标识、完整生产 plan SHA、事务 `RootRhythm41011-20261104-03`，以及四个门控 `executeAllowed`、`sourceRetirementAuthorizedByThisNote`、`existingCurrentWhitelistExecutorFound`、`actualCurrentRestoreExecuted`。它们保持 false。引用的 ZIP / Mach-O / route 哈希按准备说明原文保留截断形式，不补全。
- `rootActualCurrentRecoveryFields`：完整 25 字段，停在初值。当前 readers、游戏进度、防重、四个偏好域的值、runtime-only、三库语义、附件、隔离元数据精确一致，都是 null，不是文件存在或合成夹具可以代替的结论。
- `syntheticObservation`：只描述这次合成包的结构门控，并写明 `semanticVerification: UNVERIFIED`。其中的哈希用于发现伪造清单，不构成 Root 实际收据。

真实家目录仍然全部拒绝，包括获许可后的只读捕获。可用接口只记录在 `preparationContract.readOnlyCapture`，`implemented` 为 false。它要求单独的用户授权、Root 维护证明（所有者、时间范围、写者集合、证明 SHA），并且仍然禁止写回 Active、禁止占用 build/foreground 锁。本阶段不执行该接口，也不宣称真实恢复已有路径。

## 不支持与 fail-closed

- 真实家目录中的 Group、`GaoSeries` Application Support、`Library/Preferences` 和 `/Applications` 一律拒绝，包括只读导出。
- 恢复目标已存在、不是 `.noindex`、位于源或包内部、或是符号链接时拒绝。重复恢复不覆盖已有沙盒。
- 中断发生在提交改名之前。工具只删除自己写下的 `.partial.noindex` 暂存，不删除来源。
- Group、Integration、权威、三库、`SourceArchives/Rhythm` 或缺失声明不存在时，导出失败。
- 维护标记、模块恢复标记、只读库标记、未知 Group 路径、未知 Application Support 路径、未知偏好域、硬链接，都失败。
- Root 写者暂停接口不在本仓库。`rootMaintenanceEvidence` 与 `productionPlanByteHashVerified` 保持 null。私有 staging flock 不是 Root 维护锁。
- 不实现 Active 写入，不调用 Host `applyPending`。

## 仍缺的原文

25 个字段的名字和初值已经按准备说明写入规格。生产计划文件本身仍不在仓库里，所以固定 SHA 只是规格，`productionPlanByteHashVerified` 不能改成 true。准备说明里截断的 ZIP、Mach-O 和 route 哈希也没有被补全。

## 本环境测试

命令：`python3 Tests/test_receiver_whitelist_recovery.py -v`

环境：Python 3.12.3，Linux。不是 macOS。

结果：8 项全部通过，最近一次 1.654 秒。覆盖白名单与来源排除、WAL 折叠、偏好域、用户扩展属性往返、隔离全树结构比对、无 Group 沙盒、中断与重复恢复、提交前源树被改则放弃包、符号链接父目录、外来 partial 不删除、伪造 Root 字段、`IntegratedRecovery` 纳入，以及 macOS 探针默认不创建目录。

这些测试使用合成夹具。语义字段保持 null/UNVERIFIED。Linux 没有验证 macOS quarantine、BSD flags 或 ACL。

## 尚未执行的 macOS 合成探针

`scripts/macos_synthetic_metadata_probe.py` 默认只打印 `not_run`，不创建目录。

在本人另行许可之后，于 macOS 上、对应 PR 提交的干净工作区执行：

```sh
python3 scripts/macos_synthetic_metadata_probe.py --confirm-synthetic-macos-probe
```

范围只限 `$TMPDIR` 或 `/tmp` 下一个新建的 `rhythm-macos-probe-*.noindex`。其中写入合成 quarantine 样本和 `RESULT.json`，并把合成单元测试的临时目录放在同一探针目录内。不启动 App，不拿锁，不读真实 Group、Application Support、Preferences 或 `/Applications`。探针目录不会自动删除；单元测试自己的临时目录会随测试结束清理。删除探针目录需要另一次确认。

## 以后若要做真实隔离恢复

需要单独授权，本工具当前会拒绝真实路径。授权前至少要先做完：

1. 退出搞节奏与搞健康，并使用仓库里尚未实现的 Root 写者暂停接口。不要占用 build lease 或 foreground lease。
2. 先把真实 Group、Application Support 和四个偏好域复制到真实家目录之外的私有位置。复制本身不是本工具的功能。缺失文件不能补成空文件。
3. 对那份副本运行 export。任何未知路径都要先分类，不能为了让命令通过而加进白名单。
4. 把 restore 目标放在名称以 `.noindex` 结尾、且不在真实 Group / Application Support / Preferences 下的新目录。
5. 用原计划运行 verify。只有在生产计划原文可用后，才能讨论 `productionPlanByteHashVerified`。
6. 在真实 Mac 上核对 quarantine、BSD flags 和 ACL。Linux 结果不能代替这一步。
7. 不要把本包交给 Host 的 `applyPending`，也不要从隔离沙盒回写现用库。
8. 真实只读捕获还没有实现。许可之后也要先有 Root 维护证明，并只读进真实家目录之外的新 `.noindex`；当前工具仍会拒绝真实路径。
