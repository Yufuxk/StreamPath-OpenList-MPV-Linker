# 仅操作发布清单拥有的程序产物；pending.json 提交前保留可恢复快照。
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$Package,
    [ValidateSet('portable', 'installed')][string]$Kind = 'portable',
    [string]$ExpectedSha256,
    [string]$ExpectedVersion,
    [string]$ReadyFile,
    [string]$CommitFile,
    [int]$ParentPid,
    [switch]$Recover,
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$Target = [IO.Path]::GetFullPath($Target).TrimEnd('\')
$Transaction = Join-Path $Target '.streampath-update'
$Pending = Join-Path $Transaction 'pending.json'
$UninstallKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{B71DF9AF-23E5-4C52-9ADB-D465BE79F50E}_is1'
$Locked = $false
$Cancelled = $false
$UpdateMutex = [Threading.Mutex]::new($false, 'Local\StreamPath.Update')

function Assert-PlainPath([string]$Path) {
    $Cursor = [IO.Path]::GetFullPath($Path)
    while ($Cursor) {
        if (Test-Path -LiteralPath $Cursor) {
            if ((Get-Item -LiteralPath $Cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Update path contains a reparse point.'
            }
        }
        $Parent = Split-Path $Cursor -Parent
        if ($Parent -eq $Cursor) { break }
        $Cursor = $Parent
    }
}

function Resolve-Child([string]$Root, [string]$Name) {
    if (-not $Name -or $Name.Contains('\') -or $Name.Contains(':') -or $Name.Contains([char]0) -or
        @($Name.Split('/') | Where-Object { $_ -in @('', '.', '..') -or $_.TrimEnd(' ', '.') -ne $_ }).Count) {
        throw 'Invalid program path.'
    }
    $Resolved = [IO.Path]::GetFullPath((Join-Path $Root $Name))
    if (-not $Resolved.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Program path escapes its root.'
    }
    Assert-PlainPath $Resolved
    return $Resolved
}

function Test-ProgramRoot([string]$Name) {
    return $Name -in @('data', 'include', 'lib', 'winfsp', 'licenses', 'COPYING', 'SOURCE.md', 'streampath.exe', 'streampath_iso_bridge.exe', 'native_assets.json', 'streampath-updater.ps1', 'streampath-release.json') -or
        $Name -match '^[A-Za-z0-9_.-]+\.dll$'
}

function Read-Manifest([string]$Root) {
    $File = Join-Path $Root 'streampath-release.json'
    if ((Get-Item -LiteralPath $File).Length -gt 8MB) { throw 'Program manifest is too large.' }
    $Manifest = Get-Content -LiteralPath $File -Raw -Encoding utf8 | ConvertFrom-Json
    if ($Manifest.schema -ne 1 -or $Manifest.version -notmatch '^\d+\.\d+\.\d+$' -or $Manifest.build -lt 1 -or @($Manifest.files).Count -gt 20000) {
        throw 'Unsupported program manifest.'
    }
    $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Entry in $Manifest.files) {
        $Path = Resolve-Child $Root $Entry.path
        if (-not (Test-ProgramRoot $Entry.path.Split('/')[0]) -or $Entry.path -eq 'streampath-release.json' -or
            -not $Seen.Add($Entry.path) -or $Entry.size -lt 0 -or $Entry.sha256 -notmatch '^[a-f0-9]{64}$') {
            throw 'Invalid program manifest entry.'
        }
    }
    foreach ($Required in @('streampath.exe', 'data/app.so', 'streampath-updater.ps1')) {
        if (-not $Seen.Contains($Required)) { throw 'Incomplete program manifest.' }
    }
    return $Manifest
}

function Assert-Program([string]$Root, $Manifest, [switch]$Exact) {
    foreach ($Entry in $Manifest.files) {
        $Path = Resolve-Child $Root $Entry.path
        if ((Get-Item -LiteralPath $Path).Length -ne $Entry.size -or
            (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Entry.sha256) {
            throw 'Program file integrity check failed.'
        }
    }
    if ($Exact) {
        $ExpectedNames = @($Manifest.files.path) + @('streampath-release.json')
        foreach ($File in Get-ChildItem -LiteralPath $Root -Recurse -File) {
            $Name = $File.FullName.Substring($Root.Length + 1).Replace('\', '/')
            if ($Name -notin $ExpectedNames) { throw 'Payload contains an unlisted program file.' }
        }
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'data\flutter_assets\kernel_blob.bin')) { throw 'Debug payload is not accepted.' }
}

function Remove-OwnedRoot([string]$Name) {
    $Path = Resolve-Child $Target $Name
    if (Test-Path -LiteralPath $Path) {
        $Reparse = @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($Reparse.Count) { throw 'Owned program directory contains a reparse point.' }
        Remove-Item -LiteralPath $Path -Force -Recurse
    }
}

function Set-OwnedRoot([string]$Source, [string]$Name) {
    $Destination = Resolve-Child $Target $Name
    $SourcePath = Resolve-Child $Source $Name
    $Item = Get-Item -LiteralPath $SourcePath
    if ($Item.PSIsContainer) {
        Remove-OwnedRoot $Name
        Copy-Item -LiteralPath $SourcePath -Destination $Destination -Recurse -Force
    } else {
        $Temporary = Join-Path $Transaction ([guid]::NewGuid().ToString('N') + '.new')
        Assert-PlainPath $Temporary
        Copy-Item -LiteralPath $SourcePath -Destination $Temporary -Force
        $Stream = [IO.File]::Open($Temporary, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $Stream.Flush($true) } finally { $Stream.Dispose() }
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            $Replaced = $Temporary + '.old'
            [IO.File]::Replace($Temporary, $Destination, $Replaced)
            Remove-Item -LiteralPath $Replaced -Force
        } else { [IO.File]::Move($Temporary, $Destination) }
    }
}

function Restore-Snapshot {
    $Journal = Get-Content -LiteralPath $Pending -Raw -Encoding utf8 | ConvertFrom-Json
    if ($Journal.schema -ne 1 -or $Journal.target -ne $Target) { throw 'Invalid update recovery journal.' }
    $Backup = Join-Path $Transaction 'backup'
    foreach ($Entry in $Journal.roots) {
        if (-not (Test-ProgramRoot $Entry.name) -and $Entry.name -ne 'streampath-installed' -and $Entry.name -notmatch '^unins[0-9]+\.(exe|dat|msg)$') {
            throw 'Invalid recovery root.'
        }
        if ($Entry.existed) {
            Set-OwnedRoot $Backup $Entry.name
        } else { Remove-OwnedRoot $Entry.name }
    }
    $RegistryBackup = Join-Path $Transaction 'uninstall.reg'
    if (Test-Path -LiteralPath $RegistryBackup) {
        & reg.exe import $RegistryBackup | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Uninstall registry recovery failed.' }
    }
    Remove-Item -LiteralPath $Pending -Force
}

function Invoke-Setup([string]$Directory, [switch]$Stage) {
    $Arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', ('/DIR="' + $Directory + '"'), ('/LOG="' + (Join-Path $Transaction 'setup.log') + '"'))
    if ($Stage) { $Arguments += '/STREAMPATH-STAGE=1' }
    $SetupTemp = Join-Path $Transaction 'setup-temp'
    New-Item -ItemType Directory -Path $SetupTemp -Force | Out-Null
    $StartInfo = [Diagnostics.ProcessStartInfo]::new($Package, ($Arguments -join ' '))
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $StartInfo.EnvironmentVariables['TEMP'] = $SetupTemp
    $StartInfo.EnvironmentVariables['TMP'] = $SetupTemp
    $Process = [Diagnostics.Process]::Start($StartInfo)
    try {
        $Process.WaitForExit()
        if ($Process.ExitCode -ne 0) { throw "Setup failed with exit code $($Process.ExitCode)." }
    } finally { $Process.Dispose() }
}

try {
    Assert-PlainPath $Target
    foreach ($Forbidden in @([IO.Path]::GetPathRoot($Target), $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $env:TEMP)) {
        if ($Forbidden -and ($Target -eq $Forbidden.TrimEnd('\') -or $Forbidden.StartsWith($Target + '\', [StringComparison]::OrdinalIgnoreCase))) {
            throw 'Unsafe application directory.'
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Target 'streampath.exe'))) { throw 'Application marker is missing.' }
    try { $Locked = $UpdateMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $Locked = $true }
    if (-not $Locked) { throw 'Another update is running.' }
    if ($ReadyFile) { [IO.File]::WriteAllText($ReadyFile, 'ready') }
    # 持有原进程句柄，避免 PID 重用和按名称结束无关进程。
    if ($ParentPid -gt 0) {
        $Parent = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
        if ($Parent -and -not $Parent.WaitForExit(60000)) { throw 'Application did not exit; update was cancelled.' }
    }
    $AppMutex = $null
    try { $AppMutex = [Threading.Mutex]::OpenExisting('Local\StreamPath.SingleInstance') } catch [Threading.WaitHandleCannotBeOpenedException] {}
    if ($AppMutex) { $AppMutex.Dispose(); throw 'StreamPath is still running.' }
    if ($CommitFile -and -not (Test-Path -LiteralPath $CommitFile)) {
        $Cancelled = $true
        throw 'Update was cancelled before application exit.'
    }
    if ($Recover) {
        if (-not (Test-Path -LiteralPath $Pending)) { throw 'No update recovery is pending.' }
        Restore-Snapshot
    } else {
        if (Test-Path -LiteralPath $Pending) { throw 'Recover the interrupted update before installing another release.' }
        if ($ExpectedSha256 -notmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash -ne $ExpectedSha256) {
            throw 'Downloaded package integrity check failed.'
        }
        $Installed = Test-Path -LiteralPath (Join-Path $Target 'streampath-installed')
        if ($Installed -ne ($Kind -eq 'installed')) { throw 'Package type does not match the application.' }
        Assert-PlainPath $Transaction
        if (Test-Path -LiteralPath $Transaction) {
            $Reparse = @(Get-ChildItem -LiteralPath $Transaction -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
            if ($Reparse.Count) { throw 'Update transaction contains a reparse point.' }
            # 此固定事务目录只保存程序快照，不包含用户数据。
            Remove-Item -LiteralPath $Transaction -Recurse -Force
        }
        New-Item -ItemType Directory -Path $Transaction | Out-Null
        Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $Transaction 'helper.ps1')
        $Stage = Join-Path $Transaction 'stage'
        New-Item -ItemType Directory -Path $Stage | Out-Null
        if ($Kind -eq 'installed') {
            Invoke-Setup $Stage -Stage
        } else {
            $Zip = [IO.Compression.ZipFile]::OpenRead($Package)
            try {
                if ($Zip.Entries.Count -gt 20000) { throw 'Too many ZIP entries.' }
                $Total = 0L
                $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($Entry in $Zip.Entries) {
                    $Name = $Entry.FullName
                    if ($Name.EndsWith('/')) { continue }
                    $Destination = Resolve-Child $Stage $Name
                    if (-not (Test-ProgramRoot $Name.Split('/')[0]) -or -not $Seen.Add($Name)) { throw 'Unexpected ZIP entry.' }
                    $Total += $Entry.Length
                    if ($Total -gt 1GB -or $Entry.Length -gt 256MB) { throw 'ZIP payload is too large.' }
                    New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force | Out-Null
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $Destination)
                }
            } finally { $Zip.Dispose() }
        }
        $OldManifest = Read-Manifest $Target
        $NewManifest = Read-Manifest $Stage
        if ($ExpectedVersion -and "$($NewManifest.version)+$($NewManifest.build)" -ne $ExpectedVersion) { throw 'Package version does not match release metadata.' }
        Assert-Program $Stage $NewManifest -Exact
        $OldVersion = [version]("$($OldManifest.version).$($OldManifest.build)")
        $NewVersion = [version]("$($NewManifest.version).$($NewManifest.build)")
        if ($NewVersion -le $OldVersion) { throw 'Update is not newer than the installed version.' }
        $OldRoots = @($OldManifest.files | ForEach-Object { $_.path.Split('/')[0] }) + @('streampath-release.json')
        $NewRoots = @($NewManifest.files | ForEach-Object { $_.path.Split('/')[0] }) + @('streampath-release.json')
        $Roots = @($OldRoots + $NewRoots | Sort-Object -Unique)
        foreach ($Name in $NewRoots) {
            if ($Name -notin $OldRoots -and (Test-Path -LiteralPath (Resolve-Child $Target $Name))) { throw 'New program artifact conflicts with an unowned user file.' }
        }
        if ($Installed) {
            $Roots += @('streampath-installed', 'unins000.exe', 'unins000.dat', 'unins000.msg')
            & reg.exe export $UninstallKey (Join-Path $Transaction 'uninstall.reg') /y 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not back up installed application registration.' }
        }
        $Backup = Join-Path $Transaction 'backup'
        New-Item -ItemType Directory -Path $Backup | Out-Null
        $Records = @()
        foreach ($Name in $Roots) {
            $Path = Resolve-Child $Target $Name
            $Exists = Test-Path -LiteralPath $Path
            if ($Exists) {
                if (@(Get-ChildItem -LiteralPath $Path -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Program snapshot contains a reparse point.' }
                Copy-Item -LiteralPath $Path -Destination (Join-Path $Backup $Name) -Recurse -Force
            }
            $Records += [ordered]@{ name = $Name; existed = [bool]$Exists }
        }
        $Journal = [ordered]@{ schema = 1; target = $Target; roots = $Records }
        foreach ($BackupFile in Get-ChildItem -LiteralPath $Backup -Recurse -File) {
            $BackupStream = [IO.File]::Open($BackupFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try { $BackupStream.Flush($true) } finally { $BackupStream.Dispose() }
        }
        $PendingTemporary = $Pending + '.tmp'
        [IO.File]::WriteAllText($PendingTemporary, ($Journal | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        $JournalStream = [IO.File]::Open($PendingTemporary, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $JournalStream.Flush($true) } finally { $JournalStream.Dispose() }
        [IO.File]::Move($PendingTemporary, $Pending)
        if ($Installed) {
            Invoke-Setup $Target
        } else {
            foreach ($Name in $OldRoots | Sort-Object -Unique) {
                if ($Name -notin $NewRoots) { Remove-OwnedRoot $Name }
            }
            foreach ($Name in $NewRoots | Sort-Object -Unique) { Set-OwnedRoot $Stage $Name }
        }
        Assert-Program $Target $NewManifest
        if ($Installed) {
            foreach ($Name in $OldRoots | Sort-Object -Unique) {
                if ($Name -notin $NewRoots) { Remove-OwnedRoot $Name }
            }
        }
        Remove-Item -LiteralPath $Pending -Force
    }
    $ResultJson = if ($Recover) { '{"success":false,"recovered":true}' } else { '{"success":true}' }
    [IO.File]::WriteAllText((Join-Path $Target '.streampath-update-result.json'), $ResultJson, [Text.UTF8Encoding]::new($false))
} catch {
    $Failure = $_
    if ($Locked -and (Test-Path -LiteralPath $Pending)) {
        try { Restore-Snapshot } catch {
            [IO.File]::WriteAllText((Join-Path $Transaction 'recovery-error.log'), $_.ToString())
            throw 'Update recovery failed. Program snapshots have been preserved.'
        }
    }
    if (Test-Path -LiteralPath $Transaction) { [IO.File]::WriteAllText((Join-Path $Transaction 'error.log'), $Failure.ToString()) }
    [IO.File]::WriteAllText((Join-Path $Target '.streampath-update-result.json'), '{"success":false}', [Text.UTF8Encoding]::new($false))
    throw $Failure
} finally {
    if ($Locked) { $UpdateMutex.ReleaseMutex() }
    $UpdateMutex.Dispose()
    if ($Locked -and -not $NoRestart -and -not $Cancelled -and -not (Test-Path -LiteralPath $Pending)) {
        Start-Process -FilePath (Join-Path $Target 'streampath.exe') -WorkingDirectory $Target -WindowStyle Hidden
    }
}
