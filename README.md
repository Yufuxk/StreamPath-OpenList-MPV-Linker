# StreamPath

StreamPath 是面向 Windows 的便携 WebDAV 媒体浏览器。它负责浏览目录、解析
STRM、匹配外挂字幕、启动 MPV 等外部播放器，并将播放进度、缓存策略和会话状态
保存在程序目录下的 `stream_path_data/`。

当前版本重点支持 OpenList v4、AList v3 和 MPV 0.34～0.41+。详细架构、协议与
维护约束见 [PROJECT.md](PROJECT.md)。

## 主要功能

- 使用 WebDAV `PROPFIND` 浏览目录，支持中文长路径、自然排序和目录缓存。
- WebDAV 密码可以为空；每次登录都强制访问服务器验证当前输入，不使用旧账号缓存冒充
  登录结果，失败时保留登录页并显示原因。
- 播放视频、音频和同源 STRM；视频自动切集，音频自动生成带曲名的 M3U8。
- 音频支持 MP3、FLAC、WAV、M4A/M4B、AAC、OGG/Opus、WMA、APE、
  ALAC、AIFF、MKA、AC3/EAC3、DTS、DSF/DFF、WV、TAK、TTA、AAX 等
  常见格式，实际解码能力由当前 MPV 构建决定。
- 音频自动注入同目录同名 LRC；封面优先使用音频内嵌图片，外挂封面按
  同名图片优先，其次匹配 `cover`、`folder`、`front`、`album` 等标准名称。
- 按同目录、同文件名规则匹配字幕；“自动注入”和“自动选择”可分别关闭。
- 使用 SQLite、MPV watch_later 和逐媒体 JSONL 日志同步续播进度。
- 最多同时管理两个独立播放会话；状态文件、命令文件、IPC 和临时脚本互不共用。
- 音频另有独立下边栏、历史、SQLite、watch_later、状态/命令/进度文件和
  MPV 进程服务；音频模块故障不会占用或修改视频会话资源。
- 根据媒体大小、时长、内存、网络和历史样本生成 MPV 缓存参数，并在播放中安全降级。
- 音频播放完全绕过上述缓存控制与动态优化，并移除播放器模板中的 MPV 缓存覆盖参数，
  只使用 MPV 自身默认缓存机制。
- 可选的 OpenList/AList 自动恢复：仅在 MPV 明确报告 `end-file reason=error` 时尝试
  重新登录、刷新存储并重新拉起播放；默认关闭。
- 浏览页以名称、大小和修改时间展示目录内容，文件夹的大小单元格显示短杠；窄窗口会把普通
  文件的大小与时间收进条目副标题。页面支持时间、体积、名称排序和鼠标滚轮，显示排序
  不改变稳定播放列表顺序。
- 设置页按服务器、播放、缓存、界面和基础设置分页；再次进入时会在本次软件运行期间保留上次
  打开的分页；鼠标位于表单或空白区域时均可使用滚轮滚动当前分页。
- 界面页可在默认样式与 Windows 磨砂玻璃之间切换，可选择自动、Acrylic 或 Mica 材质并
  调整背景不透明度。自动模式在 Windows 11 优先 Mica、Windows 10 使用 Acrylic；显式
  Mica 不可用时回退 Acrylic。磨砂效果整体不可用时软件会继续使用不透明界面。磨砂模式
  内部按背景、结构栏、
  内容、浮起表面和临时弹窗分级，文件列表不逐项叠加模糊以保持大目录滚动性能。界面页还会
  显示 Windows 版本、透明效果、高对比度与窗口实际材质；系统限制只影响当前显示，不会清除
  已保存的磨砂选择。
- 使用自绘标题栏替换 Windows 系统标题栏：显示应用标识并提供最小化、最大化/还原与
  关闭按钮，拖动与双击最大化行为与系统一致；标题栏与页面顶部信息栏共用同一背景色，
  默认样式与磨砂玻璃样式下均自然衔接。
- 缓存页可分别配置目录刷新、目录快照、页面滚动位置、续播记录和媒体元数据的过期时间；
  长时间未访问的数据自动淘汰，缓存学习数据始终只允许主动清理。
