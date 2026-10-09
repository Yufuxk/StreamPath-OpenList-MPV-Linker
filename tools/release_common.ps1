# 发布工具共用的版本与清单约定。
function Repair-StreamPathReleaseIntegrity {
    param([string]$Path)
    if (-not ('StreamPathReleaseSecurity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class StreamPathReleaseSecurity {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    private static extern uint GetNamedSecurityInfo(string name, int type, uint info,
        out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ConvertSecurityDescriptorToStringSecurityDescriptor(
        IntPtr descriptor, uint revision, uint info, out IntPtr text, out uint length);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr pointer);
    public static string ReadLabel(string path) {
        IntPtr owner, group, dacl, sacl, descriptor, text;
        uint error = GetNamedSecurityInfo(path, 1, 0x10, out owner, out group,
            out dacl, out sacl, out descriptor);
        if (error != 0) throw new Win32Exception((int)error);
        try {
            uint length;
            if (!ConvertSecurityDescriptorToStringSecurityDescriptor(descriptor, 1,
                0x10, out text, out length)) throw new Win32Exception();
            try { return Marshal.PtrToStringUni(text); }
            finally { LocalFree(text); }
        } finally { LocalFree(descriptor); }
    }
}
'@
    }
    $Item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ([StreamPathReleaseSecurity]::ReadLabel($Item.FullName) -match ';;;LW\)') {
        # 仅修正产物的完整性标签，保留原有访问权限。
        $Level = if ($Item.PSIsContainer) { '(OI)(CI)M' } else { 'M' }
        & "$env:SystemRoot\System32\icacls.exe" $Item.FullName /setintegritylevel $Level | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not restore medium integrity: $($Item.FullName)" }
        Write-Host "Restored medium integrity: $($Item.FullName)"
    }
}

function Get-StreamPathVersion {
    param([string]$Version, [int]$BuildNumber = 1)
    if ($Version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*))?$') {
        throw 'Version must contain two or three numeric components, for example 1.0 or 1.2.3.'
    }
    $Parts = @($Version.Split('.') | ForEach-Object { [int]$_ })
    if ($Parts.Count -eq 2) { $Parts += 0 }
    if (@($Parts | Where-Object { $_ -gt 65535 }).Count -or $BuildNumber -lt 1 -or $BuildNumber -gt 65535) {
        throw 'Version components must be 0..65535; build number must be 1..65535.'
    }
    [pscustomobject]@{
        Display = $Version
        Name = $Parts -join '.'
        Build = $BuildNumber
        Full = ($Parts -join '.') + '+' + $BuildNumber
        Windows = ($Parts -join '.') + '.' + $BuildNumber
    }
}

function Read-StreamPathReleaseOptions {
    param([string]$ProjectRoot, [string]$Version, [int]$BuildNumber, [string]$ReleaseDate)
    if (-not $Version) {
        $DefaultVersion = (Select-String -LiteralPath (Join-Path $ProjectRoot 'pubspec.yaml') -Pattern '^version: ([0-9.]+)\+([0-9]+)').Matches[0].Groups[1].Value
        $Version = Read-Host "Version [$DefaultVersion]"
        if (-not $Version) { $Version = $DefaultVersion }
    }
    if ($BuildNumber -eq 0) {
        $InputBuild = Read-Host 'Build number [1]'
        $BuildNumber = if ($InputBuild) { [int]$InputBuild } else { 1 }
    }
    if (-not $ReleaseDate) {
        $DefaultDate = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'China Standard Time').ToString('yyyyMMdd')
        $ReleaseDate = Read-Host "Release date [$DefaultDate]"
        if (-not $ReleaseDate) { $ReleaseDate = $DefaultDate }
    }
    [DateTime]::ParseExact($ReleaseDate, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture) | Out-Null
    [pscustomobject]@{ Version = Get-StreamPathVersion $Version $BuildNumber; Date = $ReleaseDate }
}

function Write-StreamPathProgramManifest {
    param([string]$Directory, [string]$Version, [int]$BuildNumber)
    $Root = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    if ((Test-Path -LiteralPath (Join-Path $Root 'stream_path_data')) -or
        (Test-Path -LiteralPath (Join-Path $Root 'streampath-installed'))) {
        throw 'Build output contains user data or an installation marker.'
    }
    $Files = @(
        Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
            $_.Name -ne 'streampath-release.json' -and $_.Extension -ne '.pdb'
        } | ForEach-Object {
            [ordered]@{
                path = $_.FullName.Substring($Root.Length + 1).Replace('\', '/')
                size = $_.Length
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )
    $Manifest = [ordered]@{ schema = 1; version = $Version; build = $BuildNumber; files = $Files }
    $Json = $Manifest | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText((Join-Path $Root 'streampath-release.json'), $Json, [Text.UTF8Encoding]::new($false))
}

function Write-StreamPathReleaseMetadata {
    param([string]$OutputDirectory, $Options, [string]$AssetPath, [ValidateSet('portable', 'installed')][string]$Kind)
    $MetadataPath = Join-Path $OutputDirectory 'StreamPath.release.json'
    $Assets = @()
    if (Test-Path -LiteralPath $MetadataPath) {
        $Previous = Get-Content -LiteralPath $MetadataPath -Raw -Encoding utf8 | ConvertFrom-Json
        if ($Previous.version -ne $Options.Version.Name -or $Previous.build -ne $Options.Version.Build -or $Previous.date -ne $Options.Date -or $Previous.displayVersion -ne $Options.Version.Display) {
            throw 'Output contains metadata for another release. Select an empty output directory.'
        }
        $Assets = @($Previous.assets | Where-Object { $_.kind -ne $Kind })
    }
    $Asset = Get-Item -LiteralPath $AssetPath
    $Assets += [ordered]@{
        kind = $Kind; platform = 'windows-x64'; name = $Asset.Name; size = $Asset.Length
        sha256 = (Get-FileHash -LiteralPath $AssetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $Metadata = [ordered]@{
        schema = 1; version = $Options.Version.Name; build = $Options.Version.Build
        displayVersion = $Options.Version.Display; date = $Options.Date; assets = $Assets
    }
    [IO.File]::WriteAllText($MetadataPath, ($Metadata | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}
