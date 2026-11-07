# 接收方维护锁与隔离恢复：调查、阻塞与未执行的 Mac 方案

本文件是收工交接，不是执行许可，也不是 `productionReady`。固定代码仍是提交 `f95ec876b12dc13ad463fb74f62b584a8f3e78b1`。本轮没有改恢复工具，没有读真实家目录，没有在 Mac 上执行，没有停 App，没有安装或发布，没有删除来源。

Info.plist 仍是 4.10 / build 11。签名团队、Bundle、钥匙串、`authority.json`、三个现用库、原 plan SHA、原 receipt 都没有改。

## 源码调查和实际实现分开

调查只说明仓库里已经有的行为。它不是运行时证明，也没有在本轮变成新的锁实现。

已有且本轮未改的实现：

- `scripts/receiver_whitelist_recovery.py` 的 `export`、`capture`、`restore`、`verify`。
- `export` 拒绝真实家目录。`capture` 在代码上可以读调用方显式给出的路径，但本轮没有这样调用。
- 恢复只允许新的 `.noindex`。不写现用 Group、Application Support、Preferences、钥匙串，不调用 `applyPending`，不 activate，不回滚，不删来源。
- 外部维护门控只接受一份声明 JSON。`rootLockIntegrated` 必须为 false。工具不检查进程。`rootMaintenanceEvidence` 保持 null。
- 协调锁文件若出现在 Group 里，只被排除出包，原因是不打包该锁。工具不去 `flock` 它。
- 维护标记 `.rhythm-integration-maintenance.json` 或模块恢复标记存在时，导出失败，并且不删除标记。

本轮明确没有实现、因此不能声称已经接上的部分：

- 工具没有取得或释放 `.rhythm-integration-writers.lock`。
- 没有写者进程核实，没有“写者已暂停”的运行时证据。
- 没有把维护竞争、写者复活、锁丢失接成可运行入口。这些定向测试不存在；下面把它们标成阻塞，而不是未跑的通过项。
- 没有给 App 增加白名单导出按钮，也没有改 `RhythmPersistence`、UserDefaults 或钥匙串的加锁方式。那会是写者行为改造，不能为了宣称 READY 去做。

## 固定文件

| 文件 | SHA-256 |
|---|---|
| `scripts/receiver_whitelist_recovery.py` | `5d52152c8ca5c068b2fed2054f1646977a4eee773933b58e34f85b55c033e1cd` |
| `scripts/macos_synthetic_metadata_probe.py` | `1163bb36150c3c01e48bb2a4c1b14c68233d7a8ea5a7b793da6d702b3b2d6ff7` |
| `Tests/test_receiver_whitelist_recovery.py` | `aafa9a1377b84380bc5b8f2fde272c066d6ce0258c00dff8bffa852a2bac7817` |
| `docs/receiver-whitelist-recovery.md` | 随本交接提交改变；工具与探针哈希以上表为准 |

`53ea49ab` 与更早的探针许可不能用于这些文件。独立探针只证明它自己的合成样本。它没有在本轮的 Mac 上重跑。

## 已有导出入口，以及它证明不了什么

支持本阶段合成测试的入口是命令行，不是 App 菜单。

```sh
python3 scripts/receiver_whitelist_recovery.py export \
  --group <绝对路径> --app-support <绝对路径> \
  --preferences-dir <绝对路径> --plan <绝对路径> \
  --output <新目录名以 .noindex 结尾>

python3 scripts/receiver_whitelist_recovery.py capture \
  --group <绝对路径> --app-support <绝对路径> \
  --preferences-dir <绝对路径> --plan <绝对路径> \
  --maintenance-gate <绝对路径> --output <新的 .noindex>
  # --production-plan 可选；不传则 productionPlanByteHashVerified 为 null

python3 scripts/receiver_whitelist_recovery.py restore \
  --package <包.noindex> --target <新的 .noindex>

python3 scripts/receiver_whitelist_recovery.py verify \
  --package <包.noindex> --plan <绝对路径> \
  --restored <隔离目录.noindex> --source-group <绝对路径>
```

