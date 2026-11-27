# 搞节奏 Windows 4.12

适用于 Windows 10 和 Windows 11 x64。应用显示版本为 **4.12+5**，Windows Installer 产品版本为 **4.12.5**。通过开始菜单启动后，默认使用应用专属的 Edge 窗口和临时浏览器配置。Edge 不可用时使用系统默认浏览器，退出时会停止本地服务，外部浏览器的窗口由浏览器管理。应用服务只监听本机环回地址，业务接口使用每次启动生成的会话令牌。

## 安装和运行

双击 **GaoJieZou-4.12+5-Windows-x64.msi** 为当前 Windows 用户安装。安装后可从开始菜单打开搞节奏、打开桌面小组件，也可使用已注册的 `gaojiezou://` 链接。

关闭主窗后，搞节奏的图标留在通知区域，Windows 也可能把它放在隐藏图标区。从图标或菜单中的「打开搞节奏」可以恢复主窗。重复启动、应用链接和小组件深链共用当前运行实例。专注遇到锁屏、显示器关闭或系统待机时由系统事件暂停，解除相关状态后继续。手动暂停需要手动继续。睡眠使用实际开始及结束时间，在后台和待机期间继续计时。

把鼠标移到托盘图标上，可以查看关联行动的剩余专注分钟、目标达成、超出目标或暂停状态。未关联时间目标时提示已专注时长。更新由计时状态和分钟变化驱动，沿用原有通知机制。

窗口菜单和托盘菜单的「退出」都会先确认、保存并暂停正在运行的专注，再关闭主窗、小组件和本地服务，移除托盘图标。取消会保留当前会话。睡眠会保留起始时间供下次打开时继续。命令行查询和无窗口测试模式不创建通知区域图标。

| Windows 资料 | 用途 |
| --- | --- |
| `%APPDATA%\GaoSeries\Rhythm\library.json` | 节奏资料 schema 11，包含打卡、专注、睡眠、目标、琐事、奖励和庄园进度 |
| `%APPDATA%\GaoSeries\Rhythm\settings.json` | 显示语言、外观、睡眠目标和提醒时间 |
| `Integration/authority.json` | 已激活模块和共同睡眠的路径说明 |
| `Integration/SharedSleep/sleep-records.sqlite` | 节奏与健康共用的权威睡眠记录、删除墓碑和迁移凭据 |
| `Integration/Modules/Health/health.sqlite` | 健康记录、快速事项、设置与荒岛进度 |
| `Integration/Modules/Footprints/footprints.sqlite` | 到访、旅行、常驻城市、照片索引和旅行列车 |
| `Integration/Modules/Footprints/Photos/` | 本地照片文件 |
| `widget-snapshot.json` | 兼容原 Windows 快照命令的校验与计数信息 |

资料目录可用 `GAOJIEZOU_DATA_DIR` 或 `--data-dir` 指定。首次打开空目录时会请求确认后创建。无法安全读取的已有资料会显示相应状态。程序文件与资料目录分开，MSI 卸载保留资料。支持已有 Windows schema 11 和可迁移的旧节奏 JSON。附带模块仅在当前 Integration 权威记录指向支持的库时读取。

## 工作台与 Windows 实现

构建 4 将五个工作台放到桌面导航侧栏，窄窗改用横向导航。今日工作台可以直接开始专注、打卡和补录睡眠。节奏页将操作清单和时间线并排，健康页增加紧凑的记录表与筛选，足迹页将地图与城市浏览、旅行与明细放在一起。乐园将常用工具移到场景外，并提供水族馆入口。设置、表单反馈和六个桌面小组件使用同一套浅深色与焦点样式。

构建 5 从今日工作台打开「每周复盘」。复盘按 Windows 本地时间从周一到周日排列，选择一天可查看已保存的专注、打卡、共同睡眠及行动和目标完成记录。本周及未来周按当前安排显示计划。过往周的计划数留空，因为已有资料缺少计划快照。睡眠按起床日计入。跨午夜的专注若原记录缺少暂停区间，按各日的区间占比分摊并标为估算。已有长期目标缺少完成日期时，界面提示无法归入某周。

