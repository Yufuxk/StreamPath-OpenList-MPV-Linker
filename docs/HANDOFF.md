# StreamPath 对抗性审查与修复交接

> 审查日期：2026-08-23  
> 审查范围：当前工作区，而不是仅审查 Git HEAD  
> 当前分支：master  
> 当前 HEAD：7f845d45b245cb4cb3d44b58669e4330207ccc47
> 审查方法：对抗性审查 + 第一性原理分析  
> 实施状态：阶段 0～5 已完成，最终验收已通过
> 整体结论：当前交接范围已完成；后续只需按本文件记录的命令复测

## 1. 交接用途

本文用于在新的聊天中直接继续修复。开始工作前应先阅读本文、docs/PROJECT.md、
docs/README.md 和 docs/BUGRECODE.md。

首次审查快照中 git status 共 76 个条目，已在当前 HEAD（7f845d4）中保存为基线；阶段
2～5 的后续改动仍保留在当前工作树，未执行提交。仍不得用 git reset、git clean、checkout
覆盖或全仓格式化来“恢复干净状态”。所有复测和修复都要以当前工作树为基线，逐项做窄改动
和回归验证。

2026-08-23 已按本文顺序完成阶段 0～5 的发布阻断项及其先红后绿测试；没有停止、重启或调用正在
运行的 5244 OpenList/AList 管理 API，也没有终止用户真实 MPV。所有后续工作均以当前工作树为
基线，只做复测或新增兼容样本，不再从阶段 0 重新开始。

## 2. 必须保持的业务不变量

- WebDAV、目录缓存和 OpenList/AList 恢复属于可降级能力，失败不得阻塞基础播放。
- 视频与音频服务、历史、SQLite、watch_later、状态文件和缓存控制必须保持隔离。
- 正式播放进度与临时缓冲检查点不得合并。
- 媒体库来源继续按不含凭据、查询参数和片段的 sourceId 隔离。
- 自动恢复只接受 MPV 的 end-file reason=error/file_error；普通 EOF、退出和缓冲不是恢复触发器。
- OpenList/AList 第三层本机重启必须失败关闭，不能强杀，不能在身份不完整时猜测。
- 进程终止必须证明“当前 PID 仍是本会话启动的那个进程”，不能只证明 PID 存活。
- 不得为兼容旧 AList 而把缺失的增量 update 静默回退为破坏性的全量 build。
- 设置页隐藏分类仍需参与保存校验，不能为了懒加载而丢失隐藏页校验。
- 目录搜索只搜索已访问快照，不得改成递归扫描网盘。

## 3. 已执行验证

### 3.1 Flutter 与 Windows 构建

| 验证 | 结果 |
|---|---|
| flutter analyze --no-pub | 通过，无问题 |
| flutter test --no-pub -r compact | 745 项通过，3 项条件式 MPV 测试跳过 |
| 阶段 0 + 1 合并定向测试 | 125 项通过 |
| OpenList 身份与恢复定向测试 | 19 项通过 |
| 实体 MPV 跨版本套件 | 5 个实体 MPV 全部通过 |
| flutter build windows --release --no-pub | 通过，生成 Release\streampath.exe |
| tools/build.ps1 Release 流程 | 退出码 0，正确定位项目根构建产物 |
| 项目内部打包目标验证 | 退出码 1，目标前后均不存在 |
| git diff --check | 无空白错误；仅有既有 LF/CRLF 警告 |

完整测试通过只能说明既有断言成立，不能反证未接入的硬件解码和用户自定义配置场景。多数已确认问题恰好缺少
PID 复用、档案切换、损坏后写入、旧工件、超时和查询次数等测试。

新增恢复测试首次进入全仓并发运行时曾因测试清理先关闭 SQLite、后台退出 watcher 后收敛而
出现 1 项失败；改为先结束测试自有假进程并等待退出同步后，独立测试与全仓复跑均通过。

### 3.2 构建脚本修复前回归复现

从项目根执行以下命令：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build.ps1 -Mode release -SkipAnalyze -SkipTest -SkipPackage
~~~

实际 Flutter Release 构建成功，但脚本随后查找错误的
tools\build\windows\x64\runner\Release\streampath.exe，并以退出码 1 失败。

以下命令只执行路径校验，没有创建目录：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build.ps1 -ValidateTargetOnly -Target C:\Users\YX\Documents\StreamPathProject\_audit_target_should_be_rejected
~~~

脚本错误地报告“打包目标校验通过”，证明脚本把 tools 目录而不是实际项目根作为安全边界。

修复后同一 Release 命令退出码为 0；同一项目内部目标验证退出码为 1，验证前后均未创建目标。

### 3.3 当前本机 OpenList

2026-08-23 的只读快照：