真实调用时必须由当次许可逐项给出路径。下面的 `$HOME/...` 是参数类别，不表示这台机器上已经存在这些目录。

`export` 需要四类输入：Group 根、`GaoSeries/Rhythm` 应用支持目录、四个偏好 plist 所在目录、迁移 plan 文件。输出必须是新的 `.noindex`。此入口拒绝落在真实家目录数据根上的路径。

`capture` 还要一份外部维护门控 JSON，以及可选的生产 plan 原文件。门控必须正好列出这 8 个 bundle id，且 `rootLockIntegrated` 为 false：`com.gaoseries.GaoJianKang`、`com.gaoseries.GaoJianKang.widgets`、`com.gaoseries.GaoZuJi`、`com.gaoseries.GaoZuJi.widgets`、`com.gaojiezou.rhythm`、`com.gaojiezou.rhythm.widgets`、`com.gaojiezou.rhythm.health.widgets`、`com.gaojiezou.rhythm.footprints.widgets`。这份名单是声明，不是进程已退出的证据。多一个字段、改成 true、或用确认字符串，都会失败。

`verify --source-group` 只有在该路径等于 plan 里的 `targetGroup` 时，才只读调用 `integrate_sources.py verify --plan <原plan> --runtime-only`。隔离目录不会被写成新的活动根。

App 里已有、但不是本白名单入口的代码：

- `Host/AppBackupExport.swift` 的 `export` 在 `withWriterLease` 下复制应用支持、整个 Group 和 SharedSleep，并读四个偏好域，打成 ZIP。它自己持有共享锁，不是维护暂停。它不生成白名单包，也不产生 25 字段收据。本轮不构建、不安装、不启动。
- 健康与足迹模块各自有完整资料 ZIP。它们恢复的是模块树，不替代接收方白名单链。
- `Host/AppBackupRestore.swift` 的 `prepare → schedule → 下次启动 applyPending` 会在独占维护租约下改现用资料。本方案禁止把白名单包交给这条链。

因此不需要、本轮也没有新增 App 内白名单按钮。字符串里的来源名或导出人不能当成维护证明。

## 读和写的目录类别

只在未来单独许可的命令里出现。本轮一条都没有执行。

读取类别：

- `$HOME/Library/Group Containers/5G96498KGJ.com.gaojiezou.rhythm/`
- `$HOME/Library/Application Support/GaoSeries/Rhythm/`
- 调用方给出的偏好目录，其中要有这四个文件名：`com.gaojiezou.rhythm.plist`、`com.gaojiezou.rhythm.Rhythm.plist`、`com.gaojiezou.rhythm.integrated.health.plist`、`com.gaojiezou.rhythm.integrated.footprints.plist`
- 调用方给出的 plan 文件。若要核验生产 plan，原始字节 SHA-256 必须等于 `333685220a4be4e773f9b10f8c1c6e904b363d10799a79489b413758346599e6`，事务标识为 `RootRhythm41011-20261104-03`

不读取：钥匙串、`/Applications`、来源 Group `5G96498KGJ.com.gaoseries.GaoJianKang` 与 `5G96498KGJ.com.gaoseries.GaoZuJi`。工具不会用“直接打开真实库”代替上述显式路径。文件缺失和读失败都失败，不会当成空库。

写入类别，且必须落在上述真实根之外：

- 新的包目录，名称以 `.noindex` 结尾
- 同父目录下的 `<包名去掉 .noindex>.partial.noindex`，只在提交改名前存在；失败时只删除带本进程 `STAGING.json` 的这份暂存
- 包父目录上的 `.receiver-whitelist-recovery.lock`，这是打包互斥，不是整合写者锁

恢复写入另一个新的 `.noindex`。不写活动 Group，不写维护标记，不删除来源，不删除混合容器里未列入白名单的邻居。来源原始字节和接收方现用业务在排除清单里分开记录。`SourceArchives/Health` 与 `SourceArchives/Footprints` 不进入可恢复包；`SourceArchives/Rhythm/library.json` 与现用档不一致则整次失败，不整目录丢掉。

