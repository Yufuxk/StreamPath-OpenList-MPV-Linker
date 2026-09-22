# 旧版 SendKeys 辅助，仅保留供历史验收复查。
param([string]$pidTarget, [string]$keys)
$ws = New-Object -ComObject WScript.Shell
$ok = $ws.AppActivate([int]$pidTarget)
Start-Sleep -Milliseconds 400
if ($ok) { $ws.SendKeys($keys); Write-Host "sent '$keys' to pid $pidTarget (activated=$ok)" }
else { Write-Host "activate failed for pid $pidTarget" }
