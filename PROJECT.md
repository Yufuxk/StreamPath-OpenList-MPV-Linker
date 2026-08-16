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
| 外部播放器 | MPV 为主要目标，其他播放器走参数模板 |
| Windows 集成 | `win32`、`super_clipboard`、`flutter_acrylic`、MethodChannel |
| 测试 | `flutter_test`、本地 HTTP 服务器、条件式实体 MPV 测试 |

项目采用便携数据布局，不依赖当前工作目录。开发构建会从可执行文件路径向上定位
项目根；便携构建直接使用可执行文件所在目录。不可写时才回退系统应用支持目录。

## 2. 启动与模块关系

启动顺序：

1. `WidgetsFlutterBinding` 初始化；
2. 迁移旧版平铺数据，迁移期间不启动数据库或日志写入；
3. 加载独立缓存过期配置，再并行初始化目录缓存、SQLite、统一配置和播放历史；
4. 初始化基础缓存策略、智能缓存配置、媒体元数据与聚合学习存储；
5. 组装 `AppState` 与独立的 `AppearanceController`，根据地址和用户名是否完整决定自动连接或显示登录页；
6. 持久化为磨砂样式时在首帧前恢复窗口外观，避免窗口合成状态切换产生黑帧；默认样式不初始化窗口材质插件，恢复失败继续使用不透明主题。

主要目录：

```text
lib/
├─ core/                 常量、异常、路径、URL、Windows 剪贴板适配
├─ data/
│  ├─ local/             配置、Hive、SQLite、播放历史
│  ├─ models/            WebDAV、播放器、OpenList、界面外观和统一配置模型
│  └─ remote/            WebDAV HTTP 客户端与 XML 解析
├─ domain/services/      WebDAV、视频/音频 MPV、字幕/LRC、进度和 OpenList 恢复
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

`stream_path_config.json` 保存连接、播放器、字幕、排序、隐藏扩展名开关与列表、OpenList
和界面外观配置。`appearance` 缺失或样式值未知时按 `classic` 读取，因此旧配置和新安装
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
- `config/cache_policy.json`：确定性缓存策略；
- `config/cache_intelligence.json`：本地智能建议器模式和边界；
- `config/cache_expiration.json`：可重建缓存的过期时间；
- `cache/directory_cache/`：目录缓存；
- `cache/streampath.db`：按无凭据 URL 存储的播放进度；
- `cache/playback_history.json`：最多两个会话的继续播放信息；
- `cache/audio_streampath.db`：独立的音频播放进度；
- `cache/audio_playback_history.json`：最多两个音频继续播放会话；
- `cache/media_metadata.json`：媒体长度、时长、码率、ETag 等；
- `cache/cache_intelligence_learning.json`：匿名聚合样本；
- `cache/mpv-watch-later/`：MPV 原生续播文件；
- `cache/mpv-audio-watch-later/`：音频专用 MPV 原生续播文件；
- `cache/mpv-current-*`、`mpv-command-*`、`mpv-progress-*`：会话通道。
- `cache/mpv-audio-current-*`、`mpv-audio-command-*`、
  `mpv-audio-progress-*`：独立音频会话通道。

迁移已覆盖基础配置、智能缓存配置、学习数据、SQLite、历史、媒体元数据、MPV 状态、
命令、JSONL、播放列表、Lua 和 watch_later。目标存在时用户数据优先；单项失败保留
源文件并在下次启动重试。旧配置 JSON 结构错误时不会阻塞启动，也不会删除原文件。
统一配置保存使用临时文件原子替换，并保留最近一次有效备份；启动加载失败时依次回退
备份和默认值，损坏的主文件与备份均保留供人工恢复。

### 3.1 缓存生命周期

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
目录缓存键包含用户名命名空间的 SHA-256，因此同一 WebDAV 地址下的不同账号不会读取
彼此的目录快照；用户名本身不以明文写入缓存键。

### 4.2 目录与 STRM

目录请求使用 `PROPFIND Depth: 1`，解析标准 DAV 命名空间和非标准前缀，名称缺失时
从 href 解码。宽窗口按名称、大小和修改时间显示，普通文件显示格式化大小，文件夹的
大小单元格显示短杠；窄窗口把普通文件的大小与时间收进条目副标题，文件夹只显示时间。
宽窗口的文件、文件夹和返回上级条目使用统一紧凑行高并垂直居中，窄窗口保留两行布局。
显示列表可按名称、时间或体积排序；播放列表始终使用后台自然名称正序，避免临时排序
改变切集顺序和历史索引。

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
继续发送给跨来源重定向目标。当前实现只对与统一配置 `serverUrl` 同源的媒体和字幕 URL
写入百分号编码的 userinfo；空密码保留 `username:` 中的冒号，以兼容 MPV 0.34。
四个实测版本均能完成源站 Basic，并在跨来源重定向后移除凭据。第三方 URL 不注入。

### 5.2 单集、多集和字幕

单集直接展开 `{url}`，并使用 `--force-media-title`。多集生成 M3U：

- `#EXTINF` 和 `EXTVLCOPT:force-media-title` 保存稳定标题；
- `--playlist-start` 决定点击的起始集；
- 标题 Lua 是不支持 EXTVLCOPT 的旧版兜底；
- 字幕 Lua 监听 `file-loaded`，按 `playlist-pos` 调用 `sub-add`；
- 自动选择关闭时加入轨道但恢复原 sid；自动注入关闭时不增加字幕参数或脚本。

