# 搞节奏 Windows 4.12

适用于 Windows 10 和 Windows 11 x64。应用显示版本为 **4.12+2**，Windows Installer 产品版本为 **4.12.2**。通过开始菜单启动后，默认使用独立的 Edge 应用窗口。Edge 不可用时使用系统默认浏览器。应用服务只监听本机环回地址，业务接口使用每次启动生成的会话令牌。

## 安装和运行

双击 **GaoJieZou-4.12-Windows-x64.msi** 为当前 Windows 用户安装。安装后可从开始菜单打开搞节奏、打开桌面小组件，也可使用已注册的 `gaojiezou://` 链接。

关闭主窗口后可以在通知区域重新打开应用。专注遇到锁屏、显示器关闭或系统待机时由系统事件暂停，解除相关状态后继续。手动暂停需要手动继续。睡眠使用实际开始及结束时间，在后台和待机期间继续计时。通过窗口菜单或通知区域显式退出会先结算和保存。

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

| 区域 | Windows 工作流 |
| --- | --- |
| 今天 | 计时入口、睡眠补录、今日打卡和行动、健康摘要、月度总览、近期奖励 |
| 节奏 | 专注启停、睡眠计时与补录、历史打卡、跨日琐事、长期目标、带日期的短期行动、趋势和 CSV |
| 健康 | 饮水、饮食、运动、体重、共同睡眠、筛选检索、趋势、快速事项、模板、CSV 和岛屿经营 |
| 足迹 | 中国和世界离线地图、中文英文和拼音查找、城市到访、旅行、时间轴、常驻城市、照片、地图 PNG 和记录 CSV/JSON 导出 |
| 乐园 | 农场、牧场、渔场、水族馆、荒岛和旅行列车，保留各自奖励和游戏进度 |
| 托盘与小组件 | 本机专注控制、定时打卡提醒、重开窗口、节奏统计、月历、目标、健康日常、快速事项及足迹地图 |

共同睡眠遵循单一 SQLite 权威、一次性历史迁移、近似去重和删除墓碑。健康与节奏从各自界面写入同一个存档。牧场和小岛分别按本地结算凭据防止重复发奖。Windows 支持本机刷新，macOS App Group 和 Darwin 通知属于各自宿主。

地图使用离线城市坐标、Natural Earth 世界轮廓和公开的中国省级轮廓。中国地图按选定范围和地理投影绘制，地级到访点以坐标展示。资源与许可见 [Windows 第三方说明](src/gaojiezou/assets/THIRD_PARTY_NOTICES.txt)。照片保存、预览和导出在本机完成。已写入的 HEIC 原件仍可导出，预览取决于本机图像解码支持。

Windows 游戏场景使用仓库中原有的二维场景图及图集。SceneKit 的三维相机、光照、运动效果和物理交互仍有差异。浏览器与 Tk 使用 Windows 字体、控件和图形实现，因此与 SwiftUI、Swift Charts 和 WidgetKit 存在渲染差异。小组件使用独立可置顶的 Windows 桌面窗口。打卡提醒通过后台托盘进程发送，实际显示受 Windows 通知设置影响。

## 构建与隔离验收

在干净的 Windows x64 CPython 3.12 环境运行以下命令。

~~~powershell
cd windows
.\build.ps1 -Python C:\path\to\venv\Scripts\python.exe
.\smoke-install.ps1 -Package ..\dist\GaoJieZou-4.12-Windows-x64.msi -CheckShell
~~~

构建脚本先运行测试，再生成 `dist/GaoJieZou-4.12-Windows-x64.msi` 和对应的 `.msi.sha256`。隔离冒烟使用合成资料，核对安装入口、前版资料重开、已安装程序的 HTTP 读写与系统卸载保留资料。GitHub Actions 执行相同构建和冒烟并保留产物。

开发或独立运行测试时可显式指定隔离目录。

~~~powershell
cd windows
python -m pytest -q
python .\launch.py --serve --no-browser --port 8765 --data-dir .\build\isolated-rhythm
~~~

`GaoJieZou-cli.exe --inspect` 打印计数及资料状态。`--version` 打印 `4.12+2`。`--widget-snapshot` 兼容旧 Windows 的计数文件用法。`--widgets` 打开桌面小组件。`--create-empty` 明确在空目录创建资料。`--serve` 配合 `--no-browser` 可在独立目录冒烟，`--port 0` 由系统分配端口。