- 进程：openlist.exe；
- 命令行：server --force-bin-dir；
- 监听端口：5244；
- GET /api/public/settings：HTTP 200、业务 code 200；
- 版本：OpenList v4.1.4，Commit 2edc446c。

本轮没有使用管理员凭据，没有调用 load_all、index/update，也没有执行停止或重启。

隔离契约矩阵使用临时端口和临时数据目录，7/7 通过：AList 3.0.1、3.6.0、3.7.1、
3.63.0，以及 OpenList 4.0.0、4.1.4、4.2.5。最近一次报告：
`C:\Users\YX\AppData\Local\Temp\StreamPathContractMatrix-20260823\runs-20260823-043010-533\matrix-summary.json`。
矩阵运行前后 5244 端口所有者均为 PID 18160，未触碰真实实例。

### 3.4 MPV 实体兼容

以下五个实体构建均通过 Lua、命令文件、进度日志、Basic 认证与跨来源去凭据、动态缓存
属性、TS、字幕、watch_later、file_error、idle 完成标记、远程 WAV、本地化 LRC 和远程
封面列表测试：

| 来源 | mpv --version |
|---|---|
| 打包版本\mpv-0.34.0-x86_64 | mpv 0.34.0 |
| 打包版本\mpv-lazy-20260510-noVS | mpv v0.41.0-615-g7b057f66f |
| 打包版本\mpv-v0.41.0-x86_64-pc-windows-msvc | mpv v0.41.0-dev-g41f6a6450 |
| 打包版本\mpv-x86_64-20260610-git-304426c | mpv v0.41.0-744-g304426c39 |
| `D:\MPV_Player\mpv_config-2026.04.14\mpv.exe` | mpv v0.41.0-460-g2f6561947 |

复测命令：

```powershell
$env:STREAMPATH_MPV_TEST_ROOT = 'C:\Users\YX\Documents\StreamPathProject\cross_version_testing\打包版本'
$env:STREAMPATH_PATH_MPV = 'D:\MPV_Player\mpv_config-2026.04.14\mpv.exe'
flutter test --no-pub test/mpv_version_compatibility_test.dart -r expanded
```

审查还额外启动了五个无媒体、无配置的隐藏测试进程，并真实连接每个 Windows named pipe：

- get_property mpv-version：五个版本全部成功；
- set_property cache：五个版本全部成功；
- set_property demuxer-seekable-cache：五个版本全部成功；
- set_property demuxer-max-bytes：五个版本全部成功；
- set_property cache-secs：五个版本全部成功。

测试进程均已精确退出，审查结束时没有命令行含 streampath_audit 或
streampath_cache_audit 的残留 MPV。

剩余未覆盖的是硬件解码、具体媒体编解码能力、用户自定义 mpv.conf 组合和真实远程视频
缓存压力；TS 时间轴、视频字幕、跨版本 watch_later、真实 file_error 与 idle 完成路径已
纳入当前实体套件。

## 4. 发布前必须修复

### SAFE-01：MPV PID 复用可能误杀无关进程（已修复）

- 级别：HIGH
- 置信度：高
- 证据：
  - lib/domain/services/external_player_service.dart:1508-1525、1616-1643、1735-1789
  - lib/domain/services/audio_player_service.dart:499-514、628-668
- 原因：
  - launchedHere 为 true 时可以绕过进程镜像校验直接 taskkill /T /F；
  - 恢复会话只保存 PID 和 pipe；
  - 回退校验只判断映像名是否包含 mpv。
- 触发：原 MPV 退出后 PID 被分配给无关进程或另一 MPV，随后执行 terminateSession。
- 影响：可能结束无关进程或另一会话的整个进程树。
- 最小修复：
  1. 启动时记录规范化 exe 绝对路径、PID、进程创建时间；
  2. MPV 会话额外用 GetNamedPipeServerProcessId 证明 named pipe 的服务 PID；
  3. 每次 taskkill 前重新匹配 PID、创建时间、exe 和 pipe；
  4. 任一证据缺失时失败关闭。
- 必补测试：
  - PID 被非 MPV 复用；
  - PID 被另一目录的 MPV 复用；
  - pipe 服务 PID 与历史 PID 不一致；
  - 身份查询失败时 taskkill 调用次数为 0。
- 实施结果：视频和音频统一保存 PID、规范化 exe 绝对路径与原始创建 FILETIME，MPV 再核对
  named pipe owner；同一进程句柄从身份读取一直持有到终止命令返回。证据缺失时返回类型化
  `refused/failed`，界面保留历史和会话，不调用终止器。

### SAFE-02：OpenList 重启身份没有绑定目标服务（已修复）

