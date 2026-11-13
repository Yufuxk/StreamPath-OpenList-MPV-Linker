param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility')
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Archive')
$Root = [IO.Path]::GetFullPath($Destination)
$Manifest = Join-Path $Root 'runtime-manifest.json'
if (Test-Path -LiteralPath $Manifest) {
    $Existing = Get-Content -LiteralPath $Manifest -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($Entry in $Existing.files.PSObject.Properties) {
        $File = Join-Path $Root $Entry.Name
        if (-not (Test-Path -LiteralPath $File) -or (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -ne $Entry.Value) {
            throw "BD-J runtime cache integrity failure: $($Entry.Name)"
        }
    }
    return
}
New-Item -ItemType Directory -Path $Root -Force | Out-Null
$Downloads = Join-Path $Root '_downloads'
New-Item -ItemType Directory -Path $Downloads -Force | Out-Null
function Get-LockedFile([string]$Url, [string]$Name, [string]$Hash) {
    $File = Join-Path $Downloads $Name
    if (-not (Test-Path -LiteralPath $File)) { Invoke-WebRequest -Uri $Url -OutFile $File -UseBasicParsing }
    if ((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -ne $Hash) { throw "BD-J dependency hash mismatch: $Name" }
    return $File
}
$JavaUrl = 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.21%2B9/OpenJDK17U-jre_x64_windows_hotspot_17.0.21_9.zip'
$JarUrl = 'https://deb.debian.org/debian/pool/main/libb/libbluray/libbluray-bdj_1.5.0-3_all.deb'
$JavaZip = Get-LockedFile $JavaUrl 'java.zip' 'fe4656bd78fb09812dc38c49da777f79cc33e7ee435a254be82f9e7f40d9d117'
$Deb = Get-LockedFile $JarUrl 'bdj.deb' 'd6de52a0c27457696faaf127d70c4c344f9bdf6d6fa6910eba4d7df7a6f783ed'
Expand-Archive -LiteralPath $JavaZip -DestinationPath $Downloads -Force
New-Item -ItemType Directory -Path (Join-Path $Root 'java') -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $Downloads 'jdk-17.0.21+9-jre') | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Root 'java') -Recurse -Force
}
& tar -xf $Deb -C $Downloads data.tar.xz
if ($LASTEXITCODE -ne 0) { throw 'Could not unpack BD-J package' }
& tar -xf (Join-Path $Downloads 'data.tar.xz') -C $Downloads
if ($LASTEXITCODE -ne 0) { throw 'Could not unpack BD-J data' }
foreach ($Name in @('libbluray-j2se-1.5.0.jar','libbluray-awt-j2se-1.5.0.jar')) {
    Copy-Item -LiteralPath (Join-Path $Downloads "usr/share/java/$Name") -Destination $Root -Force
}
$Licenses = Join-Path $Root 'licenses'
New-Item -ItemType Directory -Path $Licenses -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $Downloads 'usr/share/doc/libbluray-bdj/copyright') -Destination (Join-Path $Licenses 'libbluray-copyright.txt') -Force
$Files = [ordered]@{}
Get-ChildItem -LiteralPath (Join-Path $Root 'java') -File -Recurse | ForEach-Object {
    $Relative = $_.FullName.Substring($Root.Length + 1).Replace('\','/')
    $Files[$Relative] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
foreach ($Name in @('libbluray-j2se-1.5.0.jar','libbluray-awt-j2se-1.5.0.jar')) {
    $Files[$Name] = (Get-FileHash -LiteralPath (Join-Path $Root $Name) -Algorithm SHA256).Hash.ToLowerInvariant()
}
[ordered]@{schema=1;architecture='x64';javaVersion='17.0.21+9';jarVersion='1.5.0-3';javaSource=$JavaUrl;jarSource=$JarUrl;sourceCode=@('https://github.com/adoptium/jdk17u/tree/jdk-17.0.21+9','https://deb.debian.org/debian/pool/main/libb/libbluray/');files=$Files} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Manifest -Encoding utf8
