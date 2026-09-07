[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [string]$SourceArchive,
    [string]$BuildDirectory,
    [string]$RuntimeDirectory,
    [string]$BundleDirectory,
    [switch]$PrepareOnly,
    [switch]$EnableForTesting
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$adapterRoot = Join-Path $projectRoot 'windows/iso_bridge/mpv'
$lock = Get-Content -LiteralPath (Join-Path $adapterRoot 'source-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($SourceArchive) {
    if ((Get-FileHash -LiteralPath $SourceArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $lock.archiveSha256) {
        throw 'MPV source archive checksum mismatch.'
    }
    if (Test-Path -LiteralPath $SourceDirectory) { throw 'Archive extraction requires a new SourceDirectory.' }
    New-Item -ItemType Directory -Path $SourceDirectory | Out-Null
    & tar -xf $SourceArchive --strip-components=1 -C $SourceDirectory
    if ($LASTEXITCODE -ne 0) { throw 'MPV source extraction failed.' }
}
$sourceRoot = (Resolve-Path -LiteralPath $SourceDirectory).Path

function Assert-Exit([string]$Operation) {
    if ($LASTEXITCODE -ne 0) { throw "$Operation failed (exit $LASTEXITCODE)." }
}
function Invoke-MpvProbe([string]$Executable, [string]$Option) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = [IO.Path]::GetFullPath($Executable)
    $info.Arguments = "--no-config --terminal=yes $Option"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(20000)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'MPV capability probe timed out.'
        }
        if ($process.ExitCode -ne 0) { throw "MPV capability probe failed (exit $($process.ExitCode))." }
        $null = $stderr.Result
        return $stdout.Result
    } finally { $process.Dispose() }
}
function Text-Hash([string]$Path) {
    $content = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($content)))).Replace('-', '').ToLowerInvariant()
    } finally { $algorithm.Dispose() }
}

