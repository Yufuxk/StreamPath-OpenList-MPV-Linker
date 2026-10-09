$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_common.ps1')
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$TestRoot = Join-Path $ProjectRoot ('build\update-acceptance-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TestRoot | Out-Null
$Helper = Join-Path $PSScriptRoot 'streampath-updater.ps1'
$Passed = 0
function Make-Program([string]$Path, [int]$Build) {
    New-Item -ItemType Directory -Path (Join-Path $Path 'data') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $Path 'streampath.exe'), "synthetic-exe-$Build")
    [IO.File]::WriteAllText((Join-Path $Path 'data\app.so'), "synthetic-aot-$Build")
    Copy-Item -LiteralPath $Helper -Destination $Path
    Write-StreamPathProgramManifest $Path '1.1.0' $Build
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw $Message }
}
function Run-Helper([string]$Application, [string]$ZipPath, [string]$Hash, [string]$Log, [switch]$Recovery, [string]$Commit) {
    $Info = [Diagnostics.ProcessStartInfo]::new('powershell.exe')
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    $Info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Helper + '" -Target "' + $Application + '" -NoRestart'
    if ($Recovery) { $Info.Arguments += ' -Recover' }
    else { $Info.Arguments += ' -Package "' + $ZipPath + '" -ExpectedSha256 ' + $Hash + ' -ExpectedVersion 1.1.0+2' }
    if ($Commit) { $Info.Arguments += ' -CommitFile "' + $Commit + '"' }
    $Process = [Diagnostics.Process]::Start($Info)
    $Output = $Process.StandardOutput.ReadToEnd()
    $Errors = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()
    [IO.File]::WriteAllText($Log, $Output + $Errors)
    return $Process.ExitCode
}
foreach ($Case in @('success', 'committed', 'cancelled', 'digest', 'traversal', 'conflict', 'rollback', 'recovery')) {
    $CaseRoot = Join-Path $TestRoot $Case
    $App = Join-Path $CaseRoot 'app'
    $New = Join-Path $CaseRoot 'new'
    Make-Program $App 1
    Make-Program $New 2
    New-Item -ItemType Directory -Path (Join-Path $App 'stream_path_data\cache') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $App 'stream_path_data\cache\playback.json'), 'user-progress')
    [IO.File]::WriteAllText((Join-Path $App 'my-player.exe'), 'user-player')
    if ($Case -eq 'conflict') {
        [IO.File]::WriteAllText((Join-Path $App 'extra.dll'), 'user-owned')
        [IO.File]::WriteAllText((Join-Path $New 'extra.dll'), 'new-runtime')
        Write-StreamPathProgramManifest $New '1.1.0' 2
    }
    $ZipPath = Join-Path $CaseRoot 'release.zip'
    $Zip = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($File in Get-ChildItem -LiteralPath $New -Recurse -File) {
            $Name = $File.FullName.Substring($New.Length + 1).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Zip, $File.FullName, $Name) | Out-Null
        }
    } finally { $Zip.Dispose() }
    if ($Case -eq 'traversal') {
        $Zip = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Update)
        try { $Entry = $Zip.CreateEntry('../escape.dll'); $Writer = [IO.StreamWriter]::new($Entry.Open()); $Writer.Write('escape'); $Writer.Dispose() } finally { $Zip.Dispose() }
    }
    $Hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Case -eq 'digest') { $Hash = 'a' * 64 }
    $Lock = $null
    if ($Case -eq 'rollback') {
        $Lock = [IO.File]::Open((Join-Path $App 'streampath.exe'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    }
    if ($Case -eq 'recovery') {
        $Transaction = Join-Path $App '.streampath-update'
        New-Item -ItemType Directory -Path (Join-Path $Transaction 'backup') -Force | Out-Null
        foreach ($Name in @('data', 'streampath.exe', 'streampath-updater.ps1', 'streampath-release.json')) {
            Copy-Item -LiteralPath (Join-Path $App $Name) -Destination (Join-Path $Transaction 'backup') -Recurse
        }
        $Journal = @{ schema = 1; target = $App; roots = @(@{name='data';existed=$true},@{name='streampath.exe';existed=$true},@{name='streampath-updater.ps1';existed=$true},@{name='streampath-release.json';existed=$true}) }
        [IO.File]::WriteAllText((Join-Path $Transaction 'pending.json'), ($Journal | ConvertTo-Json -Depth 6))
        [IO.File]::WriteAllText((Join-Path $App 'data\app.so'), 'interrupted-install')
        $Exit = Run-Helper -Application $App -Log (Join-Path $CaseRoot 'result.log') -Recovery
    } else {
        $Commit = if ($Case -in @('committed', 'cancelled')) { Join-Path $CaseRoot 'helper-commit' } else { '' }
        if ($Case -eq 'committed') { [IO.File]::WriteAllText($Commit, 'prepared') }
        $Exit = Run-Helper -Application $App -ZipPath $ZipPath -Hash $Hash -Log (Join-Path $CaseRoot 'result.log') -Commit $Commit
    }
    if ($Lock) { $Lock.Dispose() }
    if ($Case -in @('success', 'committed', 'recovery')) { Assert-Equal $Exit 0 "$Case failed: $(Get-Content -LiteralPath (Join-Path $CaseRoot 'result.log') -Raw)" }
    else { if ($Exit -eq 0) { throw "$Case was incorrectly accepted." } }
    if ($Case -eq 'rollback' -and (Test-Path -LiteralPath (Join-Path $App '.streampath-update\pending.json'))) {
        $RecoveryExit = Run-Helper -Application $App -Log (Join-Path $CaseRoot 'recovery.log') -Recovery
        Assert-Equal $RecoveryExit 0 'Rollback recovery failed.'
    }
    $Expected = if ($Case -in @('success', 'committed')) { 'synthetic-aot-2' } else { 'synthetic-aot-1' }
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $App 'data\app.so'))) $Expected "$Case changed the wrong program."
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $App 'stream_path_data\cache\playback.json'))) 'user-progress' "$Case changed user progress."
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $App 'my-player.exe'))) 'user-player' "$Case changed an unowned executable."
    $Passed++
    Write-Host "PASS $Case"
}
Write-Host "Update acceptance: $Passed passed. Evidence: $TestRoot"