TS/M2TS 使用 `--rebase-start-time=yes`，无历史进度时不得注入 `--start=0`，避免对非零
起始时间戳执行无意义 seek。TS 直链不启用通用 seekable cache 参数。

### 5.3 会话和进度协议

每次 MPV 启动获得唯一 Windows named pipe。最多两个界面会话，每个会话使用独立的：

- `mpv-current-<session>.txt`；
- `mpv-command-<session>.txt`；
- `mpv-progress-<session>.jsonl`；
- Lua、M3U 和 IPC pipe；
- 缓存策略状态、代际令牌和进程身份。

状态文件逻辑上有十四个字段：

```text
playlist-pos
path
paused
time-pos
duration
cache-buffering-state
cache-used-bytes
network-speed-bps
cache-idle
speed_src|speed|idle_src|idle_raw
paused-for-cache
bof-cached
eof-cached
resolution
```

MPV 0.41 优先读取 `demuxer-cache-idle`，旧版回退 `cache-idle`；速度优先
`cache-speed`，再回退 `demuxer-cache-state.raw-input-rate` 和旧版 reader 结构。属性缺失
写 `-1`，监控按未知降级，不能抛错或停止播放。

JSONL 记录每个 `end-file` 的播放列表位置、路径、位置、时长、原因和错误。自然 EOF
删除 SQLite 旧进度，0 秒是明确状态，普通退出允许 watch_later 的精确值覆盖每秒采样。
认证播放 URL 的 watch_later 按实际 URL 的 MD5 读取，最终 SQLite 键和轨道比较均剥离
userinfo。MPV 只有 `reason=error` 才进入 OpenList 恢复判断。

应用重启后恢复的 PID 在强制结束前必须再次确认仍是 MPV，避免 PID 复用伤及其他进程。
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


## 6. 缓存控制系统

缓存控制是增强层，任何配置损坏、探测超时、内存读取失败、智能建议器异常或 IPC 失败
都只能跳过或降级，不能阻塞起播。

本节只适用于视频与 STRM。音频禁止进入 `CachePolicyService`、媒体探测、动态监控和
缓存 IPC 更新；音频启动还会移除用户播放器模板中的 MPV 缓存参数族，确保完全回到
MPV 默认缓存。该边界由源码依赖检查、参数过滤单元测试和启动集成测试共同覆盖。

### 6.1 确定性策略

核心输入包括媒体长度、已知时长/码率、分辨率、可用内存、活动会话数、用户模式和
历史元数据。计算顺序：

