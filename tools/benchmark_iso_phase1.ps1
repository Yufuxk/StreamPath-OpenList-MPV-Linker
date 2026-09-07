[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchiveRoot,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Cold', 'Warm')]
    [string]$Mode,

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
    [int]$RunCount = 5,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredNumber {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][string[]]$Path
    )
    $current = $Root
    foreach ($segment in $Path) {
        if ($null -eq $current) {
            throw "Missing numeric metric: $($Path -join '.')"
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) {
            throw "Missing numeric metric: $($Path -join '.')"
        }
        $current = $property.Value
    }
    if ($current -is [bool] -or $null -eq $current) {
        throw "Invalid numeric metric: $($Path -join '.')"
    }
    try {
        $number = [Convert]::ToDouble(
            $current,
            [Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw "Invalid numeric metric: $($Path -join '.')"
    }
    if ([Double]::IsNaN($number) -or [Double]::IsInfinity($number) -or $number -lt 0) {
        throw "Invalid numeric metric: $($Path -join '.')"
    }
    return $number
}

function Get-RequiredBoolean {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][string[]]$Path
    )
    $current = $Root
    foreach ($segment in $Path) {
        if ($null -eq $current) {
            throw "Missing boolean metric: $($Path -join '.')"
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) {
            throw "Missing boolean metric: $($Path -join '.')"
        }
        $current = $property.Value
    }
    if ($current -isnot [bool]) {
        throw "Invalid boolean metric: $($Path -join '.')"
    }
    return [bool]$current
}

