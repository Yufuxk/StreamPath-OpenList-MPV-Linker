param(
    [Parameter(Mandatory = $true)][string]$Baseline,
    [Parameter(Mandatory = $true)][string]$Candidate,
    [Parameter(Mandatory = $true)][string]$Output,
    [int[]]$Sizes = @(24, 100, 300, 1000),
    [int]$Repeats = 3,
    [int]$RunOffset = 0,
    [ValidateSet('baseline', 'candidate')][string[]]$Labels = @('baseline', 'candidate')
)
$ErrorActionPreference = 'Stop'
$bundles = @{ baseline = (Resolve-Path -LiteralPath $Baseline).Path; candidate = (Resolve-Path -LiteralPath $Candidate).Path }
foreach ($bundle in $bundles.Values) {
    if (-not (Split-Path $bundle -Leaf).StartsWith('detail-profile-lab-')) { throw 'Only isolated detail-profile-lab-* bundles are allowed' }
}
New-Item -ItemType Directory -Path $Output -Force | Out-Null
foreach ($size in $Sizes) {
    for ($repeat = 1; $repeat -le $Repeats; $repeat++) {
        foreach ($label in $Labels) {
            $bundle = $bundles[$label]
            $run = "r$($repeat + $RunOffset)"
            $result = Join-Path $bundle "$size-$run.json"
            if (Test-Path -LiteralPath $result) { throw "Result already exists: $result" }
            $process = Start-Process -FilePath (Join-Path $bundle 'streampath.exe') -ArgumentList "$size", $run -WorkingDirectory $bundle -WindowStyle Hidden -PassThru
            $samples = [System.Collections.Generic.List[object]]::new()
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $process.HasExited) {
                if ($timer.Elapsed.TotalMinutes -gt 10) { Stop-Process -Id $process.Id; throw "Probe timed out: $label $size $run" }
                $process.Refresh()
                if (-not $process.HasExited) {
                    $samples.Add([pscustomobject]@{ elapsedMs = $timer.ElapsedMilliseconds; pid = $process.Id;
                        workingSet = $process.WorkingSet64; privateBytes = $process.PrivateMemorySize64;
                        cpuMs = $process.TotalProcessorTime.TotalMilliseconds; handles = $process.HandleCount })
                }
                Start-Sleep -Milliseconds 100
            }
            $process.WaitForExit()
            if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $result)) {
                $errorLog = Join-Path $bundle 'error.log'
                if (Test-Path -LiteralPath $errorLog) { Get-Content -LiteralPath $errorLog -Encoding UTF8 }
                throw "Probe failed: $label $size $run exit=$($process.ExitCode)"
            }
            Copy-Item -LiteralPath $result -Destination (Join-Path $Output "$label-$size-$run.json")
            Copy-Item -LiteralPath (Join-Path $bundle "$size-$run.png") -Destination (Join-Path $Output "$label-$size-$run.png")
            $samples | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Output "$label-$size-$run-process.json") -Encoding UTF8
            Write-Output "Completed $label count=$size run=$run samples=$($samples.Count)"
        }
    }
}