1. 内存预算 = 可用内存乘安全比例，并受配置上下限约束；
2. 多会话按活动数和压力折减单会话预算；
3. 优先使用可信元数据码率，其次用 `文件大小 × 8 ÷ 时长`，最后按分辨率估算；
4. 目标字节约为 `码率 × cacheSecs × 125000 × 1.3` 并受预算封顶；
5. 码率未知时不伪造可达秒数，直接使用预算作为字节上限；
6. 小文件可进入全量缓存候选，但全缓存真值只取 `bof-cached && eof-cached`；
7. TS/M2TS 走直接播放与时间轴规则，不套用通用 seekable cache 注入。

媒体探测使用 HEAD；服务器不支持或没有长度时回退 `Range: bytes=0-0`。总 deadline
默认 1.5 秒，最多 5 次手动重定向；Authorization 只在同源保留。ETag 和
Last-Modified 用于元数据失效判断。

### 6.2 播放中监控

监控每秒读取状态文件并维护 O(1) 聚合量：

- 卡顿真值优先使用 `paused-for-cache`；旧版缺失时回退 `0 < buffering < 100`；
- 已暂停、播放结束、全缓存或 `cache-idle=true` 时跳过网络不足判定；
- 已知码率按相对阈值判断；未知码率使用 512 KB/s 和 256 KB/s 绝对阈值；
- 连续卡顿可直接增档和告警，不依赖可能是缓存读取速度的瞬时值；
- 内存压力连续出现时降档，健康样本连续出现后逐步回落到基线；
- 切集使用代际令牌，迟到的旧探测不能覆盖当前曲目；
- IPC 更新失败不影响播放，且不重启 MPV。

### 6.3 本地智能建议器

智能层只处理匿名聚合数据，不调用在线服务。默认影子模式只记录建议，最终策略与确定性
基线一致；应用模式也只能在硬内存边界、档位和 TS 规则内调整引擎输入。码率桶最多
256 个，来源画像最多 128 个，按旧记录淘汰。读写串行并用临时文件替换；采样回调不
等待磁盘写入。建议器超时或永久不返回时按截止时间回退。

## 7. OpenList/AList 恢复

该功能默认关闭，并与普通 WebDAV 播放解耦。兼容策略以 API 能力探测为准，不按版本号
硬编码：