- 级别：HIGH
- 置信度：高
- 证据：lib/domain/services/openlist_process_restart_service.dart:95-132、248-317
- 原因：
  - 服务只有一个全局 _identity；
  - restart 本次找不到监听器时会回退任意旧身份；
  - validator 没有证明 PID 仍监听目标地址和端口。
- 触发：先捕获本机 A，再切换远程 B 或另一端口 B；B 没有本机监听器；B 进入第三次恢复。
- 影响：可能向 A 发送 Ctrl+C，错误重启无关本机实例。
- 最小修复：
  1. 用 normalized origin、resolved local address 和 port 作为 identity key；
  2. restart 必须取得同 key 的身份，禁止跨 key 回退；
  3. 发 Ctrl+C 前重新证明 listener 的 OwningProcess 等于记录 PID；
  4. 多监听器或地址歧义时失败关闭。
- 必补测试：A/B 端口切换、远程目标、并发 capture、监听 PID 更换、同端口多地址。
- 实施结果：身份按 normalized origin、resolved local address、port 分键，禁止跨 key 回退；
  发 Ctrl+C 前重新核对目标 listener owner。相同物理地址和端口的并发重启共享一个在途结果，
  只允许发送一次信号和启动一次进程。

### REC-01：播放恢复读取当前档案而不是启动快照（已修复）

- 级别：HIGH
- 置信度：高
- 证据：lib/domain/services/external_player_service.dart:78-125、259-285、506-538、1338-1430
- 原因：
  - runtime 只保存 username、password、profileId；
  - 失败处理读取 _configStore.current.openListRecovery；
  - 自动重拉起再次加载当前完整配置。
- 触发：A 档案开始播放后切换或编辑为 B，A 随后发生 MPV error。
- 影响：
  - 用 B 的恢复地址或凭据处理 A；
  - 可能重启 B 的 OpenList；
  - 用 B 的 PlayerConfig 重拉起 A；
  - 新 runtime 的 profileId 变成 B，后续进度写入串档。
- 最小修复：
  - 新建不可变 PlaybackLaunchContext，至少包含 PlayerConfig、serverUrl、
    OpenListRecoveryConfig、profileId、用户名和密码；
  - 首次 launch 保存该快照；
  - 恢复、取链、重启和自动重拉起只使用 runtime 快照。
- 必补测试：A 播放后切 B，再注入 A error；provider、restarter、参数和进度命名空间必须全部属于 A。
- 实施结果：首次启动深拷贝播放器、服务器、恢复配置、档案 ID 和 WebDAV 凭据；provider、
  restarter、自动重拉起与进度写入只使用 runtime 快照，切换 B 后仍完整属于 A。

### REC-02：终止型恢复结果被错误升级为第三次重启（已修复）

- 级别：HIGH
- 置信度：高
- 证据：
  - lib/domain/services/openlist_recovery_service.dart:164-178
  - lib/domain/services/external_player_service.dart:1356-1415
- 原因：
  - provider 在第二次强制刷新前发现媒体已可读，会返回 success=false 和“停止自动恢复”；
  - 外层把所有 success=false 都当成可重试，直接进入第三次本机重启。
- 影响：链接已恢复或错误不属于链接失效时，仍中断本机 OpenList。
- 最小修复：把布尔结果改为 ready、retryableFailure、terminalNotLinkFailure 等类型化 outcome。
- 必补测试：“第一次失败，第二次媒体已可读”，OpenList restart 调用次数必须为 0。
- 实施结果：恢复结果改为 `ready`、`retryableFailure`、`terminalNotLinkFailure`、
  `terminalFailure`；只有可重试失败能进入下一层，第二次已可读会立即停止且 restart 为 0 次。

### DATA-01：损坏媒体库会在下一次写入时被静默覆盖（已修复）

- 级别：HIGH
- 置信度：高
- 证据：
  - lib/data/local/media_library_store.dart:92-115、137-315、426-451
  - test/media_library_store_test.dart:319-325
- 原因：
  - media_library.json 读取失败后，四类数据被设为空并标记 _loaded=true；
  - 现有测试只验证读取阶段原文件未删除；
  - 下一次收藏、播放或最近目录 mutation 会用空状态整体重写文件。
- 影响：收藏、最近目录和长期播放历史可能静默丢失。
- 最小修复：
  1. 保存 loadFailed 或 corrupt 状态；
  2. 未保护原始文件前禁止 mutation 覆盖；
  3. 首次写入前把原字节原子隔离为唯一 .corrupt-时间戳.bak，或要求人工处理。
- 必补测试：损坏文件和瞬时读取失败后，分别执行四类 mutation，原文件或精确备份必须仍存在。
- 实施结果：Store 保存读取状态；损坏数据首次 mutation 前写入唯一 `.corrupt-*.bak` 并逐字节
  校验，未来 schema 与瞬时读取失败均拒绝写入。四类 mutation 和备份重名已覆盖。

