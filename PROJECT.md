# StreamPath 项目说明

本文档面向开发和维护人员，描述当前代码库的架构、关键数据流、业务约束、兼容策略与维护风险。用户操作和构建命令见 [README.md](README.md)。

## 1. 项目定位

StreamPath 是 Flutter 桌面端 WebDAV 媒体浏览器，当前目标平台为 Windows 和 Linux。核心职责不是自行解码媒体，而是完成以下工作：

1. 读取和缓存 WebDAV 目录。
2. 对文件进行稳定显示排序。
3. 组织视频和 STRM 播放列表。
4. 严格匹配同目录外挂字幕。
5. 调用外部播放器，重点增强 mpv。
6. 持久化播放进度和最多两个继续播放会话。
7. 在 Windows 提供额外的剪贴板兼容处理。

应用定位为受信任的单机工具。WebDAV 密码以明文写入本地 JSON 配置，不具备多用户密钥管理能力。

## 2. 技术栈

| 领域 | 实现 |
|---|---|
| UI 与状态 | Flutter Material、Provider |
| WebDAV 请求 | Dio、`PROPFIND Depth: 1`、Basic Authentication |
| XML | `xml`，按 `localName` 解析以兼容命名空间前缀 |
| 目录缓存 | Hive |
| 播放进度 | SQLite、`sqflite_common_ffi` |
| 字幕与播放 | 外部播放器，mpv 使用 m3u、Lua、watch_later 和 IPC 标识 |
| 剪贴板 | `super_clipboard`、Windows MethodChannel 与键盘事件修复 |

## 3. 目录结构

```text
lib/
  core/
    constants.dart              全局常量、扩展名和会话上限
    errors/                     统一异常
    utils/                      路径、URL、排序、STRM、剪贴板等纯工具
  data/
    local/                      Hive、SQLite、JSON 持久化
    models/                     配置、文件、字幕、播放历史与进度模型
    remote/                     WebDAV HTTP 客户端和 XML 解析
  domain/
    repositories/               目录仓库接口
    services/                   WebDAV、字幕、播放器、MPV 脚本和会话控制
  presentation/
    pages/                      自动连接、登录、浏览、设置
    state/                      AppState 服务装配
    widgets/                    文件项和剪贴板菜单
windows/                        Windows runner 与剪贴板原生通道
linux/                          Linux GTK runner
test/                           单元、组件和真实 MPV 会话测试
stream_path_data/               运行时数据，不属于源码
```

## 4. 启动与依赖装配

[lib/main.dart](lib/main.dart) 的启动顺序：

1. 初始化 Flutter binding。
2. 安装 Windows 剪贴板兼容逻辑；非 Windows 直接跳过。
3. 解析数据目录并初始化 Hive。
4. 打开 SQLite 播放进度库。
5. 加载统一配置。
6. 加载继续播放历史。
7. 创建 `AppState`，装配 WebDAV、字幕和播放器服务。
8. 配置完整时进入 `AutoConnectGate`，否则显示登录页。

`AppState` 只保存当前连接的内存状态和服务实例。连接配置由 `StreamPathConfigStore` 持久化；调用 `disconnect()` 不会删除配置文件。

## 5. 数据目录与持久化

### 5.1 路径策略

[lib/core/utils/app_paths.dart](lib/core/utils/app_paths.dart) 从 `Platform.resolvedExecutable` 查找路径中的 `build` 段：

- 标准 Flutter 源码构建布局下，取 `build` 之前的项目根目录。
- 找不到 `build` 时，使用当前工作目录。
- 目标目录不可写时，回退系统应用支持目录。

因此不能假设数据始终位于可执行文件旁。部署或改变启动工作目录时，应先确认实际 `stream_path_data/` 位置。

### 5.2 数据文件

| 数据 | 存储 | 说明 |
|---|---|---|
| 用户配置 | `stream_path_config.json` | 连接、播放器、字幕开关、隐藏后缀、默认排序 |
| 目录缓存 | Hive `directory_cache` box | 条目快照与缓存时间 |
| 播放进度 | `streampath.db` | URL 主键、位置、时长、更新时间 |
| 播放会话 | `playback_history.json` | 版本 2，会话数组，最多两条 |
| MPV 进度 | `mpv-watch-later/` | mpv 原生续播与临时 Lua/m3u |
| MPV 状态与命令 | `mpv-current-<session>.txt`、`mpv-command-<session>.txt` | 每个会话独立 |

