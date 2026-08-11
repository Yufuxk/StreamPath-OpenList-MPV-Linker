# =============================================================
# StreamPath 便携版打包入口
#
# 直接运行后输入目标目录；直接回车使用现有便携版目录。
# 脚本会调用 build.ps1 完成静态分析、全部测试、Release/AOT
# 构建和安全覆盖，并保留目标中的 stream_path_data 用户数据。
# =============================================================

param(
    [string]$Target
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
$BuildScript = Join-Path $ProjectRoot 'build.ps1'
$DefaultTarget = Join-Path (Split-Path $ProjectRoot -Parent) `
    'StreamPath_Release\StreamPath 20260809 V0.1 test portable'

if (-not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) {
    throw "未找到构建脚本：$BuildScript"
}

if ([string]::IsNullOrWhiteSpace($Target)) {
    Write-Host '=== StreamPath 便携版打包 ===' -ForegroundColor Cyan
    Write-Host "默认目录：$DefaultTarget"
    $Target = Read-Host '请输入打包目录（直接回车使用默认目录）'
    if ([string]::IsNullOrWhiteSpace($Target)) {
        $Target = $DefaultTarget
    }
}

# 允许从资源管理器复制带双引号的路径，但拒绝空路径。
$Target = [Environment]::ExpandEnvironmentVariables($Target.Trim().Trim('"'))
if ([string]::IsNullOrWhiteSpace($Target)) {
    throw '打包目录不能为空。'
}
$Target = [IO.Path]::GetFullPath($Target)

Write-Host "目标目录：$Target" -ForegroundColor Yellow
$Answer = Read-Host '确认构建并更新此便携目录？（Y/回车=继续，N=取消）'
if ($Answer -in @('n', 'N', 'no', 'NO')) {
    Write-Host '已取消打包。' -ForegroundColor Yellow
    exit 0
}

& $BuildScript -Mode release -Target $Target -Yes
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host '便携版已生成，可直接运行目标目录中的 streampath.exe。' `
    -ForegroundColor Green
