# StreamPath 项目说明

本文是 StreamPath 的工程基线，面向维护者
说明当前实现、外部协议、兼容边界、测试方法和不可破坏的行为。用户使用说明见
[README.md](README.md)。

## 1. 技术基线

| 项目 | 当前选择 |
| --- | --- |
| 客户端 | Flutter 3.44.6、Dart 3.12.2、Windows x64 |
| 状态管理 | `provider` / `ChangeNotifier` |
| WebDAV | Dio 5.11，手动重定向与 XML multistatus 解析 |
| 目录缓存 | Hive |
| 播放进度 | SQLite：`sqflite_common_ffi` + `sqlite3` Native Assets |
| 外部播放器 | MPV 为主要目标，其他播放器走参数模板；WebDAV ISO 由固定 libbluray Bridge 解析，本地 ISO/BDMV 由受控 MPV `bd://` 入口播放 |
| Windows 集成 | `win32`、`super_clipboard`、`flutter_acrylic`、MethodChannel |
| 测试 | `flutter_test`、本地 HTTP 服务器、条件式实体 MPV 测试 |

项目采用便携数据布局，不依赖当前工作目录。开发构建会从可执行文件路径向上定位
项目根；便携构建直接使用可执行文件所在目录。不可写时才回退系统应用支持目录。

## 2. 启动与模块关系

启动顺序：

1. `WidgetsFlutterBinding` 初始化；
2. 迁移旧版平铺数据，迁移期间不启动数据库或日志写入；
3. 加载独立缓存过期配置和统一配置；配置必须先于 SQLite 完成，使旧进度迁移能够绑定到
   稳定 `profileId`，随后并行初始化目录缓存、视频/音频 SQLite、播放历史和个人媒体资产；
4. 初始化基础缓存策略、智能缓存配置、媒体元数据与聚合学习存储；
5. 初始化可降级的 ISO 远程播放服务、本地 Blu-ray 启动服务，并扫描远程 Bridge/MPV 双进程会话；文件系统不可用时只关闭对应模块；
6. 组装 `AppState` 与独立的 `AppearanceController`，根据地址和用户名是否完整决定自动连接或显示存储根目录/登录页；
7. 持久化为磨砂样式时在首帧前恢复窗口外观，避免窗口合成状态切换产生黑帧；默认样式不初始化窗口材质插件，恢复失败继续使用不透明主题。

主要目录：

```text
lib/
├─ core/                 常量、异常、路径、URL、Windows 剪贴板适配
├─ data/
│  ├─ local/             版本化配置、Windows 凭据、Hive、SQLite、播放历史
│  ├─ models/            服务器档案、WebDAV、播放器、OpenList、界面外观和统一配置模型
│  └─ remote/            WebDAV HTTP 客户端与 XML 解析
├─ domain/services/      WebDAV、视频/音频 MPV、独立 ISO Bridge、字幕/LRC、进度、诊断和 OpenList 恢复
├─ features/cache_control/
│  ├─ engine/            缓存策略纯计算
│  ├─ intelligence/      本地解释型建议器
│  ├─ monitor/           播放中内存、速度和卡顿监控
│  ├─ providers/         HTTP 媒体探测与系统内存探测
│  └─ store/             策略、元数据与学习数据持久化
├─ features/cache_expiration/
│  ├─ models/            可配置过期策略与边界收敛
│  └─ store/             独立 JSON 配置读写
└─ presentation/         登录、浏览、设置、会话界面与 AppState
```

## 3. 统一配置与数据迁移

`stream_path_config.json` 使用当前 `schemaVersion = 5`，保存服务器档案的非敏感字段、
活动档案 ID、播放器、字幕、排序、隐藏扩展名开关与列表、媒体中心、界面外观和显示语言配置。
同时保存 `localRoots` 本地根目录列表；每项使用稳定 `rootId`、显示名称、规范化绝对路径和启用状态，媒体中心以 `local:<rootId>` 隔离来源。
每个 `ServerProfile` 包含稳定且唯一的 `profileId`、名称、WebDAV 地址、账号、默认目录和
对应的 OpenList/AList 恢复配置。新档案使用随机 UUID；编辑地址或账号不得改变 ID。
旧单账号配置和旧双文件配置使用原有 `mediaSourceId` 算法生成“默认服务器”ID，使现有
收藏、访问索引和播放进度仍能归入同一来源。

密码和 OpenList/AList Token 默认由 `WindowsProfileCredentialStore` 保存为当前 Windows
用户的通用凭据，目标名为 `StreamPath/server-profile/<profileId>`；主配置 JSON 不保存这些
字段。全局 `credentialStorageMode` 可以明确切换为 `portablePlaintext`，此时敏感字段直接
写入便携 JSON，并在配置成功提交后尝试删除对应 Windows 凭据。安全模式写入多个凭据时，
必须先保存旧值；任一写入或配置提交失败都回滚本次已改写凭据，不能留下“旧配置配新密码”
的混合状态。服务器与 OpenList/AList 基础地址解析时统一剥离 URL userinfo，不能借地址字段
绕过凭据存储边界。删除档案只在配置原子提交后清理不可达凭据。

`appearance` 缺失或样式值未知时按 `classic` 读取，因此旧配置和新安装
均继续使用原有不透明界面；磨砂背景不透明度限制为 60%～95%。材质偏好支持
`automatic`、`acrylic` 和 `mica`：旧版磨砂配置缺少材质字段时迁移为 `acrylic` 以保持
原有视觉，其他缺失或未知值按 `automatic` 读取，并在下次保存时写入新字段。
`hiddenExtensionsEnabled`
缺失时按 `true` 读取，以保持旧配置原有过滤行为；关闭
开关只停止应用过滤，不清空 `hiddenExtensions`。
自动连接完整性只要求 `serverUrl` 和 `username` 非空，密码允许为空。OpenList 管理员
登录仍要求 Token，或同时提供管理员账号和密码；它与 WebDAV 空密码语义无关。

运行数据分为：

- `config/stream_path_config.json`：统一用户配置；
- `config/stream_path_config.json.bak`：最近一次可解析配置备份；
- `config/stream_path_config.json.migration-v*-*.bak`：跨版本迁移前的精确备份；
- `config/stream_path_config.json.migration-legacy-files-*.bak/`：旧双配置文件的原样备份目录；
- `config/stream_path_config.json.migrations.jsonl`：迁移时间、版本、结果与备份路径；
- `config/cache_policy.json`：确定性缓存策略；
- `config/cache_intelligence.json`：本地智能建议器模式和边界；
- `config/cache_expiration.json`：可重建缓存的过期时间；
- `cache/directory_cache/`：目录缓存；
- `cache/streampath.db`：按 `(profile_id, 无凭据 URL)` 分表存储正式播放进度与缓冲临时播放点；
- `cache/playback_history.json`：普通视频与 ISO 共用的最多两个下边栏继续播放会话；
- `cache/audio_streampath.db`：同样按档案隔离的独立音频播放进度；
- `cache/audio_playback_history.json`：最多两个音频继续播放会话；
- `cache/media_metadata.json`：媒体长度、时长、码率、ETag 等；
- `cache/cache_intelligence_learning.json`：匿名聚合样本；
- `library/media_library.json`：按匿名来源隔离的收藏、最近目录以及视频、音频、ISO 长期播放历史；
- 本地 ISO 会话记录在媒体库 ISO 历史中附带 `rootId`、相对路径、大小、修改时间、fingerprint 及 MPV 进程身份快照；旧记录缺少该字段时仍可读取；
- `cache/mpv-watch-later/`：MPV 原生续播文件；
- `cache/mpv-audio-watch-later/`：音频专用 MPV 原生续播文件；
- `cache/mpv-current-*`、`mpv-command-*`、`mpv-progress-*`：会话通道。
- `cache/mpv-audio-current-*`、`mpv-audio-command-*`、
  `mpv-audio-progress-*`：独立音频会话通道。
- `cache/iso_temp/<session>/`：ISO Bridge 会话的 M3U8、Lua、JSONL、状态/命令文件、脱敏双进程
  manifest 和 metrics；不得创建完整 ISO，MPV/helper 都明确退出后删除，身份无法证明时保守保留。
- `cache/iso_catalog.json`：以匿名 ISO 键保存 Title 顺序、选择结果和最后播放 MPLS。
- `cache/iso_watch_later/<匿名 ISO 键>/`：ISO 独立续播点，不与视频或音频进度混用。
- `diagnostics/streampath-diagnostics-*.json`：用户主动导出的脱敏诊断包。

控制台、stderr 和内部诊断日志固定使用英文，异常只记录英文 `error-type`，避免把面向用户的
本地化错误文案混入日志；界面提示和用户主动导出的诊断内容仍按现有本地化规则显示。

迁移已覆盖基础配置、智能缓存配置、学习数据、SQLite、历史、媒体元数据、MPV 状态、
命令、JSONL、播放列表、Lua 和 watch_later。目标存在时用户数据优先；单项失败保留
源文件并在下次启动重试。旧配置 JSON 结构错误时不会阻塞启动，也不会删除原文件。
统一配置保存使用临时文件原子替换，并保留最近一次有效备份；启动加载失败时依次回退
备份和默认值，损坏的主文件与备份均保留供人工恢复。任何跨版本迁移都必须先复制精确
备份，再写入新格式，并把成功或失败追加到迁移日志。备份失败时禁止开始迁移；高于当前
支持版本的配置必须拒绝解析；启动界面可以使用内置默认值降级显示，但本次进程禁止保存，
不能让旧程序覆盖新格式。迁移备份可能保留旧版或便携模式
的明文凭据，属于敏感回退材料。

