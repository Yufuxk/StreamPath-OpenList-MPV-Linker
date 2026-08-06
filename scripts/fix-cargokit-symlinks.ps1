<<<<<<< ours
﻿<#
=======
<#
>>>>>>> theirs
.SYNOPSIS
    修复 cargokit 的 resolve_symlinks.ps1 在 Windows 下抛出的 "Get-Item 找不到项" 噪声错误。

.DESCRIPTION
    super_native_extensions / irondash_engine_context 等通过 cargokit 构建 Rust 代码的插件，
    在 Windows 上每次构建会调用 cargokit/cmake/resolve_symlinks.ps1 解析符号链接路径。
    上游脚本对 Get-Item 失败不做容错：当目录符号链接的目标带有 \\?\ 前缀或结尾反斜杠时，
    Get-Item 抛出 ObjectNotFound，错误信息会泄漏到 stderr，虽然不影响最终解析结果，
    但每次 flutter run 都会打印一行刺眼的红字。

    本脚本把 plugin_symlinks 涉及到的 cargokit resolve_symlinks.ps1 就地打上容错补丁，
    改成 Get-Item 失败时跳过本段 LinkTarget 重置、继续逐段累加，输出保持不变。
    幂等：已经打过补丁的文件不会被重复修改。

.NOTES
    需要写到 %LOCALAPPDATA%\Pub\Cache（沙盒外），首次执行可能触发 UAC/权限确认。
    不修改任何项目源代码（Dart/C++/CMake），只改 pub cache 内第三方插件的构建脚本。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
<<<<<<< ours
$marker = 'Get-Item $realPath -ErrorAction SilentlyContinue'
$nl = "`r`n"

=======

$marker = 'Get-Item $realPath -ErrorAction SilentlyContinue'

# 通过 ephemeral 的 plugin_symlinks 找到本次构建实际用到的、带 cargokit 的插件包。
>>>>>>> theirs
$ephemeral = Join-Path $PSScriptRoot '..\windows\flutter\ephemeral\.plugin_symlinks'
if (-not (Test-Path $ephemeral)) {
    Write-Warning "找不到 plugin_symlinks：$ephemeral。请先执行 flutter pub get 再运行本脚本。"
    exit 1
}

$files = Get-ChildItem -Path $ephemeral -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $sym = Get-Item -Force $_.FullName -ErrorAction SilentlyContinue
    $target = if ($sym.Target) { $sym.Target } else { $sym.LinkTarget }
    if (-not $target) { return }
    $ps1 = Join-Path $target 'cargokit\cmake\resolve_symlinks.ps1'
    if (Test-Path $ps1) { (Get-Item $ps1).FullName }
}

if (-not $files) {
    Write-Host "没有发现需要打补丁的 cargokit 脚本。"
    exit 0
}

<<<<<<< ours
$origLine = '        $item = Get-Item $realPath'
$origTail = '        if ($item.LinkTarget) {'
$patchedFirst  = '        $item = Get-Item $realPath -ErrorAction SilentlyContinue'
$patchedSkip   = '        if ($null -eq $item) {'
$patchedNote1  = '            # Windows 符号链接目标可能带 \\?\ 前缀或结尾反斜杠，导致 Get-Item 解析失败；'
$patchedNote2  = '            # 跳过本段 LinkTarget 重置、继续逐段累加，避免向 stderr 泄漏 ObjectNotFound 噪声。'
$patchedCont   = '            continue'
$patchedClose  = '        }'
$patchedTail   = '        if ($item.LinkTarget) {'

=======
>>>>>>> theirs
foreach ($f in ($files | Select-Object -Unique)) {
    $content = Get-Content -Raw -Path $f -Encoding UTF8
    if ($content.Contains($marker)) {
        Write-Host "已是容错版本，跳过：$f"
        continue
    }
<<<<<<< ours
    if (-not $content.Contains($origLine) -or -not $content.Contains($origTail)) {
=======

    $original = "        `$item = Get-Item `$realPath`r`n        if (`$item.LinkTarget) {"
    $patched  = "        `$item = Get-Item `$realPath -ErrorAction SilentlyContinue`r`n        if (`$null -eq `$item) {`r`n            # Windows 符号链接目标可能带 \\?\ 前缀或结尾反斜杠，导致 Get-Item 解析失败；`r`n            # 跳过本段 LinkTarget 重置、继续逐段累加，避免向 stderr 泄漏 ObjectNotFound 噪声。`r`n            continue`r`n        }`r`n        if (`$item.LinkTarget) {"

    if (-not $content.Contains($original)) {
>>>>>>> theirs
        Write-Warning "脚本结构已变化，未自动匹配：$f。请人工核对后再补丁。"
        continue
    }

<<<<<<< ours
    $replacement = ($patchedFirst + $nl + $patchedSkip + $nl + $patchedNote1 + $nl + $patchedNote2 + $nl + $patchedCont + $nl + $patchedClose + $nl + $patchedTail)
    $before = ($origLine + $nl + $origTail)
    $newContent = $content.Replace($before, $replacement)
    if ($newContent -eq $content) {
        $newContent = $content.Replace($origLine, $patchedFirst).Replace($origTail, "$patchedSkip" + $nl + $patchedNote1 + $nl + $patchedNote2 + $nl + $patchedCont + $nl + $patchedClose + $nl + $patchedTail)
    }
=======
    $newContent = $content.Replace($original, $patched)
>>>>>>> theirs
    Set-Content -Path $f -Value $newContent -Encoding UTF8 -NoNewline
    Write-Host "已修补：$f"
}

<<<<<<< ours
Write-Host "完成。"
=======
Write-Host "完成。"
>>>>>>> theirs