- 缓存页可在确认后清理目录缓存、播放进度、继续播放记录和 MPV 临时文件；缓存学习
  数据由独立按钮清理。两种操作都保留全部配置，播放器运行期间不会执行。
- 基础设置可单独启用或关闭隐藏后缀过滤；关闭后仍保留后缀列表，输入格式统一为
  `.ass, .mkv`，并强制使用英文逗号分隔。
- 基础设置底部提供低误触的“重置全部设置”入口，确认后恢复服务器、播放、缓存策略、界面
  和基础设置的默认值；目录缓存、续播记录、学习数据及当前连接和播放会话均保持不变。

## 运行要求

- Windows 10 或 Windows 11 x64。
- 一个可访问的 WebDAV 地址和用户名（推荐为Openlist）；服务器未设置密码时密码框留空。
- MPV 或其他接受 URL 参数的外部播放器。推荐使用已实测的 MPV 版本。
- 额外注意事项：播放 Strm 文件时建议在 Openlist 的 Strm 存储设置中开启 `启用签名` 选项。建议在 MPV 配置文件中完全注释或删除 IPC 的配置代码，保证软件的 IPC 功能能够正常运行（如 `input-ipc-server=` 字样）。

## 快速使用

1. 启动 `streampath.exe`。
2. 填写 WebDAV 地址和用户名；密码按服务器实际配置填写或留空。
3. 连接成功后进入目录，单击视频、音频或有效 STRM 播放。
4. 首次使用前在设置页确认播放器可执行文件路径和参数模板。
5. 右上角退出仅断开当前连接并返回登录页，已保存配置不会被清空。

默认 MPV 参数模板可使用以下占位符：

- `{url}`：媒体 URL。
- `{subfile}`：单集字幕 URL；多集字幕由 Lua 按播放列表位置注入。
- `{start}`：单集续播秒数；多集续播使用 watch_later。

## 音频播放

单击音频后，StreamPath 使用当前目录的稳定自然顺序创建 UTF-8 M3U8，点击项作为
播放起点，每个条目使用服务器文件名作为自定义曲名。临时排序、隐藏后缀和搜索结果
不会改变播放列表顺序。

音频伴随文件规则：

- 歌词只接受音频同目录、主文件名完全相同且扩展名为 `.lrc` 的文件，大小写不敏感；
  LRC 服从现有“自动注入”和“自动选择”开关，关闭自动选择时仅加入轨道并保留原选择；
  远程 LRC 会按原始字节保存为本次 MPV 会话资源，以兼容不支持 Range 的 WebDAV
  响应；整批准备最多等待 10 秒，读取失败或超时只跳过相应歌词，不会阻断音频播放；
- 内嵌封面由 MPV 原生识别，并保持最高优先级；
- 外挂封面先匹配同目录同名图片，再匹配 `cover`、`folder`、`front`、`album`、
  `albumart`、`thumb` 等标准名称；
- LRC 和外挂封面按当前 M3U8 的 `playlist-pos` 逐曲目注入，切歌时不会串到其他曲目。

音频下边栏支持显示当前曲名、暂停、继续、关闭与应用重启后的“继续播放”；现有“自动
续播”开关同时控制视频与音频。播放位置
通过音频专用 SQLite、MPV 音频 watch_later 和逐曲目 JSONL 合并：自然播放完会清除旧
进度，明确回到 0 秒会覆盖旧正数进度，普通退出使用 MPV 的精确最终位置。

音频模块不调用缓存策略、媒体探测、动态监控或 OpenList 恢复。启动时还会过滤模板中
的 `cache`、`cache-secs`、`demuxer-max-bytes`、`demuxer-seekable-cache`、
`stream-buffer-size` 等参数，确保音频只采用 MPV 默认缓存。音频的 LRC、封面、M3U8
和下边栏功能要求播放器配置为 MPV。LRC 会话文件只保存歌词、不保存音频数据，播放
会话结束后删除，不属于可复用缓存；音频媒体流和封面仍由 MPV 直接读取。

## MPV 兼容性