# 仅接受专用源码根目录，避免 git apply 意外作用于父仓库。
if (-not $SourceArchive) {
    $gitRoot = (& git -C $sourceRoot rev-parse --show-toplevel).Trim()
    Assert-Exit 'Locate MPV source repository'
    if ([IO.Path]::GetFullPath($gitRoot) -ne $sourceRoot) { throw 'SourceDirectory must be the MPV repository root.' }
}
$allOriginal = $true
$allPatched = $true
foreach ($file in $lock.files) {
    $hash = Text-Hash (Join-Path $sourceRoot $file.path)
    $allOriginal = $allOriginal -and ($hash -eq $file.originalSha256)
    $allPatched = $allPatched -and ($hash -eq $file.patchedSha256)
}
if (-not $allOriginal -and -not $allPatched) { throw 'MPV source differs from the locked revision or has unrelated edits.' }
if ($allOriginal) {
    # --unsafe-paths 不使用；归档源码也通过独立工作目录应用已锁定补丁。
    Push-Location $sourceRoot
    try {
    & git --git-dir=__no_repository__ apply --check (Join-Path $adapterRoot 'remote-disc.patch')
    Assert-Exit 'Check remote disc patch'
    & git --git-dir=__no_repository__ apply (Join-Path $adapterRoot 'remote-disc.patch')
    Assert-Exit 'Apply remote disc patch'
    } finally { Pop-Location }
}
Copy-Item -LiteralPath (Join-Path $adapterRoot 'streampath_disc.h') -Destination (Join-Path $sourceRoot 'stream/streampath_disc.h')
foreach ($file in $lock.files) {
    if ((Text-Hash (Join-Path $sourceRoot $file.path)) -ne $file.patchedSha256) { throw 'Patched source verification failed.' }
}
Write-Output "MPV adapter source verified: $($lock.revision)"
if ($PrepareOnly) { return }
if (-not $BuildDirectory -or -not $RuntimeDirectory -or -not $BundleDirectory) {
    throw 'Building requires BuildDirectory, RuntimeDirectory and BundleDirectory.'
}
if (-not $SourceArchive) {
    $revision = (& git -C $sourceRoot rev-parse HEAD).Trim()
    Assert-Exit 'Read MPV revision'
    if ($revision -ne $lock.revision) { throw 'The complete MPV checkout must match the locked revision.' }
}
if (Test-Path -LiteralPath $BuildDirectory) { throw 'Use a new dedicated BuildDirectory.' }
if (Test-Path -LiteralPath $BundleDirectory) { throw 'Use a new dedicated BundleDirectory.' }
# 在已配置 Windows x64 依赖的 Meson 环境执行，libbluray 必须动态链接。
& meson setup $BuildDirectory $sourceRoot --buildtype=release -Dlibbluray=enabled -Dlibmpv=false -Dgpl=true -Dlua=enabled -Ddvdnav=disabled
Assert-Exit 'Configure MPV'
& meson compile -C $BuildDirectory
Assert-Exit 'Build MPV'
$executable = Join-Path $BuildDirectory 'mpv.exe'
if (-not (Test-Path -LiteralPath $executable)) { throw 'MPV build did not produce mpv.exe.' }
$imports = & dumpbin /imports $executable
Assert-Exit 'Inspect MPV dependencies'
if (-not ($imports -match 'bluray-4\.dll')) { throw 'MPV must import the fixed bluray-4.dll runtime.' }
New-Item -ItemType Directory -Path $BundleDirectory | Out-Null
Copy-Item -LiteralPath $executable -Destination (Join-Path $BundleDirectory 'mpv.exe')
$fixedRuntime = Join-Path $projectRoot 'windows/iso_bridge/third_party/libbluray'
Copy-Item -LiteralPath (Join-Path $fixedRuntime 'bin/bluray-4.dll') -Destination (Join-Path $BundleDirectory 'bluray-4.dll')
$pending = New-Object 'System.Collections.Generic.Queue[string]'
$pending.Enqueue((Join-Path $BundleDirectory 'mpv.exe'))
$pending.Enqueue((Join-Path $BundleDirectory 'bluray-4.dll'))
while ($pending.Count -gt 0) {
    $binary = $pending.Dequeue()
    $dependencyOutput = & dumpbin /dependents $binary
    Assert-Exit 'Inspect runtime dependency closure'
    foreach ($line in $dependencyOutput) {
        if ($line -notmatch '^\s+([\w.+-]+\.dll)\s*$') { continue }
        $name = $Matches[1]
        $target = Join-Path $BundleDirectory $name
        if (Test-Path -LiteralPath $target) { continue }
        $candidate = Join-Path $RuntimeDirectory $name
        if (Test-Path -LiteralPath $candidate) {
            Copy-Item -LiteralPath $candidate -Destination $target
            $pending.Enqueue($target)
        } elseif ($name -notmatch '^(api-ms-|ext-ms-)' -and -not (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32/$name"))) {
            throw "Missing runtime dependency: $name"
        }
    }
}
$licenses = Join-Path (Split-Path -Parent $RuntimeDirectory) 'share/licenses'
if (Test-Path -LiteralPath $licenses) {
    Copy-Item -LiteralPath $licenses -Destination (Join-Path $BundleDirectory 'licenses') -Recurse
}
Copy-Item -LiteralPath (Join-Path $fixedRuntime 'SOURCE.md') -Destination (Join-Path $BundleDirectory 'LIBBLURAY-SOURCE.md')
Copy-Item -LiteralPath (Join-Path $fixedRuntime 'COPYING') -Destination (Join-Path $BundleDirectory 'COPYING.libbluray')
Copy-Item -LiteralPath (Join-Path $sourceRoot 'Copyright') -Destination (Join-Path $BundleDirectory 'COPYRIGHT.mpv')
Copy-Item -LiteralPath (Join-Path $sourceRoot 'LICENSE.GPL') -Destination (Join-Path $BundleDirectory 'LICENSE.GPL')
Copy-Item -LiteralPath (Join-Path $sourceRoot 'LICENSE.LGPL') -Destination (Join-Path $BundleDirectory 'LICENSE.LGPL')
$bundleMpv = Join-Path $BundleDirectory 'mpv.exe'
$buildPath = $env:PATH
try {
    # 能力探测只使用随包 DLL 和 Windows 系统依赖。
    $env:PATH = "$env:SystemRoot/System32;$env:SystemRoot"
$options = Invoke-MpvProbe $bundleMpv '--list-options'
if (-not ($options -match 'bluray-remote-disc') -or -not ($options -match 'bluray-remote-metrics')) {
    throw 'MPV adapter option probe failed.'
}
$commands = Invoke-MpvProbe $bundleMpv '--input-cmdlist'
if (-not ($commands -match 'discnav')) { throw 'MPV disc navigation command probe failed.' }
} finally { $env:PATH = $buildPath }
$files = [ordered]@{}
Get-ChildItem -LiteralPath $BundleDirectory -File | Where-Object { $_.Extension -in '.dll', '.exe' } | ForEach-Object {
    $files[$_.Name] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$capability = [ordered]@{
    schema = 1; enabled = [bool]$EnableForTesting; protocol = 'remote-disc-blocks-v1'
    validationStage = 'development'; adapterProbePassed = $true
    menuCommandsProbePassed = $true; revision = $lock.revision
    libblurayVersion = '1.5.1'; bdj = $false; files = $files
    hdmvSamples = @(); legacyRegressionPassed = $false; networkFaultsPassed = $false
}
$json = $capability | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $BundleDirectory 'capabilities.json'), $json, (New-Object Text.UTF8Encoding($false)))
Write-Output 'Development bundle created. Real-disc acceptance remains pending.'
