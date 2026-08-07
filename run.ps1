# =============================================================
# StreamPath 运行脚本（通用版）
# 功能：选择运行 Debug 或 Release 模式，选择后开始运行。
# 用法（放在项目根目录）：
#   powershell -ExecutionPolicy Bypass -File .\run.ps1
# =============================================================

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
Set-Location $Root

Write-Host '=== StreamPath 运行 ===' -ForegroundColor Cyan

# ── 选择运行模式 ──
$mode = ''
while ($mode -notin @('1', '2')) {
    Write-Host '请选择运行模式：'
    Write-Host '  [1] Debug'
    Write-Host '  [2] Release'
    $mode = Read-Host '请输入 1 或 2'
}

$modeName = if ($mode -eq '1') { 'debug' } else { 'release' }
Write-Host "开始运行：$modeName ..." -ForegroundColor Yellow

flutter run -d windows --$modeName

if ($LASTEXITCODE -ne 0) {
    Write-Host "运行结束（退出码：$LASTEXITCODE）" -ForegroundColor Red
    exit $LASTEXITCODE
}