### TOOL-01：脚本迁入 tools 后项目根和安全边界仍指向 tools（已修复）

- 级别：HIGH
- 置信度：高，已实际复现
- 证据：
  - tools/build.ps1:35-36、158-164
  - tools/package.ps1:14-17
  - tools/cleanup.ps1:21-29
  - tools/run.ps1:9-10
  - docs/README.md:338-370
- 影响：
  - build 实际编译成功后检查错误路径并返回失败；
  - package 的默认目录落入真实项目目录；
  - build 的安全校验错误地允许项目内部目标；
  - cleanup 默认清理 tools\stream_path_data，并把 tools 当禁止边界；
  - README 仍调用已从根目录删除的脚本。
- 最小修复：
  1. 每个脚本统一使用 Split-Path -Parent $PSScriptRoot 得到 ProjectRoot；
  2. 启动时断言 ProjectRoot\pubspec.yaml 存在；
  3. 构建产物、默认数据目录和禁止范围全部基于 ProjectRoot；
  4. README 改用 .\tools 下的实际脚本；
  5. 增加不会创建或删除真实目录的脚本路径烟雾测试。
- 验收：
  - 项目内部目标必须被拒绝；
  - 正常 Release 构建返回 0；
  - cleanup 默认目标必须是项目根的 stream_path_data；
  - 不得用真实用户数据验证 cleanup。
- 实施结果：四个脚本统一解析并验证真实 `ProjectRoot`；构建产物、默认数据目录和禁止范围均
  以项目根计算。cleanup 修正空 Label、显式 DataDir、重解析点与学习数据边界；脚本测试只使用
  临时假项目。

## 5. 第二批正确性与兼容性修复

本节保留审查时的根因、影响和最小修复建议，标题标注“已修复”的条目已经落地；实现结果
与测试证据以第 3、8、9 节为准。

### START-01：目录缓存打开异常会阻止整个应用启动（已修复）

- 级别：MEDIUM/HIGH
- 证据：
  - lib/data/local/directory_cache.dart:80-88
  - lib/main.dart:85、107
- 现状：purgeExpired 有降级捕获，但 Hive.openBox 位于 try 外；异常会从 main 冒出。
- 最小修复：把 openBox 纳入降级路径，保持 _box=null；缓存读写已经支持空 box。
- 测试：注入 openBox 失败，仍应进入基础 UI，WebDAV 缓存按未命中工作。

### SESSION-01：稳定 sessionId 的旧工件可能控制新播放（已修复）

- 级别：MEDIUM/HIGH
- 证据：
  - external_player_service.dart:402-429、1472-1488、1848-1859
  - audio_player_service.dart:138-153、680-705
  - mpv_scripts.dart:487-523
- 现状：
  - 磁盘文件名只有 sessionId，没有 launch epoch；
  - 启动只删除 progress，status 只在首行 -1 时删除，command 不清；
  - 删除失败仍继续使用原路径。
- 影响：旧 pause 可暂停新进程；删除失败时旧 error JSONL 可触发错误恢复。
- 最小修复：epoch 进入所有工件文件名和 JSONL 记录；清理失败也必须换新路径。
- 测试：预置旧 command、status、error JSONL 并模拟删除失败，新会话必须完全忽略。

### SESSION-02：idle=yes 会留下失去所有权的 MPV（已修复）

- 级别：MEDIUM
- 证据：
  - browser_page.dart:1223-1232、1570-1580
  - external_player_service.dart:1792-1800
  - audio_player_service.dart:517-520
- 现状：Lua 写出 -1 后，UI 使用 terminateProcess=false；releaseSession 只移除跟踪。
- 影响：用户模板包含 idle=yes 或 keep-open=yes 时，重复播放可积累空闲 MPV。
- 最小修复：自然完成且进程仍存活时精确终止；若决定支持 idle，则必须继续跟踪和复用。
- 测试：以 idle=yes 实体启动，完成后进程和会话所有权必须同时收敛。

### SESSION-03：终止、启动失败和页面失效的所有权回滚不完整（已修复）

- 级别：MEDIUM
- 证据：
  - external_player_service.dart:303-493、1735-1758
  - audio_player_service.dart:138-251、499-515
  - browser_page.dart:820-831、1020-1034
- 问题：
  - Process.start 失败后可能遗留 M3U、Lua、status、progress 和缓存会话；
  - terminateSession 先移除 runtime，再确认进程是否结束；
  - 视频 launch 完成时若页面已失效，没有镜像音频的终止回滚；
  - 旧恢复等待 provider 时，同 sessionId 的手动新启动可能在新 recovery state 登记前被旧结果覆盖。