function Get-Statistics {
    param([Parameter(Mandatory = $true)][double[]]$Values)
    if ($Values.Count -eq 0) {
        throw 'Cannot summarize an empty metric sample.'
    }
    $sorted = @($Values | Sort-Object)
    $middle = [Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 0) {
        $median = ($sorted[$middle - 1] + $sorted[$middle]) / 2
    } else {
        $median = $sorted[$middle]
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

$resolvedArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot).Path
$runDirectories = @(
    Get-ChildItem -LiteralPath $resolvedArchiveRoot -Directory |
        Where-Object { $_.Name -like 'iso_*' } |
        Sort-Object Name
)
if ($runDirectories.Count -lt $RunCount) {
    throw "At least $RunCount archived runs are required; the first selected run is warm-up only."
}
$runDirectories = @($runDirectories | Select-Object -Last $RunCount)

$metricPaths = [ordered]@{
    openToProbeMs = @('timings', 'openToProbeMs')
    probeToTitlesMs = @('timings', 'probeToTitlesMs')
    selectionToLoopbackReadyMs = @('timings', 'selectionToLoopbackReadyMs')
    selectionToStablePlaybackMs = @('timings', 'selectionToStablePlaybackMs')
    mpvLaunchToStablePlaybackMs = @('timings', 'mpvLaunchToStablePlaybackMs')
    networkRequestCount = @('network', 'requestCount')
    networkRedirectCount = @('network', 'redirectCount')
    networkRedirectResolveCount = @('network', 'redirectResolveCount')
    networkResolvedUrlReuseCount = @('network', 'resolvedUrlReuseCount')
    networkResponseHeaderLatencyUsTotal = @('network', 'responseHeaderLatencyUsTotal')
    networkResponseBodyActiveUsTotal = @('network', 'responseBodyActiveUsTotal')
    networkRemoteBodyBytes = @('network', 'remoteBodyBytes')
    networkProbeBodyBytes = @('network', 'probeBodyBytes')
    networkActiveRequestPeak = @('network', 'activeRequestPeak')
    cacheForegroundFetchBytes = @('cache', 'foregroundFetchBytes')
    cachePrefetchFetchBytes = @('cache', 'prefetchFetchBytes')
    cacheConsumerBytesDelivered = @('cache', 'consumerBytesDelivered')
    cacheHitCount = @('cache', 'cacheHitCount')
    cacheMissCount = @('cache', 'cacheMissCount')
    cachePrefetchHitCount = @('cache', 'prefetchHitCount')
    cachePrefetchUnusedBytes = @('cache', 'prefetchUnusedBytes')
    cacheCancelledForegroundBytes = @('cache', 'cancelledForegroundBytes')
    cacheCancelledPrefetchBytes = @('cache', 'cancelledPrefetchBytes')
    cacheEvictionCount = @('cache', 'evictionCount')
    cacheRefetchCount = @('cache', 'refetchCount')
    blurayContextCreateCount = @('bluray', 'contextCreateCount')
    blurayContextCreateUsTotal = @('bluray', 'contextCreateUsTotal')
    blurayTitleEnumerationUs = @('bluray', 'titleEnumerationUs')
    blurayMediaGetCount = @('bluray', 'mediaGetCount')
}
$phase5MetricPaths = [ordered]@{
    metadataNetworkRequestCount = @('metadataNetwork', 'requestCount')
    metadataNetworkResponseHeaderLatencyUsTotal = @('metadataNetwork', 'responseHeaderLatencyUsTotal')
    metadataNetworkRemoteBodyBytes = @('metadataNetwork', 'remoteBodyBytes')
    playbackNetworkRequestCount = @('playbackNetwork', 'requestCount')
    playbackNetworkResponseHeaderLatencyUsTotal = @('playbackNetwork', 'responseHeaderLatencyUsTotal')
    playbackNetworkRemoteBodyBytes = @('playbackNetwork', 'remoteBodyBytes')
    metadataCacheRequestCount = @('metadataCache', 'requestCount')
    metadataCacheForegroundFetchBytes = @('metadataCache', 'foregroundFetchBytes')
    metadataCacheConsumerBytesDelivered = @('metadataCache', 'consumerBytesDelivered')
    metadataCacheHitCount = @('metadataCache', 'cacheHitCount')
    metadataCacheMissCount = @('metadataCache', 'cacheMissCount')
    metadataCacheEvictionCount = @('metadataCache', 'evictionCount')
    metadataCacheRefetchCount = @('metadataCache', 'refetchCount')
    metadataCacheCapacityBytes = @('metadataCache', 'capacityBytes')
    metadataCacheBlockBytes = @('metadataCache', 'blockBytes')
    metadataCacheRetainedBytes = @('metadataCache', 'retainedBytes')
    playbackCacheRequestCount = @('playbackCache', 'requestCount')
    playbackCacheForegroundFetchBytes = @('playbackCache', 'foregroundFetchBytes')
    playbackCacheConsumerBytesDelivered = @('playbackCache', 'consumerBytesDelivered')
    playbackCacheHitCount = @('playbackCache', 'cacheHitCount')
    playbackCacheMissCount = @('playbackCache', 'cacheMissCount')
    playbackCacheEvictionCount = @('playbackCache', 'evictionCount')
    playbackCacheRefetchCount = @('playbackCache', 'refetchCount')
    playbackCacheCapacityBytes = @('playbackCache', 'capacityBytes')
    playbackCacheBlockBytes = @('playbackCache', 'blockBytes')
}

$samples = [ordered]@{}
foreach ($name in $metricPaths.Keys) {
    $samples[$name] = @()
}
foreach ($name in $phase5MetricPaths.Keys) {
    $samples[$name] = @()
}
$samples['seekRecoveryMs'] = @()
$samples['titleSwitchGapMs'] = @()
$persistentContextReuseSamples = @()
$persistentContextReusePresence = 0
$phase5MetricsPresence = 0
$structureCacheHitPresence = 0
$structureCacheHitSamples = @()
$runs = @()

# 第一轮固定作为预热，只校验工件完整性，不进入统计。
for ($index = 0; $index -lt $runDirectories.Count; $index++) {
    $directory = $runDirectories[$index]
    $summaryPath = Join-Path $directory.FullName 'iso-performance.json'
    $metricsPath = Join-Path $directory.FullName 'iso-bridge-metrics.json'
    $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $metrics = Get-Content -LiteralPath $metricsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($summary.version -ne 1 -or $summary.status -ne 'complete') {
        throw "Incomplete performance summary in run $($index + 1)."
    }
    if ($metrics.version -ne 2) {
        throw "Metrics v2 is required in run $($index + 1)."
    }
    if ($metrics.bridge.final -ne $true) {
        throw "Final native metrics are required in run $($index + 1)."
    }
    $nativeErrorsProperty = $metrics.PSObject.Properties['errors']
    if ($null -ne $nativeErrorsProperty -and @($nativeErrorsProperty.Value).Count -gt 0) {
        throw "Native metric collection reported an error in run $($index + 1)."
    }
    $errorsProperty = $summary.PSObject.Properties['errors']
    if ($null -ne $errorsProperty -and @($errorsProperty.Value).Count -gt 0) {
        throw "Metric collection reported an error in run $($index + 1)."
    }

    $runValues = [ordered]@{}
    foreach ($name in $metricPaths.Keys) {
        $root = if ($name -like 'open*' -or
            $name -like 'probe*' -or
            $name -like 'selection*' -or
            $name -like 'mpvLaunch*') { $summary } else { $metrics }
        $value = Get-RequiredNumber -Root $root -Path $metricPaths[$name]
        $runValues[$name] = $value
        if ($index -gt 0) {
            $samples[$name] += $value
        }
    }
    $phase5RootsPresent = @(
        [bool]($null -ne $metrics.PSObject.Properties['metadataNetwork'])
        [bool]($null -ne $metrics.PSObject.Properties['playbackNetwork'])
        [bool]($null -ne $metrics.PSObject.Properties['metadataCache'])
        [bool]($null -ne $metrics.PSObject.Properties['playbackCache'])
    )
    $phase5PresentCount = @($phase5RootsPresent | Where-Object { $_ }).Count
    if ($phase5PresentCount -ne 0 -and $phase5PresentCount -ne 4) {
        throw "Phase 5 metric groups are incomplete in run $($index + 1)."
    }
    if ($phase5PresentCount -eq 4) {
        $phase5MetricsPresence++
        foreach ($name in $phase5MetricPaths.Keys) {
            $value = Get-RequiredNumber -Root $metrics -Path $phase5MetricPaths[$name]
            $runValues[$name] = $value
            if ($index -gt 0) {
                $samples[$name] += $value
            }
        }
    }
    $persistentContextReuseProperty =
        $metrics.bluray.PSObject.Properties['persistentContextReuseCount']
    $persistentContextReuseValue = $null
    if ($null -ne $persistentContextReuseProperty) {
        $persistentContextReuseValue = Get-RequiredNumber `
            -Root $metrics -Path @('bluray', 'persistentContextReuseCount')
        $persistentContextReusePresence++
        if ($index -gt 0) {
            $persistentContextReuseSamples += $persistentContextReuseValue
        }
    }
    $runValues['blurayPersistentContextReuseCount'] =
        $persistentContextReuseValue
    $structureCacheHitProperty =
        $metrics.bluray.PSObject.Properties['structureCacheHit']
    $structureCacheHit = $null
    if ($null -ne $structureCacheHitProperty) {
        $structureCacheHit = Get-RequiredBoolean `
            -Root $metrics -Path @('bluray', 'structureCacheHit')
        $structureCacheHitPresence++
        if ($index -gt 0) {
            $structureCacheHitSamples += $structureCacheHit
        }
    }
    $runValues['structureCacheHit'] = $structureCacheHit
    $seekValues = @($summary.seekRecoveryMs)
    $switchValues = @($summary.titleSwitchGapMs)
    if ($seekValues.Count -eq 0 -or $switchValues.Count -eq 0) {
        throw "Run $($index + 1) must include at least one seek and one automatic title switch."
    }
    if ($index -gt 0) {
        foreach ($value in $seekValues) {
            $samples['seekRecoveryMs'] += Get-RequiredNumber `
                -Root ([pscustomobject]@{ value = $value }) `
                -Path @('value')
        }
        foreach ($value in $switchValues) {
            $samples['titleSwitchGapMs'] += Get-RequiredNumber `
                -Root ([pscustomobject]@{ value = $value }) `
                -Path @('value')
        }
    }
    $runRecord = [ordered]@{
        ordinal = $index + 1
        warmup = $index -eq 0
        values = $runValues
        seekRecoveryMs = @($seekValues)
        titleSwitchGapMs = @($switchValues)
    }
    $runs += [pscustomobject]$runRecord
}

$statistics = [ordered]@{}
foreach ($name in $samples.Keys) {
    if (@($samples[$name]).Count -eq 0) {
        continue
    }
    $statistics[$name] = Get-Statistics -Values @($samples[$name])
}
if ($persistentContextReusePresence -ne 0 -and
    $persistentContextReusePresence -ne $runDirectories.Count) {
    throw 'persistentContextReuseCount must be present in every selected run or absent from every selected run.'
}
if ($persistentContextReusePresence -eq $runDirectories.Count) {
    $statistics['blurayPersistentContextReuseCount'] =
        Get-Statistics -Values @($persistentContextReuseSamples)
}
if ($phase5MetricsPresence -ne 0 -and
    $phase5MetricsPresence -ne $runDirectories.Count) {
    throw 'Phase 5 metric groups must be present in every selected run or absent from every selected run.'
}
if ($phase5MetricsPresence -eq 0) {
    foreach ($name in $phase5MetricPaths.Keys) {
        $statistics.Remove($name)
    }
}
if ($structureCacheHitPresence -ne 0 -and
    $structureCacheHitPresence -ne $runDirectories.Count) {
    throw 'structureCacheHit must be present in every selected run or absent from every selected run.'
}
$structureCacheSummary = $null
if ($structureCacheHitPresence -eq $runDirectories.Count) {
    $measuredHits = @($structureCacheHitSamples | Where-Object { $_ }).Count
    $measuredCount = $runDirectories.Count - 1
    if ($Mode -eq 'Warm' -and $measuredHits -ne $measuredCount) {
        throw 'Every measured Warm run must report structureCacheHit=true.'
    }
    if ($Mode -eq 'Cold' -and $measuredHits -ne 0) {
        throw 'Every measured Cold run must report structureCacheHit=false.'
    }
    $structureCacheSummary = [ordered]@{
        hits = $measuredHits
        misses = $measuredCount - $measuredHits
        hitRate = [Math]::Round($measuredHits / $measuredCount, 3)
    }
}
$report = [ordered]@{
    version = 1
    mode = $Mode
    machineProfile = $MachineProfile
    sampleId = $SampleId
    mpvProfile = $MpvProfile
    networkProfile = $NetworkProfile
    networkShaping = $NetworkShaping
    runCount = $runDirectories.Count
    warmupExcluded = 1
    measuredRunCount = $runDirectories.Count - 1
    statistics = $statistics
    runs = $runs
}
if ($null -ne $structureCacheSummary) {
    $report['structureCache'] = $structureCacheSummary
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = [IO.Path]::GetDirectoryName($resolvedOutput)
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}
$utf8WithoutBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText(
    $resolvedOutput,
    ($report | ConvertTo-Json -Depth 12),
    $utf8WithoutBom
)
Write-Host "ISO Phase 1 benchmark report written: $resolvedOutput"