2026-08-13 使用
本人在 Github 下载的五个实体程序完成自动化实测。
每个版本都实际加载媒体并验证 Lua、暂停/恢复命令、命名管道、十四字段状态文件、
逐媒体进度日志、空密码 Basic 认证的跨来源重定向隔离，以及不支持 Range 的远程 LRC
与远程外挂封面同时存在时的两首音频列表自然推进。

| 测试程序 | `mpv --version` | 结果 |
| --- | --- | --- |
| `mpv-0.34.0-x86_64` | `mpv 0.34.0` | 通过 |
| `mpv-v0.41.0-x86_64-pc-windows-msvc` | `v0.41.0-dev-g41f6a6450` | 通过 |
| `mpv-lazy-20260510-noVS` | `v0.41.0-615-g7b057f66f` | 通过 |
| `mpv-x86_64-20260610-git-304426c` | `v0.41.0-744-g304426c39` | 通过 |
| `mpv-v0.41.0-460-g2f6561947(MPV Config 版本)` | `v0.41.0-460-g2f6561947` | 通过 |

普通测试默认跳过实体 MPV 测试。需要复测时执行：

```powershell
$env:STREAMPATH_MPV_TEST_ROOT = 'MPV根文件夹路径'
flutter test test/mpv_version_compatibility_test.dart --no-pub -r expanded
```

测试会自动把系统 PATH 中的 `mpv.exe` 作为第五个版本；也可以通过
`STREAMPATH_PATH_MPV` 指定该版本的完整路径。

## OpenList/AList 自动恢复

设置页可填写后台地址和管理员 Token，或填写管理员账号、密码。推荐使用 Token；启用
2FA 的账号必须使用 Token。管理员 `Authorization` 值直接使用 Token，不添加
`Bearer`。

恢复流程只在以下条件全部满足时运行：

1. 功能已启用且配置完整；
2. MPV 明确报告当前媒体读取错误；
3. 原媒体地址的 Range 探测仍不可用。

系统优先调用 `/api/auth/login`，仅当端点不存在时回退
`/api/auth/login/hash`，随后调用 `/api/admin/storage/load_all` 并等待存储列表和
媒体地址恢复。失败只显示提示，不会中断播放器退出监听或反复无限重试。
如果 MPV 第二次报告读取错误，但 Range 探测确认媒体仍可读取，系统会将其判定为
非链接失效并停止自动恢复，不会强制刷新全部存储。

## 数据目录

便携版数据位于程序同级 `stream_path_data/`：

```text
stream_path_data/
├─ config/
│  ├─ stream_path_config.json
│  ├─ cache_policy.json
│  ├─ cache_intelligence.json
│  └─ cache_expiration.json
└─ cache/
   ├─ directory_cache/
   ├─ streampath.db
   ├─ playback_history.json
   ├─ audio_streampath.db
   ├─ audio_playback_history.json
   ├─ media_metadata.json
   ├─ cache_intelligence_learning.json
   ├─ mpv-watch-later/
   ├─ mpv-audio-watch-later/
   └─ 视频与音频 MPV 会话状态、命令、进度、脚本及 M3U/M3U8 播放列表
```

旧版平铺数据会在启动时迁移到上述目录。目标已存在时不会覆盖；迁移失败时原文件
保留，应用继续启动。统一配置采用临时文件原子替换，并保留最近一次有效备份；启动时
主配置损坏会回退备份，备份也不可用时使用默认值并保留损坏文件。

## 缓存过期配置

“设置 → 缓存 → 缓存过期时间”可以修改以下项目：

- 目录刷新间隔：默认 10 分钟，可设置 1～1440 分钟。超过后先显示旧快照，再后台刷新；
- 目录快照保留时间：默认 30 天，可设置 1～3650 天。按最后访问时间自动清理；
- 滚动位置保留时间：默认 30 分钟，可设置 1～1440 分钟。长时间未打开的目录从顶部显示；
- 续播记录保留时间：默认 365 天，可设置 1～3650 天，同时作用于视频/音频 SQLite、
  继续播放记录和 MPV `watch_later`；
- 媒体元数据保留时间：默认 180 天，可设置 1～3650 天，适用于文件大小、时长、码率、
  ETag 和 Last-Modified 等缓存。

