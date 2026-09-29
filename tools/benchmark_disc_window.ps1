param(
    [string]$SessionRoot = 'stream_path_data\cache\iso_temp',
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$sessionPath = [System.IO.Path]::GetFullPath($SessionRoot)
$watchStarted = [DateTime]::UtcNow

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class DiscWindowProbe {
    private delegate bool EnumWindowCallback(IntPtr window, IntPtr parameter);

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);

    public static bool IsVisible(int processId) {
        bool found = false;
        EnumWindows((window, parameter) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != processId || !IsWindowVisible(window) || IsIconic(window)) return true;
            Rect rect;
            if (!GetWindowRect(window, out rect) || rect.Right <= rect.Left || rect.Bottom <= rect.Top) return true;
            int cloaked;
            if (DwmGetWindowAttribute(window, 14, out cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
            found = true;
            return false;
        }, IntPtr.Zero);
        return found;
    }
}
'@
Write-Output 'READY'

$deadline = $watchStarted.AddSeconds($TimeoutSeconds)
$timing = $null
$timingFileWrittenUtcUs = $null
while ([DateTime]::UtcNow -lt $deadline) {
    if ([System.IO.Directory]::Exists($sessionPath)) {
        foreach ($directory in [System.IO.Directory]::EnumerateDirectories($sessionPath)) {
            $file = [System.IO.Path]::Combine($directory, 'disc-startup.json')
            if (-not [System.IO.File]::Exists($file)) { continue }
            $written = [System.IO.File]::GetLastWriteTimeUtc($file)
            if ($written -lt $watchStarted) { continue }
            try {
                $candidate = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
                if ($candidate.pid -and $candidate.firstClickUtcUs) {
                    $timing = $candidate
                    $timingFileWrittenUtcUs = ($written.Ticks - 621355968000000000) / 10
                    break
                }
            } catch [System.IO.IOException] {
                continue
            } catch [System.ArgumentException] {
                continue
            }
        }
    }
    if ($timing) { break }
    Start-Sleep -Milliseconds 20
}
if (-not $timing) { throw 'No new disc-startup.json was observed.' }

while ([DateTime]::UtcNow -lt $deadline) {
    if ([DiscWindowProbe]::IsVisible([int]$timing.pid)) {
        $visibleUtcUs = ([DateTime]::UtcNow.Ticks - 621355968000000000) / 10
        [pscustomobject]@{
            pid = [int]$timing.pid
            clickToWindowMs = [math]::Round(($visibleUtcUs - [double]$timing.firstClickUtcUs) / 1000, 1)
            processingToWindowMs = [math]::Round(($visibleUtcUs - [double]$timing.firstClickUtcUs) / 1000 - [double]$timing.titleSelectionWaitMs, 1)
            processToWindowMs = [math]::Round(($visibleUtcUs - [double]$timing.processStartedUtcUs) / 1000, 1)
            observerLagMs = [math]::Round(($visibleUtcUs - [double]$timingFileWrittenUtcUs) / 1000, 1)
            modeToProcessStartedMs = [int]$timing.modeToProcessStartedMs
        } | ConvertTo-Json -Compress
        exit 0
    }
    Start-Sleep -Milliseconds 20
}
throw 'MPV did not show a visible window before the timeout.'
