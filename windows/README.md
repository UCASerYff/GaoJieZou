# 搞节奏 Windows 版

面向 Windows 10/11 x64 的独立版本。营销版本与当前 Mac 版同为 **4.12**，Windows 构建号为 **1**。Mac 版的 Swift 源码、签名、Bundle ID 和 `Info.plist` 版本号都不改。

界面在本机浏览器中打开。服务只监听 `127.0.0.1`。

## 选型

使用 **Python 3.12 标准库** 实现业务，界面是随程序打包的本地网页，安装包用 **PyInstaller** 在 `windows-latest` 上打成单个 exe。这与搞研究 Windows 版的做法相同。

这样选，是因为业务和测试可以在 Linux 上完成，GitHub Actions 的 Windows runner 能直接构建并产出可执行文件。没有做成 WinUI 或 Electron。三维庄园、WidgetKit、菜单栏和 macOS 钥匙串依赖 AppKit / SceneKit / WidgetKit，浏览器界面先把已经对齐的业务跑起来。

## 构建

在 Windows 10/11 x64 上安装 Python 3.12，然后：

```powershell
cd windows
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

脚本会安装开发依赖、运行单元测试，并在 `windows/dist/` 生成：

- `GaoJieZou.exe`：打开界面的窗口程序
- `GaoJieZou-cli.exe`：命令行，用于检查条数和生成计数快照

GitHub Actions 工作流 `.github/workflows/windows.yml` 在 `windows-latest` 上执行同一套步骤。打包之后会用临时目录后台启动 `GaoJieZou.exe`（`--serve --no-browser --port --data-dir`，不打开浏览器），轮询到本机 HTTP 200，再通过该服务新建并读回一次 `library.json`，然后结束进程。两个 exe 作为 artifact `GaoJieZou-Windows-4.12` 上传。这个工作流不会创建 GitHub Release，也不会安装到运行器之外的电脑。

只跑测试：

```powershell
cd windows
python -m pip install -r requirements-dev.txt
python -m pytest -q
```

在 Linux 或 macOS 上也可以跑同一套测试。开发时启动界面：

```sh
cd windows
PYTHONPATH=src python3 launch.py --data-dir /tmp/gaojiezou-dev --no-browser --port 8765
```

然后用浏览器打开 `http://127.0.0.1:8765/`。

## 运行

不需要安装程序。把 `GaoJieZou.exe` 放到任意文件夹，双击运行。程序会打开系统浏览器。关闭浏览器标签不会结束进程；页面右上角的「退出」会暂停仍在走的专注、保存后退出。

资料目录：