### 3.1 服务器档案隔离

`profileId` 是多服务器数据隔离的唯一主键，不能再以当前用户名、可编辑地址或显示名称
代替。`WebDAVService` 使用它构造 Hive 目录缓存命名空间与访问型索引 `sourceId`；
`MediaLibraryStore` 的收藏、最近目录和长期历史使用同一来源 ID；视频和音频 SQLite 的
正式、临时进度表使用 `(profile_id, url)` 复合主键。播放器运行时在启动时捕获档案 ID，
即使随后切换活动档案，退出同步仍写回原档案。

登录页和设置页都先对候选档案执行强制 WebDAV 根目录验证，成功后才更新活动档案；设置页
还会同步当前内存连接和登录页表单。验证或配置保存失败时保留旧活动配置与旧连接，不保存
候选修改。档案默认目录只决定浏览页首次进入的相对路径，不改变 WebDAV 根地址、播放列表
和媒体 URL。

旧版 SQLite 升级到版本 3 时，把全部旧行绑定到已经迁移出的“默认服务器”ID，再建立
复合主键和更新时间索引。配置因此必须先于 SQLite 加载。目录缓存改用 `profileId` 后允许
形成缓存未命中并重新拉取，但旧访问快照与个人资产的来源 ID 继续可识别。

### 3.2 本地存储与来源边界

`mediaLibrary.sharingMode` 控制展示范围：`independent` 默认各来源独立，`localShared` 合并本地挂载，`allShared` 合并本地与网络来源。共享媒体中心和底栏保留每条记录的原始 `sourceId`，进度读取、会话恢复及切集写回均使用该身份；切换模式不迁移数据库、不改写路径，现有按来源容量限制继续生效。跨来源打开条目复用对应 `BrowserPage`，网络连接仍先验证再激活。共享列表批量清理只作用于当前展示范围，设置页既有“当前来源”清理仍保持原范围。

本地蓝光历史的可选 `playbackBarDismissed` 只控制底栏可见性，独立于媒体中心的 `continueDismissed`。删除底栏仍核验并关闭对应播放器，但不删除媒体中心历史、Title 快照或续播点。蓝光播放方式按钮统一为带边框按钮，取消动作保持原样。

本次上述改动已于 2026-09-05 由用户在本机完成构建、Test 和各项实际功能验证，验收结论为通过。

最外层目录固定提供“网络存储”和“本地存储”两个入口。网络存储沿用当前 WebDAV 首页和已挂载连接；本地存储只显示配置中启用的本地根目录，未配置或目录暂不可用时显示空状态，不影响 WebDAV。

本地根目录通过设置页或本地存储页右上角 `+` 添加。Windows runner 在 STA 线程使用 `IFileOpenDialog` 目录选择器并通过 MethodChannel 返回选择或取消，也允许直接输入绝对路径；保存前检查目录存在、可枚举并解析最终路径。每个根目录由 `local:<rootId>` 作为独立来源，目录内部只使用 `/` 分隔的相对路径；`.`、`..`、空段、根目录外的 junction/symlink 和删除后的路径均拒绝。

`LocalMediaSource` 按进入目录按需枚举，不递归扫描整棵磁盘。视频调用 `ExternalPlayerService.launchLocal`，音频调用 `AudioPlayerService.launchLocal`，二者都跳过 WebDAV 认证、远程缓存和 OpenList 恢复；同目录音频只匹配本地 LRC 与封面。`LocalDiscPlaybackService` 独立生成受控 MPV 参数，ISO 使用文件路径，BDMV 使用包含 `BDMV`/`CERTIFICATE` 的光盘根目录；固定设备、`bd://menu`/`bd://longest`、私有 IPC 和退出策略，但保留用户所选 MPV 的配置、脚本与普通显示/音频参数。

本地媒体可进入收藏、最近目录和媒体库播放历史。ISO 会话记录附带本地根 ID、相对路径、文件大小/修改时间、fingerprint、MPV 进程身份和可用的 edition；菜单片头与菜单页不写入线性进度，进入稳定 Title 后才显示和保存续播，fingerprint 变化后旧位置失效。应用关闭时停止本地探活器并清空内存会话，但不会替用户终止播放器进程。真实 ISO/BDMV 的只读 Title 状态探测已通过，完整菜单交互仍需在目标 Windows/MPV 环境执行。

### 3.3 缓存生命周期

`CacheRetentionPolicy` 是各存储依赖的只读接口；具体 JSON 模型、设置页和文件存储位于
`features/cache_expiration/`。目录、进度、历史、元数据和界面都只依赖策略接口或其
提供函数，不反向依赖设置页。`cache_expiration.json` 提供五个整数配置：

- `directoryFreshnessMinutes`：目录内容新鲜期，默认 10，范围 1～1440 分钟；
- `directoryRetentionDays`：目录快照最大空闲期，默认 30，范围 1～3650 天；
- `directoryScrollRetentionMinutes`：目录滚动位置最大空闲期，默认 30，范围 1～1440 分钟；
- `playbackRetentionDays`：视频/音频进度、继续播放历史和 `watch_later` 保留期，默认
  365，范围 1～3650 天；
- `mediaMetadataRetentionDays`：媒体探测元数据保留期，默认 180，范围 1～3650 天。

配置缺失或损坏时使用上述默认值，越界值收敛到边界。系统时钟回拨时保守保留缓存，避免
误删。自动维护失败只保留旧缓存或形成缓存未命中，不能阻断浏览和播放。各存储在自然生命
周期点维护，禁止增加常驻全盘扫描定时器：

- 页面滚动位置使用 O(1) 的有界 LRU，最多 128 条，读取刷新空闲时间；
- Hive 目录快照最多 512 条，启动时清理，访问时间最多每小时落盘一次以限制写放大；
- SQLite 在启动、查询和显式维护时用索引清理旧进度；历史 JSON 首次加载时过滤非活动旧
  会话，仍带 PID 或 IPC 身份的会话不得自动删除；
- 应用启动时单次扫描视频和音频 `watch_later` 目录，MPV 启动和进度同步也会忽略并删除
  过期记录；批量检查采用 MD5 直查与单次目录扫描，不能按播放列表长度重复全目录扫描，
  全局扫描只识别恢复记录，不删除同目录的播放列表或脚本；
- 媒体元数据在串行队列中按时间和 1000 条容量上限维护。

`cache_intelligence_learning.json` 明确不实现自动过期，也不接受外部过期值；只有用户
主动执行“清理学习数据”才允许重置。普通缓存清理继续保留该文件。

### 3.3 诊断与非破坏性数据库维护

`DiagnosticService` 是诊断数据的唯一边界。一次运行分别产生 WebDAV 强制根目录验证、
播放器文件或 PATH、活动 MPV IPC 只读属性、OpenList/AList 公开设置 API、数据目录
创建/刷新/删除探针、视频/音频 SQLite `PRAGMA quick_check`、Hive 初始化与条目数量、
配置版本/迁移/凭据状态。各项独立收敛为 `DiagnosticItem`，单项失败不能中止其他检查。

导出格式是版本化 JSON 诊断包。服务器地址只能输出规范化 `origin` 与路径 SHA-256；
无效地址只输出整体摘要。档案 ID 与默认目录只输出摘要，不输出档案名称或用户名。摘要和
任意层级详情在序列化边界统一递归脱敏，移除已知密码/Token、Basic/Bearer、userinfo、
查询与签名参数。迁移记录只导出备份文件名，不能导出包含用户目录的绝对路径。文件先写
临时文件再原子改名；同一诊断结果重复导出时使用不冲突的新文件名。

`PlaybackProgressService.repairNonDestructive()` 先要求 `quick_check` 通过，再使用
`VACUUM INTO` 生成一致性备份，最后执行 `REINDEX` 和 `ANALYZE`，不得删除或改写进度
语义。数据库已经报告损坏时必须停止自动维护，交给人工恢复。界面入口还要求视频与音频
播放器全部停止，避免维护与退出同步竞争；同一秒重复维护生成不同备份文件。

### 3.4 展示层有限拆分边界

展示层继续使用 `provider` 和现有 `AppState`，不迁移状态管理框架，也不拆解稳定的 MPV
内部流程。当前仅建立以下边界：

- `DirectoryBrowserController` 持有目录、面包屑导航、排序、当前目录搜索、加载错误和请求
  代次，只依赖 `DirectoryRepository` 与配置存储。控制器的 `files` 始终保存完整目录；
  隐藏后缀、搜索和排序只派生 `visibleFiles`，播放列表、字幕、LRC、封面和媒体资产仍使用
  完整目录。
- `PlaybackSessionPresenter` 持有视频与音频下边栏会话、会话编号和轮询计时器，并阻止页面
  直接改写会话集合。MPV 状态同步、播放进度、异常恢复、进程控制及历史持久化仍沿用原有
  Service 和页面编排，不能因展示拆分改变事件顺序。
- `SettingsConfigDraft` 统一持有设置页尚未保存的输入值，负责在表单值与现有配置模型之间
  转换。服务器、播放、媒体中心、缓存、诊断、界面和基础设置分别使用独立表单组件，拥有
  独立的验证键、滚动控制器和页面存储键。配置保存顺序、凭据回滚、外观失败回退和缓存配置
  独立持久化语义仍由原提交链保证。

收藏、访问型索引、服务器档案、诊断与缓存配置继续使用已经独立的 Store/Service；禁止仅为
缩短文件或追求形式统一而增加新的业务层。

## 4. WebDAV 协议层

### 4.1 认证和重定向

`WebDavClient` 不在 Dio 实例上设置全局 `Authorization`。每个请求以 WebDAV 根地址
为原始来源，最多手动跟随 5 次重定向：

