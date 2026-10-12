param(
    [Parameter(Mandatory=$true)][string]$Bundle,
    [Parameter(Mandatory=$true)][ValidateSet('baseline','candidate')][string]$Label,
    [int[]]$Sizes = @(1000,5000,20000),
    [Parameter(Mandatory=$true)][string]$Output,
    [switch]$Natural
)
$ErrorActionPreference = 'Stop'
$bundlePath = (Resolve-Path -LiteralPath $Bundle).Path
if (-not (Split-Path $bundlePath -Leaf).StartsWith('film-memory-lab-')) {
    throw 'Only isolated film-memory-lab-* bundles are allowed'
}
New-Item -ItemType Directory -Path $Output -Force | Out-Null
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FilmProbeCounters {
    [StructLayout(LayoutKind.Sequential)]
    public struct IO { public ulong ReadCount, WriteCount, OtherCount, ReadBytes, WriteBytes, OtherBytes; }
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetProcessIoCounters(IntPtr process, out IO counters);
}
'@
foreach ($size in $Sizes) {
    $launch = [System.Diagnostics.ProcessStartInfo]::new()
    $launch.FileName = Join-Path $bundlePath 'streampath.exe'
    $launch.WorkingDirectory = $bundlePath
    $launch.UseShellExecute = $false
    $launch.CreateNoWindow = $true
    $launch.WindowStyle = 'Hidden'
    $launch.ArgumentList.Add($Label)
    $launch.ArgumentList.Add("$size")
    if ($Natural) { $launch.ArgumentList.Add('natural') }
    $process = [System.Diagnostics.Process]::Start($launch)
    $samples = [System.Collections.Generic.List[object]]::new()
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $process.HasExited) {
        $process.Refresh()
        if ($timer.Elapsed.TotalMinutes -gt 12) {
            Stop-Process -Id $process.Id
            throw "Isolated probe timed out for $size"
        }
        $io = [FilmProbeCounters+IO]::new()
        $hasIo = [FilmProbeCounters]::GetProcessIoCounters($process.Handle,[ref]$io)
        $samples.Add([pscustomobject]@{
            elapsedMs=$timer.ElapsedMilliseconds; pid=$process.Id;
            workingSet=$process.WorkingSet64; privateBytes=$process.PrivateMemorySize64;
            cpuMs=$process.TotalProcessorTime.TotalMilliseconds; handles=$process.HandleCount;
            readBytes=$(if ($hasIo) {$io.ReadBytes} else {$null});
            writeBytes=$(if ($hasIo) {$io.WriteBytes} else {$null});
            otherBytes=$(if ($hasIo) {$io.OtherBytes} else {$null})
        })
        Start-Sleep -Milliseconds 100
    }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        $errorFile = Join-Path $bundlePath 'probe-error.log'
        if (Test-Path -LiteralPath $errorFile) { Get-Content -LiteralPath $errorFile -Encoding UTF8 }
        throw "Probe exited with $($process.ExitCode)"
    }
    $result = Join-Path $bundlePath "$Label-$size.json"
    if (-not (Test-Path -LiteralPath $result)) { throw "Probe produced no result for $size" }
    Copy-Item -LiteralPath $result -Destination $Output
    $samples | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Output "$Label-$size-process.json") -Encoding utf8
    Write-Output "Completed $Label size=$size samples=$($samples.Count)"
}
