param(
    [string]$Executable = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\windows\x64\runner\Release\streampath.exe')
)

$ErrorActionPreference = 'Stop'
if (Get-Process streampath -ErrorAction SilentlyContinue) {
    throw 'Close existing StreamPath processes before running this isolated test.'
}
$binary = Get-Item -LiteralPath $Executable
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('streampath_instance_' + [guid]::NewGuid().ToString('N'))
$testProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
$lease = $null

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class StreamPathWindowProbe {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MonitorInfo { public int Size; public Rect Monitor, Work; public int Flags; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string name, string title);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr window, int flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
}
'@

function Start-TestApp([string]$Path) {
    $process = Start-Process -FilePath $Path -WorkingDirectory (Split-Path -Parent $Path) -WindowStyle Hidden -PassThru
    $testProcesses.Add($process)
    return $process
}

function Wait-TestWindow {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $window = [StreamPathWindowProbe]::FindWindow('StreamPath.MainWindow', 'streampath')
        if ($window -ne [IntPtr]::Zero -and [StreamPathWindowProbe]::IsWindowVisible($window)) { return $window }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The primary window did not appear.'
}

function Assert-Secondary([string]$Path) {
    $process = Start-TestApp $Path
    if (-not $process.WaitForExit(5000) -or $process.ExitCode -ne 0) { throw 'A duplicate process did not exit successfully.' }
    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $Path) 'stream_path_data')) {
        throw 'A duplicate process initialized a data directory.'
    }
}

try {
    $portable = New-Item -ItemType Directory -Path (Join-Path $testRoot 'primary')
    $alternate = New-Item -ItemType Directory -Path (Join-Path $testRoot 'alternate')
    # 只复制构建产物，数据始终写入临时便携目录。
    Get-ChildItem -LiteralPath $binary.DirectoryName | Where-Object Name -ne 'stream_path_data' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $portable.FullName -Recurse
    }
    Get-ChildItem -LiteralPath $binary.DirectoryName -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $alternate.FullName
    }
    $primaryExe = Join-Path $portable.FullName 'streampath.exe'
    $alternateExe = Join-Path $alternate.FullName 'streampath.exe'
    $primary = Start-TestApp $primaryExe
    Write-Output 'Checking startup duplicates and initial geometry.'
    # 在首窗口出现前连续启动，副本故意不带 Dart data 目录。
    $burst = @(1..8 | ForEach-Object { Start-TestApp $alternateExe })
    foreach ($process in $burst) {
        if (-not $process.WaitForExit(5000) -or $process.ExitCode -ne 0) { throw 'Startup exclusivity failed.' }
    }
    $window = Wait-TestWindow
    $rect = [StreamPathWindowProbe+Rect]::new()
    $monitor = [StreamPathWindowProbe+MonitorInfo]::new()
    $monitor.Size = [Runtime.InteropServices.Marshal]::SizeOf($monitor)
    if (-not [StreamPathWindowProbe]::GetWindowRect($window, [ref]$rect) -or
        -not [StreamPathWindowProbe]::GetMonitorInfo([StreamPathWindowProbe]::MonitorFromWindow($window, 2), [ref]$monitor)) {
        throw 'Window geometry query failed.'
    }
    $dx = [Math]::Abs(($rect.Left + $rect.Right) - ($monitor.Work.Left + $monitor.Work.Right))
    $dy = [Math]::Abs(($rect.Top + $rect.Bottom) - ($monitor.Work.Top + $monitor.Work.Bottom))
    if ($dx -gt 2 -or $dy -gt 2) { throw "Initial window is not centered: $dx, $dy." }
    Assert-Secondary $alternateExe
    [void][StreamPathWindowProbe]::ShowWindow($window, 6)
    Assert-Secondary $alternateExe
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([StreamPathWindowProbe]::IsIconic($window) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
    if ([StreamPathWindowProbe]::IsIconic($window)) { throw 'Duplicate launch did not restore the minimized window.' }
    [void][StreamPathWindowProbe]::ShowWindow($window, 3)
    Assert-Secondary $alternateExe
    Start-Sleep -Milliseconds 100
    if (-not [StreamPathWindowProbe]::IsZoomed($window)) { throw 'Duplicate launch changed the maximized state.' }
    if (([StreamPathWindowProbe]::GetWindowLongPtr($window, -20).ToInt64() -band 8) -ne 0) { throw 'The window stayed permanently topmost.' }
    $foreground = [StreamPathWindowProbe]::GetForegroundWindow() -eq $window
    if (-not $foreground) { throw 'The primary window did not receive foreground focus.' }
    $primary.Refresh()
    if ($primary.HasExited -or @(Get-Process streampath).Count -ne 1) { throw 'More than one StreamPath instance is running.' }
    if (Test-Path -LiteralPath (Join-Path $alternate.FullName 'stream_path_data')) { throw 'The duplicate created data.' }

    # 保留内核对象句柄后终止测试主实例，验证 abandoned mutex 可以重新起播。
    $lease = [Threading.Mutex]::OpenExisting('Local\StreamPath.SingleInstance')
    Stop-Process -Id $primary.Id
    $primary.WaitForExit()
    $restart = Start-TestApp $primaryExe
    Write-Output 'Checking abandoned mutex restart.'
    Assert-Secondary $alternateExe
    $window = Wait-TestWindow
    $owner = [uint32]0
    [void][StreamPathWindowProbe]::GetWindowThreadProcessId($window, [ref]$owner)
    if ($owner -ne $restart.Id) { throw 'Abandoned mutex prevented restart.' }
    [void][StreamPathWindowProbe]::PostMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    if (-not $restart.WaitForExit(10000)) { throw 'Normal window close failed.' }
    $final = Start-TestApp $primaryExe
    Write-Output 'Checking restart after normal close.'
    Assert-Secondary $alternateExe
    $window = Wait-TestWindow
    [void][StreamPathWindowProbe]::PostMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    if (-not $final.WaitForExit(10000)) { throw 'Restart after normal close failed.' }
    [pscustomobject]@{
        StartupDuplicates = $burst.Count
        DuplicateDataWrites = 0
        CenterOffset = @(($dx / 2), ($dy / 2))
        MinimizedRestore = $true
        MaximizedPreserved = $true
        Foreground = $foreground
        PermanentTopmost = $false
        AbandonedRestart = $true
        NormalRestart = $true
    } | ConvertTo-Json
} finally {
    foreach ($process in $testProcesses) {
        $process.Refresh()
        if (-not $process.HasExited) { Stop-Process -Id $process.Id; $process.WaitForExit() }
        $process.Dispose()
    }
    if ($lease) { $lease.Dispose() }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notlike 'streampath_instance_*') {
        throw 'Unsafe temporary cleanup path.'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
