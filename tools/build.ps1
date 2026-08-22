# =============================================================
# StreamPath 通用构建工具
# 一键完成：flutter analyze → flutter test → flutter build
# windows → 打包便携版（可选）。便携交付默认使用 Release/AOT。
#
# 用法（在项目根目录执行）：
#   powershell -ExecutionPolicy Bypass -File .\tools\build.ps1
#   # 打包到指定目录（不询问确认）：
#   powershell -ExecutionPolicy Bypass -File .\tools\build.ps1 -Target "D:\portable" -Yes
#   # 跳过某一步（调试用）：
#   powershell -ExecutionPolicy Bypass -File .\tools\build.ps1 -SkipTest -SkipPackage
#
# 参数：
#   -Mode         release（默认）/ profile / debug
#   -SkipAnalyze  跳过 flutter analyze
#   -SkipTest     跳过 flutter test
#   -SkipPackage  只构建，不打包便携版
#   -Target       便携版目标目录（缺省自动探测
#                 <项目根上一级>\StreamPath_Release\StreamPath 20260809 V0.1 test portable）
#   -Yes          打包前不询问确认
# =============================================================

param(
    [ValidateSet('debug', 'profile', 'release')]
    [string]$Mode = 'release',
    [switch]$SkipAnalyze,
    [switch]$SkipTest,
    [switch]$SkipPackage,
    [string]$Target,
    [switch]$Yes,
    [switch]$ValidateTargetOnly
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$ProjectRoot = [IO.Path]::GetFullPath((Split-Path $ScriptRoot -Parent))
$ProjectMarker = Join-Path $ProjectRoot 'pubspec.yaml'
if (-not (Test-Path -LiteralPath $ProjectMarker -PathType Leaf)) {
    throw "无法确认 StreamPath 项目根：$ProjectRoot"
}
Set-Location -LiteralPath $ProjectRoot

function Resolve-SafePackageTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$BuildOutput
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw '打包目标不能为空。'
    }
    $Resolved = [IO.Path]::GetFullPath($Path)
    $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
    $BuildOutput = [IO.Path]::GetFullPath($BuildOutput)
    $TargetRoot = [IO.Path]::GetPathRoot($Resolved)
    $ForbiddenExact = @($TargetRoot, $ProjectRoot, $BuildOutput)
    foreach ($EnvironmentPath in @(
            $env:USERPROFILE,
            $env:APPDATA,
            $env:LOCALAPPDATA,
            $env:TEMP
        )) {
        if (-not [string]::IsNullOrWhiteSpace($EnvironmentPath)) {
            $ForbiddenExact += [IO.Path]::GetFullPath($EnvironmentPath)
        }
    }
    if ($ForbiddenExact | Where-Object {
            [string]::Equals(
                $_,
                $Resolved,
                [StringComparison]::OrdinalIgnoreCase
            )
        }) {
        throw "拒绝使用不安全的打包目标：$Resolved"
    }

    $ProjectPrefix = $ProjectRoot.TrimEnd(
        [IO.Path]::DirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    if ($Resolved.StartsWith(
            $ProjectPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "拒绝使用项目目录内部作为打包目标：$Resolved"
    }

    $TargetPrefix = $Resolved.TrimEnd(
        [IO.Path]::DirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    foreach ($ProtectedPath in @(
            $ProjectRoot,
            [IO.Path]::GetFullPath($env:USERPROFILE)
        )) {
        if ($ProtectedPath.StartsWith(
                $TargetPrefix,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "拒绝使用包含项目或用户目录的打包目标：$Resolved"
        }
    }

    $ExistingPath = $Resolved
    while (-not (Test-Path -LiteralPath $ExistingPath)) {
        $ParentPath = [IO.Path]::GetDirectoryName($ExistingPath)
        if ([string]::IsNullOrWhiteSpace($ParentPath) -or
            [string]::Equals($ParentPath, $ExistingPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "无法确认打包目标的父路径：$Resolved"
        }
        $ExistingPath = $ParentPath
    }
    $PathCursor = Get-Item -LiteralPath $ExistingPath -Force
    while ($null -ne $PathCursor) {
        if (($PathCursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "打包目标路径经过重解析点：$($PathCursor.FullName)"
        }
        $PathCursor = $PathCursor.Parent
    }

    if (Test-Path -LiteralPath $Resolved) {
        $TargetItem = Get-Item -LiteralPath $Resolved -Force
        if (-not $TargetItem.PSIsContainer -or
            (($TargetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "打包目标无效或为重解析点：$Resolved"
        }
        $Children = @(Get-ChildItem -LiteralPath $Resolved -Force)
        $HasPackageMarker =
            (Test-Path -LiteralPath (Join-Path $Resolved 'streampath.exe') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $Resolved 'data\app.so') -PathType Leaf)
        if ($Children.Count -ne 0 -and -not $HasPackageMarker) {
            throw "非空目标不是可识别的 StreamPath 便携目录：$Resolved"
        }
        $ReparsePoints = @(Get-ChildItem -LiteralPath $Resolved -Recurse -Force |
            Where-Object {
                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            })
        if ($ReparsePoints.Count -ne 0) {
            throw "打包目标包含重解析点，停止覆盖：$Resolved"
        }
    }
    return $Resolved
}

# ── 步骤包装：失败即退出（携带退出码） ──
function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Body
    )
    Write-Host "── $Name ..." -ForegroundColor Cyan
    & $Body
    if ($LASTEXITCODE -ne 0) {
        Write-Host "失败：$Name（退出码 $LASTEXITCODE）" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

$ModeDirectory = @{
    debug = 'Debug'
    profile = 'Profile'
    release = 'Release'
}[$Mode]
$BuildOutput = [IO.Path]::GetFullPath(
    (Join-Path $ProjectRoot "build\windows\x64\runner\$ModeDirectory")
)
if ($ValidateTargetOnly) {
    $ValidatedTarget = Resolve-SafePackageTarget -Path $Target `
        -ProjectRoot $ProjectRoot -BuildOutput $BuildOutput
    Write-Host "打包目标校验通过：$ValidatedTarget" -ForegroundColor Green
    exit 0
}
Write-Host "=== StreamPath 通用构建（$ModeDirectory） ===" -ForegroundColor Cyan

# ── 0. 检查 flutter ──
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Host '未找到 flutter，请先安装并加入 PATH。' -ForegroundColor Red
    exit 1
}

# ── 1. 静态分析 ──
if (-not $SkipAnalyze) {
    Invoke-Step 'flutter analyze' { flutter analyze }
} else {
    Write-Host '（已跳过 flutter analyze）' -ForegroundColor Yellow
}

# ── 2. 测试 ──
if (-not $SkipTest) {
    Invoke-Step 'flutter test' { flutter test }
} else {
    Write-Host '（已跳过 flutter test）' -ForegroundColor Yellow
}

# ── 3. 构建 ──
Invoke-Step "flutter build windows --$Mode" { flutter build windows "--$Mode" }

$exe = Join-Path $BuildOutput 'streampath.exe'
if (-not (Test-Path $exe)) {
    Write-Host "构建产物缺失：$exe" -ForegroundColor Red
    exit 1
}

# 产物指纹校验：避免把 Debug/JIT 文件误装进标为 Release 的便携目录。
$KernelBlob = Join-Path $BuildOutput 'data\flutter_assets\kernel_blob.bin'
$AppSo = Join-Path $BuildOutput 'data\app.so'
if ($Mode -eq 'debug') {
    if (-not (Test-Path -LiteralPath $KernelBlob -PathType Leaf)) {
        throw "Debug 产物缺少 kernel_blob.bin：$KernelBlob"
    }
} else {
    if (-not (Test-Path -LiteralPath $AppSo -PathType Leaf)) {
        throw "$ModeDirectory 产物缺少 AOT 文件 app.so：$AppSo"
    }
    if (Test-Path -LiteralPath $KernelBlob -PathType Leaf) {
        throw "$ModeDirectory 产物意外包含 Debug kernel_blob.bin：$KernelBlob"
    }
}
Write-Host "构建完成：$exe" -ForegroundColor Green

# ── 4. 打包便携版（可选） ──
if (-not $SkipPackage) {
    # 目标目录：-Target 优先；只有 Release 缺省探测正式便携目录，
    # 防止 Debug/Profile 产物覆盖正式交付目录。
    if (-not $Target -and $Mode -eq 'release') {
        $DefaultTarget = Join-Path (Split-Path $ProjectRoot -Parent) 'StreamPath_Release\StreamPath 20260809 V0.1 test portable'
        if (Test-Path $DefaultTarget) {
            $Target = $DefaultTarget
        }
    }
    if (-not $Target) {
        Write-Host '未指定 -Target 且未探测到默认便携目录，跳过打包（可用 -Target 指定）。' -ForegroundColor Yellow
    } else {
        # 确认（除非 -Yes）。
        if (-not $Yes) {
            $ans = Read-Host "将打包到: $Target（回车=确认，n=跳过）"
            if ($ans -in @('n', 'N', 'no', 'NO')) {
                Write-Host '已跳过打包。' -ForegroundColor Yellow
                $Target = $null
            }
        }
    }
    if ($Target) {
        $Target = Resolve-SafePackageTarget -Path $Target `
            -ProjectRoot $ProjectRoot -BuildOutput $BuildOutput

        $BuildItem = Get-Item -LiteralPath $BuildOutput -Force
        if (-not $BuildItem.PSIsContainer -or
            (($BuildItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "构建产物目录无效或为重解析点：$BuildOutput"
        }
        $BuildReparsePoints = @(Get-ChildItem -LiteralPath $BuildOutput -Recurse -Force |
            Where-Object {
                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            })
        if ($BuildReparsePoints.Count -ne 0) {
            throw "构建产物目录包含重解析点，停止打包：$BuildOutput"
        }
        if (@(Get-Process -Name 'streampath' -ErrorAction SilentlyContinue).Count -ne 0) {
            throw 'StreamPath 正在运行，请关闭程序后再打包。'
        }

        Write-Host "── 打包便携版 → $Target" -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
        $TargetItem = Get-Item -LiteralPath $Target -Force
        if (-not $TargetItem.PSIsContainer -or
            (($TargetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "打包目标无效或为重解析点：$Target"
        }
        $TargetReparsePoints = @(Get-ChildItem -LiteralPath $Target -Recurse -Force |
            Where-Object {
                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            })
        if ($TargetReparsePoints.Count -ne 0) {
            throw "打包目标包含重解析点，停止覆盖：$Target"
        }

        # 清理旧构建产物；保留 使用说明.txt、stream_path_data/ 等用户文件。
        $TargetPrefix = $Target.TrimEnd([IO.Path]::DirectorySeparatorChar) +
            [IO.Path]::DirectorySeparatorChar
        $OldArtifacts = @(Get-ChildItem -LiteralPath $Target -Force | Where-Object {
            $_.Name -eq 'data' -or $_.Name -like '*.dll' -or
            $_.Name -eq 'native_assets.json' -or $_.Name -like '*.exe' -or
            $_.Name -like '*.pdb'
        })
        foreach ($Artifact in $OldArtifacts) {
            $ArtifactPath = [IO.Path]::GetFullPath($Artifact.FullName)
            if (-not $ArtifactPath.StartsWith(
                    $TargetPrefix,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw "拒绝删除打包目标以外的文件：$ArtifactPath"
            }
            if (($Artifact.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "拒绝删除重解析点：$ArtifactPath"
            }
        }
        foreach ($Artifact in $OldArtifacts) {
            Remove-Item -LiteralPath $Artifact.FullName -Recurse -Force
        }

        # 复制新产物。
        foreach ($BuildChild in @(Get-ChildItem -LiteralPath $BuildOutput -Force)) {
            Copy-Item -LiteralPath $BuildChild.FullName -Destination $Target `
                -Recurse -Force
        }

        # 复制后再次校验正式便携包指纹，防止目标目录残留错误构建模式。
        $TargetKernelBlob = Join-Path $Target 'data\flutter_assets\kernel_blob.bin'
        $TargetAppSo = Join-Path $Target 'data\app.so'
        if ($Mode -eq 'release') {
            if (-not (Test-Path -LiteralPath $TargetAppSo -PathType Leaf) -or
                (Test-Path -LiteralPath $TargetKernelBlob -PathType Leaf)) {
                throw "便携包 Release/AOT 指纹校验失败：$Target"
            }
        }

        # 删除调试符号。
        $pdb = Join-Path $Target 'streampath.pdb'
        if (Test-Path -LiteralPath $pdb -PathType Leaf) {
            Remove-Item -LiteralPath $pdb -Force
            Write-Host '  已删除调试符号 streampath.pdb'
        }
        Write-Host "打包完成：$Target" -ForegroundColor Green
        Write-Host '  保留项：使用说明.txt、stream_path_data/（用户数据不会被覆盖）'
    }
}

Write-Host '=== 构建流程结束 ===' -ForegroundColor Cyan
