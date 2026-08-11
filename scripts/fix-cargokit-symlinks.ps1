<#
.SYNOPSIS
    修补 cargokit 在 Windows 上解析符号链接时产生的非致命错误输出。

.DESCRIPTION
    脚本只修改当前项目目录内的 cargokit 副本，并保持幂等。指向全局
    Pub 缓存的 plugin_symlinks 会被跳过，避免影响其他 Flutter 项目。
    找不到预期代码结构时不会写入文件，避免误改新版第三方脚本。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$marker = 'Get-Item $realPath -ErrorAction SilentlyContinue'
$ephemeral = Join-Path $PSScriptRoot '..\windows\flutter\ephemeral\.plugin_symlinks'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectPrefix = $projectRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) +
    [IO.Path]::DirectorySeparatorChar

if (-not (Test-Path -LiteralPath $ephemeral -PathType Container)) {
    Write-Warning "找不到 plugin_symlinks：$ephemeral。请先执行 flutter pub get。"
    exit 1
}

$files = @(
    Get-ChildItem -LiteralPath $ephemeral -Directory -ErrorAction Stop |
        ForEach-Object {
            $link = Get-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            $target = if ($link.Target) { $link.Target } else { $link.LinkTarget }
            if ($target) {
                $candidate = Join-Path $target 'cargokit\cmake\resolve_symlinks.ps1'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $candidatePath = [IO.Path]::GetFullPath(
                        (Get-Item -LiteralPath $candidate -Force).FullName
                    )
                    if ($candidatePath.StartsWith(
                            $projectPrefix,
                            [StringComparison]::OrdinalIgnoreCase
                        )) {
                        $candidatePath
                    } else {
                        Write-Warning "跳过项目目录外的 cargokit 脚本：$candidatePath"
                    }
                }
            }
        } |
        Select-Object -Unique
)

if ($files.Count -eq 0) {
    Write-Host '没有发现需要修补的 cargokit 脚本。'
    exit 0
}

$originalFirst = '        $item = Get-Item $realPath'
$originalNext = '        if ($item.LinkTarget) {'
$replacementLines = @(
    '        $item = Get-Item $realPath -ErrorAction SilentlyContinue',
    '        if ($null -eq $item) {',
    '            # 无法解析当前链接段时保留已累积路径，并继续处理后续段。',
    '            continue',
    '        }',
    '        if ($item.LinkTarget) {'
)

foreach ($file in $files) {
    $content = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    if ($content.Contains($marker)) {
        Write-Host "已是容错版本，跳过：$file"
        continue
    }

    $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $original = $originalFirst + $newline + $originalNext
    if (-not $content.Contains($original)) {
        Write-Warning "脚本结构已变化，未自动修改：$file"
        continue
    }

    $replacement = $replacementLines -join $newline
    $updated = $content.Replace($original, $replacement)
    Set-Content -LiteralPath $file -Value $updated -Encoding UTF8 -NoNewline
    Write-Host "已修补：$file"
}

Write-Host '处理完成。'