### 5.3 配置兼容

`StreamPathConfig` 是平铺统一配置。主要字段：

```json
{
  "serverUrl": "http://host/dav",
  "username": "user",
  "password": "pass",
  "playerName": "mpv",
  "playerExecutable": "mpv",
  "playerArgs": ["--sub-file={subfile}", "{url}", "--start={start}"],
  "subtitleInjectionEnabled": true,
  "subtitleAutoSelectEnabled": true,
  "resumeEnabled": true,
  "hiddenExtensions": [".ass"],
  "defaultSortMode": "name",
  "defaultSortDirection": "ascending",
  "playerStartupTimeoutSeconds": 60
}
```

兼容规则：

- 旧 `player_config.json` 与 `connection_config.json` 可迁移到统一配置。
- 旧 `subtitleEnabled` 同时映射到注入和自动选择。
- 注入关闭时，自动选择会被强制视为关闭。
- 未知排序方式回退名称，未知方向回退正序。
- `playerStartupTimeoutSeconds` 默认 60 秒，可写 5 到 3600 秒，超出范围会被限制到边界值。
- 隐藏后缀会规范化为小写点号格式。

## 6. WebDAV 目录链路

### 6.1 请求与解析

[lib/data/remote/webdav_client.dart](lib/data/remote/webdav_client.dart) 发送 `PROPFIND`，请求深度为 1，并通过 Dio 超时和异常映射返回中文业务错误。

[lib/data/remote/webdav_xml_parser.dart](lib/data/remote/webdav_xml_parser.dart) 负责：

- 忽略 XML 命名空间前缀差异。
- 解析目录、文件、大小、修改时间和内容类型。
- 在缺少 `getdisplayname` 时从 href 末段解码名称。
- 识别当前目录自身条目，供 UI 渲染“返回上级目录”。
- 兼容 HTTP 日期与 ISO8601 修改时间。

解析后的后台列表固定按自然名称正序排列。该顺序也是播放列表的稳定基础，不受浏览页临时时间或体积排序影响。

### 6.2 缓存和刷新

[lib/domain/services/webdav_service.dart](lib/domain/services/webdav_service.dart) 组合远端客户端与 `DirectoryCache`：

- 普通请求优先读取缓存。
- 新鲜缓存 TTL 为 10 分钟。
- 过期缓存先返回旧快照，再后台刷新。
- 同路径普通请求共享 Future。
- 强制刷新会与同目录刷新合并；若旧普通请求仍运行，则等待后再发起真正刷新。
- 只有成功网络结果可以覆盖缓存。
- 缓存读取、写入或 Hive 异常不阻断已经成功的网络结果。

缓存键由 `cacheKeyFor` 生成。短 URL 保持旧格式；超过 Hive 字符串键限制风险的长 URL 使用 SHA-256 固定长度摘要。

### 6.3 页面一致性

`BrowserPage._load` 为每次导航或刷新分配递增 ID，并固定本次请求路径。只有最后一次请求能更新当前页面，避免快速进入、返回或刷新时旧响应覆盖新目录。

## 7. 文件类型与显示排序

`WebDavFile` 根据名称和 href 末段双重判断类型，以兼容服务器丢失显示名扩展名的情况。

- 视频扩展名由 `AppConstants.videoExtensions` 定义。
- STRM 使用 `.strm`。
- 字幕扩展名由 `AppConstants.subtitleExtensions` 定义。
- `isPlayable` 包含视频和 STRM。

[lib/core/utils/file_sort.dart](lib/core/utils/file_sort.dart) 提供：

- `FileSortMode`：名称、修改时间、体积。
- `FileSortDirection`：正序、倒序。
- “返回上级、目录、文件”固定分组。
- 时间按分钟比较，缺失值始终置后。
- 体积排序不应用于目录；纯目录页面禁用体积入口。
- 同值回退名称和 href，保持确定性。

