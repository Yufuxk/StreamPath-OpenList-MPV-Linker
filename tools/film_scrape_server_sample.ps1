param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$Subdirectory = '',
    [switch]$Full,
    [string]$Roots = ''
)
# 只读目录枚举：仅 PROPFIND Depth:1，只申请 displayname/resourcetype，不读取文件内容。
$ErrorActionPreference = 'Stop'
$baseUri = [Uri]'http://192.168.2.124:5244'
$allowed = '/dav/QuarkFilmsData_STRM'
if (!$env:STREAMPATH_PROBE_USER -or !$env:STREAMPATH_PROBE_PASSWORD) {
    throw 'Probe credentials must be supplied through the process environment'
}
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(120)
$auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($env:STREAMPATH_PROBE_USER + ':' + $env:STREAMPATH_PROBE_PASSWORD))
$client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Basic', $auth)
$records = [Collections.Generic.List[object]]::new()
$listings = @{}
$lastRequest = [DateTime]::MinValue
$intervalMilliseconds = if ($Full) { 800 } else { 1000 }
function Read-Directory([string]$Directory) {
    if (($Directory -ne $allowed -and !$Directory.StartsWith($allowed + '/', [StringComparison]::Ordinal)) -or $Directory.Split('/') -contains '..') {
        throw 'Probe request escaped the authorized root'
    }
    $remaining = $intervalMilliseconds - ([DateTime]::UtcNow - $script:lastRequest).TotalMilliseconds
    if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Ceiling($remaining)) }
    $encodedPath = ($Directory.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $uri = [Uri]::new($baseUri, $encodedPath)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new('PROPFIND'), $uri)
    $request.Headers.Add('Depth', '1')
    $request.Content = [System.Net.Http.StringContent]::new('<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>', [Text.Encoding]::UTF8, 'application/xml')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $script:lastRequest = [DateTime]::UtcNow
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $status = [int]$response.StatusCode
    if ($status -ne 207) { throw "PROPFIND failed with status $status at $Directory" }
    $xmlText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $elapsed = $watch.Elapsed.TotalMilliseconds
    [xml]$xml = $xmlText
    $children = [Collections.Generic.List[object]]::new()
    foreach ($entry in $xml.SelectNodes('//*[local-name()="response"]')) {
        $href = [string]$entry.SelectSingleNode('./*[local-name()="href"]').InnerText
        $childUri = [Uri]::new($baseUri, $href)
        if ($childUri.Authority -ne $baseUri.Authority -or $childUri.Query) { throw 'Untrusted PROPFIND href' }
        $childPath = [Uri]::UnescapeDataString($childUri.AbsolutePath).TrimEnd('/')
        if ($childPath -eq $Directory) { continue }
        if (!$childPath.StartsWith($Directory + '/', [StringComparison]::Ordinal)) { throw 'Unexpected PROPFIND child' }
        $suffix = $childPath.Substring($Directory.Length + 1)
        if ($suffix.Contains('/') -or $suffix -in @('.', '..', '')) { throw 'Invalid direct child' }
        $children.Add([pscustomobject]@{path=$childPath; name=$suffix; directory=($null -ne $entry.SelectSingleNode('.//*[local-name()="resourcetype"]/*[local-name()="collection"]'))})
    }
    $records.Add([pscustomobject]@{method='PROPFIND';path=$Directory;status=$status;milliseconds=$elapsed;bytes=[Text.Encoding]::UTF8.GetByteCount($xmlText);entries=$children.Count})
    $script:listings[$Directory] = [pscustomobject]@{requestUrl=$uri.AbsoluteUri;xml=$xmlText;children=@($children.ToArray())}
    $response.Dispose()
    $request.Dispose()
    return ,$children.ToArray()
}
try {
    $pending = [Collections.Generic.Stack[string]]::new()
    function Write-Manifest([string]$Path, [bool]$Complete, $Listings, $Records, $Failed, $Started, $Resumed) {
        $entries = [Collections.Generic.List[object]]::new()
        foreach ($directory in $Listings.Keys) {
            foreach ($child in @($Listings[$directory].children)) {
                $entries.Add([pscustomobject]@{
                    path=($child.path.Substring(5))
                    parent=($directory.Substring(5))
                    name=$child.name
                    directory=$child.directory
                })
            }
        }
        [pscustomobject]@{
            root=$allowed
            complete=$Complete
            resumedEntries=$Resumed
            started=@($Started)
            skippedDirectoryNames=@('BDMV','CERTIFICATE','VIDEO_TS')
            failed=@($Failed.ToArray())
            requests=@($Records.ToArray())
            entries=@($entries.ToArray())
        } | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $Path -Encoding utf8
        return ,$entries
    }
    if ($Full) {
        $startDirectories = if ($Roots) {
            foreach ($root in ($Roots -split ',')) {
                $trimmed = $root.Trim().Trim('/')
                if (!$trimmed -or $trimmed -match '(^|/)\.\.(/|$)') { throw "Full snapshot root escaped the authorized tree: $trimmed" }
                if ($trimmed -notmatch '^QuarkFilmsData_STRM(/|$)') { $trimmed = 'QuarkFilmsData_STRM/' + $trimmed }
                $allowed + '/' + $trimmed.Substring('QuarkFilmsData_STRM/'.Length)
            }
        } else { $allowed }
    } else {
        $pending.Push($(if ($Subdirectory) { $allowed + '/' + $Subdirectory } else { $allowed }))
        $startDirectories = @()
    }
    if ($Full) {
        $manifestPath = Join-Path $OutputDirectory 'server-manifest.json'
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        $resumed = 0
        $restored = [Collections.Generic.HashSet[string]]::new()
        if (Test-Path -LiteralPath $manifestPath) {
            # 断点续采：旧清单里已枚举的目录不再请求，空目录同样保留。
            $previous = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
            foreach ($entry in @($previous.entries)) {
                $directory = '/dav/' + $entry.parent
                if (!$listings.ContainsKey($directory)) {
                    $listings[$directory] = [pscustomobject]@{requestUrl='';xml='';children=@()}
                }
                $listings[$directory].children += [pscustomobject]@{
                    path='/dav/' + $entry.path
                    name=$entry.name
                    directory=[bool]$entry.directory
                }
                $resumed++
            }
            $previous.requests | ForEach-Object { $null = $records.Add($_) }
            foreach ($directory in $listings.Keys) { $null = $restored.Add($directory) }
            Write-Host "resumed $($listings.Count) directories from the previous manifest"
        }
        foreach ($start in $startDirectories) { $pending.Push($start) }
        foreach ($directory in $listings.Keys) {
            foreach ($child in @($listings[$directory].children)) {
                if ($child.directory -and $child.name -notin @('BDMV', 'CERTIFICATE', 'VIDEO_TS')) { $pending.Push($child.path) }
            }
        }
        $visited = [Collections.Generic.HashSet[string]]::new()
        $failed = [Collections.Generic.List[object]]::new()
        $lastCheckpoint = 0
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            if ($restored.Contains($directory) -or !$visited.Add($directory)) { continue }
            $children = $null
            for ($attempt = 1; $attempt -le 3 -and $null -eq $children; $attempt++) {
                try {
                    $children = Read-Directory $directory
                } catch {
                    if ($attempt -eq 3) {
                        $failed.Add([pscustomobject]@{path=$directory;error=$_.Exception.Message})
                        Write-Host "FAILED $directory : $($_.Exception.Message)"
                    } else {
                        Start-Sleep -Seconds (2 * $attempt)
                    }
                }
            }
            if ($null -eq $children) { continue }
            foreach ($entry in @($children | Where-Object directory | Sort-Object name -Descending)) {
                if ($entry.name -notin @('BDMV', 'CERTIFICATE', 'VIDEO_TS')) { $pending.Push($entry.path) }
            }
            if ($records.Count - $lastCheckpoint -ge 25) {
                $lastCheckpoint = $records.Count
                Write-Host "requests=$($records.Count) visited=$($visited.Count) pending=$($pending.Count) failed=$($failed.Count)"
                $null = Write-Manifest $manifestPath $false $listings $records $failed $startDirectories $resumed
            }
        }
        $entries = Write-Manifest $manifestPath ($failed.Count -eq 0) $listings $records $failed $startDirectories $resumed
        [pscustomobject]@{
            mode='full'
            complete=($failed.Count -eq 0)
            requests=$records.Count
            directories=$listings.Count
            entries=$entries.Count
            files=@($entries | Where-Object { !$_.directory }).Count
            failed=$failed.Count
            statuses=@($records.status | Select-Object -Unique)
            fileReads=0
            writes=0
        } | ConvertTo-Json -Compress
        exit 0
    }
    $leafDirectories = [Collections.Generic.List[string]]::new()
    while ($pending.Count -gt 0 -and $listings.Count -lt 35 -and $leafDirectories.Count -lt 10) {
        $directory = $pending.Pop()
        $children = Read-Directory $directory
        if (@($children | Where-Object { !$_.directory -and $_.name -match '\.(strm|mkv|mp4|iso)$' }).Count -gt 0) { $leafDirectories.Add($directory) }
        foreach ($entry in @($children | Where-Object directory | Sort-Object name -Descending)) {
            if ($entry.name -notin @('BDMV', 'CERTIFICATE', 'VIDEO_TS')) { $pending.Push($entry.path) }
        }
    }
    for ($round=0; $round -lt 2; $round++) {
        foreach ($directory in $leafDirectories) { $null = Read-Directory $directory }
    }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    [pscustomobject]@{root=$allowed;complete=$false;requests=$records.ToArray();listings=$listings;fixedSample=$leafDirectories.ToArray()} | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'server-listings.json') -Encoding utf8
    [pscustomobject]@{requests=$records.Count;directories=$listings.Count;fixedDirectories=$leafDirectories.Count;methods=@($records.method | Select-Object -Unique);statuses=@($records.status | Select-Object -Unique);fileReads=0;writes=0} | ConvertTo-Json -Compress
} finally {
    $client.Dispose()
    $handler.Dispose()
}