- 只接受 HTTP/HTTPS；
- 严格比较 scheme、host 和有效端口；
- 只有同源请求携带 Basic；
- 跨来源 GET 可以继续，但移除认证；
- PROPFIND 同源重定向保留方法、`Depth: 1` 和认证。

空密码编码为 `base64("username:")`。连接失败统一转为可展示的网络错误，登录页保留
地址、用户名和密码输入状态，用户可直接修改后重试。

登录验证必须调用 `verifyConnection()` 强制刷新根目录，禁止通过新鲜 Hive 缓存返回。
目录缓存键包含稳定 `profileId` 命名空间的 SHA-256，因此即使两个档案使用相同 WebDAV
地址和用户名，也不会读取彼此的目录快照；档案 ID 本身不以明文写入缓存键。

### 4.2 目录与 STRM

目录请求使用 `PROPFIND Depth: 1`，解析标准 DAV 命名空间和非标准前缀，名称缺失时
从 href 解码。宽窗口按名称、大小和修改时间显示，普通文件显示格式化大小，文件夹的
大小单元格显示短杠；窄窗口把普通文件的大小与时间收进条目副标题，文件夹只显示时间。
宽窗口的文件、文件夹和返回上级条目使用统一紧凑行高并垂直居中，窄窗口保留两行布局。
显示列表可按名称、时间或体积排序；播放列表始终使用后台自然名称正序，避免临时排序
改变切集顺序和历史索引。

浏览页当前目录搜索先应用隐藏后缀，再按文件名执行不区分大小写的包含匹配，最后沿用当前
排序；返回上级条目不参与匹配并始终保留。显示列表从后台全量目录派生，视频/音频播放列表、
字幕、LRC、封面与索引继续使用完整目录。关闭搜索恢复原目录滚动位置，任何目录切换都会
退出搜索。两个搜索输入框都复用登录和设置页的 `buildClipboardHistoryMenu`，全局
`ClipboardHistoryFix` 继续负责 Windows `Win+V` 注入兼容。

浏览页搜索框默认范围仍为“当前目录”。用户主动切换到“OpenList 全部索引”后，输入至少
2 个字符并等待 400 毫秒防抖，才调用 OpenList/AList 的 `/api/fs/search`；该接口只读取
服务端已经建立的本地索引，StreamPath 不对 WebDAV 执行递归扫描。搜索使用当前 WebDAV
普通用户登录，以服务端权限和 `base_path` 限制结果；管理员 Token 不能用于搜索。索引结果
只保存名称、父路径和基础元数据，点击后必须进入真实 WebDAV 目录重新读取并核对条目，不能
直接把可能过期的索引路径交给播放器。关闭搜索、切换目录后范围恢复“当前目录”，且索引结果
不能改写控制器的完整 `files`。

OpenList/AList 索引节点不保证提供文件修改时间。索引搜索继续在文件名下方显示完整父路径，宽窗口的
右侧“所在文件夹”列只显示直接父文件夹名称；不能把索引完成时间冒充文件修改时间，也不能为
每条结果追加 `/api/fs/get` 回源请求。当前目录列表继续显示 WebDAV `getlastmodified`，不受
该限制影响。

“设置 → 服务器 → OpenList/AList 索引”提供手动更新和默认关闭的定时更新。两者只调用后台
索引管理 API；提交前读取 `/api/admin/index/progress`，服务端正在构建时跳过，进程内请求也
互斥。定时器启动或配置变更后先等待一个完整间隔，任务完成后才安排下一次，避免慢更新重叠。
更新间隔限制为 5～10080 分钟：表单拒绝越界值，配置反序列化和运行时调度再次钳制，手改
JSON 也不能低于 5 分钟。更新沿用 OpenList/AList 已配置的最大索引深度；StreamPath 不修改
服务端的索引类型或自动更新开关。管理员凭据只用于索引更新，搜索与更新身份严格分离。
若服务端未启用数据库索引或增量自动更新能力，界面只展示后台返回的失败信息，不能通过
清空后全量重建来绕过这一保护。

索引设置卡使用 `/api/admin/index/progress` 展示 `obj_count`、`is_done`、`last_done_time`
和服务端错误。OpenList 不提供总条目数，因此运行中使用不确定进度条，不伪造完成百分比。
页面首次进入只读取一次；仅当服务器分页可见且索引正在运行时每 2 秒轮询，完成、切换分页、
切换档案或页面销毁后立即停止。手动提交后的 5 秒短暂宽限用于跨过后台任务启动竞态；管理员
登录 Token 在同一凭据会话内复用，避免每次轮询重新登录。状态读取只访问 OpenList/AList
后台内存状态，不读取挂载目录。

Hive 新目录快照保存匿名 `sourceId` 和相对目录路径；旧快照仍可浏览，但没有元数据时不参与
全局搜索。只读枚举不刷新快照访问时间，仍沿用 512 条容量、目录空闲过期和缓存清理规则。
媒体中心全局搜索不发网络请求、不递归扫描服务器，只索引目录、视频、STRM 和音频；按名称完全匹配、
名称前缀、其他名称或完整路径包含、最近缓存时间排序，180 毫秒防抖，最多返回 200 项。

STRM 规则：

- 最多读取 8192 字节；声明长度和流式累计长度都执行上限；
- UTF-8 非法字节以替换字符处理，不允许读取无界正文；
- 取第一条非空、非注释的 HTTP/HTTPS 地址；
- 相对地址基于 WebDAV 根路径解析；
- 最终地址必须与 WebDAV 根严格同源，否则条目无效；
- 任意网络、解析或安全检查失败都只跳过该条目。

目录强制刷新会等待正在进行的同目录请求结束，再发起真实新请求。只有成功结果覆盖
缓存；刷新失败保留最后一次成功数据。目录内容新鲜期与快照空闲保留期相互独立：前者
触发 stale-while-revalidate，后者到期后不再展示旧快照。

## 5. 外部播放器与 MPV

### 5.1 启动参数和认证

播放器参数由 `PlayerConfig.args` 展开。MPV 通过可执行文件名识别并增加 IPC、脚本、
标题、进度和缓存参数。配置中后出现的 MPV 参数覆盖前值，便于策略层在不改用户模板的
前提下追加安全参数。

不能给 MPV 使用全局 `--http-header-fields=Authorization`：实体测试证实它会把 Basic
继续发送给跨来源重定向目标。当前实现只对与播放启动快照中 `serverUrl` 同源的媒体和字幕 URL
写入百分号编码的 userinfo；空密码保留 `username:` 中的冒号，以兼容 MPV 0.34。
四个实测版本均能完成源站 Basic，并在跨来源重定向后移除凭据。第三方 URL 不注入。

### 5.2 单集、多集、字幕和外挂字体

单集直接展开 `{url}`，并使用 `--force-media-title`。多集生成 M3U：

- `#EXTINF` 和 `EXTVLCOPT:force-media-title` 保存稳定标题；
- `--playlist-start` 决定点击的起始集；
- 标题 Lua 是不支持 EXTVLCOPT 的旧版兜底；
- 字幕 Lua 监听 `file-loaded`，按 `playlist-pos` 调用 `sub-add`；
- 自动选择关闭时加入轨道但恢复原 sid；自动注入关闭时不增加字幕参数或脚本。

WebDAV 外挂字体复用同一“自动注入”开关，但不参与字幕轨道选择。浏览页始终从完整的
当前目录条目中精确匹配一个直属字体目录；媒体与候选目录必须同源、父目录相同，目录请求
路径从服务器返回的实际 `href` 推导。名称识别忽略大小写、空格和常见连接符，但不做包含
`font` 的模糊命中；多个候选按字幕专用、常规、字体文件/字体包、备份目录的顺序选择。

命中后只接受该目录直属的 `.ttf`、`.otf`、`.ttc`、`.otc`，再次校验同源、父目录和路径
深度，不递归读取任何子目录。字体通过既有 WebDAV 客户端按原始字节下载到本次 launch
独占的本地目录，最多 256 个文件、单文件 64 MiB、合计 512 MiB、4 个并发请求，准备阶段
总计不超过 30 秒。会话 Lua 在 `on_load` 阶段设置 file-local `sub-fonts-dir`，使播放列表
切集时继续使用同一个隔离目录；MPV 不支持该属性时脚本直接跳过，不用未知命令行参数阻断
播放。单个字体下载失败只跳过该文件，会话结束时按精确文件清单清理本地副本和空目录。

TS/M2TS 使用 `--rebase-start-time=yes`，无历史进度时不得注入 `--start=0`，避免对非零
起始时间戳执行无意义 seek。零点首次起播保持 `cache=no` 快速路径，首次
`playback-restart` 后切入 15～60 秒、最多 128 MiB 的运行态小窗口；非零续播从启动阶段启用
该窗口。拖动时观察到 `seeking=true` 即启用缓存，只有当前文件的新 `playback-restart`、
`seeking=false` 和有效 `time-pos` 同时成立后才启动监控与学习。全程保持
`demuxer-seekable-cache=no`。

### 5.3 会话和进度协议

每次 MPV 启动获得唯一 Windows named pipe。最多两个界面会话，每个会话使用独立的：

- `mpv-current-<session>.txt`；
- `mpv-command-<session>.txt`；
- `mpv-progress-<session>.jsonl`；
- Lua、M3U 和 IPC pipe；
- 缓存策略状态、代际令牌和进程身份。

状态文件固定为十八行：

