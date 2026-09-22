param(
  [string]$ConfigPath = "$PSScriptRoot/../stream_path_data/config/stream_path_config.json"
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class IsoProbeCredential {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct Credential {
    public uint Flags, Type;
    public string TargetName, Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public uint CredentialBlobSize;
    public IntPtr CredentialBlob;
    public uint Persist, AttributeCount;
    public IntPtr Attributes;
    public string TargetAlias, UserName;
  }
  [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool CredRead(string target, uint type, uint flags, out IntPtr result);
  [DllImport("advapi32.dll")] static extern void CredFree(IntPtr value);
  public static string Read(string target) {
    IntPtr ptr;
    if (!CredRead(target, 1, 0, out ptr)) throw new InvalidOperationException("Credential unavailable");
    try {
      var c=(Credential)Marshal.PtrToStructure(ptr, typeof(Credential));
      var bytes=new byte[c.CredentialBlobSize];
      Marshal.Copy(c.CredentialBlob,bytes,0,bytes.Length);
      return System.Text.Encoding.UTF8.GetString(bytes);
    } finally { CredFree(ptr); }
  }
}
'@
$config = Get-Content -Raw -Encoding UTF8 -LiteralPath $ConfigPath | ConvertFrom-Json
$profile = @($config.profiles | Where-Object profileId -EQ $config.activeProfileId)[0]
$baseUri = [uri]($profile.serverUrl.TrimEnd('/') + '/')
$secrets = [IsoProbeCredential]::Read('StreamPath/server-profile/' + $profile.profileId) | ConvertFrom-Json
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($profile.username + ':' + $secrets.webDavPassword))
$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(30)
function Request-Probe([string]$Method, [uri]$Uri, [bool]$NoRange = $false) {
  for ($hop=0; $hop -le 5; $hop++) {
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Uri)
    [void]$request.Headers.TryAddWithoutValidation('User-Agent','StreamPath ISO Bridge/1')
    [void]$request.Headers.TryAddWithoutValidation('Accept-Encoding','identity')
    if ($Uri.GetLeftPart([UriPartial]::Authority) -eq $baseUri.GetLeftPart([UriPartial]::Authority)) {
      $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Basic',$basic)
    }
    if ($Method -eq 'GET' -and !$NoRange) { $request.Headers.Range = [Net.Http.Headers.RangeHeaderValue]::new(0,0) }
    if ($Method -eq 'PROPFIND') { [void]$request.Headers.TryAddWithoutValidation('Depth','1') }
    try { $response = $client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult() }
    finally { $request.Dispose() }
    if ($Method -ne 'PROPFIND') {
      [Console]::WriteLine(('Hop method={0} index={1} status={2} sourceOrigin={3}' -f $Method,$hop,[int]$response.StatusCode,($Uri.GetLeftPart([UriPartial]::Authority) -eq $baseUri.GetLeftPart([UriPartial]::Authority))))
    }
    if ([int]$response.StatusCode -in @(301,302,303,307,308)) {
      $nextUri = [uri]::new($Uri, $response.Headers.Location)
      $response.Dispose()
      $Uri = $nextUri
      continue
    }
    $script:finalUri = $Uri
    return $response
  }
  throw 'Redirect limit reached'
}
try {
  $parent = [uri]::new($baseUri, 'QuarkFilmsData_SPECIAL/0.MOVIE%20SPs/')
  $listing = Request-Probe 'PROPFIND' $parent
  try {
    if ([int]$listing.StatusCode -ne 207) { throw ('Directory status ' + [int]$listing.StatusCode) }
    [xml]$xml = $listing.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  } finally { $listing.Dispose() }
  $matches = @($xml.SelectNodes('//*[local-name()="response"]') | Where-Object {
    $href = $_.SelectSingleNode('./*[local-name()="href"]').InnerText
    [uri]::UnescapeDataString($href) -match '秒速.*2007'
  })
  if ($matches.Count -ne 1) { throw ('Directory match count ' + $matches.Count) }
  $discDirectory = [uri]::new($baseUri, $matches[0].SelectSingleNode('./*[local-name()="href"]').InnerText.TrimEnd('/') + '/')
  $fileUri = [uri]::new($discDirectory, [uri]::EscapeDataString('5 Centimeters Per Second.2007.iso'))
  foreach ($method in @('HEAD','GET')) {
    $response = Request-Probe $method $fileUri
    if ($method -eq 'HEAD') { $headFinalUri = $script:finalUri }
    try {
      $bytesRead = 0
      if ($method -eq 'GET' -and [int]$response.StatusCode -eq 206) {
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $buffer = [byte[]]::new(2)
        while ($bytesRead -lt 2) {
          $readTask = $stream.ReadAsync($buffer,$bytesRead,2-$bytesRead)
          if (!$readTask.Wait(30000)) { throw 'Body timeout' }
          if ($readTask.Result -eq 0) { break }
          $bytesRead += $readTask.Result
        }
      }
      [pscustomobject]@{
        Method=$method; Status=[int]$response.StatusCode
        ContentLength=$response.Content.Headers.ContentLength
        ContentRange=[string]$response.Content.Headers.ContentRange
        StrongETag=($null -ne $response.Headers.ETag -and !$response.Headers.ETag.IsWeak)
        LastModifiedPresent=($null -ne $response.Content.Headers.LastModified)
        BodyBytesRead=$bytesRead
        ContentType=[string]$response.Content.Headers.ContentType
      } | ConvertTo-Json -Compress
    } finally { $response.Dispose() }
  }
  $response = Request-Probe 'GET' $headFinalUri
  try {
    [pscustomobject]@{Test='GET on resolved HEAD URL';Status=[int]$response.StatusCode;ContentRange=[string]$response.Content.Headers.ContentRange} | ConvertTo-Json -Compress
    if ([int]$response.StatusCode -eq 412 -and $response.Content.Headers.ContentLength -lt 4096) {
      $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      $plain = [regex]::Replace($body,'<[^>]*>',' ')
      $plain = [regex]::Replace($plain,'https?://\S+','[redacted-url]')
      $plain = [regex]::Replace($plain,'(?i)(token|password|authorization|signature|sign|cookie)\s*[=:]\s*\S+','$1=[redacted]')
      Write-Output ('Response text: ' + ([regex]::Replace($plain,'\s+',' ')).Trim())
      $codes = [regex]::Matches($body, '<(?:Code|Message|title)>([^<]+)</(?:Code|Message|title)>')
      foreach($match in $codes) {
        $safe = [regex]::Replace($match.Groups[1].Value,'https?://\S+','[redacted-url]')
        Write-Output ('Error detail: ' + $safe)
      }
    }
  } finally { $response.Dispose() }
  $response = Request-Probe 'GET' $fileUri $true
  try {
    [pscustomobject]@{Test='GET without Range (headers only)';Status=[int]$response.StatusCode} | ConvertTo-Json -Compress
  } finally { $response.Dispose() }
} catch {
  Write-Output ('Probe failed: ' + $_.Exception.GetType().Name)
  exit 1
} finally { $client.Dispose() }
