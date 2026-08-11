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
- 播放视频和同源 STRM，自动生成 MPV 单集或多集播放任务。
- 按同目录、同文件名规则匹配字幕；“自动注入”和“自动选择”可分别关闭。
- 使用 SQLite、MPV watch_later 和逐媒体 JSONL 日志同步续播进度。
- 最多同时管理两个独立播放会话；状态文件、命令文件、IPC 和临时脚本互不共用。
- 根据媒体大小、时长、内存、网络和历史样本生成 MPV 缓存参数，并在播放中安全降级。
- 可选的 OpenList/AList 自动恢复：仅在 MPV 明确报告 `end-file reason=error` 时尝试
  重新登录、刷新存储并重新拉起播放；默认关闭。
- 浏览页支持时间、体积、名称排序和鼠标滚轮；显示排序不改变稳定播放列表顺序。
- 设置页按服务器、播放、缓存和基础设置分页；再次进入时会在本次软件运行期间保留上次
  打开的分页。

## 运行要求

- Windows 10 或 Windows 11 x64。
- 一个可访问的 WebDAV 地址和用户名（推荐为Openlist）；服务器未设置密码时密码框留空。
- MPV 或其他接受 URL 参数的外部播放器。推荐使用已实测的 MPV 版本。
- 额外注意事项：播放 Strm 文件时建议在 Openlist 的 Strm 存储设置中开启 `启用签名` 选项。建议在 MPV 配置文件中完全注释或删除 IPC 的配置代码，保证软件的 IPC 功能能够正常运行（如 `input-ipc-server=` 字样）。

## 快速使用

1. 启动 `streampath.exe`。
2. 填写 WebDAV 地址和用户名；密码按服务器实际配置填写或留空。
3. 连接成功后进入目录，单击视频或有效 STRM 播放。
4. 首次使用前在设置页确认播放器可执行文件路径和参数模板。
5. 右上角退出仅断开当前连接并返回登录页，已保存配置不会被清空。

默认 MPV 参数模板可使用以下占位符：

- `{url}`：媒体 URL。
- `{subfile}`：单集字幕 URL；多集字幕由 Lua 按播放列表位置注入。
- `{start}`：单集续播秒数；多集续播使用 watch_later。

## MPV 兼容性

2026-08-11 使用
本人在 Github 下载的五个实体程序完成自动化实测。
每个版本都实际加载媒体并验证 Lua、暂停/恢复命令、命名管道、十四字段状态文件、
逐媒体进度日志以及空密码 Basic 认证的跨来源重定向隔离。

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
│  └─ cache_intelligence.json
└─ cache/
   ├─ directory_cache/
   ├─ streampath.db
   ├─ playback_history.json
   ├─ media_metadata.json
   ├─ cache_intelligence_learning.json
   ├─ mpv-watch-later/
   └─ MPV 会话状态、命令、进度、脚本与播放列表
```

旧版平铺数据会在启动时迁移到上述目录。目标已存在时不会覆盖；迁移失败时原文件
保留，应用继续启动。统一配置采用临时文件原子替换，并保留最近一次有效备份；启动时
主配置损坏会回退备份，备份也不可用时使用默认值并保留损坏文件。

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

当前常规测试结果为 457 项通过、2 项条件跳过；跳过项是需要显式提供 MPV 实体目录的
两项兼容测试。

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
