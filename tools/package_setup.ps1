param(
    [string]$OutputDirectory,
    [string]$Version,
    [int]$BuildNumber,
    [string]$ReleaseDate,
    [string]$Compiler,
    [switch]$SkipAnalyze,
    # 兼容旧调用，打包流程不执行测试。
    [switch]$SkipTest
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'pubspec.yaml'))) { throw 'StreamPath project root is missing.' }
. (Join-Path $PSScriptRoot 'release_common.ps1')
$Options = Read-StreamPathReleaseOptions $ProjectRoot $Version $BuildNumber $ReleaseDate
if (-not $OutputDirectory) {
    $DefaultOutput = Join-Path $ProjectRoot "build\releases\StreamPath.$($Options.Date).V$($Options.Version.Display)"
    $OutputDirectory = Read-Host "Installer output directory [$DefaultOutput]"
    if (-not $OutputDirectory) { $OutputDirectory = $DefaultOutput }
}
$OutputDirectory = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($OutputDirectory.Trim().Trim('"')))
$Source = Join-Path $ProjectRoot 'build\windows\x64\runner\Release'
if ($OutputDirectory -eq $Source -or $OutputDirectory.StartsWith($Source + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Installer output directory must be outside the build output.'
}
if (-not $Compiler) {
    $Candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path $ProjectRoot 'build\toolchains\inno\ISCC.exe'),
        (Join-Path $ProjectRoot 'build\toolchains\inno\app\ISCC.exe')
    )
    $Compiler = $Candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $Compiler) {
        $Compiler = Read-Host 'Inno Setup 6 ISCC.exe path (https://jrsoftware.org/isdl.php)'
    }
}
if (-not $Compiler -or -not (Test-Path -LiteralPath $Compiler -PathType Leaf)) { throw 'Install Inno Setup 6 or supply -Compiler pointing to ISCC.exe.' }
Repair-StreamPathReleaseIntegrity -Path $Compiler
foreach ($CompressionName in @('islzma32.exe', 'islzma64.exe')) {
    $CompressionPath = Join-Path (Split-Path $Compiler -Parent) $CompressionName
    if (Test-Path -LiteralPath $CompressionPath -PathType Leaf) {
        Repair-StreamPathReleaseIntegrity -Path $CompressionPath
    }
}
$AssetName = "StreamPath.$($Options.Date).V$($Options.Version.Display).setup.exe"
$AssetPath = Join-Path $OutputDirectory $AssetName
if (Test-Path -LiteralPath $AssetPath) { throw "Release asset already exists: $AssetPath" }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
& (Join-Path $PSScriptRoot 'build.ps1') -Mode release -SkipPackage -Version $Options.Version.Name -BuildNumber $Options.Version.Build -SkipAnalyze:$SkipAnalyze
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $Compiler "/DSourceDir=$Source" "/DOutputDir=$OutputDirectory" "/DOutputName=$([IO.Path]::GetFileNameWithoutExtension($AssetName))" "/DAppVersion=$($Options.Version.Name)" "/DDisplayVersion=$($Options.Version.Display)" "/DWindowsVersion=$($Options.Version.Windows)" (Join-Path $PSScriptRoot 'installer\StreamPath.iss')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Repair-StreamPathReleaseIntegrity -Path $AssetPath
Write-StreamPathReleaseMetadata $OutputDirectory $Options $AssetPath 'installed'
Write-Host "Installer: $AssetPath" -ForegroundColor Green
Write-Host 'Upload the installer and StreamPath.release.json to the same GitHub Release.'
