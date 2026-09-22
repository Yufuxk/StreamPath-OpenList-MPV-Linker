# 第 7 条故障注入验收工具

本目录保存可复用的验收脚本；运行时控制文件、日志、探测结果和证据仍写入 `%TEMP%\sp_accept\`。
清理系统临时文件不会丢失脚本，只会清除可重新生成的验收产物。

首次使用时把 `config.example.json` 复制为 `local_config.json` 并填写本机代理、StreamPath
profile 和验收媒体信息。`local_config.json` 位于项目目录但已被 Git 忽略；密码不会写入该文件，
代理仍从 Windows Credential Manager 读取。

## 组成

- `proxy.py`：双端口 WebDAV 故障注入代理。
- `acceptance_control.py`：带唯一 `arm_id` 的单次注入状态机。
- `control_cli.py`：启动探测脚本使用的原子 arm/disarm 命令入口。
- `item7_round.py`：播放中故障的确定性回合控制器。
- `journal_copier.py`：独立的提前证据镜像器；正常情况下由 `item7_round.py` 内置镜像代替。
- `mpvkey2.ps1`：按 PID 精确向 MPV 发送按键。
- `run_helper_probe.ps1`：启动探测故障的 helper 级验证。
- `verify_proxy_control.py`：使用既有媒体路径执行只读的 arm/竞争写入/单次命中集成检查。
- `align_check.py`、`show_run.py`、`wait_round.py`：归档检查辅助。
- `legacy/`：已停用或被更精确脚本替代的历史交互工具。

## 播放中故障回合

先启动代理：

```powershell
python .\tools\acceptance\item7\proxy.py
```

在应用中通过验收代理开始播放并稳定后运行：

```powershell
python .\tools\acceptance\item7\item7_round.py msc_01 midstream_cut
python .\tools\acceptance\item7\item7_round.py rc_01 remote_changed
```

控制器会依次执行：无注入 J 验证代理链路、原子写入并回读 `arm_id`、连续 J 直到相同
`arm_id` 的代理请求实际命中、停止输入、等待 60 秒并持续镜像证据。如果链路未经过代理、
控制权被其他回合占用或注入未命中，脚本会终止并明确标记本轮禁止判定。

最终通过仍须核对事件流为 `end-file`、journal 为 `position`，且不存在 `title-eof`、
`completed`、崩溃事件或新转储。

`run_helper_probe.ps1` 会为非 `baseline` 模式自动创建独占 `arm_id`，并在 helper 退出后解除；
无需再手工改写 `proxy_control.json`。
