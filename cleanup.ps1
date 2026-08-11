# =============================================================
# StreamPath 快速清理脚本
# 功能：清除缓存、日志、播放进度、播放历史、watch_later 等数据，
#       防止旧数据干扰功能正常运行。
# 保留：config/ 下的连接、播放器、缓存策略与智能缓存配置
#
# 用法（在项目根目录）：
#   powershell -ExecutionPolicy Bypass -File .\cleanup.ps1
#   # 保留播放历史（继续播放入口）时：
#   powershell -ExecutionPolicy Bypass -File .\cleanup.ps1 -KeepHistory
#   # 仅清理指定数据目录（测试用，默认项目根下 stream_path_data）：
#   powershell -ExecutionPolicy Bypass -File .\cleanup.ps1 -DataDir <路径>
# =============================================================

param(
    [switch]$KeepHistory,   # 保留 playback_history.json（继续播放记录）
    [string]$DataDir        # 数据目录（默认 <项目根>/stream_path_data）
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($PSScriptRoot)
if (-not $DataDir) {
    $DataDir = Join-Path $Root 'stream_path_data'
}
$DataDir = [IO.Path]::GetFullPath($DataDir)
$ForbiddenRoots = @(
    [IO.Path]::GetPathRoot($DataDir),
    $Root,
    [IO.Path]::GetFullPath($env:USERPROFILE),
    [IO.Path]::GetFullPath($env:APPDATA)
)
if ($ForbiddenRoots | Where-Object {
        [string]::Equals($_, $DataDir, [StringComparison]::OrdinalIgnoreCase)
    }) {
    throw "拒绝清理不安全的数据目录：$DataDir"
}
if (Test-Path -LiteralPath $DataDir) {
    $DataItem = Get-Item -LiteralPath $DataDir -Force
    if (-not $DataItem.PSIsContainer -or
        (($DataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "数据目录无效或为重解析点：$DataDir"
    }
}
$CacheDir = Join-Path $DataDir 'cache'
$DataPrefix = $DataDir.TrimEnd([IO.Path]::DirectorySeparatorChar) +
    [IO.Path]::DirectorySeparatorChar

function Remove-ValidatedItem {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AllowedPrefix,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $FullPath = [IO.Path]::GetFullPath($Path)
    if (-not $FullPath.StartsWith(
            $AllowedPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "拒绝删除允许目录以外的目标：$FullPath"
    }
    $Item = Get-Item -LiteralPath $FullPath -Force
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "拒绝删除重解析点：$FullPath"
    }
    Remove-Item -LiteralPath $FullPath -Recurse -Force
    Write-Host "  已删除${Label}: $FullPath"
}

Write-Host '=== StreamPath 数据清理 ===' -ForegroundColor Cyan
Write-Host "数据目录: $DataDir"

# ── 1. cache/ 子目录内的缓存/动态数据（配置目录 config/ 不受影响） ──
$targets = @(
    'streampath.db',            # 播放进度 SQLite
    'directory_cache',          # Hive 目录缓存（目录形式）
    'directory_cache.hive',     # Hive 目录缓存（散落文件形式）
    'directory_cache.lock',
    'mpv-current.txt',          # 旧版 MPV 当前播放状态上报
    'mpv-command.txt',          # 旧版软件下发命令文件
    'mpv-current-*.txt',        # 分会话 MPV 当前播放状态上报
    'mpv-command-*.txt',        # 分会话软件下发命令文件
    'mpv-progress-*.jsonl',     # 分会话逐媒体播放结果
    'mpv-watch-later',          # MPV watch_later 续播记录
    'streampath-playlist.m3u',  # 多集播放列表临时文件
    'streampath-playlist-*.m3u',# 分会话播放列表临时文件
    '*.lua',                    # 会话 Lua 脚本产物
    'mpv-scripts',              # 脚本基础目录
    'mpv.log',                  # MPV 日志
    'media_metadata.json',      # 缓存系统媒体元数据
    'cache_intelligence_learning.json', # 智能缓存聚合学习数据
    'clipboard_history_fix.log' # 剪贴板诊断日志
)
if (-not $KeepHistory) {
    $targets += 'playback_history.json'  # 播放历史（继续播放入口）
} else {
    Write-Host '已指定 -KeepHistory：保留 playback_history.json' -ForegroundColor Yellow
}

# 新布局：cache/ 子目录；旧平铺布局残留（迁移失败等）同样清理。
$scopes = @($CacheDir, $DataDir)
foreach ($scope in $scopes) {
    if (-not (Test-Path -LiteralPath $scope -PathType Container)) {
        continue
    }
    $ScopeItem = Get-Item -LiteralPath $scope -Force
    if (($ScopeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "拒绝枚举重解析点目录：$scope"
    }
    $Children = @(Get-ChildItem -LiteralPath $scope -Force)
    foreach ($t in $targets) {
        foreach ($Candidate in @($Children | Where-Object { $_.Name -like $t })) {
            if (Test-Path -LiteralPath $Candidate.FullName) {
                Remove-ValidatedItem -Path $Candidate.FullName `
                    -AllowedPrefix $DataPrefix -Label ''
            }
        }
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
    if (Test-Path -LiteralPath $path) {
        $LegacyParent = [IO.Path]::GetFullPath((Split-Path $path -Parent))
        $LegacyPrefix = $LegacyParent.TrimEnd(
            [IO.Path]::DirectorySeparatorChar
        ) + [IO.Path]::DirectorySeparatorChar
        Remove-ValidatedItem -Path $path -AllowedPrefix $LegacyPrefix `
            -Label '(旧位置)'
    }
}

# ── 3. 结果 ──
Write-Host ''
Write-Host '清理完成。当前数据目录内容：' -ForegroundColor Green
foreach ($sub in @('cache', 'config')) {
    $dir = Join-Path $DataDir $sub
    if (Test-Path -LiteralPath $dir) {
        Write-Host "  [$sub/]"
        Get-ChildItem $dir | Select-Object Name, Length | Format-Table -AutoSize
    } else {
        Write-Host "  [$sub/] (不存在，应用首次运行时会自动创建)"
    }
}
Write-Host '保留: config/ 下的全部用户配置' -ForegroundColor Green