```text
playlist-pos
path
paused
time-pos
duration
cache-buffering-state
network-speed-bps
cache-idle
speed_src|speed|idle_src|idle_raw
paused-for-cache
bof-cached
eof-cached
resolution
seeking
playback-restart serial
demuxer-cache-duration
forward-cache-bytes
total-cache-bytes
```

MPV 0.41 优先读取 `demuxer-cache-idle`，旧版回退 `cache-idle`；速度优先
`cache-speed`，再回退 `demuxer-cache-state.raw-input-rate` 和旧版 reader 结构。属性缺失
写 `-1`，监控按未知降级，不能抛错或停止播放。

JSONL 记录每个 `end-file` 的播放列表位置、路径、位置、时长、原因和错误。自然 EOF
删除 SQLite 旧进度，0 秒是明确状态，普通退出允许 watch_later 的精确值覆盖每秒采样。
认证播放 URL 的 watch_later 按实际 URL 的 MD5 读取，最终 SQLite 键和轨道比较均剥离
userinfo。MPV 只有 `reason=error` 才进入 OpenList 恢复判断。

状态脚本同时观察 `paused-for-cache`：起播后的前 5 秒只用于排除瞬时缓冲，之后每段新
缓冲立即追加独立的临时播放点事件。连续健康播放 5 秒、自然完成或到达 99% 时追加清除
事件。退出监听每 2 秒增量落库；临时播放点使用独立 SQLite 表并优先用于下次续播，普通
正式进度即使写成 0 秒也不能覆盖它。

视频和音频启动时都保存 PID、规范化可执行文件绝对路径和 Windows 进程创建时间；MPV
还保存 named pipe。终止前用同一个打开的进程句柄重新核对全部身份和 pipe 服务 PID，
并将句柄持有到终止命令返回后再关闭，使该 PID 在校验与终止之间不能被复用。旧历史缺少
完整身份、查询失败或任一证据不一致时均失败关闭，并保留界面会话供用户重试。
播放历史的读、改、写在单个存储实例内串行执行，并通过临时文件原子替换，避免两个
MPV 会话同时更新时互相覆盖或留下半写入 JSON。

### 5.4 实体版本结果

| 构建 | 版本 | Lua/命令/IPC/进度 | 认证隔离 | 远程 LRC + 封面 |
| --- | --- | --- | --- | --- |
| `mpv-0.34.0-x86_64` | 0.34.0 | 通过 | 通过 | 通过 |
| `mpv-v0.41.0-x86_64-pc-windows-msvc` | 0.41.0-dev-g41f6a6450 | 通过 | 通过 | 通过 |
| `mpv-lazy-20260510-noVS` | 0.41.0-615-g7b057f66f | 通过 | 通过 | 通过 |
| `mpv-x86_64-20260610-git-304426c` | 0.41.0-744-g304426c39 | 通过 | 通过 | 通过 |
| `mpv-v0.41.0-460-g2f6561947` | v0.41.0-460-g2f6561947 | 通过 | 通过 | 通过 |

四个固定版本来自
`C:\Users\YX\Documents\StreamPathProject\cross_version_testing\打包版本`，第五个版本来自
`D:\MPV_Player\mpv_config-2026.04.14\mpv.exe`。复测命令：

```powershell
$env:STREAMPATH_MPV_TEST_ROOT = 'C:\Users\YX\Documents\StreamPathProject\cross_version_testing\打包版本'
$env:STREAMPATH_PATH_MPV = 'D:\MPV_Player\mpv_config-2026.04.14\mpv.exe'
flutter test --no-pub test/mpv_version_compatibility_test.dart -r expanded
```

测试同时覆盖 Lua、named pipe、四项动态缓存属性、TS、字幕、watch_later、file_error、
idle 完成标记和自然完成后的进程退出。

### 5.5 音频播放链路

音频入口按 `AppConstants.audioExtensions` 识别常见有损、无损、有声书、DSD 与纯音频
容器。浏览页从后台全量目录只收集音频，使用稳定自然顺序创建 `.m3u8`；每个条目的
`EXTINF`、`EXTVLCOPT:force-media-title` 和标题兜底 Lua 均使用服务器文件名，点击项
通过 `--playlist-start` 定位。

伴随资源由 `AudioCompanionMatcher` 在同目录内匹配：

- LRC 必须与音频主文件名完全相同；
- LRC 复用视频字幕设置语义：自动注入关闭时不匹配、不添加 LRC 或 `--sub-auto=no`；
  自动选择关闭时以 `auto` 加入轨道并恢复注入前的 `sid`；
- `AudioLyricsLocalizer` 通过当前 WebDAV 连接读取远程 LRC 原始字节，单文件上限 2 MiB，
  最多四路并发，整批准备上限 10 秒，并把成功读取的歌词写为当前会话专用文件。这样
  MPV 读取的是可 seek 的本地 LRC，不依赖服务器 Range 行为，也不会因远程 LRC 与
  外挂封面并存而阻塞播放列表推进；
- LRC 读取、超限或写入失败时只移除该曲目的歌词引用。会话文件不保存媒体内容、不跨
  会话复用，并在会话清理时删除，因此不属于音频缓存控制或优化系统；
- 外挂封面先选同名图片，再按 `cover`、`folder`、`front`、`album` 等标准名称回退；
- MPV 以 `audio-display=embedded-first` 保持内嵌封面优先；没有内嵌封面时，Lua 以
  `video-add ... yes` 添加并选中外挂图片轨道；
- `file-loaded` 按 `playlist-pos` 注入对应 LRC、外挂封面和曲名。LRC 下载沿用视频链路
  的同源 Basic Auth 与跨来源重定向去认证规则；音频和封面 URL 仍由 MPV 直接读取。

`AudioPlayerService` 与 `ExternalPlayerService` 是并列服务。音频拥有独立进程运行时、
named pipe、状态/命令/JSONL、M3U8、Lua、watch_later、SQLite、历史存储、下边栏集合
和初始化降级路径。二者只共享无媒体类型假设的 URL 安全函数、MPV watch_later 解析器、
`PlaybackMediaEntry` 最小进度契约和已验证的 JSONL 合并器；音频不导入缓存控制、
OpenList 恢复、视频 `MediaEntry` 或字幕匹配模块。

音频状态脚本只写 `playlist-pos`、`path`、`paused`、`time-pos`、`duration` 五行，不读
任何缓存属性。进度仍遵守视频经过实体验证的语义：自然 EOF 删除旧进度，0 秒覆盖旧
正数位置，普通退出允许 watch_later 覆盖每秒事件采样。应用先退出、MPV 后退出时，
继续播放前会先按稳定会话 ID 合并遗留 JSONL 和音频 watch_later，再读取音频 SQLite。
视频与音频共同服从 `resumeEnabled`，关闭时音频不写 watch_later 启动参数或恢复位置。

### 5.6 WebDAV Blu-ray ISO 无驱动 Bridge 链路

阶段二已接入可选的 WebDAV HDMV 菜单流程，代码和自动检查已完成，等待用户真实验收，尚未标记为正式能力。当前通过 helper 内 WinFsp 只读 ISO 使用用户配置的普通本地菜单 MPV，无需专用播放器；复用既有 RangeSource/Metadata Cache/BlockCache，详见[集成与验收](WebDAV%20ISO%20蓝光菜单播放流程系统/WinFsp集成与优化验收.md)。菜单组件通过能力核验后才提供入口，用户明确选择菜单，失败时可返回 Title/MPLS 选择，不自动切换或完整下载。未启用菜单时保持原有 Title/MPLS 流程。本地 ISO/BDMV 菜单边界不变。

远程菜单复用既有 Range、validator、BlockCache、进程身份和会话清理，使用独立的 `webdavHdmvMenu` 历史键；仅支持未加密 HDMV，拒绝 BD-J。真实光盘、体验、网盘请求行为和旧 Title 性能回归由用户验收。实现状态与验收记录见[阶段二说明](WebDAV%20ISO%20蓝光菜单播放流程系统/阶段二实现与验收说明.md)。

2026-09-07 菜单接入现有缓存策略：MPV 自动预算 16 MiB，ISO 字节缓存按策略内存预算分配、最高 1 GiB，最多四分之三用于前向预读。窗口从 8 MiB 起步，连续读取后按消费速度与目标时长逐步扩大，Seek 后重新从短窗口起步；仅菜单保护未消费的前向窗口。短窗口保留 4 MiB 批次，长窗口合并最多 16 MiB Range，仍只有一个 worker。MPV 导航缓存条可能仍为 0，详见[菜单长缓存与波动回归](WebDAV%20ISO%20蓝光菜单播放流程系统/菜单长缓存与波动回归.md)。菜单启动不再恢复 edition/时间。设置“WebDAV 蓝光菜单进度”默认为独立：不保存菜单线性进度；共享时保存明确 MPLS 的正片进度，退出同步到同源 ISO 的 Title/MPLS watch_later。菜单底栏与媒体中心继续播放依据历史保留光盘和目录，不要求时间进度；不保存光盘 VM 快照。详见[菜单进度独立与共享](WebDAV%20ISO%20蓝光菜单播放流程系统/菜单进度独立与共享.md)。上一轮续播验证见[菜单缓存与续播修复验收](WebDAV%20ISO%20蓝光菜单播放流程系统/菜单缓存与续播修复验收.md)。

`.iso` 由 `WebDavFile.isIso` 独立识别，不加入 `videoExtensions`、`isPlayable`、
`isMediaPlayable` 或 `MediaLibraryKind`。未启用菜单时，浏览页点击后直接进入 ISO 远程播放测试弹窗，不调用视频或
音频播放函数，也不占用其会话槽位。`IsoPlaybackService` 仅由 `AppState` 可选注册；初始化
失败不影响目录浏览、视频和音频。