## 写者锁：App 里有，工具没接上

`Integration/Shared/IntegrationAuthority.swift` 的调查结果：

- 锁文件相对名是 `.rhythm-integration-writers.lock`，位于 Group 根。
- 写者经 `withWriterLease` 取共享 `flock`。维护经 `withMaintenanceLease(owner:)` 取独占 `flock`。owner 只能是 `host`、`health`、`footprints`。
- 打开标志是创建、读写、不跟随符号链接。文件必须是普通文件且 uid 为当前用户。独占或共享锁用非阻塞 `flock`，最多约 5 秒。
- 维护成功时写 `{schemaVersion:1, owner, startedAt}` 到 `.rhythm-integration-maintenance.json`，体成功结束后删除。异常留下标记。进程退出会放开 `flock`，但不会自动删标记。
- 锁文件存在不等于有进程持有它。`flock` 不能列出全部共享持有者。

这条锁只覆盖会调用上述租约的接收方代码路径，包括三个现用库、整合偏好准备、Host/模块备份导出，以及 Host、健康、足迹的 `applyPending`。它覆盖不了、因此必须 fail-closed 的写者：

- `Sources/RhythmPersistence.swift` 对应用支持 `library.json` 的保存，不经过该 `flock`
- 四个偏好域的 UserDefaults / cfprefsd
- 钥匙串
- 仍可能独立运行的搞健康、搞足迹及其 widget；它们使用自己的 Group，不持有接收方这把锁
- 任何名单以外的 bundle
- 门控 JSON、owner 字符串、导出人字符串、锁文件“在场”

所以即使未来工具真的持有独占 `flock`，`rootMaintenanceEvidence` 仍然不能改成已核实。未覆盖写者没有进程级证据。未知或未实现的核实方式一律失败，不能升成 PASS。

本轮阻塞就在这里：恢复工具没有实现取得、持有、丢失检测和释放。不能用现有门控补上这个洞。也不在本轮改 App 写者去“凑覆盖”。

## 合成链已经能测的部分

`python3 Tests/test_receiver_whitelist_recovery.py`：13 项通过，Python 3.12.3，Linux，1.633 秒。夹具是临时目录。结论全部是合成或 `UNVERIFIED`，不是 Mac，也不是真实恢复。

已经由现有测试覆盖、且只在合成夹具上成立的行为：

- 归档后恢复到新的 `.noindex`，不要求事先存在 Group；活动业务文件与隔离副本按白名单字节一致
- `verify` 对夹具 plan 跑 runtime-only，`sourceArchivesChecked` 为 false；这不把隔离目录变成活动根
- 提交前中断不留下目标，不改来源权威字节；再次恢复拒绝已存在目标
- 符号链接、`..`、真实数据根、未知路径、维护标记、伪造收据失败
- 读期间来源哈希或目录名单变化则失败，包不提交
- 包内 25 个 Root 字段停在初值；语义项为 null；`reMigrationPerformed`、`reActivationPerformed`、`activeBusinessRolledBack` 为 false
- 门控不能靠确认字符串或 `rootLockIntegrated: true` 通过
- 探针 `main → confirm → run_in` 用 mock Darwin，只说明调度和合成 ACL 样本。Linux 上 `metadataOverall` 为 `UNVERIFIED`

Mac 上才能看的 quarantine、BSD flags、ACL，在这些 Linux 测试里保持 `UNVERIFIED`。mock 的 ACL PASS 只属于探针样本，不能写进捕获保真。

尚未测试、因为入口不存在：

- 另一个进程持有共享锁时，维护独占必须立即失败
- 独占释放后写者才能再次取得共享锁；持有期间不能取得
- 锁 fd 被关闭、路径 inode 被换成另一个文件时，后续步骤必须失败
- 以上三项都不能用 bundle 字符串假装通过

## 失败时工具已经会停的条件

命令缺参数时由 argparse 退出，码为 2，不写包。业务拒绝打印 `{"status":"refused","code":...}`，退出码 1，`realRecoveryCompleted` 为 false。成功打印摘要 JSON，退出码 0。退出码 0 只表示该次合成或捕获命令写完了它自己的目录，不是 READY。

