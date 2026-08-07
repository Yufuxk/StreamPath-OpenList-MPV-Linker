# =============================================================
# StreamPath 构建脚本（通用版）
# 功能：选择构建 Debug 或 Release 模式，选择后开始构建。
# 用法（放在项目根目录）：
#   powershell -ExecutionPolicy Bypass -File .\build.ps1
# =============================================================

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
Set-Location $Root

Write-Host '=== StreamPath 构建 ===' -ForegroundColor Cyan

# ── 选择构建模式 ──
$mode = ''
while ($mode -notin @('1', '2')) {
    Write-Host '请选择构建模式：'
    Write-Host '  [1] Debug'
    Write-Host '  [2] Release'
    $mode = Read-Host '请输入 1 或 2'
}

$modeName = if ($mode -eq '1') { 'debug' } else { 'release' }
Write-Host "开始构建：$modeName ..." -ForegroundColor Yellow

flutter build windows --$modeName

if ($LASTEXITCODE -ne 0) {
    Write-Host "构建失败（$modeName），退出码：$LASTEXITCODE" -ForegroundColor Red
    exit $LASTEXITCODE
}

$exe = Join-Path $Root "build\windows\x64\runner\$modeName\streampath.exe"
Write-Host "构建完成：$exe" -ForegroundColor Green
