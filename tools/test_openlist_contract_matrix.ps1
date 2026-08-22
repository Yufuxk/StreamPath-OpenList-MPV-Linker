[CmdletBinding()]
param(
    [string]$MatrixRoot = (Join-Path $env:TEMP 'StreamPathContractMatrix-20260823'),
    [int]$FirstPort = 35201,
    [string[]]$CaseName = @()
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$resolvedProjectRoot = [System.IO.Path]::GetFullPath($projectRoot)
$resolvedMatrixRoot = [System.IO.Path]::GetFullPath($MatrixRoot)
$resolvedTemp = [System.IO.Path]::GetFullPath($env:TEMP)
if (-not $resolvedMatrixRoot.StartsWith(
        $resolvedTemp + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw "矩阵目录必须位于 TEMP 下：$resolvedMatrixRoot"
}

$cases = @(
    [pscustomobject]@{ Name = 'alist-v3.0.1'; Product = 'alist'; Version = '3.0.1'; HashLogin = $false; IndexSearch = $false; IndexProgress = $false; IndexUpdate = $false; StorageReload = $false; LegacyConfig = $true },
    [pscustomobject]@{ Name = 'alist-v3.6.0'; Product = 'alist'; Version = '3.6.0'; HashLogin = $false; IndexSearch = $true; IndexProgress = $true; IndexUpdate = $false; StorageReload = $false; LegacyConfig = $false },
    [pscustomobject]@{ Name = 'alist-v3.7.1'; Product = 'alist'; Version = '3.7.1'; HashLogin = $false; IndexSearch = $true; IndexProgress = $true; IndexUpdate = $true; StorageReload = $true; LegacyConfig = $false },
    [pscustomobject]@{ Name = 'alist-v3.63.0'; Product = 'alist'; Version = '3.63.0'; HashLogin = $true; IndexSearch = $true; IndexProgress = $true; IndexUpdate = $true; StorageReload = $true; LegacyConfig = $false },
    [pscustomobject]@{ Name = 'openlist-v4.0.0'; Product = 'openlist'; Version = '4.0.0'; HashLogin = $true; IndexSearch = $true; IndexProgress = $true; IndexUpdate = $true; StorageReload = $true; LegacyConfig = $false },
    [pscustomobject]@{ Name = 'openlist-v4.1.4'; Product = 'openlist'; Version = '4.1.4'; HashLogin = $true; IndexSearch = $true; IndexProgress = $true; IndexUpdate = $true; StorageReload = $true; LegacyConfig = $false },
    [pscustomobject]@{ Name = 'openlist-v4.2.5'; Product = 'openlist'; Version = '4.2.5'; HashLogin = $true; IndexSearch = $true; IndexProgress = $true; IndexUpdate = $true; StorageReload = $true; LegacyConfig = $false }
)
if ($CaseName.Count -gt 0) {
    $selectedCases = @($cases | Where-Object { $CaseName -contains $_.Name })
    $missingCases = @($CaseName | Where-Object { $_ -notin $selectedCases.Name })
    if ($missingCases.Count -gt 0) {
        throw "未知矩阵样本：$($missingCases -join ', ')"
    }
    $cases = $selectedCases
}
if ($FirstPort -lt 1024 -or ($FirstPort + $cases.Count - 1) -gt 65535) {
    throw "合同测试端口范围无效：$FirstPort"
}

$managedEnvironmentKeys = @(
    'ALIST_ADDR', 'ALIST_PORT', 'ALIST_HTTP_PORT', 'ALIST_DB_FILE',
    'ALIST_TEMP_DIR', 'ALIST_BLEVE_DIR', 'OPENLIST_ADDR',
    'OPENLIST_HTTP_PORT', 'OPENLIST_DB_FILE', 'OPENLIST_TEMP_DIR',
    'OPENLIST_BLEVE_DIR', 'STREAMPATH_CONTRACT_BASE_URL',
    'STREAMPATH_CONTRACT_USERNAME', 'STREAMPATH_CONTRACT_PASSWORD',
    'STREAMPATH_CONTRACT_VERSION', 'STREAMPATH_CONTRACT_HASH_LOGIN',
    'STREAMPATH_CONTRACT_INDEX_SEARCH',
    'STREAMPATH_CONTRACT_INDEX_PROGRESS',
    'STREAMPATH_CONTRACT_INDEX_UPDATE',
    'STREAMPATH_CONTRACT_STORAGE_RELOAD'
)
$savedEnvironment = @{}
foreach ($key in $managedEnvironmentKeys) {
    $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}

function Set-ProcessEnvironment {
    param([string]$Name, [AllowNull()][string]$Value)
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function Get-ListenerOwners {
    param([int]$Port)
    return @(
        Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess |
            Sort-Object -Unique
    )
}

function Stop-OwnedContractProcess {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Executable,
        [string]$RunDirectory
    )
    if ($null -eq $Process -or $Process.HasExited) { return }
    $owned = Get-CimInstance Win32_Process -Filter "ProcessId = $($Process.Id)"
    $expectedExecutable = [System.IO.Path]::GetFullPath($Executable)
    $actualExecutable = if ($null -eq $owned) { '' } else { [System.IO.Path]::GetFullPath($owned.ExecutablePath) }
    if (
        $null -eq $owned -or
        -not [string]::Equals($expectedExecutable, $actualExecutable, [System.StringComparison]::OrdinalIgnoreCase) -or
        $owned.CommandLine -notlike "*$RunDirectory*"
    ) {
        throw "拒绝终止身份不匹配的合同测试进程 PID $($Process.Id)"
    }
    Stop-Process -Id $Process.Id
    if (-not $Process.WaitForExit(5000)) {
        throw "合同测试进程未在时限内退出：PID $($Process.Id)"
    }
}

$before5244 = Get-ListenerOwners -Port 5244
$runRoot = Join-Path $resolvedMatrixRoot ('runs-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $runRoot | Out-Null
$matrixResults = @()

try {
    for ($index = 0; $index -lt $cases.Count; $index++) {
        $case = $cases[$index]
        $port = $FirstPort + $index
        if ($port -eq 5244) { throw '合同测试端口不得使用 5244' }
        if ((Get-ListenerOwners -Port $port).Count -ne 0) {
            throw "合同测试端口已被占用：$port"
        }

        $caseRoot = Join-Path $resolvedMatrixRoot $case.Name
        $executableName = if ($case.Product -eq 'alist') { 'alist.exe' } else { 'openlist.exe' }
        $executable = Join-Path $caseRoot $executableName
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "缺少合同测试可执行文件：$executable"
        }

        $runDirectory = Join-Path $runRoot $case.Name
        $dataDirectory = Join-Path $runDirectory 'data'
        $tempDirectory = Join-Path $runDirectory 'temp'
        $bleveDirectory = Join-Path $runDirectory 'bleve'
        New-Item -ItemType Directory -Path $runDirectory | Out-Null
        $stdoutPath = Join-Path $runDirectory 'stdout.log'
        $stderrPath = Join-Path $runDirectory 'stderr.log'

        Set-ProcessEnvironment 'ALIST_ADDR' '127.0.0.1'
        Set-ProcessEnvironment 'ALIST_PORT' ([string]$port)
        Set-ProcessEnvironment 'ALIST_HTTP_PORT' ([string]$port)
        Set-ProcessEnvironment 'ALIST_DB_FILE' (Join-Path $dataDirectory 'data.db')
        Set-ProcessEnvironment 'ALIST_TEMP_DIR' $tempDirectory
        Set-ProcessEnvironment 'ALIST_BLEVE_DIR' $bleveDirectory
        Set-ProcessEnvironment 'OPENLIST_ADDR' '127.0.0.1'
        Set-ProcessEnvironment 'OPENLIST_HTTP_PORT' ([string]$port)
        Set-ProcessEnvironment 'OPENLIST_DB_FILE' (Join-Path $dataDirectory 'data.db')
        Set-ProcessEnvironment 'OPENLIST_TEMP_DIR' $tempDirectory
        Set-ProcessEnvironment 'OPENLIST_BLEVE_DIR' $bleveDirectory

        $arguments = if ($case.LegacyConfig) {
            @('server', '--conf', (Join-Path $dataDirectory 'config.json'))
        } else {
            @('server', '--data', $dataDirectory)
        }
        $process = $null
        try {
            $startArguments = @{
                FilePath = $executable
                ArgumentList = $arguments
                WorkingDirectory = $runDirectory
                RedirectStandardOutput = $stdoutPath
                RedirectStandardError = $stderrPath
                WindowStyle = 'Hidden'
                PassThru = $true
            }
            $process = Start-Process @startArguments

            $baseUrl = "http://127.0.0.1:$port"
            $settingsReady = $false
            for ($attempt = 0; $attempt -lt 120; $attempt++) {
                if ($process.HasExited) { break }
                try {
                    $settings = Invoke-RestMethod `
                        -Uri "$baseUrl/api/public/settings" `
                        -Method Get `
                        -TimeoutSec 1
                    if ($settings.code -eq 200) {
                        $settingsReady = $true
                        break
                    }
                } catch {
                    Start-Sleep -Milliseconds 125
                }
            }
            if (-not $settingsReady) {
                $stderrText = if (Test-Path -LiteralPath $stderrPath) {
                    Get-Content -LiteralPath $stderrPath -Raw -Encoding utf8
                } else { '' }
                throw "$($case.Name) 未在总时限内返回公开设置 code 200：$stderrText"
            }

            $password = $null
            for ($attempt = 0; $attempt -lt 40; $attempt++) {
                $stderrText = if (Test-Path -LiteralPath $stderrPath) {
                    Get-Content -LiteralPath $stderrPath -Raw -Encoding utf8
                } else { '' }
                $stdoutText = if (Test-Path -LiteralPath $stdoutPath) {
                    Get-Content -LiteralPath $stdoutPath -Raw -Encoding utf8
                } else { '' }
                $logText = "$stderrText`n$stdoutText"
                $passwordMatch = [regex]::Match(
                    $logText,
                    'initial password is:\s*(?<password>[^"\s]+)',
                    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                )
                if ($passwordMatch.Success) {
                    $password = $passwordMatch.Groups['password'].Value
                    break
                }
                Start-Sleep -Milliseconds 100
            }
            if ([string]::IsNullOrWhiteSpace($password)) {
                throw "$($case.Name) 未在隔离启动日志中生成管理员密码"
            }

            Set-ProcessEnvironment 'STREAMPATH_CONTRACT_BASE_URL' $baseUrl
            Set-ProcessEnvironment 'STREAMPATH_CONTRACT_USERNAME' 'admin'
            Set-ProcessEnvironment 'STREAMPATH_CONTRACT_PASSWORD' $password
            Set-ProcessEnvironment 'STREAMPATH_CONTRACT_VERSION' $case.Version
            Set-ProcessEnvironment 'STREAMPATH_CONTRACT_HASH_LOGIN' ([string]$case.HashLogin).ToLowerInvariant()
            Set-ProcessEnvironment 'STREAMPATH_CONTRACT_INDEX_SEARCH' ([string]$case.IndexSearch).ToLowerInvariant()
            Set-ProcessEnvironment 'STREAMPATH_CONTRACT_INDEX_PROGRESS' ([string]$case.IndexProgress).ToLowerInvariant()
            Set-ProcessEnvironment 'STREAMPATH_CONTRACT_INDEX_UPDATE' ([string]$case.IndexUpdate).ToLowerInvariant()
            Set-ProcessEnvironment 'STREAMPATH_CONTRACT_STORAGE_RELOAD' ([string]$case.StorageReload).ToLowerInvariant()

            Push-Location $resolvedProjectRoot
            try {
                $probeOutput = & dart run tools/openlist_contract_probe.dart 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "$($case.Name) 合同探针失败：$($probeOutput -join [Environment]::NewLine)"
                }
            } finally {
                Pop-Location
            }
            $resultLine = @($probeOutput | ForEach-Object { [string]$_ }) |
                Where-Object { $_.StartsWith('STREAMPATH_CONTRACT_RESULT=') } |
                Select-Object -Last 1
            if ([string]::IsNullOrWhiteSpace($resultLine)) {
                throw "$($case.Name) 合同探针没有返回结构化结果：$($probeOutput -join [Environment]::NewLine)"
            }
            $probeJson = $resultLine.Substring('STREAMPATH_CONTRACT_RESULT='.Length) |
                ConvertFrom-Json
            $contractResultPath = Join-Path $runDirectory 'contract-result.json'
            $probeJson |
                ConvertTo-Json -Depth 10 |
                Set-Content -LiteralPath $contractResultPath -Encoding utf8NoBOM
            $matrixResults += [pscustomobject]@{
                Name = $case.Name
                Version = $probeJson.version
                Port = $port
                Result = 'passed'
                ExecutableSHA256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
                ContractResult = $contractResultPath
                EvidenceDirectory = $runDirectory
            }
            Write-Output "PASS $($case.Name) port=$port"
        } finally {
            Stop-OwnedContractProcess `
                -Process $process `
                -Executable $executable `
                -RunDirectory $runDirectory
        }
    }
} finally {
    foreach ($key in $managedEnvironmentKeys) {
        Set-ProcessEnvironment $key $savedEnvironment[$key]
    }
    $after5244 = Get-ListenerOwners -Port 5244
    if (($before5244 -join ',') -ne ($after5244 -join ',')) {
        throw '合同矩阵执行期间 5244 监听者发生变化'
    }
}

$summaryPath = Join-Path $runRoot 'matrix-summary.json'
$summary = [pscustomobject]@{
    ExecutedAt = (Get-Date).ToString('o')
    Port5244Owners = $before5244
    Cases = $matrixResults
}
$summary |
    ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM
$matrixResults | Format-Table -AutoSize
Write-Output "MATRIX_SUMMARY=$summaryPath"
Write-Output "PORT_5244_UNCHANGED=$($before5244 -join ',')"
