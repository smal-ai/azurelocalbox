# Stop ONLY the exact hash-only transport processes left by our timed-out call.
# No service, scheduled task, worker marker, storage object or unrelated PID touched.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\storage-20261028-01'
if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or (Test-Path (Join-Path $root 'recovery-authorised.json')) -or (Test-Path (Join-Path $root 'worker.before-recovery.ps1'))) { throw 'Transport cleanup state changed' }
if ((Get-FileHash (Join-Path $root 'worker.ps1')).Hash -ne '8C4B65A8299101ABA4ADEC3A6513432DFA0785571FA34322D6E7929749B490B0' -or (Get-ScheduledTask -TaskName 'LocalBox-Storage-20261028-01').State.ToString() -ne 'Ready' -or (Get-Volume -DriveLetter V -ErrorAction SilentlyContinue) -or (Get-StoragePool -FriendlyName LocalBoxPool -ErrorAction SilentlyContinue)) { throw 'No-effects reconciliation no longer matches' }
$encoded = '__PENDING_RECOVERY_LOADER__'
if (-not $encoded -or $encoded -like '__*') { throw 'Exact historical transport identity missing' }
$rows = @(Get-CimInstance Win32_Process -Filter ("Name='powershell.exe' AND CommandLine LIKE '%" + $encoded + "%'"))
$ids = @($rows | ForEach-Object ProcessId)
$stopped = @()
foreach ($row in ($rows | Sort-Object { if ($_.ParentProcessId -in $ids) { 0 } else { 1 } })) {
    $process = Get-Process -Id $row.ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { continue }
    if ([math]::Abs(($process.StartTime.ToUniversalTime() - $row.CreationDate.ToUniversalTime()).TotalSeconds) -gt 1) { throw 'Process identity changed; no further cleanup' }
    Stop-Process -InputObject $process -Force
    $stopped += $row.ProcessId
}
@{ stoppedExactTransportPids = $stopped; scheduledTaskStopped = $false; markerRemoved = $false; storageChanged = $false; clusterBootstrapComplete = $false } | ConvertTo-Json -Compress
