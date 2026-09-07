param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$runtime = Join-Path $PSScriptRoot 'winfsp-2.1.25156.msi'
$digest = '073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a'
if (!(Test-Path -LiteralPath $runtime -PathType Leaf)) { throw 'Bundled WinFsp installer is missing.' }
if ((Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash.ToLowerInvariant() -ne $digest) {
    throw 'WinFsp installer hash mismatch.'
}
$signature = Get-AuthenticodeSignature -LiteralPath $runtime
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=NAVIMATICS LLC,') {
    throw 'WinFsp installer signature is invalid.'
}
if ($CheckOnly) { Write-Output 'WinFsp installer hash and signature verified.'; exit 0 }
$installed = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\WinFsp' -Name InstallDir -ErrorAction SilentlyContinue
if ($installed -and (Test-Path -LiteralPath (Join-Path $installed.InstallDir 'bin\winfsp-x64.dll'))) {
    Write-Output 'WinFsp runtime is already installed.'
    exit 0
}
$install = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
    -ArgumentList @('/i', ('"' + $runtime + '"'), '/passive', '/norestart', 'ADDLOCAL=F.Main,F.User') `
    -Verb RunAs -WindowStyle Hidden -Wait -PassThru
if ($install.ExitCode -notin @(0, 3010)) { throw ('WinFsp installation failed: ' + $install.ExitCode) }
Write-Output $(if ($install.ExitCode -eq 3010) { 'WinFsp installed; Windows requires a restart.' } else { 'WinFsp runtime installed.' })