自然名称比较器支持任意长度数字块、全角字符、前导零、中文序数、常见罗马数字季名和分隔符。显式序号规则为：

1. 优先识别名称开头数字。
2. 没有开头数字时，识别扩展名前由空格、横线或下划线分隔的末尾数字。
3. 不把 `1080p`、`x264` 这类无分隔发布信息当作末尾主键。

浏览页排序只作用于 `_files` 的显示副本。页面以目录路径、排序方式和方向构造 `PageStorageKey`，滚动位置仅存内存。

## 8. STRM 处理

[lib/core/utils/strm_parser.dart](lib/core/utils/strm_parser.dart) 从 STRM 文本中读取第一个非空、非注释行。`WebDAVService.fetchStrmUrl` 再将其作为绝对或相对地址解析，并强制校验与当前 WebDAV 根地址同源。

播放前，`BrowserPage` 按每批 4 个并发读取当前目录的 STRM：

- 解析成功的 STRM 进入播放列表。
- 解析失败的 STRM 被剔除。
- 用户点击的 STRM 解析失败时，本次播放终止并提示。
- 字幕匹配入口仍使用 STRM 文件自身的 WebDAV 条目，因此目录约束不会被真实媒体 URL 绕过。

## 9. 字幕匹配与注入

### 9.1 匹配边界

[lib/domain/services/subtitle_matcher.dart](lib/domain/services/subtitle_matcher.dart) 先做硬边界，再做名称评分：

1. 绝对 URL 必须同源。
2. 父目录路径必须完全相同。
3. 明确的季集编号冲突直接拒绝。

这三条保证媒体库中的“字幕备份”目录不会向剧集目录串入字幕。

名称处理会：

- 去扩展名并归一化大小写和分隔符。
- 剥离语言标签和 `forced`、`default`、`sdh`、`cc` 等字幕属性。
- 识别 `S01E01`、`1x01`、`E01`、`EP01`、中文集号和纯数字集号。
- 允许片名一致、集号一致但发布信息不同的候选。

评分优先级为完全同名、同名中文、相似中文、同名其他语言、相似无标签、相似其他语言；同分时短名称优先。

### 9.2 两个配置开关

- `subtitleInjectionEnabled`：是否查找并注入匹配字幕。
- `subtitleAutoSelectEnabled`：注入后是否自动选择，依赖前者。

设置页在注入关闭时禁用自动选择控件。浏览页仅在注入开启时调用 `findBestFor`，从源目录全量列表中为每个播放项独立保存匹配结果。

### 9.3 MPV 注入

mpv 不再依赖模板中的 `--sub-file={subfile}` 注入字幕。`MpvScripts` 生成 Lua：

- 单集：在 `file-loaded` 时注入本次匹配字幕。
- 多集：在每次 `file-loaded` 时读取 `playlist-pos`，从 `SUBS[pos]` 注入当前集字幕。
- 自动选择开启：`sub-add ... select`。
- 自动选择关闭：`sub-add ... auto`，记录注入前 `sid` 并在下一事件循环恢复，达到“加入轨道但不改变当前字幕”的效果。

自动注入开启时追加 `--sub-auto=no`，阻止 mpv 自身配置跨目录搜索字幕。非 mpv 播放器仍可通过 `{subfile}` 参数模板接收字幕 URL。

## 10. 播放器启动与认证

[lib/domain/services/external_player_service.dart](lib/domain/services/external_player_service.dart) 是播放器联动核心。

### 10.1 参数模板

支持 `{url}`、`{subfile}`、`{start}`。无值占位符所在参数会清理空外壳；缺少 `{url}` 时自动追加媒体地址。

mpv 增强当前按播放器可执行文件配置字符串是否包含 `mpv` 判断。增强行为包括：

- Basic Authorization header，不把凭据写入媒体 URL。
- 单集标题或多集 m3u 标题。
- 每次启动唯一 named pipe 标识。
- 独立 Lua 字幕、标题和状态脚本。
- 独立 watch_later 目录和进度同步。

