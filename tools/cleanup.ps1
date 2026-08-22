# =============================================================
# StreamPath 快速清理脚本
# 功能：清除缓存、日志、播放进度、播放历史、watch_later 等数据，
#       防止旧数据干扰功能正常运行。
# 保留：config/ 下的连接、播放器、缓存策略与智能缓存配置
#
# 用法（在项目根目录）：
#   powershell -ExecutionPolicy Bypass -File .\tools\cleanup.ps1
#   # 保留播放历史（继续播放入口）时：
#   powershell -ExecutionPolicy Bypass -File .\tools\cleanup.ps1 -KeepHistory
#   # 仅清理指定数据目录（测试用，默认项目根下 stream_path_data）：
#   powershell -ExecutionPolicy Bypass -File .\tools\cleanup.ps1 -DataDir <路径>
# =============================================================

param(
    [switch]$KeepHistory,   # 保留 playback_history.json（继续播放记录）
    [string]$DataDir        # 数据目录（默认 <项目根>/stream_path_data）
)

$ErrorActionPreference = 'Stop'
$ExplicitDataDir = $PSBoundParameters.ContainsKey('DataDir')
$ScriptRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$ProjectRoot = [IO.Path]::GetFullPath((Split-Path $ScriptRoot -Parent))
$ProjectMarker = Join-Path $ProjectRoot 'pubspec.yaml'
if (-not (Test-Path -LiteralPath $ProjectMarker -PathType Leaf)) {
    throw "无法确认 StreamPath 项目根：$ProjectRoot"
}

function Test-SamePathOrContainsProtectedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$ProtectedPath
    )
    if ([string]::Equals(
            $Candidate,
            $ProtectedPath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        return $true
    }
    $CandidatePrefix = $Candidate.TrimEnd(
        [IO.Path]::DirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    return $ProtectedPath.StartsWith(
        $CandidatePrefix,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Assert-NoReparsePointInPathChain {
    param([Parameter(Mandatory = $true)][string]$Path)

    $FullPath = [IO.Path]::GetFullPath($Path)
    $PathRoot = [IO.Path]::GetPathRoot($FullPath)
    $RelativePath = $FullPath.Substring($PathRoot.Length)
    $Cursor = $PathRoot
    foreach ($Segment in [Regex]::Split($RelativePath, '[\\/]+')) {
        if ([string]::IsNullOrWhiteSpace($Segment)) {
            continue
        }
        $Cursor = Join-Path $Cursor $Segment
        if (-not (Test-Path -LiteralPath $Cursor)) {
            break
        }
        $Item = Get-Item -LiteralPath $Cursor -Force
        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "目标路径经过重解析点：$($Item.FullName)"
        }
    }
}

if (-not $DataDir) {
    $DataDir = Join-Path $ProjectRoot 'stream_path_data'
}
$DataDir = [IO.Path]::GetFullPath($DataDir)
$ProtectedPaths = @($ProjectRoot)
foreach ($EnvironmentPath in @(
        $env:USERPROFILE,
        $env:APPDATA,
        $env:LOCALAPPDATA
    )) {
    if (-not [string]::IsNullOrWhiteSpace($EnvironmentPath)) {
        $ProtectedPaths += [IO.Path]::GetFullPath($EnvironmentPath)
    }
}
if ([string]::Equals(
        [IO.Path]::GetPathRoot($DataDir),
        $DataDir,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "拒绝清理驱动器根目录：$DataDir"
}
foreach ($ProtectedPath in $ProtectedPaths) {
    if (Test-SamePathOrContainsProtectedPath `
            -Candidate $DataDir -ProtectedPath $ProtectedPath) {
        throw "拒绝清理包含受保护目录的路径：$DataDir"
    }
}
Assert-NoReparsePointInPathChain -Path $DataDir
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
        [AllowEmptyString()][string]$Label = ''
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
    Assert-NoReparsePointInPathChain -Path $FullPath
    if ($Item.PSIsContainer) {
        $NestedReparsePoint = Get-ChildItem -LiteralPath $FullPath `
                -Recurse -Force -ErrorAction Stop |
            Where-Object {
                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            } |
            Select-Object -First 1
        if ($null -ne $NestedReparsePoint) {
            throw "拒绝递归删除包含重解析点的目录：$($NestedReparsePoint.FullName)"
        }
    }
    Remove-Item -LiteralPath $FullPath -Recurse -Force
    $DisplayLabel = if ([string]::IsNullOrWhiteSpace($Label)) {
        ''
    } else {
        " $Label"
    }
    Write-Host "  已删除${DisplayLabel}: $FullPath"
}

Write-Host '=== StreamPath 数据清理 ===' -ForegroundColor Cyan
Write-Host "数据目录: $DataDir"

# ── 1. cache/ 子目录内的缓存/动态数据（配置目录 config/ 不受影响） ──
$targets = @(
    'streampath.db',            # 播放进度 SQLite
    'audio_streampath.db',      # 音频播放进度 SQLite
    'directory_cache',          # Hive 目录缓存（目录形式）
    'directory_cache.hive',     # Hive 目录缓存（散落文件形式）
    'directory_cache.lock',
    'mpv-current.txt',          # 旧版 MPV 当前播放状态上报
    'mpv-command.txt',          # 旧版软件下发命令文件
    'mpv-current-*.txt',        # 分会话 MPV 当前播放状态上报
    'mpv-command-*.txt',        # 分会话软件下发命令文件
    'mpv-progress-*.jsonl',     # 分会话逐媒体播放结果
    'mpv-audio-current-*.txt',  # 音频分会话状态上报
    'mpv-audio-command-*.txt',  # 音频分会话命令通道
    'mpv-audio-progress-*.jsonl',# 音频分会话播放结果
    'mpv-watch-later',          # MPV watch_later 续播记录
    'mpv-audio-watch-later',    # 音频 MPV watch_later 续播记录
    'streampath-playlist.m3u',  # 多集播放列表临时文件
    'streampath-playlist-*.m3u',# 分会话播放列表临时文件
    'streampath-audio-playlist-*.m3u8',# 音频分会话播放列表
    '*.lua',                    # 会话 Lua 脚本产物
    'mpv-scripts',              # 脚本基础目录
    'mpv.log',                  # MPV 日志
    'media_metadata.json',      # 缓存系统媒体元数据
    'clipboard_history_fix.log' # 剪贴板诊断日志
)
if (-not $KeepHistory) {
    $targets += 'playback_history.json'  # 播放历史（继续播放入口）
    $targets += 'audio_playback_history.json' # 音频播放历史
} else {
    Write-Host '已指定 -KeepHistory：保留视频与音频播放历史' -ForegroundColor Yellow
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
# 显式 -DataDir 用于隔离清理，不得越界处理真实用户旧目录。
if (-not $ExplicitDataDir) {
    $legacyPaths = @(
        (Join-Path $ProjectRoot 'clipboard_history_fix.log'),
        (Join-Path $env:USERPROFILE 'clipboard_history_fix.log'),
        (Join-Path $env:APPDATA 'com.streampath\streampath\mpv-watch-later'),
        (Join-Path $env:APPDATA 'com.streampath\streampath\streampath.db'),
        (Join-Path $env:APPDATA 'com.streampath\streampath\directory_cache'),
        (Join-Path $env:APPDATA 'com.streampath\streampath\directory_cache.hive'),
        (Join-Path $env:APPDATA 'com.streampath\streampath\directory_cache.lock'),
        (Join-Path $env:APPDATA 'com.streampath\streampath\clipboard_history_fix.log')
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
Write-Host '保留: config/ 下的全部用户配置和缓存学习数据' -ForegroundColor Green