- 最小修复：使用 launch ownership scope 和启动代际；进程确认退出前保持 terminating runtime；
  每个 await 后核对 runtime 所有权，过期恢复按自己的进程身份收敛；视频与音频对齐页面失效回滚。

### SESSION-04：进度同步并发和 JSONL 半行可能造成旧进度回写（已修复）

- 级别：MEDIUM
- 证据：
  - external_player_service.dart:1472-1488、1579-1596、1706-1709
  - mpv_playback_progress_sync.dart:260-304
  - audio_player_service.dart:442-445、541-551
- 问题：
  - 多个 _syncProgress 没有会话级串行化，较早的慢同步可能晚于新同步落库；
  - 行数游标先推进到 lines.length，读到未完成尾行时以后不会重读该行。
- 最小修复：每 runtime 串行同步并加代次；JSONL 改用只提交到最后完整换行的字节偏移。
- 测试：旧同步晚完成不得复活已完成记录；半行补全后必须被处理一次。

### OPEN-01：不能继续泛称“兼容全部 AList v3”（已修复）

- 级别：HIGH，属于兼容性声明问题
- 证据：
  - docs/README.md:7
  - settings_page.dart:1263-1287
  - openlist_index_service.dart:141-223
  - openlist_recovery_service.dart:321-453
- 最小修复：
  1. 把“产品可连接”与“搜索、索引更新、存储恢复”分开声明；
  2. 建立 OpenListCapabilities；
  3. 缺失能力时禁用对应 UI 并显示明确版本或端点提示；
  4. 不得把 update 缺失回退到 full build。

官方 tag 静态矩阵：

| 后端样本 | plain login | login/hash | fs/search | index progress | index update | storage/load_all | 结论 |
|---|---:|---:|---:|---:|---:|---:|---|
| AList v3.0.1～v3.5.1 | 是 | 否 | 否 | 否 | 否 | 否 | 仅基础 WebDAV；增强功能不可用 |
| AList v3.6.0 | 是 | 否 | 是 | 是 | 否 | 否 | 搜索和进度可用，更新和恢复不可用 |
| AList v3.7.1 | 是 | 否 | 是 | 是 | 是 | 是 | 端点齐全，但 update handler 在 AutoUpdate=false 时缺少 return |
| AList v3.63.0 | 是 | 是 | 是 | 是 | 是 | 是 | 当前契约静态匹配 |
| OpenList v4.0.0、v4.1.4、v4.2.5 | 是 | 是 | 是 | 是 | 是 | 是 | 当前契约静态匹配 |

官方源码：

- https://github.com/AlistGo/alist/blob/v3.0.1/server/router.go
- https://github.com/AlistGo/alist/blob/v3.6.0/server/router.go
- https://github.com/AlistGo/alist/blob/v3.7.1/server/router.go
- https://github.com/AlistGo/alist/blob/v3.7.1/server/handles/index.go
- https://github.com/AlistGo/alist/blob/v3.63.0/server/router.go
- https://github.com/OpenListTeam/OpenList/blob/v4.0.0/server/router.go
- https://github.com/OpenListTeam/OpenList/blob/v4.1.4/server/router.go
- https://github.com/OpenListTeam/OpenList/blob/v4.2.5/server/router.go

以上是接口源码核对，不是真实多版本服务集成。现有 OpenList/AList 测试都是注入式协议桩。

### OPEN-02：load_all 完成与成功冷却的语义错误（已修复）

- 级别：MEDIUM/HIGH
- 证据：openlist_recovery_service.dart:249-273、365-453
- 官方行为：
  - load_all 异步返回；
  - 单个存储 Drop 或 Load 失败只记录日志并继续；
  - 管理员存储列表可读取，不足以证明目标媒体已恢复。
- 当前问题：
  - 代码把列表请求成功表述为“全部启用存储已重新加载”；
  - 在最终媒体探测前写入五分钟成功冷却；
  - 媒体仍失败时，后续有效恢复会被冷却阻止。
- 最小修复：
  - 文案改为“刷新流程结束”；
  - 只有目标媒体最终探测成功才写成功冷却；
  - 如需限流，另设较短 attemptAt，不得冒充 success。
- 官方源码：
  - https://github.com/AlistGo/alist/blob/main/server/handles/storage.go
  - https://github.com/OpenListTeam/OpenList/blob/main/server/handles/storage.go

### OPEN-03：max_index_depth 读取失败时会静默提交错误深度（已修复）

- 级别：MEDIUM
- 证据：openlist_index_service.dart:325-340
- 当前行为：失败或畸形值回退 20，超过 1000 截断。
- 影响：用户配置的深层内容可能从增量索引中消失，UI 仍报告已提交。
- 最小修复：读取或解析失败时禁止 update；保留 -1 和服务端有效原值；移除无官方依据的 1000 上限。
- 测试：404、code 500、畸形、-1、5000，失败分支 update 请求数必须为 0。