这些值保存在 `stream_path_data/config/cache_expiration.json`。软件启动时加载一次；在
设置页保存或点击右上角“从配置文件重新加载”后，后续缓存访问使用新值。直接修改文件后
也可以重启软件使其生效。非法类型回退默认值，越界数值自动收敛到允许范围，配置损坏不会
阻止浏览或播放。

缓存学习数据 `cache/cache_intelligence_learning.json` 不读取任何过期时间，不会被
自动清理。只有“清理学习数据”按钮会重置它；普通缓存清理仍会保留该文件。

## 安全边界

- WebDAV 与 OpenList 管理请求手动处理重定向，只在严格同源时携带凭据。
- MPV 不使用会跨域转发的全局 `--http-header-fields=Authorization`；仅给 WebDAV
  同源 URL 写入 userinfo。实测的五个 MPV 版本在跨来源重定向时会移除该凭据。
- STRM 最大读取 8192 字节，只接受 HTTP/HTTPS 且与 WebDAV 根地址同源的目标。
- OpenList 管理员请求拒绝跨来源重定向；媒体探测跳到签名域名后立即移除 Basic。
- 配置文件目前以便携 JSON 保存，请自行保护便携目录的访问权限。

## 开发、测试与打包

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

当前常规测试覆盖视频与音频识别、M3U/M3U8、字幕/LRC/封面、进度、会话隔离、缓存
边界和 WebDAV；需要显式提供 MPV 目录的多版本兼容测试仍按条件跳过。项目内另有一项
使用当前实测 MPV 的音频实体测试，会实际加载 WAV、LRC、外挂封面和完成事件。

Release/AOT 构建并更新指定便携目录：

```powershell
.\package.ps1
```

脚本启动后输入打包目录；直接回车使用现有便携版目录。也可以在命令行直接传入目录：

```powershell
.\package.ps1 -Target 'D:\StreamPath portable'
```

需要细分构建参数时使用底层脚本：

```powershell
.\build.ps1 -Mode release `
  -Target 'C:\Users\YX\Documents\StreamPath_Release\StreamPath 20260809 V0.1 portable' `
  -Yes
```

构建脚本依次执行静态分析、全部常规测试和 Windows Release 构建，并校验
`data/app.so` 存在且没有 Debug `kernel_blob.bin`。覆盖目标时只替换程序构建产物，
保留 `使用说明.txt` 与 `stream_path_data/` 用户数据。非空目标必须同时含已有
`streampath.exe` 和 `data/app.so` 标记，否则拒绝覆盖。

仅清理缓存和运行时数据、保留全部配置：

```powershell
.\cleanup.ps1
```

保留播放历史时使用 `.\cleanup.ps1 -KeepHistory`。脚本会验证目标范围并拒绝驱动器
根目录、项目根目录、用户目录和目标路径链中的重解析点；旧版播放器与连接配置也不会
被清理。

也可以在软件的“设置 → 缓存 → 缓存文件清理”中执行。确认后会清除播放进度与继续
播放记录，但保留缓存学习数据和 `stream_path_data/config/`。需要重置匿名码率、
存储画像和缓存习惯统计时，使用同页独立的“清理学习数据”按钮，该操作不会清除其他
缓存。开发构建和便携版都会按当前可执行文件定位各自的 `stream_path_data/cache/`；
两种清理操作开始前都需要先关闭仍在运行的播放器。

## 常见问题

- **空密码无法连接**：确认服务器确实允许该用户名使用空密码；StreamPath 会发送
  `username:` 对应的 Basic 凭据，失败会显示服务器或网络错误。
- **登录页标签闪动或重叠**：当前实现首帧同步填充控制器并固定标签浮动位置；若仍出现，
  请记录系统缩放比例和复现步骤。
- **MPV 无法启动**：在设置页使用 `mpv.exe` 的完整路径，先在终端执行该文件的
  `--version`。
- **STRM 不显示或不可播放**：只接受非空、8192 字节以内且与 WebDAV 同源的目标；
  第三方直链会被拒绝。
- **OpenList 恢复失败**：检查后台根地址、Token 权限和 2FA；后台反向代理必须允许
  管理 API 且不能把管理员请求重定向到其他来源。
