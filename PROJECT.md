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
| Windows 集成 | `win32`、`super_clipboard`、MethodChannel |
| 测试 | `flutter_test`、本地 HTTP 服务器、条件式实体 MPV 测试 |

项目采用便携数据布局，不依赖当前工作目录。开发构建会从可执行文件路径向上定位
项目根；便携构建直接使用可执行文件所在目录。不可写时才回退系统应用支持目录。

## 2. 启动与模块关系

启动顺序：

1. `WidgetsFlutterBinding` 初始化；
2. 迁移旧版平铺数据，迁移期间不启动数据库或日志写入；
3. 并行初始化目录缓存、SQLite、统一配置和播放历史；
4. 初始化基础缓存策略、智能缓存配置与聚合学习存储；
5. 组装 `AppState`，根据地址和用户名是否完整决定自动连接或显示登录页。

主要目录：

```text
lib/
├─ core/                 常量、异常、路径、URL、Windows 剪贴板适配
├─ data/
│  ├─ local/             配置、Hive、SQLite、播放历史
│  ├─ models/            WebDAV、播放器、OpenList 和统一配置模型
│  └─ remote/            WebDAV HTTP 客户端与 XML 解析
├─ domain/services/      WebDAV、字幕、MPV、进度和 OpenList 恢复
├─ features/cache_control/
│  ├─ engine/            缓存策略纯计算
│  ├─ intelligence/      本地解释型建议器
│  ├─ monitor/           播放中内存、速度和卡顿监控
│  ├─ providers/         HTTP 媒体探测与系统内存探测
│  └─ store/             策略、元数据与学习数据持久化
└─ presentation/         登录、浏览、设置、会话界面与 AppState
```

## 3. 统一配置与数据迁移

`stream_path_config.json` 保存连接、播放器、字幕、排序、隐藏扩展名和 OpenList 配置。
自动连接完整性只要求 `serverUrl` 和 `username` 非空，密码允许为空。OpenList 管理员
登录仍要求 Token，或同时提供管理员账号和密码；它与 WebDAV 空密码语义无关。

运行数据分为：

- `config/stream_path_config.json`：统一用户配置；
- `config/cache_policy.json`：确定性缓存策略；
- `config/cache_intelligence.json`：本地智能建议器模式和边界；
- `cache/directory_cache/`：目录缓存；
- `cache/streampath.db`：按无凭据 URL 存储的播放进度；
- `cache/playback_history.json`：最多两个会话的继续播放信息；
- `cache/media_metadata.json`：媒体长度、时长、码率、ETag 等；
- `cache/cache_intelligence_learning.json`：匿名聚合样本；
- `cache/mpv-watch-later/`：MPV 原生续播文件；
- `cache/mpv-current-*`、`mpv-command-*`、`mpv-progress-*`：会话通道。

迁移已覆盖基础配置、智能缓存配置、学习数据、SQLite、历史、媒体元数据、MPV 状态、
命令、JSONL、播放列表、Lua 和 watch_later。目标存在时用户数据优先；单项失败保留
源文件并在下次启动重试。旧配置 JSON 结构错误时不会阻塞启动，也不会删除原文件。
统一配置保存使用临时文件原子替换，并保留最近一次有效备份；启动加载失败时依次回退
备份和默认值，损坏的主文件与备份均保留供人工恢复。

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
从 href 解码。显示列表可按名称、时间或体积排序；播放列表始终使用后台自然名称正序，
避免临时排序改变切集顺序和历史索引。

STRM 规则：

- 最多读取 8192 字节；声明长度和流式累计长度都执行上限；
- UTF-8 非法字节以替换字符处理，不允许读取无界正文；
- 取第一条非空、非注释的 HTTP/HTTPS 地址；
- 相对地址基于 WebDAV 根路径解析；
- 最终地址必须与 WebDAV 根严格同源，否则条目无效；
- 任意网络、解析或安全检查失败都只跳过该条目。

目录强制刷新会等待正在进行的同目录请求结束，再发起真实新请求。只有成功结果覆盖
缓存；刷新失败保留最后一次成功数据。

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

| 构建 | 版本 | Lua/命令/IPC/进度 | 空密码认证与跨域隔离 |
| --- | --- | --- | --- |
| `mpv-0.34.0-x86_64` | 0.34.0 | 通过 | 通过 |
| `mpv-v0.41.0-x86_64-pc-windows-msvc` | 0.41.0-dev-g41f6a6450 | 通过 | 通过 |
| `mpv-lazy-20260510-noVS` | 0.41.0-615-g7b057f66f | 通过 | 通过 |
| `mpv-x86_64-20260610-git-304426c` | 0.41.0-744-g304426c39 | 通过 | 通过 |
| `mpv-v0.41.0-460-g2f6561947(MPV Config 版本)` | `v0.41.0-460-g2f6561947` | 通过 |


## 6. 缓存控制系统

缓存控制是增强层，任何配置损坏、探测超时、内存读取失败、智能建议器异常或 IPC 失败
都只能跳过或降级，不能阻塞起播。

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

设置页使用顶部分类栏，将配置拆分为“服务器”“播放”“缓存”“基础设置”四个分页。
分页由统一的页面描述列表注册，新增分类时只需补充页面元数据与内容构建器。每个分页拥有
独立表单和滚动状态，保存仍一次提交全部配置；隐藏分页校验失败时会自动切换到对应页。
当前选择只缓存在进程内，退出设置页后再次进入仍显示上次分页，软件重启后恢复服务器页。

登录页的三个控制器在 `initState` 同步读取保存配置，标签统一固定为
`FloatingLabelBehavior.always`。因此从右上角退出返回登录页时，不会先渲染空控制器再
异步填值，也不会出现标签瞬间落入输入框文本的重叠。

浏览页显示列表与播放基础列表分离：隐藏扩展名、搜索、右上角临时排序和滚动位置只影响
当前显示；字幕候选、稳定播放顺序和会话索引使用后台全量列表。默认排序设置持久化，
临时排序和滚动位置不持久化。

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

重点覆盖：WebDAV 空密码、同源/跨源重定向、PROPFIND 方法保持、STRM 字节上限、
OpenList 加盐 hash 和 Token 隔离、MPV 参数/Lua/watch_later/JSONL/IPC、多会话代际、
缓存策略和监控、登录首帧布局、旧数据迁移、排序与滚轮。

2026-08-12 常规套件结果：457 项通过，2 项条件跳过；设置 MPV 测试目录后，两项实体
兼容测试均通过。


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
8. 显示排序和隐藏规则不得改变稳定播放列表和字幕候选基础。
9. 旧数据迁移不覆盖目标、不删除无法解析的源文件。
10. Release 便携包必须是 AOT，并保留用户数据目录。
11. 项目文档只维护 `README.md` 和 `PROJECT.md`；协议、算法或维护边界变化时同步更新。
