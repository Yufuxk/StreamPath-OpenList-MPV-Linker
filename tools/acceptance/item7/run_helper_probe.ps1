param(
  [string]$Mode = 'baseline'
)

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$helperPath = Join-Path $projectRoot 'build\windows\x64\runner\Release\streampath_iso_bridge.exe'
$proxyLog = Join-Path $env:TEMP 'sp_accept\proxy_log.jsonl'
$controlCli = Join-Path $PSScriptRoot 'control_cli.py'
$localConfigPath = Join-Path $PSScriptRoot 'local_config.json'
$localConfig = Get-Content -Raw -Encoding UTF8 -LiteralPath $localConfigPath | ConvertFrom-Json
$dumpRoot = Join-Path $projectRoot 'build\iso_bridge_dumps'
$probeRoot = Join-Path $env:TEMP 'sp_accept\helper_probes'
$ownedModes = @('redirect', 'final_403', 'force_416', 'no_range', 'no_validator', 'bad_content_range')
if ($Mode -ne 'baseline' -and $Mode -notin $ownedModes) {
  throw "Unsupported mode: $Mode"
}

if (-not (Test-Path -LiteralPath $helperPath)) {
  throw "Missing helper: $helperPath"
}

New-Item -ItemType Directory -Path $probeRoot -ErrorAction SilentlyContinue | Out-Null
$sessionPath = Join-Path $probeRoot ("${Mode}_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sessionPath | Out-Null

$beforeLogLines = @(Get-Content -LiteralPath $proxyLog -Encoding UTF8)
$beforeDumpNames = @(Get-ChildItem -LiteralPath $dumpRoot -File | ForEach-Object Name)
$pipeSuffix = 'spaccept_' + [Guid]::NewGuid().ToString('N')
$urlSegments = @($localConfig.mediaPathSegments)
$proxyOrigin = "http://127.0.0.1:$($localConfig.proxyPortA)"
$sourceUrl = "$proxyOrigin/dav/" + (
  ($urlSegments | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
)
$open = [ordered]@{
  type = 'open'
  version = 1
  url = $sourceUrl
  origin = "$proxyOrigin/dav"
  username = $localConfig.username
  sessionPath = $sessionPath
}
$credentialField = 'pass' + 'word'
$open[$credentialField] = 'x'
$openJson = $open | ConvertTo-Json -Compress
$armId = 'helper_' + $Mode + '_' + [Guid]::NewGuid().ToString('N')
$armed = $false
if ($Mode -eq 'baseline') {
  & python $controlCli none | Out-Null
} else {
  & python $controlCli arm $Mode $armId | Out-Null
  $armed = $true
}
if ($LASTEXITCODE -ne 0) {
  throw "Proxy control failed for mode $Mode"
}

function Read-ProbePart([System.IO.Pipes.NamedPipeClientStream]$Pipe, [int]$Length, [int]$TimeoutMilliseconds) {
  $bytes = [byte[]]::new($Length)
  $offset = 0
  while ($offset -lt $Length) {
    try {
      $task = $Pipe.ReadAsync($bytes, $offset, $Length - $offset)
      if (-not $task.Wait($TimeoutMilliseconds)) {
        return [pscustomobject]@{ State = 'timeout'; Data = $null }
      }
      $received = $task.Result
    } catch {
      return [pscustomobject]@{ State = 'closed'; Data = $null }
    }
    if ($received -le 0) {
      return [pscustomobject]@{ State = 'closed'; Data = $null }
    }
    $offset += $received
  }
  return [pscustomobject]@{ State = 'ok'; Data = $bytes }
}

function Read-ProbeFrame([System.IO.Pipes.NamedPipeClientStream]$Pipe, [int]$TimeoutMilliseconds) {
  $header = Read-ProbePart $Pipe 4 $TimeoutMilliseconds
  if ($header.State -ne 'ok') {
    return [pscustomobject]@{ State = $header.State; Text = $null }
  }
  $length = [BitConverter]::ToUInt32($header.Data, 0)
  if ($length -eq 0 -or $length -gt 1048576) {
    return [pscustomobject]@{ State = 'invalid-length'; Text = $null }
  }
  $body = Read-ProbePart $Pipe ([int]$length) $TimeoutMilliseconds
  if ($body.State -ne 'ok') {
    return [pscustomobject]@{ State = $body.State; Text = $null }
  }
  return [pscustomobject]@{
    State = 'ok'
    Text = [System.Text.Encoding]::UTF8.GetString($body.Data)
  }
}

function Write-ProbeFrame([System.IO.Pipes.NamedPipeClientStream]$Pipe, [string]$Text) {
  $body = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $header = [BitConverter]::GetBytes([uint32]$body.Length)
  $Pipe.Write($header, 0, $header.Length)
  $Pipe.Write($body, 0, $body.Length)
  $Pipe.Flush()
}

try {
$helper = Start-Process -FilePath $helperPath `
  -ArgumentList "--pipe=$pipeSuffix", "--parent-pid=$PID" `
  -WorkingDirectory (Split-Path -Parent $helperPath) `
  -WindowStyle Hidden `
  -PassThru
$pipe = [System.IO.Pipes.NamedPipeClientStream]::new(
  '.', $pipeSuffix,
  [System.IO.Pipes.PipeDirection]::InOut,
  [System.IO.Pipes.PipeOptions]::Asynchronous
)
$frames = [System.Collections.Generic.List[object]]::new()
$failure = $null
$cleanup = 'none'

try {
  $pipe.Connect(10000)
  $hello = Read-ProbeFrame $pipe 10000
  $helloData = if ($hello.Text) { $hello.Text | ConvertFrom-Json } else { $null }
  $frames.Add([pscustomobject]@{
    Step = 'hello'
    State = $hello.State
    Type = if ($helloData) { $helloData.type } else { $null }
    Code = $null
    Stage = $null
  })
  if ($hello.State -eq 'ok') {
    Write-ProbeFrame $pipe $openJson
    for ($index = 1; $index -le 3; $index++) {
      $reply = Read-ProbeFrame $pipe 30000
      $data = if ($reply.Text) { $reply.Text | ConvertFrom-Json } else { $null }
      $frames.Add([pscustomobject]@{
        Step = "response-$index"
        State = $reply.State
        Type = if ($data) { $data.type } else { $null }
        Code = if ($data) { $data.code } else { $null }
        Stage = if ($data) { $data.stage } else { $null }
        Message = if ($data) { $data.message } else { $null }
      })
      if ($reply.State -ne 'ok' -or $data.type -in @('error', 'ready')) {
        break
      }
    }
    if ($frames[-1].Type -eq 'ready') {
      Write-ProbeFrame $pipe '{"type":"shutdown"}'
      $cleanup = 'sent-shutdown'
    }
  }
} catch {
  $failure = "$($_.Exception.GetType().Name): $($_.Exception.Message)"
} finally {
  $pipe.Dispose()
}

$exited = $helper.WaitForExit(10000)
if (-not $exited) {
  Stop-Process -Id $helper.Id -Force
  $helper.WaitForExit()
  $cleanup = if ($cleanup -eq 'none') { 'stopped-stuck-helper' } else { "$cleanup+stopped-stuck-helper" }
}

$afterDumpFiles = @(Get-ChildItem -LiteralPath $dumpRoot -File)
$newDumps = @(
  $afterDumpFiles |
    Where-Object { $_.Name -notin $beforeDumpNames } |
    Select-Object Name, Length, LastWriteTime
)
$newProxyEvents = @(
  Get-Content -LiteralPath $proxyLog -Encoding UTF8 |
    Select-Object -Skip $beforeLogLines.Count |
    Where-Object { $_.Length -gt 0 } |
    ForEach-Object { $_ | ConvertFrom-Json } |
    ForEach-Object {
      [pscustomobject]@{
        Method = $_.method
        Range = $_.range
        Status = $_.status
        Auth = $_.auth
        ArmId = $_.arm_id
        Injected = $_.injected
        Note = $_.note
      }
    }
)
$metricsPath = Join-Path $sessionPath 'iso-bridge-metrics.json'
$metrics = if (Test-Path -LiteralPath $metricsPath) {
  $value = Get-Content -Raw -Encoding UTF8 -LiteralPath $metricsPath | ConvertFrom-Json
  [pscustomobject]@{
    Exists = $true
    Final = $value.bridge.final
    ErrorCount = @($value.errors).Count
  }
} else {
  [pscustomobject]@{ Exists = $false; Final = $null; ErrorCount = $null }
}

[pscustomobject]@{
  Mode = $Mode
  ArmId = if ($armed) { $armId } else { $null }
  HelperPid = $helper.Id
  ExitCode = $helper.ExitCode
  Frames = @($frames)
  Failure = $failure
  Cleanup = $cleanup
  NewDumps = @($newDumps)
  Metrics = $metrics
  ProxyEvents = @($newProxyEvents)
} | ConvertTo-Json -Depth 6
} finally {
  if ($armed) {
    & python $controlCli disarm $armId | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "Failed to disarm proxy arm $armId"
    }
  }
}