已有拒绝码覆盖：路径和符号链接、真实根、重叠路径、输出已存在、暂存锁忙、维护或模块恢复进行中、缺权威或三库或节奏档案、plan 与权威不一致、来源在读期间变化、生产 plan 字节不符、门控字段或时间窗或 bundle 集合不符、恢复目标已存在或不是 `.noindex`、树成员或 mode/mtime/大小/哈希/xattr/flags/uid 不符、收据声称真实恢复或活动写入。中断点 `before_commit` 只在测试里触发，发生在改名之前。

崩溃保护限于工具自己的暂存：只删除带本进程标记的 `.partial.noindex`。不清理来源，不接管别人留下的暂存。权限不足或元数据读回不一致则失败，不把缺的 Darwin 元数据记成已保全。

## 25 个 Root 字段

合成收据和 Root 实际字段是两块。`syntheticObservation` / `captureObservation` 可以记夹具哈希，并标明 `notRootEvidence` 与 `semanticVerification: UNVERIFIED`。这些值不能填进 `rootActualCurrentRecoveryFields`。当前 `seal_root_fields` 会拒绝把任一字段写成 true，也会拒绝偏离初值。

| 字段 | 初值 | 将来要的证据 | 谁产生 | 现在不能证明 |
|---|---|---|---|---|
| status | NOT_EXECUTED | Root 在真实数据上完成一次受控恢复 | Root 执行记录 | 合成导出成功 |
| captureAt | null | 真实捕获时钟，且与当次包绑定 | 未来经许可的 capture | 夹具时间 |
| restoreCheckAt | null | 真实隔离恢复核对时钟 | 未来经许可的 restore 核对 | 合成 `isolatedRestoreCheckedAt` |
| rootMaintenanceEvidence | null | 独占锁仍持有，且未覆盖写者也有独立进程证据 | 目前没有实现 | 门控 JSON、锁文件在场、导出人字符串 |
| freshCurrentBackup | null | 真实当前包的名称与树哈希 | 未来 capture | 合成包 |
| whitelistAndExclusionManifestSHA256 | null | 当次真实清单哈希 | 未来 capture | 合成清单 |
| authoritySHA256 | null | 当次未改权威原字节 | 未来 capture 与调用方复核 | 夹具权威 |
| sameActiveTransactionVerified | null | 活动事务、原 plan、原 receipt 三者一致且 plan 字节核过 | 未来 capture，仅当生产 plan 文件被传入且事务为 `RootRhythm41011-20261104-03` | 夹具自己的事务 |
| productionPlanByteHashVerified | null | 调用方传入的原文件字节等于固定 SHA | 未来 capture；不传文件必须保持 null | 规范里抄来的 SHA 字符串 |
| originalTransactionReceiptSHA256 | null | 活动事务 receipt 原字节 | 未来 capture | 夹具 receipt |
| payloadMetadataPolicy | null | 当次元数据政策文本 | 未来 capture 可写政策，不是保真 PASS | Linux 观察 |
| actualArchiveTreeSHA256 | null | 当次真实归档树 | 未来 capture | 合成树 |
| isolatedRestoreTargetIdentity | null | 真实新 `.noindex` 的设备与 inode | 未来 restore | 合成目标身份 |
| actualArchiveToRestoreMetadataExact | null | 真实 Mac 上归档与隔离树的类型、mode、mtime、大小、哈希、xattr、flags、ACL 一致 | 尚未有 Root 级证明 | 合成结构匹配、探针 PASS |
| fourPreferenceDomainsPresenceAndValuesVerified | null | 四个域的存在性与值都经核对且不打印秘密 | Root；合成捕获即使读了字节也不能升成这个字段 | 文件存在或 SHA |
| threeCurrentDatabasesConsistent | null | 三库在维护窗口内的一致性 | Root | 合成快照的 integrity_check |
| attachmentsAndGameProgressVerified | null | 附件与游戏进度语义 | Root | 文件个数或夹具摘要 |
| sharedSleepSeedTombstoneRequestRewardDedupVerified | null | 睡眠种子、墓碑、请求、奖励去重 | Root | 合成计数 |
| receiverSourceArchivesRhythmAndAbsencesPreservedOrPreciselyRecoverable | null | 节奏档案与缺失声明可精确恢复 | Root | 合成字节保留 |
| currentReadersCompatible | null | 当前读者能读恢复结果 | Root | runtime-only 对夹具 plan 返回 active |
| runtimeOnlyCompatibleWithUnchangedRootPlanAndReceipt | null | 原 plan 与原 receipt 未改的 runtime-only | Root | 夹具 `syntheticFixtureRuntimeOnly` |
| pureSourceRawExcludedFromRecoverablePackage | null | 纯来源 raw 未进入可恢复包 | Root | 合成排除清单 |
| reMigrationPerformed | false | 必须保持 false，除非另有禁止的迁移许可 | 工具拒绝写成 true | 不能从合成推断已迁移 |
| reActivationPerformed | false | 必须保持 false | 工具拒绝写成 true | 不能从合成推断已激活 |
| activeBusinessRolledBack | false | 必须保持 false | 工具拒绝写成 true | 不能从合成推断已回滚 |