| 区域 | Windows 工作流 |
| --- | --- |
| 今天 | 计时入口、睡眠补录、今日打卡和行动、健康摘要、每周复盘、月度总览、近期奖励 |
| 节奏 | 专注启停、睡眠计时与补录、历史打卡、跨日琐事、长期目标、带日期的短期行动、趋势和 CSV |
| 健康 | 饮水、饮食、运动、体重、共同睡眠、筛选检索、趋势、快速事项、模板、CSV 和岛屿经营 |
| 足迹 | 中国和世界离线地图、中文英文和拼音查找、城市到访、旅行、时间轴、常驻城市、照片、地图 PNG 和记录 CSV/JSON 导出 |
| 乐园 | 农场、牧场、渔场、水族馆、荒岛和旅行列车，保留各自奖励和游戏进度 |
| 托盘与小组件 | 重开窗口、定时打卡提醒、安全退出、节奏统计、月历、目标、健康日常、快速事项及足迹地图 |

共同睡眠遵循单一 SQLite 权威、一次性历史迁移、近似去重和删除墓碑。健康与节奏从各自界面写入同一个存档。牧场和小岛分别按本地结算凭据防止重复发奖。Windows 支持本机刷新，macOS App Group 和 Darwin 通知属于各自宿主。

地图使用离线城市坐标、Natural Earth 世界轮廓和 CTAmap 中国行政轮廓。省级和 370 个收藏城市按原有编号匹配，支持边界点选及高分辨率离线地图 PNG 导出。资源与许可见 [Windows 第三方说明](src/gaojiezou/assets/THIRD_PARTY_NOTICES.txt)。已有 HEIC 原件可下载。Windows Imaging Component 具备相应解码器时可在应用内预览，新录入的 HEIC 照片按现有 JPEG 规则保存。

农场、牧场、渔场、水族馆、荒岛和旅行列车使用 WebGL 场景与仓库原有画材。场景支持点选、相机操作、牧场排序、荒岛建筑摆放、鱼类巡游和列车车厢内部视图。WebGL 不可用时使用对应的二维图和业务控件。光照、透明排序和选中边界仍与 SceneKit 有差异。

小组件使用独立可置顶的 Windows 桌面窗口。打卡提醒由后台托盘进程通过 Windows 通知中心发送，支持打开日常打卡。WinRT 通知服务不可用时使用 Windows 托盘兼容提醒。横幅和通知中心的实际显示受系统通知设置影响。

## 构建与隔离验收

在干净的 Windows x64 CPython 3.12 环境运行以下命令。

~~~powershell
cd windows
.\build.ps1 -Python C:\path\to\venv\Scripts\python.exe
.\smoke-install.ps1 -Package '..\dist\GaoJieZou-4.12+5-Windows-x64.msi' -CheckShell
~~~

构建脚本先运行测试，再生成 `dist/GaoJieZou-4.12+5-Windows-x64.msi` 和对应的 `.msi.sha256`。安装包文件名包含 Windows 构建号，可与旧版并存。隔离冒烟使用合成资料，核对安装入口、前版资料重开、已安装程序的 HTTP 读写与系统卸载保留资料。GitHub Actions 执行相同构建和冒烟并保留产物。

可用 Node.js 和 Edge 运行浏览器回归。脚本使用独立的 Edge 配置和合成资料。

~~~powershell
node .\tests\world_browser_smoke.mjs C:\path\to\venv\Scripts\python.exe
~~~

开发或独立运行测试时可显式指定隔离目录。

~~~powershell
cd windows
python -m pytest -q
python .\launch.py --serve --no-browser --port 8765 --data-dir .\build\isolated-rhythm
~~~

`GaoJieZou-cli.exe --inspect` 打印计数及资料状态。`--version` 打印 `4.12+5`。`--widget-snapshot` 兼容旧 Windows 的计数文件用法。`--widgets` 打开桌面小组件。`--create-empty` 明确在空目录创建资料。`--serve` 配合 `--no-browser` 可在独立目录冒烟，`--port 0` 由系统分配端口。
