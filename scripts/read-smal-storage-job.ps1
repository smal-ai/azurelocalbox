$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\storage-20261028-01'
$taskName = 'LocalBox-Storage-20261028-01'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task) {
    @{ runId = 'storage-20261028-01'; scope = 'storage-only'; taskExists = $false; directoryExists = (Test-Path $root); startedMarkerExists = (Test-Path (Join-Path $root 'execution.started')); clusterBootstrapComplete = $false } | ConvertTo-Json -Compress
    exit 0
}
$info = Get-ScheduledTaskInfo -TaskName $taskName
$s = Get-Content (Join-Path $root 'state.json') -Raw | ConvertFrom-Json
$heartbeat = if (Test-Path (Join-Path $root 'heartbeat.json')) { Get-Content (Join-Path $root 'heartbeat.json') -Raw | ConvertFrom-Json } else { $null }
$volume = Get-Volume -DriveLetter V -ErrorAction SilentlyContinue
$tokens = $null; $parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'worker.ps1'), [ref]$tokens, [ref]$parseErrors)
$pending = if (Test-Path (Join-Path $root 'state.json.tmp')) { Get-Content (Join-Path $root 'state.json.tmp') -Raw | ConvertFrom-Json } else { $null }
$diagnostic = @{ startedMarkerExists = (Test-Path (Join-Path $root 'execution.started')); temporaryStateExists = (Test-Path (Join-Path $root 'state.json.tmp')); temporaryStatePhase = $pending.phase; workerParseErrors = @($parseErrors | ForEach-Object { @{ id = $_.ErrorId; line = $_.Extent.StartLineNumber } }); poolExists = [bool](Get-StoragePool -FriendlyName LocalBoxPool -ErrorAction SilentlyContinue); virtualDiskExists = [bool](Get-VirtualDisk -FriendlyName LocalBoxData -ErrorAction SilentlyContinue); rawDataDiskCount = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and $_.PartitionStyle.ToString() -eq 'RAW' }).Count; poolablePhysicalDiskCount = @(Get-PhysicalDisk | Where-Object CanPool -EQ $true).Count }
$diagnostic.temporaryStateErrorType = $pending.errorType
$diagnostic.temporaryProcessId = $pending.processId
$diagnostic.temporaryProcessExists = $(if ($pending.processId) { [bool](Get-Process -Id $pending.processId -ErrorAction SilentlyContinue) } else { $false })
$diagnostic.workerSha256 = (Get-FileHash (Join-Path $root 'worker.ps1')).Hash
$diagnostic.manifestSha256 = (Get-FileHash (Join-Path $root 'manifest.json')).Hash
$diagnostic.recoveryProofExists = Test-Path (Join-Path $root 'recovery-authorised.json')
$diagnostic.recoveryWorkerBackupExists = Test-Path (Join-Path $root 'worker.before-recovery.ps1')
$diagnostic.triggerCountIncludingNull = @($task.Triggers).Count
$diagnostic.actualTriggerCount = @($task.Triggers | Where-Object { $null -ne $_ }).Count
$diagnostic.taskPrincipal = $task.Principal.UserId
$diagnostic.actionIsExpected = $task.Actions.Count -eq 1 -and $task.Actions[0].Execute -ieq 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -and $task.Actions[0].Arguments -ceq ('-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $root 'worker.ps1') + '"')
$pendingLoader = '__PENDING_RECOVERY_LOADER__'
$diagnostic.matchingHistoricalRecoveryProcesses = @()
if ($pendingLoader -and $pendingLoader -notlike '__*') {
    # Match only our exact public hash-only loader. Never return command lines,
    # inspect unrelated process arguments, or stop any process.
    $diagnostic.matchingHistoricalRecoveryProcesses = @(Get-CimInstance Win32_Process -Filter ("Name='powershell.exe' AND CommandLine LIKE '%" + $pendingLoader + "%'") | Select-Object ProcessId, ParentProcessId)
}
try {
    $request = [Net.HttpWebRequest]::Create('http://169.254.169.254/metadata/instance/compute/resourceId?api-version=2021-02-01&format=text')
    $request.Proxy = $null; $request.Headers['Metadata'] = 'true'; $request.Timeout = 5000
    $response = $request.GetResponse()
    try { $reader = [IO.StreamReader]::new($response.GetResponseStream()); try { $diagnostic.azureVmResourceId = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() } } finally { $response.Close() }
} catch { $diagnostic.metadataReadErrorType = $_.Exception.GetType().Name }
@{ atUtc = (Get-Date).ToUniversalTime().ToString('o'); runId = $s.runId; scope = $s.scope; status = $s.status; phase = $s.phase; errorType = $s.errorType; taskState = $task.State.ToString(); lastTaskResult = $info.LastTaskResult; lastUpdatedAtUtc = $s.lastUpdatedAtUtc; heartbeatUtc = $(if ($heartbeat) { $heartbeat.atUtc } else { $null }); osDiskAndPartitionUnchanged = $s.osDiskAndPartitionUnchanged; volume = $(if ($volume) { @{ letter = 'V'; fileSystem = $volume.FileSystem; sizeBytes = $volume.Size; health = $volume.HealthStatus.ToString() } } else { $null }); diagnostic = $diagnostic; clusterBootstrapComplete = $false } | ConvertTo-Json -Depth 6 -Compress