捕获收据里有一部分同名键会被 `seal_capture_fields` 写成 true 或填入哈希，但整张收据标了 `notRootEvidence: true`，而且 `rootMaintenanceEvidence` 仍强制为 null，语义核对字段仍强制为 null。那不是 Root 实际字段已通过。合成导出路径则整张 25 字段停在初值。

## 若将来要在 Mac 上验证，必须拆开的许可

本轮不请求这些许可，也不要一次批准全部。

1. 只读捕获许可：给出四个真实路径、门控文件、输出 `.noindex`，以及可选的生产 plan 原文件。不包含停 App，不包含写活动目录。在写者锁接上之前，这次捕获仍不能把 `rootMaintenanceEvidence` 从 null 改掉。
2. 停写许可：要单独说明停哪些进程、由谁观察它们已退出、如何确认应用支持 `library.json` 和四个偏好域不再被写入。现有 `flock` 覆盖不了这些。本工具目前甚至不会去取那把锁。
3. 隔离写入许可：只允许一个新的 `.noindex` 目标。不包含 `applyPending`、激活、回滚、删来源、删混合容器。
4. 独立探针许可：只针对 `macos_synthetic_metadata_probe.py` 当前哈希，在 `$TMPDIR` 下新建探针目录。它不证明接收方数据。

还没有实现锁的持有与丢失检测之前，第 2 项没有工具可执行的命令。不要用第 1 项代替它。

## 只有本机才知道、且现在不必回答的事实

设计不依赖这些答案。只有在单独批准真实捕获时才需要：

- 四个偏好域现在是 Preferences 目录里的 plist，还是只活在 cfprefsd 里。工具不会自己调用 `defaults`。
- 未改动的生产 plan 原文件在这台 Mac 上的路径。仓库不收录该文件。不传则对应字段保持 null。
- 搞健康、搞足迹是否仍安装并能写它们自己的 Group。代码看不出来。

## 下次代码接续点

只在再次允许改代码时做，仍然不是生产执行：

1. 仅在拒绝真实根的 `export` 上，打开已经存在的 `.rhythm-integration-writers.lock`，不要创建它，不要写维护标记。非阻塞独占 `flock`。忙则失败码 `cooperative_writer_lock_busy`，且不读包。
2. 用子进程做三个测试：共享持有者存在时独占失败；释放后共享锁才能再次取得；fd 关闭或 inode 被替换后后续步骤失败。
3. 观察结果放在合成观察块，禁止写入 `rootMaintenanceEvidence`。未覆盖写者名单保持 fail-closed。
4. 不要把该锁加到 `capture`，以免这个能指向真实路径的入口停写。
5. 不要改 App 的 `library.json`、偏好或钥匙串加锁，除非另有一次只针对该写者的安全评审。

做完这些仍然不是 READY。Mac 元数据、真实捕获、停写和隔离写入仍要各自的许可。