`IsoAccessProvider` 是播放器编排与访问方式之间的最小边界。唯一生产实现
`IsoBridgeAccessProvider` 以 pipe 名与 StreamPath PID 启动 x64 helper，核对 pipe 服务 PID，
再通过内存 `open` 消息发送当前 WebDAV URL、来源和凭据快照。helper 与应用命令行、环境变量、
manifest 和日志都不保存这些值。旧 `FullDownloadIsoAccessProvider`、
`WebDavClient.downloadFile()` 和完整下载界面已经删除；manifest v1 只为旧活动会话安全收尾。

helper 使用 WinHTTP 手动跟随最多五次重定向，Basic 只发送到 WebDAV 基准同源地址。HEAD 仅
收集提示，权威探测必须由 `GET Range: bytes=0-0` 获得精确 206、Content-Range、长度与一个
字节正文。会话必须具备强 ETag 或 Last-Modified，并以 If-Range 阻止不同版本 ISO 混读。
不支持 Range、长度/验证器不稳定、中途断流或文件变化都明确失败，不重试且不完整下载。

同一 profile 再次打开同一未变化 ISO 时，helper 可读取独立的
`cache/iso_structure/<anonymous_iso_key>.cache`，但每轮仍先执行上述真实 Range/validator 探测。
匿名 key 继续使用 `profileId + 去敏规范 URL` 的 SHA-256；cache 只保存长度、validator 类型与摘要、
固定 schema/libbluray 结构版本，以及 Title/MPLS/章节和多 Clip 时间轴，不保存 URL、原始 validator、
文件名或凭据。所有身份与边界校验通过才跳过完整枚举，且命中路径不构造枚举用 Metadata Cache；
损坏、未来版本、身份变化或 I/O 失败均回到原枚举，且只有新枚举完整成功、ready 已发送后才由后台
任务原子替换，不阻塞后续控制消息或播放启动。该可重建 cache 与 `iso_catalog.json` 用户状态严格分离。

固定 libbluray 1.5.1 安全修订通过 `bd_open_stream()` 读取内存 LRU，枚举、按 MPLS
去重并输出 Title、时长、流大小和章节；AACS/BD+ 明确拒绝。枚举期使用独立 Metadata Cache：
256 KiB demand block、64 MiB 峰值容量且不启动预读。枚举完成先冻结元数据指标，再停止该 Cache，
把最近使用的最多 16 MiB 完整块及跨阶段 refetch 历史以移动语义交给 Playback Cache；不复制字节、
不增加 Bridge 峰值预算。交接块进入普通 LRU，首个 Persistent Context 可复用，正式媒体读取可按
原规则淘汰。Playback Cache 的随机 demand miss 仍使用 256 KiB 小块，顺序预读仍按 4 MiB 配置
单位合并；选择完成后
Flutter 在 `attachPlayer` 前发送一次 `configure_cache`，按所选 Title 最大约 8 秒数据量配置
4～12 个预读块，并把容量设为预读块数加 2、限制为 4～16 块。新播放代际的首个后台批次只取
两个块（8 MiB），后续由单 worker 把每四个相邻块合并成最多 16 MiB 的 Range。localhost 只绑定随机
`127.0.0.1` 端口，端点为 `/<128-bit token>/title/<mpls>.m2ts`，支持 HEAD、普通 GET 和
单段 Range。同一 MPLS 的媒体 GET 以独占租约复用一个 Persistent BLURAY Context，使 `bd_seek` 与
`bd_read` 在同一实例上原子执行；Title 切换、初始化失败或读取硬错误才串行销毁并重建，播放
context 同时存活上限为 1。多 Clip、seamless branching、音视频与 PGS 由
`bd_select_playlist()`/`bd_read()` 原样输出。每个连接在 accept 时取得
递增序号；只有更新的 GET 能取得播放代际、shutdown 上一个媒体 socket，并通过异步 WinHTTP
request 的受支持关闭语义取消旧前台与预读请求；迟到完成解析的旧连接不能反向取消新请求。上下文
租约、Title 打开、seek、丢弃偏差、响应头和正文读取均检查代际；context 创建和 seek 前即绑定
generation，被取代的请求直接关闭连接，不返回伪造的 416/503，也不会把 context 交给并发 handler。
loopback 媒体 socket 允许 MPV cache
正常反压，不再以 10 秒发送超时截断长响应。远端 Range、validator 或读取硬错误会跨
libbluray C 回调边界恢复为明确错误，并以 RST 终止已声明完整长度的 localhost 响应，不再让 MPV
把截断流误判为自然 EOF；失败缓存条目只在当前播放代际内保持一致，新代际会重新读取。

HTTP `Content-Range` 与实际 Title 字节保持恒等映射；时间反演重定向因无法保证 EOF 与字节长度
一致而禁用，控制协议请求启用时失败关闭。WinHTTP request 对象持有其父 connection，异步关闭
request 一次并等待 `HANDLE_CLOSING` 后释放，不再使用自引用、回收线程或 detach。终止失败按
playback generation 隔离，旧请求不能污染新代际。最终 metrics 保留原聚合字段，并以
`metadataNetwork`、`playbackNetwork`、`metadataCache`、`playbackCache` 分开记录枚举与播放阶段；
同时记录 request context 创建、关闭、
存活与峰值，以及远端传输墙钟并集、并发传输墙钟、预读并发峰值、在途字节峰值、批间空窗和
预读命中字节；性能归档记录脱敏的 MPV 终止原因、位置、时长、错误类别、shutdown、helper 哈希、
按 MPLS/目标位置对齐的 Seek 样本、缓存暂停和 Bridge/MPV 总预算。当前这些字段仅用于 Phase 4
门禁，生产路径仍为单预读 worker 和最多 16 MiB 的单 Range。

本地 M3U8 只含 loopback URI。启动时移除 `{url}`、`{subfile}`、`{start}`、旧 ISO/播放列表、
HTTP header、cookie、referrer、proxy 和原生续播参数；不使用 `--bluray-device`、
`--load-unsafe-playlists` 或 MPV 原生 watch_later。ISO Lua 按 `playlist-pos` 写入章节；非零续播
先等初始 `playback-restart`，只执行一次 `absolute+exact` seek，并在 seek 已实际发出、目标后的新
restart、`seeking=false` 且当前位置距目标不超过 2 秒时恢复播放。`IsoCacheCoordinator` 还要观察到
缓存秒数增长或位置实际推进后才开始采样，并复用现有策略与本地学习核心，以真实
WebDAV ISO URL 和 Title 码率拆分 Bridge/MPV 总预算；ISO MPV 使用独立 IPC，动态调整不能突破
总预算和 512 MiB MPV 上限。MPV 对 localhost 测得的速度不进入学习，吞吐由 Bridge 的远端实际
传输字节/有效传输时间提供。服务关闭磁盘缓存、全量 cache 等待及跨 Title 预取，并强制
`idle=no` 与 `keep-open=no`，因此播放列表自然完成后 MPV 和等待
其进程句柄的 helper 会正常退出，不残留 ISO 单任务占用。MPV/helper 命令行、manifest、catalog
和 metrics 均不含远端 URL、凭据、远端 Token 或签名参数；M3U8 只包含一次性 localhost token。

ISO Title 顺序、选择结果和最后 MPLS 只写入 `iso_catalog.json`；各 MPLS 的时间点只写入
`iso_watch_later/<匿名 ISO 键>/`。匿名键由稳定档案 ID 和去掉 userinfo、query、fragment 的
规范地址摘要生成，持久化数据不保存远端地址。退出时由 ISO 专用 JSONL 同步 watch_later，
自然完成会删除该 MPLS 的旧续播点。该状态不进入视频/音频 SQLite；媒体中心 ISO 分栏只读
取这套独立状态，`media_library.json` 与共用视频底栏历史仅保存 ISO 资产和会话引用。
`iso_structure/` 只保存可重建结构，普通缓存清理会删除；活动 ISO 仍由双进程身份和唯一收尾任务
保护，清理不得与 helper 读写并发。缓存命中判定只在 helper 启动枚举阶段执行，不进入播放或 Seek
热路径。

ISO 同时只允许一个准备或播放任务。manifest v2 依次写 `bridge-starting`、`launching`、
`playing`，保存 transport 与 MPV/helper 各自的 PID、规范 exe 路径和 Windows 创建时间，
不保存端口或 token。helper 在绑定前依赖控制 pipe，绑定后持有 MPV 句柄，因此 StreamPath
退出后 MPV 继续播放。应用重启同时核验两者，任一身份缺失或探活未知都保留目录并阻止普通
缓存清理；两者明确退出后才同步进度和删除小型会话目录。
数据库维护和学习数据清理不依赖 ISO 模块。

WebDAV 远程 ISO 支持 Windows x64 未加密 Blu-ray ISO 的原有 Title/MPLS 和可选 WinFsp HDMV 菜单；不实现 DVD ISO、
AACS、BD+、BD-J 或完整媒体磁盘缓存。本地 ISO/BDMV 的 `bd://menu`
能力已在阶段一接入，但真实样盘验收仍待执行。界面覆盖四语言。V2 自动化测试与
Windows 构建已通过；Phase 5 顺序双 Cache、16 MiB 元数据热块交接、分阶段指标，以及 Phase 6
Structure Cache 的严格编解码/失效/原子替换和旧归档兼容已完成自动化验证。2026-08-30 同源真实
轮次的 6 个完成 Seek 样本均小于 10 秒，最慢
8.968 秒。真实未加密 WebDAV Blu-ray ISO 的固定五轮前后基线、多 Clip、自动切 Title、音轨、
PGS、跨进程生命周期、Structure Cache Warm 收益、固定 Seek 非退化和读取量完整验收仍待完成。