其他播放器使用内嵌凭据 URL，并退化为普通直链参数模式。

### 10.2 播放列表

多集模式生成 m3u：

```text
#EXTM3U
#EXTINF:0,<标题>
#EXTVLCOPT:force-media-title=<标题>
<媒体 URL>
```

使用 `--playlist-start` 指定所选条目。标题 Lua 为不支持 `EXTVLCOPT` 的旧版 mpv 提供兜底。

### 10.3 进程与会话

服务以 `sessionId` 管理运行时会话，保存 PID、IPC 标识、状态文件、命令文件和存活缓存。Windows 使用 `tasklist/taskkill` 探测与终止，其他平台使用 `kill -0/kill`。

新启动的 MPV 在首个有效 `file-loaded` 状态前进入启动保护期。浏览页每秒探测一次对应 PID；在 `playerStartupTimeoutSeconds` 到期前底栏保持“继续播放”，到期仍未激活则定向终止该会话进程并删除历史。

删除会话前会校验目标 PID 与会话身份，避免误结束其他播放器进程。清理动作只处理该会话的 m3u、Lua、状态和命令文件。

## 11. 播放进度与继续播放

### 11.1 进度模型

`PlaybackProgress` 按 URL 保存 `positionMs`、可空 `durationMs` 和更新时间。

“已看完”只在时长已知时判断：距离片尾不足一分钟则从头播放。时长未知不再视为已看完，这是文档和测试必须保持一致的语义。

mpv 启动时配置专属 watch_later 目录。退出后通过 URL MD5 文件名直查，并以注释行扫描作为兼容兜底，再同步到 SQLite。

### 11.2 状态脚本

每个会话的 current Lua 写五行状态：

```text
playlist-pos
path
paused(1|0)
time-pos
duration
```

状态在 `file-loaded`、暂停变化、周期定时器和 shutdown 时更新。命令文件轮询执行 pause/resume。播放列表进入稳定 idle 后写 `-1` 完成标记。

### 11.3 最多两个会话

上限集中在 `AppConstants.maxPlaybackSessions`，当前值为 2。持久化格式为：

```json
{
  "version": 2,
  "sessions": []
}
```

旧版单对象记录会作为 `legacy` 会话读取。会话按创建时间排序，UI 反向展示，因此新会话在上、旧会话在下。

进程退出后的状态规则：

- 明确完成或退出时最后进度达到 99%：移除该会话栏。
- 未完成：切换为“继续播放”。
- 99% 规则只在确认进程退出后应用。
- 运行中的 99% 不提前隐藏。

### 11.4 继续播放栏的存活检测

播放视频后，浏览页按启动保护期每秒探测一次对应 MPV 进程：激活成功则更新底栏状态；到期仍未激活则移除底栏并清理该会话进程。

## 12. 页面职责

### AutoConnectGate

读取已加载配置并尝试连接。成功替换为浏览页；失败回到登录页并显示错误，避免登录界面短暂闪现。

### HomePage

编辑 WebDAV 地址、用户名和密码。连接成功后保存配置并进入浏览页。

### BrowserPage

项目主要交互页面，负责：

- 目录导航、缓存首帧和强制刷新。
- 显示过滤、排序和滚动位置。
- STRM 预取与播放列表组装。
- 为每个条目匹配字幕。
- 查询续播进度并启动播放器。
- 同步和渲染多个播放会话。
- 暂停、恢复、继续播放和删除会话。

文件交互当前为单击：目录进入，视频或 STRM 播放，普通文件无动作。

### SettingsPage

编辑播放器、参数模板、隐藏后缀、默认排序、WebDAV 凭据、字幕开关和自动续播。保存时写统一配置。自动选择字幕控件依赖自动注入。

## 13. Windows 剪贴板实现

Windows runner 注册 `WM_CLIPBOARDUPDATE`，通过 `streampath/clipboard` MethodChannel 通知 Dart。文本由 `super_clipboard` 读取，应用内历史最多保留五条。

