param([Parameter(Mandatory)][string]$OutputDirectory, [string]$Subdirectory = '')
$ErrorActionPreference = 'Stop'
$baseUri = [Uri]'http://192.168.2.124:5244'
$allowed = '/dav/QuarkFilmsData_STRM'
if (!$env:STREAMPATH_PROBE_USER -or !$env:STREAMPATH_PROBE_PASSWORD) {
    throw 'Probe credentials must be supplied through the process environment'
}
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(30)
$auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($env:STREAMPATH_PROBE_USER + ':' + $env:STREAMPATH_PROBE_PASSWORD))
$client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Basic', $auth)
$records = [Collections.Generic.List[object]]::new()
$listings = @{}
$lastRequest = [DateTime]::MinValue
function Read-Directory([string]$Directory) {
    if (($Directory -ne $allowed -and !$Directory.StartsWith($allowed + '/', [StringComparison]::Ordinal)) -or $Directory.Split('/') -contains '..') {
        throw 'Probe request escaped the authorized root'
    }
    $remaining = 1000 - ([DateTime]::UtcNow - $script:lastRequest).TotalMilliseconds
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
    if ($status -ne 207) { throw "PROPFIND failed with status $status" }
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
    $pending.Push($(if ($Subdirectory) { $allowed + '/' + $Subdirectory } else { $allowed }))
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
