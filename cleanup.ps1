# =============================================================
# StreamPath 快速清理脚本
# 功能：清除缓存、日志、播放进度、播放历史、watch_later 等数据，
#       防止旧数据干扰功能正常运行。
# 保留：stream_path_config.json（服务器/播放器/隐藏后缀等用户配置）
#
# 用法（在项目根目录）：
#   powershell -ExecutionPolicy Bypass -File .\cleanup.ps1
#   # 保留播放历史（继续播放入口）时：
#   powershell -ExecutionPolicy Bypass -File .\cleanup.ps1 -KeepHistory
# =============================================================

param(
    [switch]$KeepHistory   # 保留 playback_history.json（继续播放记录）
)

$ErrorActionPreference = 'SilentlyContinue'
$Root = $PSScriptRoot
$DataDir = Join-Path $Root 'stream_path_data'

Write-Host '=== StreamPath 数据清理 ===' -ForegroundColor Cyan
Write-Host "数据目录: $DataDir"

# ── 1. 数据目录内的缓存/动态数据（保留 stream_path_config.json） ──
$targets = @(
    'streampath.db',            # 播放进度 SQLite
    'directory_cache',          # Hive 目录缓存（目录形式）
    'directory_cache.hive',     # Hive 目录缓存（散落文件形式）
    'directory_cache.lock',
    'mpv-current.txt',          # 旧版 MPV 当前播放状态上报
    'mpv-command.txt',          # 旧版软件下发命令文件
    'mpv-current-*.txt',        # 分会话 MPV 当前播放状态上报
    'mpv-command-*.txt',        # 分会话软件下发命令文件
    'mpv-watch-later',          # MPV watch_later 续播记录
    'streampath-playlist.m3u',  # 多集播放列表临时文件
    'clipboard_history_fix.log' # 剪贴板诊断日志
)
if (-not $KeepHistory) {
    $targets += 'playback_history.json'  # 播放历史（继续播放入口）
} else {
    Write-Host '已指定 -KeepHistory：保留 playback_history.json' -ForegroundColor Yellow
}

foreach ($t in $targets) {
    $path = Join-Path $DataDir $t
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force
        Write-Host "  已删除: $t"
    }
}

# ── 2. 旧位置残留（历史版本散落的数据） ──
$legacyPaths = @(
    (Join-Path $Root 'clipboard_history_fix.log'),
    (Join-Path $env:USERPROFILE 'clipboard_history_fix.log'),
    (Join-Path $env:APPDATA 'com.streampath\streampath\mpv-watch-later'),
    (Join-Path $env:APPDATA 'com.streampath\streampath\streampath.db'),
    (Join-Path $env:APPDATA 'com.streampath\streampath\directory_cache'),
    (Join-Path $env:APPDATA 'com.streampath\streampath\directory_cache.hive'),
    (Join-Path $env:APPDATA 'com.streampath\streampath\directory_cache.lock'),
    (Join-Path $env:APPDATA 'com.streampath\streampath\clipboard_history_fix.log'),
    (Join-Path $env:APPDATA 'com.streampath\streampath\player_config.json'),
    (Join-Path $env:APPDATA 'com.streampath\streampath\connection_config.json')
)
foreach ($path in $legacyPaths) {
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force
        Write-Host "  已删除(旧位置): $path"
    }
}

# ── 3. 结果 ──
Write-Host ''
Write-Host '清理完成。当前数据目录内容：' -ForegroundColor Green
if (Test-Path $DataDir) {
    Get-ChildItem $DataDir | Select-Object Name, Length | Format-Table -AutoSize
} else {
    Write-Host '  (数据目录不存在，首次运行时会自动创建)'
}
Write-Host '保留: stream_path_config.json（服务器/播放器/隐藏后缀配置）' -ForegroundColor Green
