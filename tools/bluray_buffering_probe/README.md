# 蓝光第三轮供数诊断

本目录只用于研究和隔离测试，不参与应用构建或播放器启动。直接编译当前 `bridge_core.cpp`，不复制或修改生产实现。

```powershell
cmake -S tools/bluray_buffering_probe -B build/bluray-round3-analysis/native -G "Visual Studio 17 2022" -A x64
cmake --build build/bluray-round3-analysis/native --config Release
& build/bluray-round3-analysis/native/Release/bluray_buffering_probe.exe
& build/bluray-round3-analysis/native/Release/bluray_buffering_probe.exe --timed
& build/bluray-round3-analysis/native/Release/bluray_buffering_probe.exe --timed 1000
& build/bluray-round3-analysis/native/Release/bridge_core_regression.exe
python tools/bluray_buffering_probe/analyze_archives.py stream_path_data/cache/iso_benchmarks --latest 4 --output build/bluray-round3-analysis/archive-summary.json
```

默认探针重复三轮，检查：冷态 2 MiB 需求读形成八次 256 KiB fetch；完整预读块可在响应尾部结束前被消费；已缓存回读本身保留预读，而显式 `reset_read_ahead()` 会取消在途预读但保留播放 generation；16 MiB 短窗口推进 8 MiB 时，当前标题规则尚不补充，而启用既有半窗补充规则的对照已补充。这些是机制验证，不证明用户的每次卡顿已归因于门槛或重置。

探针另含一个反例：保持标题补充门槛不变，只把稳定批次改为 32 MiB，在 16 MiB 短窗口下走到边界仍未补充，随后出现新的前台 fetch。因此不能直接全局放大批次；方案必须先解开“批次上限”和“补充门槛”的耦合，并保留短窗口行为回归。

还检查提前补充的代价：16 MiB 窗口同样推进 48 MiB、同样预取 64 MiB，当前规则为 7 次请求，单纯半窗补充为 10 次。提前补充不能单独视为已经满足“减少请求”的方案，必须与传输合批联合验证；若最终增加实际来源请求，不应采用。

`--timed` 交替运行三组 16／32 MiB 批次：单预读 worker、56 MiB 容量、48 MiB 窗口、192 MiB 合成来源、600 ms 请求头等待、12 MiB/s 正文、目标 9 MiB/s 消费；第三个参数可将请求头等待改为 1000 ms。初始批次均为 2 MiB、过渡批次均为 8 MiB，先取得相同的 8 MiB 连续预读后开始消费计时。prefill 时间另报，不能冒充 GUI 起播时间；应从实际耗时核对消费速度，不能将定时调度目标当作实测速率。

计时探针使用内存 BlockSource；没有真实 HTTP、TLS、重定向、WinFsp、libbluray 或 MPV。`readWait` 是阻塞式消费者的等待，不等于 MPV 缓冲或显示卡顿。32 MiB 仅使用既有构造参数做机制对照；当前生产 WinHTTP 校验上限为 16 MiB，尚不能直接使用这个参数。运行时不要并行构建或执行其他压力测试。

归档分析器只读来源，输出白名单数值、会话名称和来源文件 SHA-256，不输出媒体 URL、凭据或签名参数。未配对、重复和截断事件单列；快照水位与事件时间并不一致，不能据其证明事件瞬间存在可用数据。`--latest` 按目录最后修改时间选择，复验时应核对所选会话。