接口语义以 [OpenList 认证 API](https://openlistteam.github.io/docs/zh/guide/api/auth.html)
和 [AList 认证 API](https://alistgo.com/guide/api/auth.html) 为依据。

1. `GET /api/public/settings` 尝试读取版本，失败不阻塞；
2. 先对原媒体地址发起一字节 Range 探测，已恢复则不刷新；第二次 MPV 错误触发恢复时
   若地址仍可读取，则判定为非链接失效并停止，不强制刷新全部存储；
3. Token 为空时调用 `/api/auth/login`；仅 HTTP 或 JSON `code` 为 404/405 时回退
   `/api/auth/login/hash`；
4. hash 密码是
   `sha256(password + "-https://github.com/alist-org/alist")`；
5. 管理 API 的 `Authorization` 直接使用 Token，不添加 Bearer；
6. `POST /api/admin/storage/load_all` 后轮询 `/api/admin/storage/list`；
7. 最后轮询真实媒体地址，确认 Range 可读后才报告恢复成功。

管理 API 最多跟随 5 次同源重定向，跨来源立即拒绝，防止 Token 外发。媒体 Range
探测可跟随网盘签名地址，但 WebDAV Basic 仅在原来源发送。并发刷新按后台根地址合并，
成功后进入 5 分钟冷却；每个会话有独立恢复次数和状态。2FA 返回时提示用户填写 Token。

异常必须收敛为 `OpenListRecoveryResult`，不能从播放器监听回调抛出。

## 8. 界面行为

设置页使用顶部分类栏，将配置拆分为“服务器”“播放”“缓存”“界面”“基础设置”五个分页。
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
缓存页的“缓存过期时间”写入独立 `cache_expiration.json`；保存后各缓存通过策略提供函数
读取新值，不需要依赖或重建设置页。滚动位置不写入磁盘，并受可配置空闲时间和 LRU 上限
约束。
缓存页的清理入口拆分为两个独立按钮，均带确认/取消操作，并在检测到播放器仍在运行时
拒绝执行。常规缓存清理通过 Hive/SQLite API 清空已打开的存储，再删除 `cache/` 下
其余运行时产物，但明确保留 `cache_intelligence_learning.json`；学习数据清理只重置
该聚合存储，不删除其他缓存、播放进度或历史。两者都保留 `config/` 下的连接、播放器、
基础缓存策略和智能缓存配置。开发构建与便携版均复用 `AppPaths` 的可执行文件定位规则，
不依赖启动时的当前工作目录。

登录页的三个控制器在 `initState` 同步读取保存配置，标签统一固定为
`FloatingLabelBehavior.always`。因此从右上角退出返回登录页时，不会先渲染空控制器再
异步填值，也不会出现标签瞬间落入输入框文本的重叠。

浏览页显示列表与播放基础列表分离：隐藏扩展名、搜索、右上角临时排序和滚动位置只影响
当前显示；字幕候选、稳定播放顺序和会话索引使用后台全量列表。默认排序设置持久化，
临时排序和滚动位置不持久化。隐藏后缀开关和列表分别保存；设置页列表统一显示为
`.ass, .mkv`，输入时必须使用英文逗号分隔，关闭开关后列表内容仍可编辑和保存。

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
绘制颜色、边框、内高光和有限阴影，不持有业务状态。确认对话框由 `showGlassDialog` 统一
提供单层背景模糊，避免为多个子表面创建离屏渲染。滑块只更新设置页本地状态，保存时才调用
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
$env:STREAMPATH_MPV_TEST_ROOT = 'MPV根文件夹路径'
flutter test test/mpv_version_compatibility_test.dart --no-pub -r expanded
```

其中四个样本从测试根目录发现，第五个版本默认从系统 PATH 发现，也可设置
`STREAMPATH_PATH_MPV` 为完整路径。音频兼容门槛会实际组合 HTTP 音频、不支持 Range
的远程 LRC 与远程外挂封面，并要求五个 MPV 都自然完成两首播放列表。

重点覆盖：WebDAV 空密码、同源/跨源重定向、PROPFIND 方法保持、STRM 字节上限、
OpenList 加盐 hash 和 Token 隔离、MPV 参数/Lua/watch_later/JSONL/IPC、多会话代际、
缓存策略和监控、缓存过期配置/边界/时钟回拨、音频格式/M3U8/LRC/封面/独立进度及缓存
隔离、登录首帧布局、界面配置迁移与窗口材质失败回退、玻璃层级主题与对话框模糊、旧数据
迁移、排序与滚轮。

音频实体测试使用当前项目实测 MPV，实际解析 M3U8，加载 WAV 音频、LRC 字幕轨道和
外挂图片轨道，并验证自然完成 JSONL。多版本测试还覆盖远程 LRC 本地化后的故障组合，
仍由环境变量显式启用。


## 10. 构建和便携发布

`package.ps1` 是面向发布人员的交互入口，启动后要求输入目标目录，直接回车使用现有
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

`cleanup.ps1` 只枚举数据目录直属的已知运行时名称，再对解析后的每个目标执行范围与
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
11. 项目文档只维护 `README.md` 和 `PROJECT.md`；协议、算法或维护边界变化时同步更新。
12. 音频不得调用缓存策略、媒体探测、动态监控、缓存 IPC 或 OpenList 恢复；模板中
    的 MPV 缓存覆盖参数必须过滤，使用 MPV 默认缓存。
13. 音频与视频的服务、运行时、历史、SQLite、watch_later、会话资源和下边栏状态必须
    隔离；任何一侧初始化或运行故障不得阻止另一侧播放。
14. 自动过期只作用于可重建缓存；缓存学习数据永不自动过期，只能由用户主动清理。
15. 续播过期必须同时覆盖 SQLite、历史和 `watch_later`，不能留下可复活旧进度的旁路。