## 6. 缓存控制系统

缓存控制是增强层，任何配置损坏、探测超时、内存读取失败、智能建议器异常或 IPC 失败
都只能跳过或降级，不能阻塞起播。

本节的策略与学习核心适用于普通视频、STRM 和 ISO。普通视频与 TS/M2TS 由
`CachePolicyService` 和 `PlaybackMonitor` 执行；ISO 由互斥的 `IsoCacheCoordinator`
协调 Bridge 与 MPV，但复用同一份匿名学习数据。同一播放会话只能由一个执行控制器写入
缓存参数。音频禁止进入媒体探测、缓存策略、动态监控和缓存 IPC 更新；音频启动还会移除
用户播放器模板中的 MPV 缓存参数族，确保完全回到 MPV 默认缓存。该边界由源码依赖检查、
参数过滤单元测试和启动集成测试共同覆盖。

### 6.1 确定性策略

核心输入包括媒体长度、已知时长/码率、分辨率、可用内存、活动会话数、用户模式和
历史元数据。计算顺序：

1. 内存预算 = 可用内存乘安全比例，并受配置上下限约束；
2. 多会话按活动数和压力折减单会话预算；
3. 优先使用可信元数据码率，其次用 `文件大小 × 8 ÷ 时长`，最后按分辨率估算；
4. 目标字节约为 `码率 × cacheSecs × 125000 × 1.3` 并受预算封顶；
5. 码率未知时不伪造可达秒数，直接使用预算作为字节上限；
6. 小文件可进入全量缓存候选，但全缓存真值只取 `bof-cached && eof-cached`；
7. TS/M2TS 保持 `demuxer-seekable-cache=no`：零点首次起播先使用 `cache=no`，首次
   `playback-restart` 后切入 15～60 秒、最多 128 MiB 的小窗口；非零续播从启动阶段启用
   该窗口，不注入 `--start=0`。

媒体探测使用 HEAD；服务器不支持或没有长度时回退 `Range: bytes=0-0`。总 deadline
默认 1.5 秒，最多 5 次手动重定向；Authorization 只在同源保留。ETag 和
Last-Modified 用于元数据失效判断。

### 6.2 播放中监控

监控默认每 5 秒读取状态文件并维护 O(1) 聚合量：

- 卡顿真值优先使用 `paused-for-cache`；旧版缺失时回退 `0 < buffering < 100`；
- 已暂停、播放结束或全缓存时跳过网络不足判定；`cache-idle=true` 只有在前向水位未知的旧版
  降级路径、已到 EOF，或前向缓存达到 `min(当前 cache-secs, 30 秒)` 时才视为安全；
- `cache-idle=true` 且前向水位连续不足时，在原策略预算和动态上限内同步扩大缓存秒数与字节上限，
  不把本地读取线程停滞直接误报成上游带宽不足；
- 已知码率按相对阈值判断；未知码率使用 512 KB/s 和 256 KB/s 绝对阈值；
- 连续卡顿可直接增档和告警，不依赖可能是缓存读取速度的瞬时值；
- 内存压力连续出现时降档，健康样本连续出现后逐步回落到基线；
- 普通 MPV 状态协议提供 `seeking`、当前文件内递增的 `playback-restart` 序号、
  `demuxer-cache-duration`、`fw-bytes` 和 `total-bytes`；TS/M2TS 只有在当前文件完成定位并再次
  开始播放后才进入稳定采样；
- 普通网络媒体在首次打开和 seek 后建立 10 秒媒体缓冲；TS/M2TS 零点快速路径仍关闭缓存，
  运行态启用后使用 5 秒恢复水位；
- 切集使用文件代际和状态序号，迟到的旧探测不能覆盖当前曲目；
- IPC 更新失败不影响播放，且不重启 MPV。

### 6.3 本地智能建议器

智能层只处理匿名聚合数据，不调用在线服务。ISO 使用真实 WebDAV ISO URL 计算来源哈希，
不得采集 localhost M2TS 地址或保存 URL、令牌和认证头。默认影子模式只记录建议，最终策略
与确定性基线一致；达到 `minSamples` 且用户开启“应用智能优化”后，建议也只能在硬内存边界、
档位、TS 规则和 ISO 总预算内调整引擎输入。码率桶最多 256 个，来源画像最多 128 个，按旧
记录淘汰。读写串行并用临时文件替换；采样回调不等待磁盘写入。建议器超时或永久不返回时
记录诊断并回退基础策略。

## 7. OpenList/AList 恢复

该功能默认关闭，并与普通 WebDAV 播放解耦。已核验版本使用能力矩阵；未知版本保持
`unknown`，再由实际端点响应收窄，不能把未知版本乐观当作完整兼容：