`%APPDATA%\GaoSeries\Rhythm\`

也可以用环境变量 `GAOJIEZOU_DATA_DIR` 或参数 `--data-dir` 改到别的目录。第一次打开空目录时需要本人确认「创建我的资料库」。程序不会在资料缺失、损坏、目录里已有其他文件，或版本高于 schema 11 时用空库覆盖原文件，也不会写自动备份。

| 参数 | 作用 |
| --- | --- |
| `--data-dir` | 资料目录。不设时使用 `%APPDATA%\GaoSeries\Rhythm\` |
| `--serve` | 启动只监听 `127.0.0.1` 的本地服务。无其他命令时也会启动服务 |
| `--no-browser` | 不调用系统浏览器 |
| `--port` | 服务端口。`0` 表示由系统分配 |
| `--create-empty` | 在空目录明确新建资料后退出；与 `--serve` 同时使用时新建后继续服务 |
| `--inspect` | 只读打印记录条数，不打印标题或正文 |
| `--widget-snapshot` | 写出只含计数和校验的 `widget-snapshot.json` |
| `--version` | 打印 `4.12+1` |

## 数据

| 位置 | 内容 |
| --- | --- |
| `library.json` | schema 11：打卡、专注、睡眠、目标、琐事、金币、鱼饵、农场、牧场、渔场、水族馆、装饰。日期是 Mac 的 Cocoa 秒（自 2001-01-01 UTC 起）。未知字段保留。`ownedAnimals` 不写回 |
| `settings.json` | 睡眠目标、外观、语言、打卡提醒时刻 |
| `widget-snapshot.json` | Windows 计数快照，含资料 SHA-256 |
| `Integration/authority.json` | 模块路径说明 |
| `Integration/SharedSleep/sleep-records.sqlite` | 与 Mac `SharedSleepStore` 相同的 schema 1：活记录、墓碑、迁移键 `rhythm-library-v1` |
| `Integration/Modules/Health/health.sqlite` | 健康状态、饮水/饮食/运动/体重、快速事项 |
| `Integration/Modules/Footprints/footprints.sqlite` | 到访、旅行、常驻城市、列车 |
| `Integration/Modules/Footprints/Photos/` | 照片副本，按 SHA-256 去重，每条足迹最多 20 张 |

Mac 上这些库位于 `~/Library/Application Support/GaoSeries/Rhythm/` 和 App Group `5G96498KGJ.com.gaojiezou.rhythm`。Windows 不会读取那两个 macOS 路径，也不会注册 App Group。可以把同一套文件复制到上面的 Windows 目录再打开；两边不要同时写入同一份文件。

本仓库的节奏源码没有钥匙串读写。Windows 版不另造凭据库。

城市坐标来自 Mac 版地理数据的城市表（7227 个城市、239 个国家或地区），见 `assets/THIRD_PARTY_NOTICES.txt` 与 `DatasetManifest.json`。行政区多边形和地图瓦片没有打包。

## 功能对齐

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 五个工作台：今天、节奏、健康、足迹、乐园 | 已对齐 | 浏览器里切换。节奏内有专注、睡眠、习惯、琐事、目标、统计 |
| schema 11 `library.json` 往返 | 已对齐 | 高于 11、损坏、目录非空却没有主库时只读，不覆盖 |
| 不制作备份、不提供恢复入口 | 已对齐 | 保存使用临时文件替换，替换后不保留副本 |
| 专注计时、15 分钟 1 金币、单次上限 20、作物按专注成长 | 已对齐 | 浇水 +0.15、施肥 +0.40，倍率上限 1。单段异常增量按 8 小时截断 |
| 关窗口后专注继续 | 部分 | 关掉浏览器标签时进程仍在计时。点「退出」会暂停并保存。Windows 收不到锁屏、熄屏和系统睡眠事件，页面提供「系统暂停 / 继续」作为手动替代 |
| 手动睡眠、0.5–24 小时、评分、60 秒内去重 | 已对齐 | 结束时刻固定规则与 Mac 相同：所选夜晚的次日 07:00 起床 |
| 牧场成长与产物 | 已对齐 | 成长最多记 14 小时，产物最多 2 个周期，只发给当时已成年的动物；重复结算不双发 |
| 共享睡眠墓碑与迁移键 | 已对齐 | 删睡眠写墓碑，不复活，不收回已发奖励。迁移键已存在时不再全量导入。没有 Darwin 通知，不能和正在运行的 macOS 搞健康实时互相同步 |
| 习惯补打卡、每天只发一次金币、取消不扣回 | 已对齐 | 未来日期拒绝。奖励夹在 1–10 |
| 琐事首次 5 金币、短期行动 8 金币 + 1 饵、长期目标 60 金币 + 3 饵 | 已对齐 | 再次完成不重复发 |
| 农场、牧场、渔场、水族馆、装饰价格 | 已对齐 | 田和窝上限 25，水族馆 25 条、离线收益最多 7 天。钓鱼稀有度按 1–100 的区间。咬钩窗口 5 秒，未中钩不扣饵 |
| 健康饮水、饮食、运动、体重、快速事项、趋势 | 已对齐 | 写入 `health.sqlite`。今日没有记录的日子不补 0。体重可隐藏显示，不删记录 |
| 荒岛水分、饱食、活力、采集、建造、升级、扩建、干粮 | 已对齐 | 数值和前置与 Mac `Engine` 相同。界面是计量和按钮，没有 SceneKit 旋转和模型 |
| 健康睡眠奖励 | 已对齐 | 同一条睡眠只加一次活力，删除不收回 |
| 足迹到访、旅行、常驻城市、照片、列车物资 | 已对齐 | 列车物资不换成节奏金币。新城市、笔记、照片和旅行的加成与车厢等级沿用 Mac 规则 |
| 城市搜索与坐标点 | 部分 | 使用离线城市坐标画点。没有 MapKit、在线瓦片、行政区填色 |
| CSV 导出 | 已对齐 | 专注、睡眠、打卡为 UTF-8 BOM、CRLF |
| 中英文与浅色/深色 | 部分 | 设置里可以切换语言和外观。页面正文以中文为主，不是 Mac 的全量文案 |
| 打卡提醒 | 部分 | 只保存提醒时刻。没有 Windows 通知横幅，也没有菜单栏图标 |
| WidgetKit | 部分 | 会写 `widget-snapshot.json` 计数和校验。不能注册 Mac 小组件，也不读取 App Group |
| `gaojiezou://`、`gaojiankang://`、`gaozuji://` | 未实现 | 没有注册 Windows URL 协议 |
| 菜单栏常驻、Dock、快捷键 ⌘0 / ⌘Q | 未实现 | 没有对应的 macOS 应用生命周期 |
| 三维农场、牧场、渔场、荒岛、列车场景和贴图 | 未实现 | 资源和使用它们的代码是 SpriteKit / SceneKit |
| 与 macOS 搞健康的即时睡眠通知 | 未实现 | 协议文件可以放在同一目录，但没有 DistributedNotificationCenter |
| 钥匙串 | 不适用 | 当前 Mac 源码没有钥匙串读写，Windows 不虚构凭据 |

## 已知限制

- 窗口程序没有自己的原生窗口。关闭浏览器标签不会退出进程，需要点「退出」。
- 专注不会自动感知 Windows 锁屏或睡眠。异常的离线段仍按 8 小时上限结算。
- 二维地图只标城市坐标，不画国界，也不声明行政区边界。
- 荒岛和列车没有三维模型。放置使用与 Mac 相同的默认点位和间距检查。
- 同一份资料不要同时被 Mac 版和 Windows 版打开写入。
- 健康库若仍是 Mac 的 `user_version` 0 单 blob，Windows 版拒绝拆写，避免改坏原库。
- 没有 `authority.json` 时，不会为已有的 `library.json` 补建空的健康、足迹或共享睡眠库。
