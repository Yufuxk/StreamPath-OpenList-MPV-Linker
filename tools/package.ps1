# =============================================================
# StreamPath 便携版打包入口
#
# 直接运行后输入目标目录；直接回车使用现有便携版目录。
# 脚本会调用 build.ps1 完成静态分析、Release/AOT
# 构建和安全覆盖，并保留目标中的 stream_path_data 用户数据。
# =============================================================

param(
    [string]$Target,
    [string]$OutputDirectory,
    [string]$Version,
    [int]$BuildNumber,
    [string]$ReleaseDate,
    [switch]$Yes,
    [switch]$SkipAnalyze,
    # 兼容旧调用，打包流程不执行测试。
    [switch]$SkipTest
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$ProjectRoot = [IO.Path]::GetFullPath((Split-Path $ScriptRoot -Parent))
$ProjectMarker = Join-Path $ProjectRoot 'pubspec.yaml'
if (-not (Test-Path -LiteralPath $ProjectMarker -PathType Leaf)) {
    throw "无法确认 StreamPath 项目根：$ProjectRoot"
}
$BuildScript = Join-Path $ScriptRoot 'build.ps1'
$DefaultTarget = Join-Path (Split-Path $ProjectRoot -Parent) `
    'StreamPath 20260809 V0.1 portable'

if (-not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) {
    throw "未找到构建脚本：$BuildScript"
}

if ([string]::IsNullOrWhiteSpace($Target)) {
    Write-Host '=== StreamPath 便携版打包 ===' -ForegroundColor Cyan
    Write-Host "默认目录：$DefaultTarget"
    $Target = Read-Host '请输入打包目录（直接回车使用默认目录）'
    if ([string]::IsNullOrWhiteSpace($Target)) {
        $Target = $DefaultTarget
    }
}

# 允许从资源管理器复制带双引号的路径，但拒绝空路径。
$Target = [Environment]::ExpandEnvironmentVariables($Target.Trim().Trim('"'))
if ([string]::IsNullOrWhiteSpace($Target)) {
    throw '打包目录不能为空。'
}
$Target = [IO.Path]::GetFullPath($Target)

Write-Host "目标目录：$Target" -ForegroundColor Yellow
$Answer = if ($Yes) { 'Y' } else { Read-Host '确认构建并更新此便携目录？（Y/回车=继续，N=取消）' }
if ($Answer -in @('n', 'N', 'no', 'NO')) {
    Write-Host '已取消打包。' -ForegroundColor Yellow
    exit 0
}
. (Join-Path $ScriptRoot 'release_common.ps1')
$Options = Read-StreamPathReleaseOptions $ProjectRoot $Version $BuildNumber $ReleaseDate

if (-not $OutputDirectory) {
    $DefaultOutput = Join-Path $ProjectRoot "build\releases\StreamPath.$($Options.Date).V$($Options.Version.Display)"
    $OutputDirectory = Read-Host "ZIP output directory [$DefaultOutput]"
    if (-not $OutputDirectory) { $OutputDirectory = $DefaultOutput }
}
$OutputDirectory = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($OutputDirectory.Trim().Trim('"')))
$Source = Join-Path $ProjectRoot 'build\windows\x64\runner\Release'
if ($OutputDirectory -eq $Source -or $OutputDirectory.StartsWith($Source + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ZIP output directory must be outside the build output.'
}
$TargetPrefix = $Target.TrimEnd('\') + '\'
if ($OutputDirectory -eq $Target -or $OutputDirectory.StartsWith($TargetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ZIP output directory must be outside the portable directory.'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
& $BuildScript -Mode release -Target $Target -Yes -Version $Options.Version.Name -BuildNumber $Options.Version.Build -SkipAnalyze:$SkipAnalyze
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

# 发布 ZIP 只包含清单拥有的程序文件，排除目标目录的用户资料。
$AssetName = "StreamPath.$($Options.Date).V$($Options.Version.Display).portable.zip"
$AssetPath = Join-Path $OutputDirectory $AssetName
if (Test-Path -LiteralPath $AssetPath) { throw "Release asset already exists: $AssetPath" }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$Archive = [IO.Compression.ZipFile]::Open($AssetPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    $Manifest = Get-Content -LiteralPath (Join-Path $Target 'streampath-release.json') -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($Name in @($Manifest.files.path) + @('streampath-release.json')) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, (Join-Path $Target $Name), $Name) | Out-Null
    }
} finally { $Archive.Dispose() }
Write-StreamPathReleaseMetadata $OutputDirectory $Options $AssetPath 'portable'
Write-Host "Release ZIP: $AssetPath" -ForegroundColor Green
Write-Host 'Upload the asset and StreamPath.release.json to the same GitHub Release.'

Write-Host '便携版已生成，可直接运行目标目录中的 streampath.exe。' `
    -ForegroundColor Green