### OPEN-04：生产 OpenList 请求没有 connectTimeout（已修复）

- 级别：MEDIUM
- 证据：
  - openlist_index_service.dart:444-504
  - openlist_recovery_service.dart:496-560
- 现状：只有 sendTimeout 和 receiveTimeout；黑洞地址可超过界面声称的 8～15 秒。恢复登录还
  把网络失败统一收敛为 terminal，且同后台在途刷新只按 base URI 合并，可能把一组凭据的
  认证失败传播给另一组凭据。
- 最小修复：设置 connectTimeout，并以单一 deadline 计算重定向和轮询剩余预算；登录结果区分
  瞬时网络失败与明确认证失败；失败的在途结果按非明文凭据指纹隔离。
- 测试：不可连接地址、每次重定向耗尽预算、PowerShell 或 WMI 超时。

### OPEN-05：诊断和 2FA 兼容缺口（已修复）

- 级别：MEDIUM
- 证据：
  - diagnostic_service.dart:293-348
  - openlist_index_service.dart:342-383
- 问题：
  - 诊断只检查 HTTP 2xx，不验证 JSON code==200，HTML 200 或 code 500 会假阳性；
  - 普通用户索引登录没有 otp_code 或独立普通用户 Token，2FA 账号搜索失败。
- 最小修复：
  - 解析官方 envelope；
  - 为搜索提供最小权限普通用户 Token，不能复用管理员 Token；
  - code 402 显示明确 2FA 指引。

### WEB-01：跨来源 PROPFIND 仍会发送到新来源（已修复）

- 级别：LOW/MEDIUM
- 证据：webdav_client.dart:117-159
- 已确认：跨来源时 Basic 认证会被正确移除，没有凭据泄露。
- 剩余风险：仍向重定向目标发送 PROPFIND + Depth，可能访问错误来源或形成客户端 SSRF。
- 最小修复：非 GET 请求遇到跨来源重定向直接失败；目标服务器应收到零次请求。

## 6. 性能修复清单

以下“现状”描述均是审查快照，用于解释为何需要对应改动；所有 PERF 条目当前均已修复，
并有查询次数、构建次数、目录枚举次数或探活状态测试作为证据。

### PERF-01：单 URL 进度通知会重扫视频和音频两条历史（已修复）

- 级别：MEDIUM，优先级最高的性能修复
- 置信度：高
- 证据：media_library_page.dart:193-242、281-310
- 现状：
  - 已按 URL 调用 _refreshProgressLane；
  - 随后仍无条件对视频和音频调用 _loadProgressLane；
  - 当有效继续播放项很少时，每条历史最多 2000 条，一次通知可接近 4000 次 SQLite 查询。
- 最小修复：
  1. 对应分栏没有变更时完全跳过；
  2. 目标更新后仍有效时不全扫；
  3. 仅在目标被移除且需要补位时扫描候选。
- 测试：计数型进度服务；普通更新只允许读取目标 URL，另一分栏读取数必须为 0。

### PERF-02：设置页高频状态重建七个隐藏表单（已修复）

- 级别：MEDIUM
- 证据：settings_page.dart:879-913、2471-2480、2780-2827、2906-2911
- 现状：索引运行时每两秒页面级 setState；滑块每个采样也页面级 setState；IndexedStack 七个子树全部重建。
- 最小修复：先把索引卡和界面外观控件局部化；保留七套 FormKey 和隐藏页验证。
- 测试：分类 build 计数；服务器轮询不得重建非服务器页，滑块不得重建非界面页。

### PERF-03：访问型搜索先全量物化、全量排序，再取 200（已修复）

- 级别：MEDIUM，需先做基准
- 证据：
  - directory_cache.dart:169-214
  - media_library_search.dart:44-99
- 现状：最多 512 个目录快照，单快照条目无界；搜索在 UI isolate 创建对象、去重、收集全部匹配并排序。
- 最小修复：先在构造 MediaLibraryItem 前做廉价过滤；使用保持现有排序规则的有界 top-k；必要时移出 UI isolate。
- 验收：大规模合成快照的结果顺序与当前实现一致，并设置时间和分配上界。

### PERF-04：watch_later 同步近似 O(N×D)（已修复）

- 级别：MEDIUM
- 证据：
  - mpv_playback_progress_sync.dart:213-256
  - mpv_watch_later_sync.dart:38-81、221-255
- 现状：每个列表项分别查 start 和 duration；MD5 未命中时反复枚举并读取整个目录。
- 最小修复：一次枚举建立 URL/hash 到记录索引，一次解析 start/duration；切集只同步受影响项。
- 测试：计数目录枚举和文件读取次数，N 条媒体不得触发 N 次全目录扫描。

