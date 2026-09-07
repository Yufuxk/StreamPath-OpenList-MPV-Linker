[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BaselineArchiveRoot,

    [Parameter(Mandatory = $true)]
    [string]$CandidateArchiveRoot,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Controlled', 'Real')]
    [string]$NetworkKind,

    [Parameter(Mandatory = $true)]
    [ValidateSet('AlternatingBaselineFirst', 'AlternatingCandidateFirst')]
    [string]$OrderPattern,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$MachineProfile,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$SampleId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$MpvProfile,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$NetworkProfile,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$NetworkShaping,

    [ValidateRange(5, 20)]
    [int]$MeasuredRunCount = 5,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][string[]]$Path
    )
    $current = $Root
    foreach ($segment in $Path) {
        if ($null -eq $current) {
            throw "Missing field: $($Path -join '.')"
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) {
            throw "Missing field: $($Path -join '.')"
        }
        $current = $property.Value
    }
    return $current
}

function Get-RequiredNumber {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][string[]]$Path
    )
    $value = Get-RequiredProperty -Root $Root -Path $Path
    if ($value -is [bool] -or $null -eq $value) {
        throw "Invalid numeric field: $($Path -join '.')"
    }
    try {
        $number = [Convert]::ToDouble(
            $value,
            [Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw "Invalid numeric field: $($Path -join '.')"
    }
    if ([Double]::IsNaN($number) -or [Double]::IsInfinity($number) -or
        $number -lt 0) {
        throw "Invalid numeric field: $($Path -join '.')"
    }
    return $number
}

function Get-Statistics {
    param([Parameter(Mandatory = $true)][double[]]$Values)
    if ($Values.Count -eq 0) {
        throw 'Cannot summarize an empty metric sample.'
    }
    $sorted = @($Values | Sort-Object)
    $middle = [Math]::Floor($sorted.Count / 2)
    $median = if (($sorted.Count % 2) -eq 0) {
        ($sorted[$middle - 1] + $sorted[$middle]) / 2
    } else {
        $sorted[$middle]
    }
    $p95Index = [Math]::Ceiling($sorted.Count * 0.95) - 1
    return [ordered]@{
        median = [Math]::Round($median, 3)
        p95 = [Math]::Round($sorted[$p95Index], 3)
        min = [Math]::Round($sorted[0], 3)
        max = [Math]::Round($sorted[-1], 3)
        samples = $sorted.Count
    }
}

function Test-ReportedErrors {
    param([Parameter(Mandatory = $true)]$Root)
    $property = $Root.PSObject.Properties['errors']
    return $null -ne $property -and @($property.Value).Count -gt 0
}

function Read-RunSet {
    param(
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][int]$RequiredCount
    )
    $resolvedRoot = (Resolve-Path -LiteralPath $ArchiveRoot).Path
    $directories = @(
        Get-ChildItem -LiteralPath $resolvedRoot -Directory |
            Where-Object { $_.Name -like 'iso_*' } |
            Sort-Object Name
    )
    if ($directories.Count -lt $RequiredCount) {
        throw "$Label requires $RequiredCount archived runs including one warm-up."
    }
    $directories = @($directories | Select-Object -Last $RequiredCount)
    $runs = @()
    for ($index = 0; $index -lt $directories.Count; $index++) {
        $summary = Get-Content -LiteralPath (
            Join-Path $directories[$index].FullName 'iso-performance.json'
        ) -Raw -Encoding UTF8 | ConvertFrom-Json
        $metrics = Get-Content -LiteralPath (
            Join-Path $directories[$index].FullName 'iso-bridge-metrics.json'
        ) -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($summary.version -ne 1 -or $summary.status -ne 'complete') {
            throw "$Label run $($index + 1) has an incomplete performance summary."
        }
        if ($metrics.version -ne 2 -or $metrics.bridge.final -ne $true) {
            throw "$Label run $($index + 1) requires final metrics v2."
        }
        if ((Test-ReportedErrors -Root $summary) -or
            (Test-ReportedErrors -Root $metrics)) {
            throw "$Label run $($index + 1) reported a collection error."
        }
        $created = Get-RequiredNumber -Root $metrics `
            -Path @('network', 'requestContextCreatedCount')
        $closed = Get-RequiredNumber -Root $metrics `
            -Path @('network', 'requestContextClosedCount')
        $live = Get-RequiredNumber -Root $metrics `
            -Path @('network', 'requestContextLive')
        if ($created -ne $closed -or $live -ne 0) {
            throw "$Label run $($index + 1) left a request context open."
        }
        $runs += [pscustomobject]@{
            ordinal = $index + 1
            warmup = $index -eq 0
            summary = $summary
            metrics = $metrics
        }
    }
    return $runs
}

function Get-SeekSamples {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $samples = @(
        Get-RequiredProperty -Root $Run.summary -Path @('seekSamples')
    )
    $legacy = @(
        Get-RequiredProperty -Root $Run.summary -Path @('seekRecoveryMs')
    )
    if ($samples.Count -eq 0 -or $samples.Count -ne $legacy.Count) {
        throw "$Label run $($Run.ordinal) has inconsistent seekSamples."
    }
    $validated = @()
    for ($index = 0; $index -lt $samples.Count; $index++) {
        $playlist = Get-RequiredProperty -Root $samples[$index] `
            -Path @('playlist')
        if ($playlist -isnot [string] -or $playlist -notmatch '^\d{5}$') {
            throw "$Label run $($Run.ordinal) has an invalid seek playlist."
        }
        $start = Get-RequiredNumber -Root $samples[$index] `
            -Path @('startPositionMs')
        $end = Get-RequiredNumber -Root $samples[$index] `
            -Path @('endPositionMs')
        $recovery = Get-RequiredNumber -Root $samples[$index] `
            -Path @('recoveryMs')
        $legacyRecovery = Get-RequiredNumber `
            -Root ([pscustomobject]@{ value = $legacy[$index] }) `
            -Path @('value')
        if ($recovery -ne $legacyRecovery) {
            throw "$Label run $($Run.ordinal) does not align seekSamples with seekRecoveryMs."
        }
        $validated += [pscustomobject]@{
            playlist = $playlist
            startPositionMs = $start
            endPositionMs = $end
            recoveryMs = $recovery
        }
    }
    return $validated
}

function Get-TitleBudgets {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $plan = Get-RequiredProperty -Root $Run.summary -Path @('cachePlan')
    [void](Get-RequiredNumber -Root $plan -Path @('bridgeBytes'))
    $titles = @(Get-RequiredProperty -Root $plan -Path @('titles'))
    if ($titles.Count -eq 0) {
        throw "$Label run $($Run.ordinal) has no cache budget records."
    }
    $budgets = @{}
    $bitrates = @{}
    foreach ($title in $titles) {
        $playlist = Get-RequiredProperty -Root $title -Path @('playlist')
        if ($playlist -isnot [string] -or $playlist -notmatch '^\d{5}$' -or
            $budgets.ContainsKey($playlist)) {
            throw "$Label run $($Run.ordinal) has invalid cache budget keys."
        }
        $budgets[$playlist] = Get-RequiredNumber -Root $title `
            -Path @('totalBudgetBytes')
        $bitrateMbps = Get-RequiredNumber -Root $title `
            -Path @('bitrateMbps')
        if ($bitrateMbps -le 0) {
            throw "$Label run $($Run.ordinal) has an invalid title bitrate."
        }
        $bitrates[$playlist] = $bitrateMbps
        [void](Get-RequiredNumber -Root $title -Path @('mpvMaxBytes'))
    }
    return [pscustomobject]@{
        budgets = $budgets
        bitrates = $bitrates
    }
}

$totalRunCount = $MeasuredRunCount + 1
$baselineRuns = @(Read-RunSet -ArchiveRoot $BaselineArchiveRoot `
    -Label 'Baseline' -RequiredCount $totalRunCount)
$candidateRuns = @(Read-RunSet -ArchiveRoot $CandidateArchiveRoot `
    -Label 'Candidate' -RequiredCount $totalRunCount)

$phase4Fields = [ordered]@{
    networkRemoteTransferWallClockUs = @('network', 'remoteTransferWallClockUs')
    networkConcurrentTransferWallClockUs = @('network', 'concurrentTransferWallClockUs')
    cachePrefetchActivePeak = @('cache', 'prefetchActivePeak')
    cachePrefetchOverlapCount = @('cache', 'prefetchOverlapCount')
    cachePrefetchPendingGapUsTotal = @('cache', 'prefetchPendingGapUsTotal')
    cachePrefetchPendingGapUsMax = @('cache', 'prefetchPendingGapUsMax')
    cachePrefetchInFlightBytesPeak = @('cache', 'prefetchInFlightBytesPeak')
    cachePrefetchHitBytes = @('cache', 'prefetchHitBytes')
    cachePrefetchConcurrentWallClockUs = @('cache', 'prefetchConcurrentWallClockUs')
}
$allRuns = @($baselineRuns) + @($candidateRuns)
foreach ($name in $phase4Fields.Keys) {
    $presence = 0
    foreach ($run in $allRuns) {
        $current = $run.metrics
        $present = $true
        foreach ($segment in $phase4Fields[$name]) {
            $property = $current.PSObject.Properties[$segment]
            if ($null -eq $property) {
                $present = $false
                break
            }
            $current = $property.Value
        }
        if ($present) { $presence++ }
    }
    if ($presence -eq 0) {
        throw "Phase 4 observability field is absent: $name"
    }
    if ($presence -ne $allRuns.Count) {
        throw "Phase 4 observability field mixes schemas: $name"
    }
}

$baselineSeek = @()
$candidateSeek = @()
$allPairsNotSlower = $true
$allSamplesUnderTenSeconds = $true
$budgetNotIncreased = $true
$pairedRuns = @()

$metricPaths = [ordered]@{
    throughputBytes = @('network', 'remoteBodyBytes')
    throughputWallUs = @('network', 'remoteTransferWallClockUs')
    pendingGapTotalUs = @('cache', 'prefetchPendingGapUsTotal')
    pendingGapMaxUs = @('cache', 'prefetchPendingGapUsMax')
    pausedCount = @('summary', 'pausedForCacheCount')
    pausedDurationMs = @('summary', 'pausedForCacheDurationMs')
    remoteBytes = @('network', 'remoteBodyBytes')
    requestCount = @('network', 'requestCount')
    prefetchUnusedBytes = @('cache', 'prefetchUnusedBytes')
    cancelledBytes = @('cache', 'cancelledPrefetchBytes')
}

$baselineMetrics = [ordered]@{}
$candidateMetrics = [ordered]@{}
foreach ($name in $metricPaths.Keys) {
    $baselineMetrics[$name] = @()
    $candidateMetrics[$name] = @()
}
$baselineThroughput = @()
$candidateThroughput = @()
$candidatePrefetchPeaks = @()
$candidateRemotePeaks = @()
$baselineUpstreamRatios = @()
$entrySignalObserved = $true

for ($runIndex = 0; $runIndex -lt $totalRunCount; $runIndex++) {
    $baselineRun = $baselineRuns[$runIndex]
    $candidateRun = $candidateRuns[$runIndex]
    $baselineSamples = @(Get-SeekSamples -Run $baselineRun -Label 'Baseline')
    $candidateSamples = @(Get-SeekSamples -Run $candidateRun -Label 'Candidate')
    if ($baselineSamples.Count -ne $candidateSamples.Count) {
        throw "Paired run $($runIndex + 1) has a different seek count."
    }
    for ($sampleIndex = 0; $sampleIndex -lt $baselineSamples.Count; $sampleIndex++) {
        $baselineSample = $baselineSamples[$sampleIndex]
        $candidateSample = $candidateSamples[$sampleIndex]
        if ($baselineSample.playlist -ne $candidateSample.playlist -or
            $baselineSample.startPositionMs -ne $candidateSample.startPositionMs) {
            throw "Paired run $($runIndex + 1) seek $($sampleIndex + 1) targets a different position."
        }
        if (-not $baselineRun.warmup) {
            $baselineSeek += $baselineSample.recoveryMs
            $candidateSeek += $candidateSample.recoveryMs
            if ($NetworkKind -eq 'Controlled' -and
                $candidateSample.recoveryMs -gt $baselineSample.recoveryMs) {
                $allPairsNotSlower = $false
            }
            if ($candidateSample.recoveryMs -gt 10000) {
                $allSamplesUnderTenSeconds = $false
            }
        }
    }

    $baselinePlan = Get-TitleBudgets -Run $baselineRun -Label 'Baseline'
    $candidatePlan = Get-TitleBudgets -Run $candidateRun -Label 'Candidate'
    if ($baselinePlan.budgets.Count -ne $candidatePlan.budgets.Count) {
        throw "Paired run $($runIndex + 1) has different cache budget titles."
    }
    foreach ($playlist in $baselinePlan.budgets.Keys) {
        if (-not $candidatePlan.budgets.ContainsKey($playlist)) {
            throw "Paired run $($runIndex + 1) has different cache budget titles."
        }
        if ($candidatePlan.bitrates[$playlist] -ne
            $baselinePlan.bitrates[$playlist]) {
            throw "Paired run $($runIndex + 1) has different title bitrates."
        }
        if ($candidatePlan.budgets[$playlist] -gt
            $baselinePlan.budgets[$playlist]) {
            $budgetNotIncreased = $false
        }
    }

    if (-not $baselineRun.warmup) {
        foreach ($name in $metricPaths.Keys) {
            $path = $metricPaths[$name]
            if ($path[0] -eq 'summary') {
                $baselineValue = Get-RequiredNumber -Root $baselineRun.summary `
                    -Path @($path[1])
                $candidateValue = Get-RequiredNumber -Root $candidateRun.summary `
                    -Path @($path[1])
            } else {
                $baselineValue = Get-RequiredNumber -Root $baselineRun.metrics `
                    -Path $path
                $candidateValue = Get-RequiredNumber -Root $candidateRun.metrics `
                    -Path $path
            }
            $baselineMetrics[$name] += $baselineValue
            $candidateMetrics[$name] += $candidateValue
        }
        $baselineWall = $baselineMetrics['throughputWallUs'][-1]
        $candidateWall = $candidateMetrics['throughputWallUs'][-1]
        if ($baselineWall -le 0 -or $candidateWall -le 0) {
            throw "Paired run $($runIndex + 1) has no transfer wall-clock sample."
        }
        $baselineThroughput +=
            $baselineMetrics['throughputBytes'][-1] * 1000000 / $baselineWall
        $candidateThroughput +=
            $candidateMetrics['throughputBytes'][-1] * 1000000 / $candidateWall
        $maximumBitrateMbps = (
            $baselinePlan.bitrates.Values | Measure-Object -Maximum
        ).Maximum
        $baselineUpstreamRatios +=
            $baselineThroughput[-1] / ($maximumBitrateMbps * 125000)
        if ($baselineMetrics['pausedCount'][-1] -le 0 -and
            $baselineMetrics['pausedDurationMs'][-1] -le 0 -and
            $baselineMetrics['pendingGapTotalUs'][-1] -le
                $baselineMetrics['pendingGapMaxUs'][-1]) {
            $entrySignalObserved = $false
        }
        $candidatePrefetchPeaks += Get-RequiredNumber `
            -Root $candidateRun.metrics -Path @('cache', 'prefetchActivePeak')
        $candidateRemotePeaks += Get-RequiredNumber `
            -Root $candidateRun.metrics -Path @('network', 'activeRequestPeak')
    }
    $pairedRuns += [pscustomobject]@{
        ordinal = $runIndex + 1
        warmup = $baselineRun.warmup
        seekCount = $baselineSamples.Count
    }
}

$baselineSeekStats = Get-Statistics -Values @($baselineSeek)
$candidateSeekStats = Get-Statistics -Values @($candidateSeek)
$seekAggregateNotSlower =
    $candidateSeekStats.median -le $baselineSeekStats.median -and
    $candidateSeekStats.p95 -le $baselineSeekStats.p95 -and
    $candidateSeekStats.max -le $baselineSeekStats.max
$baselineThroughputStats = Get-Statistics -Values @($baselineThroughput)
$candidateThroughputStats = Get-Statistics -Values @($candidateThroughput)
$throughputImproved = $candidateThroughputStats.median -ge
    $baselineThroughputStats.median * 1.10

$baselineGapTotalStats = Get-Statistics -Values @($baselineMetrics['pendingGapTotalUs'])
$candidateGapTotalStats = Get-Statistics -Values @($candidateMetrics['pendingGapTotalUs'])
$baselineGapMaxStats = Get-Statistics -Values @($baselineMetrics['pendingGapMaxUs'])
$candidateGapMaxStats = Get-Statistics -Values @($candidateMetrics['pendingGapMaxUs'])
$gapsReduced =
    $candidateGapTotalStats.median -le $baselineGapTotalStats.median * 0.50 -and
    $candidateGapMaxStats.median -le $baselineGapMaxStats.median * 0.50

$pausedNotIncreased = $true
foreach ($name in @('pausedCount', 'pausedDurationMs')) {
    $baseline = Get-Statistics -Values @($baselineMetrics[$name])
    $candidate = Get-Statistics -Values @($candidateMetrics[$name])
    if ($candidate.median -gt $baseline.median -or
        $candidate.p95 -gt $baseline.p95 -or
        $candidate.max -gt $baseline.max) {
        $pausedNotIncreased = $false
    }
}

$overheadWithinFivePercent = $true
foreach ($name in @('remoteBytes', 'requestCount', 'prefetchUnusedBytes', 'cancelledBytes')) {
    $baseline = Get-Statistics -Values @($baselineMetrics[$name])
    $candidate = Get-Statistics -Values @($candidateMetrics[$name])
    if ($candidate.median -gt $baseline.median * 1.05 -or
        $candidate.max -gt $baseline.max * 1.05) {
        $overheadWithinFivePercent = $false
    }
}

$prefetchPeakBounded = ($candidatePrefetchPeaks | Measure-Object -Maximum).Maximum -le 2
$remotePeakBounded = ($candidateRemotePeaks | Measure-Object -Maximum).Maximum -le 3
$minimumUpstreamRatio = (
    $baselineUpstreamRatios | Measure-Object -Minimum
).Minimum
$entryConditionSatisfied =
    $minimumUpstreamRatio -ge 1.20 -and $entrySignalObserved
$gates = [ordered]@{
    baselineEntryConditionSatisfied = $entryConditionSatisfied
    controlledSeekPairsNotSlower =
        $NetworkKind -ne 'Controlled' -or $allPairsNotSlower
    seekAggregateNotSlower = $seekAggregateNotSlower
    allSeekSamplesAtMostTenSeconds = $allSamplesUnderTenSeconds
    medianThroughputImprovedAtLeastTenPercent = $throughputImproved
    pendingGapTotalAndMaxReducedAtLeastHalf = $gapsReduced
    pausedForCacheNotIncreased = $pausedNotIncreased
    remoteOverheadWithinFivePercent = $overheadWithinFivePercent
    prefetchPeakAtMostTwo = $prefetchPeakBounded
    remotePeakAtMostThree = $remotePeakBounded
    bridgeAndMpvBudgetNotIncreased = $budgetNotIncreased
}
$adoptable = -not ($gates.Values -contains $false)
$report = [ordered]@{
    version = 1
    machineProfile = $MachineProfile
    sampleId = $SampleId
    mpvProfile = $MpvProfile
    networkProfile = $NetworkProfile
    networkShaping = $NetworkShaping
    networkKind = $NetworkKind
    orderPattern = $OrderPattern
    warmupRunCount = 1
    measuredRunCount = $MeasuredRunCount
    seek = [ordered]@{
        baseline = $baselineSeekStats
        candidate = $candidateSeekStats
    }
    throughputBytesPerSecond = [ordered]@{
        baseline = $baselineThroughputStats
        candidate = $candidateThroughputStats
    }
    baselineUpstreamToBitrateRatio = Get-Statistics `
        -Values @($baselineUpstreamRatios)
    pendingGapUs = [ordered]@{
        baselineTotal = $baselineGapTotalStats
        candidateTotal = $candidateGapTotalStats
        baselineMax = $baselineGapMaxStats
        candidateMax = $candidateGapMaxStats
    }
    gates = $gates
    adoptable = $adoptable
    runs = $pairedRuns
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = [IO.Path]::GetDirectoryName($resolvedOutput)
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}
$utf8WithoutBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText(
    $resolvedOutput,
    ($report | ConvertTo-Json -Depth 14),
    $utf8WithoutBom
)
Write-Host "ISO Phase 4 paired report written: $resolvedOutput"
if (-not $adoptable) {
    throw 'Phase 4 candidate failed one or more adoption gates.'
}