接口语义以 [OpenList 认证 API](https://openlistteam.github.io/docs/zh/guide/api/auth.html)
和 [AList 认证 API](https://alistgo.com/guide/api/auth.html) 为依据。

1. `GET /api/public/settings` 尝试读取版本，失败不阻塞；已核验的 AList/OpenList 版本
   映射到 `OpenListCapabilities`，设置页分别展示搜索、索引进度、增量更新和存储恢复；
2. 先对原媒体地址发起一字节 Range 探测，已恢复则不刷新；第二次 MPV 错误触发恢复时
   若地址仍可读取，则返回 `terminalNotLinkFailure` 并停止本次自动恢复，不进入第三次重启；
3. Token 为空时调用 `/api/auth/login`；仅 HTTP 或 JSON `code` 为 404/405 时回退
   `/api/auth/login/hash`；
4. hash 密码是
   `sha256(password + "-https://github.com/alist-org/alist")`；
5. 管理 API 的 `Authorization` 直接使用 Token，不添加 Bearer；共享
   `OpenListApiClient` 要求 HTTP 2xx 且 JSON `code=200`，并为连接、发送、接收及同源重定向
   共享一个总 deadline；能力探测发生 transport timeout 时立即失败关闭，不使用微小剩余
   预算继续发送下一跳请求；
6. `POST /api/admin/storage/load_all` 后轮询 `/api/admin/storage/list`；
7. 最后轮询真实媒体地址，确认 Range 可读后才报告恢复成功；准备结果使用 `ready`、
   `retryableFailure` 和终止型结果表达后续处置，不以一个布尔值混合不同语义；
8. 前两次仍无法恢复时，第三次只允许重启本机、监听端口与进程身份一致，并以标准
   `server --force-bin-dir` 运行的 `openlist.exe` / `alist.exe`。软件在连接成功、用户
   强制刷新和播放启动时更新进程身份；重启前再次核对 PID、可执行文件、命令行与控制台
   成员，通过 Ctrl+C 触发服务自身的优雅关闭，确认旧 PID 退出后才重新启动。捕获身份按
   规范化 origin、解析后的本机地址和端口分键保存；重启禁止跨目标回退，发信号前还要再次
   证明目标监听器的 OwningProcess 与记录 PID 相同，地址或监听器歧义时失败关闭。同一物理
   地址和端口的并发重启共享一个在途结果，只发送一次关闭信号并启动一次进程。

管理 API 最多跟随 5 次同源重定向，跨来源立即拒绝，防止 Token 外发。媒体 Range
探测可跟随网盘签名地址，但 WebDAV Basic 仅在原来源发送。相同后台与同一凭据的在途
刷新合并；成功冷却按后台、凭据和媒体地址隔离，并且只有目标媒体最终可读才记成功；
每个会话最多恢复 3 次并保持独立状态。每次初始启动还会冻结
`PlayerConfig`、`serverUrl`、恢复配置、`profileId` 和 WebDAV 凭据，后续取链、重启、
重拉起与进度写入只使用该快照，不受播放期间切换档案影响。安全关闭失败、控制台还
包含无关进程或退出超时时直接停止，禁止回退 `taskkill /F`。远程、反向代理、Docker、
Windows 服务及非标准启动方式不会被自动重启。2FA 返回时提示用户填写 Token。

异常必须收敛为 `OpenListRecoveryResult`，不能从播放器监听回调抛出。

## 8. 界面行为

设置页使用顶部分类栏，将配置拆分为“服务器”“播放”“媒体中心”“缓存”“诊断”“界面”
和“基础设置”七个分页。
分页由统一的页面描述列表注册，新增分类时只需补充页面元数据与内容构建器。每个分页拥有
独立表单、滚动控制器和显式滚动条；页面级滚轮兜底保证鼠标位于表单或空白区域时仍能
滚动，并通过统一事件解析避免重复滚动。保存仍一次提交全部配置；隐藏分页校验失败时会
自动切换到对应页。
当前选择只缓存在进程内，退出设置页后再次进入仍显示上次分页，软件重启后恢复服务器页。
基础设置页最底部提供独立的“配置维护”区域；“重置全部设置”必须经过确认，随后将统一
配置及基础缓存策略、智能缓存策略、缓存过期策略恢复为内置默认值。统一配置的主文件与
恢复备份会同时写入默认值，避免主文件损坏时恢复出重置前的连接信息。该操作不调用缓存
清理服务，不删除目录缓存、续播记录、学习数据或其他运行时文件，也不中断当前连接与
正在播放的会话。
基础设置页提供显示语言选择，支持简体中文、繁体中文、日文和英文。配置字段 `language`
使用稳定值 `zh-CN`、`zh-TW`、`ja`、`en`；缺失或未知值回退简体中文。保存全部配置后，
应用根节点立即更新 `Locale`，项目文案和 Flutter 内置控件语言同步切换。版本 3 配置升级时
先按既有规则生成迁移备份，再补入 `zh-CN`，不改变其他设置。版本号、数量、状态等运行时
内容通过本地化模板填充，避免动态拼接文本绕过翻译目录。
缓存页的“缓存过期时间”写入独立 `cache_expiration.json`；保存后各缓存通过策略提供函数
读取新值，不需要依赖或重建设置页。滚动位置不写入磁盘，并受可配置空闲时间和 LRU 上限
约束。
缓存页的清理入口拆分为两个独立按钮，均带确认/取消操作，并在检测到播放器仍在运行时
拒绝执行。常规缓存清理通过 Hive/SQLite API 清空已打开的存储，再删除 `cache/` 下
其余运行时产物，但明确保留 `cache_intelligence_learning.json`；学习数据清理只重置
该聚合存储，不删除其他缓存、播放进度或历史。两者都保留 `config/` 下的连接、播放器、
基础缓存策略和智能缓存配置，也不删除 `library/media_library.json` 中的个人媒体资产。
ISO Bridge 服务只额外保护常规缓存清理，避免删除仍被 MPV/helper 使用或身份未知的 `iso_temp`；
学习数据清理和数据库维护不依赖 ISO 模块。
开发构建与便携版均复用 `AppPaths` 的可执行文件定位规则，不依赖启动时的当前工作目录。

登录页的档案名称、地址、用户名和密码控制器在 `initState` 同步读取活动档案，标签统一固定为
`FloatingLabelBehavior.always`。因此从右上角退出返回登录页时，不会先渲染空控制器再
异步填值，也不会出现标签瞬间落入输入框文本的重叠。存在多个档案时显示选择器；切换只
更新候选表单，真实认证和配置保存成功后才改变活动档案。设置页认证激活其他档案后，同一
登录页实例会同步档案列表、选择项和连接字段；失败时保持原值。登录页选择已有候选档案时，
同步设置页的进程内编辑选择，但不提前改变持久化活动档案；“新建档案”使用与地址、账号
无关的新 UUID，并清空旧的进程内编辑选择。

浏览页显示列表与播放基础列表分离：隐藏扩展名、搜索、右上角临时排序和滚动位置只影响
当前显示；字幕候选、稳定播放顺序和会话索引使用后台全量列表。默认排序设置持久化，
临时排序和滚动位置不持久化。隐藏后缀开关和列表分别保存；设置页列表统一显示为
`.ass, .mkv`，输入时必须使用英文逗号分隔，关闭开关后列表内容仍可编辑和保存。

`MediaLibraryStore` 在 `stream_path_data/library/media_library.json` 中用一个版本化 JSON
保存收藏、最近目录和长期播放历史。新档案直接使用稳定 `profileId` 作为来源标识；旧单账号
迁移的档案 ID 仍由去除 userinfo、查询和片段后的规范化服务器根地址与用户名生成 SHA-256，
以继续关联既有资产。个人资产不保存密码、Token、签名参数或旧播放 URL。读改写在
单实例队列中串行执行，并通过临时文件原子替换。损坏文件在首次 mutation 前必须先保存并
逐字节核验唯一 `.corrupt-*.bak`；未来 schema 版本和瞬时读取失败禁止写入，不能用空状态
覆盖原始字节。读取或写入失败仍不能阻断浏览和播放。最近
容量设置保存在统一 `stream_path_config.json` 的 `mediaLibrary` 节点，并在模型解析和 Store 写入
两层收敛系统硬上限。默认收藏每个来源最多 2000 条，继续播放每个视频/音频分栏最多显示
500 条，最近播放每个分栏最多保存 500 条，最近目录每个来源最多保存 100 条；系统硬上限
依次为 2000、500、2000、500。降低收藏、最近播放或最近目录上限后立即淘汰最旧记录；继续
播放上限只限制派生列表的读取与显示，不复制进度数据。

媒体中心固定分为“收藏”“继续播放”“最近播放”“目录”四页，视频和音频使用独立分栏，
STRM 归入视频。从任何资产打开媒体时只向浏览页返回父目录、文件名和媒体类型；浏览页重新
加载完整父目录、确认真实条目存在后调用原播放入口，因此稳定播放列表、字幕、LRC、封面和
STRM 安全校验不被旁路。播放器成功启动和现有状态监控检测到切集或切歌后，浏览页才旁路
更新长期历史。同一视频或音频播放会话始终复用一条媒体中心记录，切集或切歌只更新该记录的
当前条目；播放器关闭后再次启动会获得新的播放会话，即使目录和文件相同也会创建新的记录。
个人资产和 SQLite 进度成功写入后发送轻量的进程内通知，媒体中心保持打开时
按当前来源只刷新对应历史或 URL；本地蓝光服务只转发当前蓝光会话和全库清理通知，ISO 后台
读取期间保留已有继续播放列表。首次有效播放状态、暂停或恢复、自动切集或切歌会立即保存正式进度，
连续播放最多每 10 秒保存一次。切集或切歌继续复用现有 JSONL 与 `watch_later` 合并，退出同步
仍是最终进度来源；不增加 MPV 回调、会话协议或数据库表。继续播放最多八路分批读取现有视频
`getResumeProgress()` 和音频 `getProgress()`，过滤 0 秒、无进度和现有规则判定的片尾。
远端缺失或暂时不可用时只提示，不自动删除收藏和历史。

设置页“媒体中心”分页提供当前来源的收藏、继续播放、最近播放和最近目录分项清理。清空继续
播放只给现有长期历史写入隐藏标记，保留最近播放、SQLite、`watch_later` 和正式/临时续播点；
同一播放会话后续切集或重新起播时会清除此标记。清空最近播放会删除当前来源的视频和音频长期
历史，因此对应的媒体中心继续播放入口同步消失，但底层进度仍保留。清空收藏或最近目录不影响
其他资产。所有清理操作都必须确认，并通过 `MediaLibraryStore` 原有串行原子写入执行。

媒体中心与浏览页新增控件只使用 `ColorScheme`、`GlassTokens`、`GlassSurface` 和
`showGlassDialog`，经典、Acrylic、Mica 三种外观共用同一业务结构；不得增加独立材质判断，
也不得在虚拟列表条目上叠加模糊层。

音频下边栏与视频下边栏使用不同会话集合和服务，但在同一底部区域呈现。每种媒体各自
最多保留两个会话；音频栏支持打开中、正在播放、暂停、继续播放、切曲同步、关闭和
右键删除。音频历史或数据库初始化失败时仅禁用音频入口并提示，视频浏览与播放继续工作。

界面主题集中在 `presentation/theme/app_theme.dart`，使用中性石墨底色、冷蓝主色、少量
青绿与琥珀语义色，并统一亮暗色阶、边框、圆角和控件尺寸。视觉优化只作用于表现层：目录
仍使用无逐项动画、无额外状态的虚拟列表，表头与文件区共用一张连续的高一阶内容面；
悬浮反馈由同层 `Material` 绘制，播放底栏的悬停只重建对应底栏。主题与布局不得反向
依赖或改写连接、缓存、播放和配置逻辑。

可选磨砂样式由 `AppearanceController` 与 `WindowAppearanceDriver` 隔离原生调用，只使用一层
Windows 窗口级 Mica 或 Acrylic，不在列表项或卡片上叠加 `BackdropFilter`。自动材质在
Windows 11 优先使用 Mica，在 Windows 10 使用 Acrylic；显式 Mica 不可用时回退 Acrylic
并记录材质降级，显式 Acrylic 不会被自动替换为 Mica。`GlassTokens` 定义
`base`、`chrome`、`content`、`raised` 和 `floating` 五级表现层材质；`GlassSurface` 只负责
绘制颜色、边框、内高光和有限阴影，不持有业务状态。主题入口把窗口实际生效材质传给
`GlassTokens`：Acrylic 的模态层保留适度透视和背景模糊，Mica 的模态层使用更厚实的表面、
更弱的柔化和阴影。确认对话框由 `showGlassDialog` 统一提供一层逐帧变化的背景模糊，遮罩
颜色、模糊半径与弹窗本体分别使用连续曲线，避免完整模糊在首帧突入，也避免为多个子表面
创建离屏渲染。设置分组与登录主卡片在磨砂模式使用无投影的 `content` 表面和细描边，分段
选择控件统一使用冷蓝主色，青绿与琥珀只保留给语义状态。业务页面不判断具体系统材质。
滑块只更新设置页本地状态，保存时才调用
窗口接口；原生效果成功后主题才切换为半透明表面，初始化或应用失败则保留当前有效样式。
`WindowAppearanceDriver` 通过同一原生通道读取 Windows 主版本、内部版本、桌面合成、系统
透明效果、高对比度、远程会话、Mica 支持与 DWM 实际背景类型。`AppearanceController` 分别
保存用户请求样式、材质偏好和窗口实际材质；系统条件不允许窗口材质时只把本次显示降级
为不透明界面，不改写用户已保存的磨砂选择。设置页的兼容性卡片只展示上述只读状态并允许
重新检测，不接入业务状态。
窗口明暗模式变化时只刷新当前窗口材质的明暗状态与实际结果，不触发业务状态重建。

窗口使用无系统标题栏样式（保留可缩放边框、系统菜单与最小化/最大化能力，并申请
Windows 11 圆角）。标题栏由表现层自绘（`presentation/widgets/window_title_bar.dart`），
经 `streampath/appearance` 通道提供最小化/最大化/关闭操作，最大化状态由 `WM_SIZE` 推送同步。
磨砂模式下，标题栏使用页面 AppBar 与 Scaffold 的等价半透明合成色，使两者最终观感一致。
Windows runner 通过 `WM_NCCALCSIZE` 将 Flutter 客户区扩展到窗口最上方，由同一个磨砂标题栏
直接绘制圆角区域；原生框架保持 `COLOR_NONE`，不再额外绘制异色带。`WM_NCHITTEST` 为边缘
保留八方向缩放，并让标题栏空白区返回 `HTCAPTION`，因此拖动与双击最大化使用 Windows
原生语义，右侧窗口控制按钮仍由 Flutter 响应。
窗口装饰始终关闭 DWM 原生边框；`WM_NCACTIVATE` 先重申无边框状态，再以 `lParam = -1`
交还 Windows 更新窗口材质激活状态，仅跳过过渡帧的非客户区重绘。标题栏点击不再闪边，
阴影、圆角、缩放边缘和磨砂聚焦效果继续保留。
三个窗口控制图标使用同一视觉框，并直接采用 Windows `Segoe Fluent Icons` 的 Caption
字形；旧系统回退 `Segoe MDL2 Assets`，由系统字体栅格化保持原生比例与 DPI 细线观感。
标题栏位于 Navigator 之上，其 Tooltip 依赖一个额外的空条目 Overlay 提供挂载点。
非 Windows 构建继续使用系统窗口装饰。

Windows 页面路由统一使用短时淡入淡出，并为旧路由提供同样的淡出委托，不使用 Material
默认的页面缩放，也不插入不透明遮罩；登录、目录和设置页面会平滑交接，各入口原有的
push、replace 和清栈语义保持不变。

## 9. 测试与质量门槛

常规质量门槛：

```powershell
flutter analyze --no-pub
flutter test --no-pub
```

实体 MPV 门槛：

```powershell
$env:STREAMPATH_MPV_TEST_ROOT = 'C:\Users\YX\Documents\StreamPathProject\cross_version_testing\打包版本'
$env:STREAMPATH_PATH_MPV = 'D:\MPV_Player\mpv_config-2026.04.14\mpv.exe'
flutter test --no-pub test/mpv_version_compatibility_test.dart -r expanded
```

其中四个样本从测试根目录发现，第五个版本默认从系统 PATH 发现，也可设置
`STREAMPATH_PATH_MPV` 为完整路径。音频兼容门槛会实际组合 HTTP 音频、不支持 Range
的远程 LRC 与远程外挂封面，并要求五个 MPV 都自然完成两首播放列表。

重点覆盖：WebDAV 空密码、同源/跨源重定向、PROPFIND 方法保持、STRM 字节上限、
ISO 独立类型、Bridge ready/IPC、Range/Content-Range、Structure Cache 身份/损坏/未来版本/原子替换、块边界/同块合并/LRU、动态块容量、
码率窗口、合并预读、顺序补窗、seek 换窗、旧预读与前台 Range 的播放代际取消、连续
A→B→C 拖动、迟到旧连接拒绝、上下文上限、loopback 背压、ISO 总预算拆分、真实远端吞吐和 localhost 来源隔离、
一次性续播握手、ISO 缓存参数隔离、取消、
MPV 参数脱敏、单任务互斥、Title/MPLS/章节、loopback 虚拟列表、独立续播、双进程 v2 与
 旧 v1 恢复、媒体中心 ISO 三分栏、多 Title 进度、共用视频底栏、缓存清理保护和四语言界面，
OpenList 加盐 hash 和 Token 隔离、MPV 参数/Lua/watch_later/JSONL/IPC、多会话代际、
缓存策略和监控、缓存过期配置/边界/时钟回拨、音频格式/M3U8/LRC/封面/独立进度及缓存
隔离、登录首帧布局、界面配置迁移与窗口材质失败回退、玻璃层级主题与对话框模糊、旧数据
迁移、排序与滚轮，以及服务器档案稳定 ID、同 URL 跨档案隔离、凭据写入失败回滚、未来
配置版本拒绝和防覆盖、两类旧配置迁移备份/日志、个人资产来源隔离、媒体库损坏备份与
未来版本拒写、MPV 进程租约身份、OpenList 跨目标重启隔离、恢复启动快照和终止型结果、
访问型搜索、诊断深层脱敏、重复导出、SQLite 复合主键升级和非破坏性维护。

音频实体测试使用当前项目实测 MPV，实际解析 M3U8，加载 WAV 音频、LRC 字幕轨道和
外挂图片轨道，并验证自然完成 JSONL。多版本测试还覆盖远程 LRC 本地化后的故障组合，
仍由环境变量显式启用。


## 10. 构建和便携发布

`tools/package.ps1` 是面向发布人员的交互入口，启动后要求输入目标目录，直接回车使用现有
便携版目录；确认后调用 `build.ps1`。`build.ps1` 默认执行 analyze、test、
`flutter build windows --release`，随后校验：

- Release/Profile 必须含 `data/app.so`；
- Release/Profile 不得含 Debug `kernel_blob.bin`；
- 构建目录和目标目录不得是重解析点；
- 非空目标必须同时含已有 `streampath.exe` 和 `data/app.so` 标记；
- 目标不得位于项目目录内部，也不得是项目目录、用户目录或其祖先目录；
- 打包时 StreamPath 进程不得运行；
- 删除目标旧产物前逐项验证路径位于目标目录内。

目标目录仅替换 `data/`、EXE、DLL、Native Assets 和符号文件，保留
`使用说明.txt`、`stream_path_data/` 以及其他用户文件。正式命令见 README。

四个脚本统一以 `tools` 的父目录作为 `ProjectRoot`，启动时必须验证其中存在
`pubspec.yaml`，构建产物、默认数据目录和禁止范围都以该根目录计算。
`cleanup.ps1` 默认处理项目根的 `stream_path_data`，只枚举数据目录直属的已知运行时名称，
保留缓存学习数据，再对解析后的每个目标执行范围与
重解析点检查；配置目录不清理。脚本不得对项目根、用户目录、APPDATA 或驱动器根执行
递归删除，也不得删除旧版 `player_config.json` 或 `connection_config.json`。

## 11. 维护不变量

任何后续改动都必须保持：

1. WebDAV、缓存、OpenList 恢复失败不能阻塞基础播放。
2. 地址和用户名完整时允许用空 WebDAV 密码尝试连接。
3. 凭据不得随跨来源重定向外发，第三方 STRM 不得进入播放链。
4. 同时会话最多两个，资源、PID、进度、缓存状态和恢复状态必须隔离。
5. TS 无历史进度不得出现 `--start=0`，有进度只恢复一次。
6. MPV 属性缺失按未知降级，不得把 `buffering=100` 当作卡顿。
7. 播放完成和明确 0 秒必须清除旧正数进度；时长未知不等于播放完成。
8. 显示排序和隐藏规则不得改变稳定播放列表和字幕候选基础；关闭隐藏开关不得清空后缀列表。
9. 旧数据迁移不覆盖目标、不删除无法解析的源文件。
10. Release 便携包必须是 AOT，并保留用户数据目录。
11. 长期项目基线维护 `README.md` 和 `PROJECT.md`；跨聊天继续实施时可维护临时
    `HANDOFF.md`，协议、算法或维护边界变化仍必须同步回前两份基线文档。
12. 音频不得调用缓存策略、媒体探测、动态监控、缓存 IPC 或 OpenList 恢复；模板中
    的 MPV 缓存覆盖参数必须过滤，使用 MPV 默认缓存。
13. 音频与视频的服务、运行时、历史、SQLite、watch_later、会话资源和下边栏状态必须
    隔离；任何一侧初始化或运行故障不得阻止另一侧播放。
14. 自动过期只作用于可重建缓存；缓存学习数据永不自动过期，只能由用户主动清理。
15. 续播过期必须同时覆盖 SQLite、历史和 `watch_later`，不能留下可复活旧进度的旁路。
16. 当前目录和媒体中心搜索不得改变完整播放列表或发起递归服务器扫描；清理目录缓存只清除
    访问型搜索索引，不得删除收藏、最近目录和长期播放历史。
17. 个人媒体资产只保存匿名来源、相对路径、名称、类型、时间、播放会话标识和继续播放隐藏
     状态，不得保存密码、
     Token、URL userinfo、查询参数、签名参数或旧媒体 URL。
18. `profileId` 是目录缓存、访问型索引、个人资产和视频/音频进度的唯一档案隔离主键；
    编辑地址、用户名或显示名称不得改变它，重复 ID 必须拒绝加载。
19. 安全凭据模式的主配置不得保存密码或 Token；多凭据保存任一步失败时必须回滚已写值，
    配置迁移必须先备份再写入并记录结果，高版本配置不得被低版本覆盖。
20. 诊断导出必须在统一序列化边界递归脱敏；URL 只能保留来源与路径摘要，不得包含密码、
    Token、userinfo、查询或签名参数。
21. 数据库维护必须先通过完整性检查并生成一致性备份；播放器运行期间不得执行，任何入口
    都不得以“修复”为名删除播放进度。
22. ISO 必须保持独立媒体类型；Bridge 只实现未加密 Blu-ray Title/MPLS 远程流式播放
    和多集业务模型。媒体中心必须使用 ISO 独立分栏，浏览页底栏只复用普通视频的会话配额与
    展示机制；不得写入视频/音频进度、字幕或 OpenList 恢复。ISO 顺序和续播只能使用自己的
    匿名索引与 watch_later；缓存只能通过 `IsoCacheCoordinator` 复用共享策略与学习核心，
    不得接入普通媒体执行控制器，也不得把 localhost M2TS 作为学习来源。
23. `iso_temp` 只有在 MPV 与 helper 身份都明确失效后才能自动删除；任一身份未知必须保留。
    不支持 Range 或远端读取失败必须明确结束，不得重试、自动重启或转入完整下载。