### PERF-05：无状态变化通知和重复探活（已修复）

- 级别：LOW
- 证据：
  - directory_browser_controller.dart:108-137、183-240
  - browser_page.dart:294-301、555-623
  - external_player_service.dart:1281-1292、1549-1575
- 问题：
  - 普通 load 和搜索可能连续发出多次无状态变化通知；
  - UI、服务 watcher 和 activation guard 各自运行 tasklist；
  - 探活异常统一返回 alive，持续失败时可无界轮询。
- 最小修复：仅在可观察状态变化时通知；每会话集中为单一探活流；unknown 状态退避并保留明确所有权。

## 7. 已完成的冗余清理与保留边界

以下项目已在对应测试就位后删除或收敛；保留项说明了不能继续删减的边界：

| 项目 | 证据与处理 |
|---|---|
| `sqflite` 直接依赖 | 已删除；Windows 仍保留 `sqflite_common_ffi` 与 `sqlite3` Native Assets。 |
| `hive_flutter` | 已删除；直接使用 `hive` 完成初始化。 |
| 七个零行为设置表单子类 | 已合并为带 `sectionName` 的 `SettingsCategoryForm`，保留各 `FormKey`。 |
| `PlaybackSessionPresenter.changed` | 已删除无调用者声明。 |
| `OpenListIndexEntry.modified` | 已删除；索引结果不伪造修改时间。 |
| 空搜索的重复 Timer | 已删除；空查询直接返回，不创建 debounce Timer。 |
| `assets/icon/app_icon.ico` | 已删除；Runner 实际使用 `windows/runner/resources/app_icon.ico`，`assets/icon/icon.png` 保留为源素材。 |
| `CachePolicyProvider.lastResultFor` 与 `_lastResults` | 已删除无调用者接口和映射。 |
| `PlaybackSample.cacheUsedBytes` 与旧状态字段 | 已删除；视频状态协议收敛为十三行。 |
| OpenList 两套 transport/auth/envelope | 已合并为 `openlist_api_client.dart`，统一 envelope、deadline、重定向、认证和能力矩阵。 |

assets/icon/icon.png 应保留为 Runner 图标源素材，并在文档注明生成用途。

### 不应误删

- _libraryGeneration、_progressGeneration、_searchGeneration：三条异步链必须独立。
- 视频与音频服务、SQLite、watch_later、状态文件：承担故障隔离，不是重复实现。
- TS 起播先禁缓存、稳定后小缓存的两阶段逻辑：有明确起播性能目的。
- 七套 FormKey、ScrollController、PageStorageKey：承担独立验证和滚动状态。
- sqlite3 的直接 dev 约束：sqflite_common_ffi 和 Native Assets 仍需要。
- app_translation_catalog.dart：是四语言完整键表，不应仅因行数大而删除。
- `launchEpoch`：同时承担内存 watcher 和磁盘工件 ABA 防护，不能退回稳定 sessionId。
- 学习数据不自动过期：是明确产品策略，不应按普通缓存删除。

## 8. 建议修复顺序

### 阶段 0：先建立失败测试（已完成）

每个问题先写能稳定失败的最小测试，不先改实现：

1. [x] PID 复用终止测试；
2. [x] OpenList A/B 身份错配测试；
3. [x] A 播放后切 B 的恢复快照测试；
4. [x] terminal recovery 不重启测试；
5. [x] 损坏 media_library 后 mutation 测试；
6. [x] tools 项目根和安全范围测试。

### 阶段 1：安全、数据和发布链（已完成）

按 SAFE-01、SAFE-02、REC-01、REC-02、DATA-01、TOOL-01 顺序逐项修复。
每修复一个 Bug，在 docs/BUGRECODE.md 追加一行简明中文记录。

阶段门槛：

- 相关负向测试通过；
- flutter analyze --no-pub 通过；
- flutter test --no-pub 全量通过；
- Windows Release 构建通过；
- 不执行真实用户 OpenList 重启。

### 阶段 2：OpenList/AList 能力兼容（已完成）

- [x] `OpenListApiClient` 统一 transport、认证、JSON envelope、HTTP 2xx/`code=200` 校验、
  同源重定向、connect/send/receive timeout 和单一总 deadline。
- [x] `OpenListCapabilities` 按已核验版本分级，未知版本保持 `unknown`；设置页分别展示
  搜索、索引进度、增量更新和存储恢复，缺失 update 不回退全量构建。
- [x] 普通用户 Token、管理员 Token 会话和 2FA 提示按 profile 与凭据指纹隔离；
  `max_index_depth` 读取失败或畸形时禁止提交 update；load_all 只有目标媒体最终可读才记
  成功冷却。
