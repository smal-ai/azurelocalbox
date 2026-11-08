# Only the exact timed-out read-only inspection. Never stop DISM/services/tasks.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ne 'LocalBox-Client') { throw 'Unexpected target' }
foreach ($path in @('C:\ProgramData\AzureLocalBox\Artifacts\2610\AzureLocal24H2.26100.32230.LCM.12.2610.0.3098.x64.en-us.iso', 'C:\ProgramData\AzureLocalBox\Bootstrap\eval-media-20261028-01\WindowsServer2025Evaluation.26100.32230.x64.en-us.iso')) {
    if ((Get-DiskImage -ImagePath $path).Attached) { throw 'Inspection may own an attachment. Do not stop it.' }
}
if (Get-Process -Name dism,dismhost -ErrorAction SilentlyContinue) { throw 'Image servicing is active. Inspect before cleanup.' }
$encoded = '__GUEST_INSPECTION_ENCODED__'
if (-not $encoded -or $encoded -like '__*') { throw 'Exact inspection selector missing' }
$rows = @(Get-CimInstance Win32_Process -Filter ("Name='powershell.exe' AND CommandLine LIKE '%" + $encoded + "%'") )
$ids = @($rows | ForEach-Object ProcessId)
$stopped = @()
foreach ($row in ($rows | Sort-Object { if ($_.ParentProcessId -in $ids) { 0 } else { 1 } })) {
    $process = Get-Process -Id $row.ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { continue }
    if ([math]::Abs(($process.StartTime.ToUniversalTime() - $row.CreationDate.ToUniversalTime()).TotalSeconds) -gt 1) { throw 'Process identity changed' }
    Stop-Process -InputObject $process -Force
    $stopped += $row.ProcessId
}
@{ stoppedExactInspectionPids = $stopped; dismountedImages = $false; networkOrGuestApplied = $false; clusterBootstrapComplete = $false } | ConvertTo-Json -Compress
