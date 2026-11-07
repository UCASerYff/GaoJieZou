# 接收方白名单灾备导出与隔离恢复

本工具只服务搞节奏接收方的当前资料。它按显式白名单把叶项写入新的私有包，并且只允许再展开到名称以 `.noindex` 结尾的隔离目录。它不写入正在使用的 App Group、Application Support、偏好或钥匙串，也不执行 apply、activate、回滚或删除来源。

`export` 仍是合成夹具入口，不读真实家目录。`capture` 是默认不启用的只读捕获：必须同时给出四个源路径、外部维护门控文件和 `.noindex` 输出。它不停止 App，不改源 metadata，不用 SQLite 打开源库，不写 Active。`productionReady` 固定为 false。`productionPlanByteHashVerified` 只有在调用时传入文件且原始字节 SHA-256 等于 `333685220a4be4e773f9b10f8c1c6e904b363d10799a79489b413758346599e6` 才为 true；不传则为 null；不一致则失败且不写包。

Info.plist 仍是 4.10 / build 11。本阶段按范围要求不构建、不签名、不安装、不增版本号。

## 命令

```sh
python3 scripts/receiver_whitelist_recovery.py export \
  --group /绝对路径/夹具Group \
  --app-support /绝对路径/夹具Rhythm \
  --preferences-dir /绝对路径/偏好夹具 \
  --plan /绝对路径/未改动的migration-plan.json \
  --output /绝对路径/receiver-package.noindex

python3 scripts/receiver_whitelist_recovery.py capture \
  --group /绝对路径/Group \
  --app-support /绝对路径/GaoSeries/Rhythm \
  --preferences-dir /绝对路径/Preferences夹具或导出目录 \
  --plan /绝对路径/authority绑定的migration-plan.json \
  --maintenance-gate /绝对路径/external-maintenance-gate.json \
  --output /绝对路径/家目录之外/capture.noindex \
  --production-plan /绝对路径/原production-plan.json

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

`capture` 可以读取调用方显式给出的源路径，包括它们位于真实家目录时。输出仍必须是新的 `.noindex`，并且不能落在 Group、Application Support、Preferences 或 `/Applications`。`export` 继续拒绝这些真实根。恢复也继续拒绝。

外部维护门控是一份 JSON，不是 `--confirmed` 字符串。它必须正好包含仓库里可见的 8 个 bundle id，`rootLockIntegrated` 必须为 false，时间窗必须覆盖当前时刻，路径必须与本次参数逐字一致。工具不检查进程是否已退出，因此 `rootMaintenanceEvidence` 保持 null，`productionReady` 为 false。真正的 Root 锁集成仍然缺着。

BSD flags 和 ACL 在本实现里是 `UNVERIFIED`，不能写成 PASS。没有读回 `com.apple.quarantine` 时也是 `UNVERIFIED`。`actualArchiveToRestoreMetadataExact` 保持 null。当前 readers、游戏进度、防重和 runtime-only 仍是 `UNVERIFIED`。

## 实现与未实现

| 能力 | 状态 |
|---|---|
| 显式路径只读捕获到新 `.noindex` | 已实现，`capture`，默认不跑 |
| 源 SQLite 不打开、不 checkpoint | 已实现，只复制字节后在私有副本上 backup |
| 源并发改动检测 | 已实现，提交前复核哈希与目录名单 |
| 源 metadata 不改 | 已实现 |
| 生产 plan 原始字节对固定 SHA | 已实现；不传文件则为 null |
| 外部维护门控 | 已实现为可审核声明，不是进程证明 |
| Root 锁集成 / 写者已暂停 | 未实现，`rootMaintenanceEvidence` 为 null |
| productionReady | 未放开，固定 false |
| ACL / BSD flags 保真 | 未实现，UNVERIFIED，阻断 READY |
| 隔离恢复 | 已实现，仍不能写 Active |
| 当前 readers、游戏、防重的生产结论 | 未实现，保持 null / UNVERIFIED |

## 不支持与 fail-closed

- `export` 拒绝真实家目录。`capture` 可以读显式源路径，但拒绝把包写进这些目录。
- 恢复目标已存在、不是 `.noindex`、位于源或包内部、或是符号链接时拒绝。重复恢复不覆盖已有沙盒。
- 中断发生在提交改名之前。工具只删除自己写下的 `.partial.noindex` 暂存，不删除来源。
- Group、Integration、权威、三库、`SourceArchives/Rhythm` 或缺失声明不存在时，导出失败。
- 维护标记、模块恢复标记、只读库标记、未知 Group 路径、未知 Application Support 路径、未知偏好域、硬链接，都失败。
- Root 写者暂停接口不在本仓库。外部门控不能代替它。`rootMaintenanceEvidence` 保持 null。不传生产计划文件时，`productionPlanByteHashVerified` 也是 null。
- 不实现 Active 写入，不调用 Host `applyPending`。

## 仍缺的原文

生产计划原文不必放进仓库。调用 `capture` 时在本机传入文件，工具只比较原始字节和固定 SHA。截断的 ZIP、Mach-O、route 哈希不参与这次恢复结论。

## 本环境测试

命令：`python3 Tests/test_receiver_whitelist_recovery.py -v`

环境：Python 3.12.3，Linux。不是 macOS。

结果：10 项全部通过，最近一次 1.770 秒。除原有白名单、WAL、隔离恢复和伪造收据覆盖外，还包括只读捕获不改源、不打开源 SQLite、错误生产计划不写包、确认字符串和维护锁自证被拒绝，以及独立 metadata 探针默认不创建目录、不支持的 metadata 不是 PASS。

这些测试使用合成夹具。语义字段保持 null/UNVERIFIED。Linux 没有验证 macOS quarantine、BSD flags 或 ACL。

## 独立 macOS metadata 探针

`f23bf92` 上的探针依赖 `receiver_whitelist_recovery.py` 和单元测试，不能按单文件许可执行。本文件替换了它。它只做 metadata 探针，不跑恢复测试。

当前文件 SHA-256：`4a0f98ab7e1199ccd21a1cd577595dda3a84a0609ef68d85ef5a9e8f4dd30e02`

依赖：Python 3 标准库（`json`、`os`、`stat`、`sys`、`tempfile`、`ctypes`、`pathlib`）。无仓库 import，不扫描当前目录。

默认不创建目录。旧旗标 `--confirm-synthetic-macos-probe` 也不会创建目录。新的执行需要新的许可，旧许可不算数。许可之后把这一个文件复制出去即可，不必检出仓库：

```sh
export TMPDIR=/绝对路径/tmp目录
export HOME=/绝对路径/家目录
python3 macos_synthetic_metadata_probe.py --confirm-standalone-metadata-probe
```

`TMPDIR` 和 `HOME` 必须都显式存在、为绝对路径、整条路径无符号链接，且 `TMPDIR` 不在家目录内，也不经过 Applications、Group Containers、Application Support、Preferences、Library。脚本只新建 `$TMPDIR/rhythm-macos-probe-*.noindex`，在其中写合成 quarantine、mode、BSD flags、ACL 的归档与恢复比较，以及 `RESULT.json`。stdout 同时打印该路径和结果。不支持或未确认的项是 `SKIP` 或 `UNVERIFIED`，整体在四项都不是 `PASS` 时为 `UNVERIFIED`。不删除该目录，不读真实业务、钥匙串、App 或偏好，不启动 App，不拿锁。

## 以后若要做真实隔离恢复

需要单独授权，本工具当前会拒绝真实路径。授权前至少要先做完：

1. 退出搞节奏与搞健康，并使用仓库里尚未实现的 Root 写者暂停接口。不要占用 build lease 或 foreground lease。
2. 准备外部维护门控 JSON。它只能声明仓库中的 8 个 bundle id 已暂停，并且 `rootLockIntegrated` 必须为 false。工具不会因此认为写者已经停止。
3. 在本机对显式路径运行 `capture`。输出放在真实数据目录之外的新 `.noindex`。需要核验生产计划时再传入 `--production-plan`。
4. 隔离 `restore` 的目标同样必须是新的 `.noindex`，不能是现用 Group。
5. 在真实 Mac 上另批独立 metadata 探针，核对 quarantine、BSD flags 和 ACL。Linux 结果不能代替。探针通过也不等于恢复通过。
6. 不要把本包交给 Host 的 `applyPending`。Root 锁没接上之前，`productionReady` 保持 false。
