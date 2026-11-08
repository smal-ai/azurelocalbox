# Exact recovery of the inspected checkpoint failure BEFORE any storage mutation.
# No marker deletion, no new job, no permissive replay after partially applied storage.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\storage-20261028-01'
$taskName = 'LocalBox-Storage-20261028-01'
$oldHash = '8C4B65A8299101ABA4ADEC3A6513432DFA0785571FA34322D6E7929749B490B0'
if ($env:COMPUTERNAME -ne 'LocalBox-Client') { throw 'Unexpected target' }
if (Test-Path (Join-Path $root 'recovery-authorised.json')) { throw 'Recovery already attempted. Inspect rather than repeat.' }
$task = Get-ScheduledTask -TaskName $taskName
$info = Get-ScheduledTaskInfo -TaskName $taskName
$state = Get-Content (Join-Path $root 'state.json') -Raw | ConvertFrom-Json
$pending = Get-Content (Join-Path $root 'state.json.tmp') -Raw | ConvertFrom-Json
if ($task.State.ToString() -ne 'Ready' -or $info.LastTaskResult -ne 1 -or $state.status -ne 'queued' -or $pending.phase -ne 'initialising' -or $pending.errorType -ne 'MethodInvocationException' -or (Get-Process -Id $pending.processId -ErrorAction SilentlyContinue)) { throw 'Original preflight failure no longer matches inspection' }
if ($task.Principal.UserId -notin @('SYSTEM', 'S-1-5-18') -or $task.Actions.Count -ne 1 -or $task.Actions[0].Execute -ine 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -or $task.Actions[0].Arguments -cne ('-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $root 'worker.ps1') + '"') -or @($task.Triggers | Where-Object { $null -ne $_ }).Count -ne 0) { throw 'Task ownership/action changed' }
if ((Get-FileHash (Join-Path $root 'worker.ps1')).Hash -ne $oldHash -or (Get-FileHash (Join-Path $root 'manifest.json')).Hash -ne '__MANIFEST_SHA256__' -or -not (Test-Path (Join-Path $root 'execution.started'))) { throw 'Original source or marker changed' }
if ((Get-Volume -DriveLetter V -ErrorAction SilentlyContinue) -or (Get-StoragePool -FriendlyName LocalBoxPool -ErrorAction SilentlyContinue) -or (Get-VirtualDisk -FriendlyName LocalBoxData -ErrorAction SilentlyContinue)) { throw 'Storage effects exist. This recovery is not applicable.' }
$m = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
$disks = @(Get-Disk); $physical = @(Get-PhysicalDisk); $win32 = @(Get-CimInstance Win32_DiskDrive)
if ($m.disks.Count -ne 8) { throw 'Exact approved disk set missing' }
foreach ($expected in $m.disks) {
    $d = @($disks | Where-Object UniqueId -CEQ $expected.guestUniqueId)
    $p = @($physical | Where-Object UniqueId -CEQ $expected.guestUniqueId)
    if ($d.Count -ne 1 -or $p.Count -ne 1) { throw 'Disk identity is ambiguous' }
    $w = @($win32 | Where-Object Index -EQ $d[0].Number)
    if ($w.Count -ne 1 -or $d[0].IsBoot -or $d[0].IsSystem -or $d[0].PartitionStyle.ToString() -ne 'RAW' -or $d[0].Size -ne 256GB -or $d[0].SerialNumber -cne $expected.serialNumber -or $p[0].CanPool -ne $true -or $p[0].SerialNumber -cne $expected.serialNumber -or $w[0].Model -cne 'Virtual_Disk NVMe Premium' -or $w[0].SCSILogicalUnit -ne ($expected.lun + 1)) { throw 'Approved untouched data state differs' }
}
[IO.File]::Copy((Join-Path $root 'worker.ps1'), (Join-Path $root 'worker.before-recovery.ps1'), $false)
[IO.File]::Copy((Join-Path $root 'state.json'), (Join-Path $root 'state.before-recovery.json'), $false)
[IO.File]::Copy((Join-Path $root 'state.json.tmp'), (Join-Path $root 'state.tmp.before-recovery.json'), $false)
$proof = @{ runId = 'storage-20261028-01'; kind = 'verified-preflight-no-storage-effects'; sourceCommit = '__SOURCE_COMMIT__'; priorWorkerSha256 = $oldHash; manifestSha256 = '__MANIFEST_SHA256__'; atUtc = (Get-Date).ToUniversalTime().ToString('o'); originalMarkerRetained = $true }
$bytes = [Text.Encoding]::UTF8.GetBytes(($proof | ConvertTo-Json))
$file = [IO.File]::Open((Join-Path $root 'recovery-authorised.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $file.Write($bytes, 0, $bytes.Length) } finally { $file.Dispose() }
[IO.File]::WriteAllBytes((Join-Path $root 'worker.ps1'), [Convert]::FromBase64String('__WORKER_BASE64__'))
if ((Get-FileHash (Join-Path $root 'worker.ps1')).Hash -ne '__WORKER_SHA256__') { throw 'Recovery worker integrity check failed' }
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument ('-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $root 'worker.ps1') + '" -ResumeVerified')
$null = Set-ScheduledTask -TaskName $taskName -Action $action
Start-ScheduledTask -TaskName $taskName
@{ runId = 'storage-20261028-01'; scope = 'storage-only'; recovery = 'verified-preflight-no-storage-effects'; sourceCommit = '__SOURCE_COMMIT__'; priorWorkerSha256 = $oldHash; workerSha256 = '__WORKER_SHA256__'; originalMarkerRetained = $true; startRequested = $true; clusterBootstrapComplete = $false } | ConvertTo-Json -Compress