- [x] 隔离契约矩阵 7/7 通过：AList 3.0.1、3.6.0、3.7.1、3.63.0，OpenList 4.0.0、
  4.1.4、4.2.5。真实 5244 实例仅做只读公开设置快照。

### 阶段 3：MPV 会话正确性（已完成）

- [x] 每次启动生成 `launchEpoch` 并进入状态、命令、JSONL、Lua、M3U/M3U8、LRC 和
  watch_later 工件；启动入口立即 claim，双启动和中止路径验证所有权。
- [x] 视频、音频各自使用 `PlayerProcessLivenessTracker`；PID、exe、创建时间和 pipe
  身份绑定，unknown 不触发清理、终止或自动恢复。
- [x] `SessionProgressSyncCoordinator` 串行合并进度；JSONL 使用完整 UTF-8 字节游标；
  watch_later 单次索引，MD5 直达优先；自然完成写入 idle marker 并保留最后播放位置。
- [x] 五个实体 MPV 的 Lua、named pipe、动态缓存 set_property、TS、字幕、watch_later、
  file_error、idle 和音频 LRC/封面测试通过。

### 阶段 4：性能（已完成）

- [x] PERF-01～05 均有查询次数、局部 build、top-k 基准、目录枚举或共享探活测试；
  PERF-05 的 unknown 采用有限指数退避并在终止路径安全拒绝。
- [x] 65536 条访问型搜索基准保持结果等价，候选峰值 200；watch_later 与单 URL 进度更新
  不再重复扫描无关数据。

### 阶段 5：冗余清理和文档（已完成）

- [x] 删除 `hive_flutter`、直接 `sqflite`、无调用者 API/字段、空 debounce Timer 和旧 ICO；
  状态协议已收敛为十三行。
- [x] 已同步 `docs/README.md`、`docs/PROJECT.md`、`docs/HANDOFF.md`、`docs/BUGRECODE.md`、
  `pubspec.lock` 与真实脚本/MPV 路径示例。

## 9. 最终验收清单

- [x] 当前工作树基线中的既有改动均被保留。
- [x] 每个阶段 1 高风险问题都有先失败、后通过的负向测试。
- [x] 进程终止前验证 PID、创建时间、exe 和 pipe。
- [x] OpenList 重启身份与 origin、address、port 绑定。
- [x] 恢复全程使用 launch snapshot。
- [x] terminalNotLinkFailure 不会进入第三次重启。
- [x] 损坏媒体库不会在后续 mutation 时丢失原始字节。
- [x] tools 脚本使用真实 ProjectRoot，项目内部打包目标被拒绝。
- [x] AList v3 能力按版本或端点分级展示。
- [x] load_all 只有目标媒体恢复后才记成功冷却。
- [x] max_index_depth 读取失败时不发送 update。
- [x] OpenList 请求具有 connectTimeout 和总 deadline。
- [x] 单 URL 进度变化不扫描无关分栏。
- [x] 设置页高频状态不重建七个分类。
- [x] watch_later 不再对每一项重复扫描目录。
- [x] 五个 MPV 的真实 IPC 和缓存 set_property 自动化通过。
- [x] 四个隔离 AList/OpenList 契约样本和三个 OpenList v4 样本均通过矩阵测试。
- [x] flutter analyze --no-pub 通过。
- [x] flutter test --no-pub 全量通过（745 项通过，3 项条件式跳过）。
- [x] flutter build windows --release --no-pub 通过。
- [x] Release 含 data/app.so，不含 Debug kernel_blob.bin。
- [x] git diff --check 无错误。
- [x] docs/BUGRECODE.md 已记录阶段 0～5 的修复。
- [x] 没有对真实 5244 OpenList 实例执行破坏性测试。

## 10. 后续复测指令

后续聊天应先完整阅读本文、`docs/PROJECT.md`、`docs/README.md` 和 `docs/BUGRECODE.md`，
保留当前工作树全部改动。默认只执行回归和新增兼容样本，不重复实施阶段 0～5；不得停止、
重启或调用真实 5244 OpenList 的管理 API，也不得终止用户 MPV。MPV 实体复测使用：

```powershell
$env:STREAMPATH_MPV_TEST_ROOT = 'C:\Users\YX\Documents\StreamPathProject\cross_version_testing\打包版本'
$env:STREAMPATH_PATH_MPV = 'D:\MPV_Player\mpv_config-2026.04.14\mpv.exe'
flutter test --no-pub test/mpv_version_compatibility_test.dart -r expanded
```

代码变更仍需追加一行中文 BUGRECODE，并在交付前执行 `flutter analyze --no-pub`、
`flutter test --no-pub -r compact`、Windows Release 构建和 `git diff --check`。