`ClipboardHistoryFix` 只在 Windows 安装，用于识别 Win+V 产生但被 Flutter 引擎吞掉部分按键的合成序列，并注入等价粘贴。Debug 模式可写诊断日志。Linux 不启用该键盘修复。

## 14. 测试策略

测试覆盖以下边界：

- WebDAV XML 命名空间、显示名回退、自身条目和中文长目录。
- 缓存 TTL、强制刷新、失败保留快照和请求合并。
- 自然排序、时间/体积方向、显式序号和纯目录体积禁用。
- STRM 文本解析。
- 字幕目录隔离、剧集编号冲突、语言和属性标签。
- 配置读写、旧字段和旧文件迁移。
- 单集/多集播放器参数、逐集字幕注入和双会话资源隔离。
- watch_later 解析、SQLite 进度、播放历史集合。
- 真实 MPV 命令文件暂停和恢复测试。
- 文件列表组件与 Windows 剪贴板状态机。

常规验证命令：

```powershell
flutter analyze
flutter test
flutter build windows --debug
```

真实 MPV 测试会启动无画面测试进程，并在测试结束后自行关闭。新增进程控制测试时必须保持同样的清理要求。

## 15. 关键约束

修改项目时应优先保护以下约束：

1. **显示列表与后台全量列表分离**：隐藏后缀和临时排序不能改变字幕候选或播放列表索引。
2. **播放列表固定自然名称正序**：浏览页的时间、体积和倒序只影响显示。
3. **字幕不跨目录**：同源、同父目录和集号兼容都是硬条件。
4. **自动选择不等于自动注入**：关闭选择后仍要逐集注入字幕轨道。
5. **会话资源完全隔离**：PID、IPC、状态、命令、Lua、m3u 和历史都按 `sessionId` 区分。
6. **缓存失败不能阻断网络结果**：缓存是优化层，不是目录正确性的依赖。
7. **进程退出后才应用 99% 隐藏规则**。
8. **体积排序不计算目录总体积**。
9. **滚动位置和右上角临时排序不持久化**。
10. **用户未要求时，不结束与目标会话无关的 MPV 进程**。

## 16. 维护入口

| 需求 | 主要位置 |
|---|---|
| 修改支持的媒体或字幕扩展名 | `lib/core/constants.dart` |
| 修改名称、时间或体积排序 | `lib/core/utils/file_sort.dart` |
| 修改长 URL 缓存键 | `lib/core/utils/url_utils.dart` |
| 修改 WebDAV 请求 | `lib/data/remote/webdav_client.dart` |
| 修改 XML 兼容 | `lib/data/remote/webdav_xml_parser.dart` |
| 修改缓存刷新策略 | `lib/domain/services/webdav_service.dart` |
| 修改字幕匹配规则 | `lib/domain/services/subtitle_matcher.dart` |
| 修改 MPV 参数和进度同步 | `lib/domain/services/external_player_service.dart` |
| 修改 Lua/m3u 生成 | `lib/domain/services/mpv_scripts.dart` |
| 修改播放会话上限 | `lib/core/constants.dart` 的 `maxPlaybackSessions` |
| 修改浏览和下边栏交互 | `lib/presentation/pages/browser_page.dart` |
| 修改配置项 | 配置模型、设置页、配置测试和两份文档 |

## 17. 当前已知维护事项

- [scripts/fix-cargokit-symlinks.ps1](scripts/fix-cargokit-symlinks.ps1) 含未解决的 Git 合并冲突标记，当前不可执行。它修改 Pub Cache 中的第三方脚本，本身也需要谨慎评审后再恢复。
- [run-d.ps1](run-d.ps1) 写死了 `C:\Users\YX\Documents\StreamPathProject`，只适用于原开发机路径。
- [build.ps1](build.ps1) 目前只是 `flutter run -d windows` 的一行包装，不执行独立构建或二次启动。
- 数据根路径依赖标准 `build/...` 布局或当前工作目录。若未来制作安装包，应明确改为稳定的便携目录或系统应用数据目录策略。
- `MpvSessionController` 的 JSON-RPC named pipe 能力目前主要用于测试和扩展；稳定的暂停/恢复主通道仍是每会话命令文件加 Lua 轮询。
