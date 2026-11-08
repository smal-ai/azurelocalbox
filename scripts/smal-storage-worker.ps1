# One-shot approved storage phase. This is NOT a complete cluster bootstrap.
param([switch]$ResumeVerified)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\storage-20261028-01'
$statePath = Join-Path $root 'state.json'
$state = [ordered]@{ schemaVersion = 1; runId = 'storage-20261028-01'; scope = 'storage-only'; status = 'running'; phase = 'initialising'; processId = $PID; clusterBootstrapComplete = $false }
function Save-State {
    $state.lastUpdatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $temporary = $statePath + '.tmp'
    [IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Depth 7), [Text.UTF8Encoding]::new($false))
    if (Test-Path $statePath) { [IO.File]::Replace($temporary, $statePath, (Join-Path $root 'state.previous.json')) } else { [IO.File]::Move($temporary, $statePath) }
    $event = @{ atUtc = $state.lastUpdatedAtUtc; phase = $state.phase; status = $state.status; runId = $state.runId; scope = $state.scope }
    [IO.File]::AppendAllText((Join-Path $root 'events.jsonl'), (($event | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}
$mutex = [Threading.Mutex]::new($false, 'Global\AzureLocalBox-Storage-20261028-01')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit 2 }
if ($ResumeVerified) {
    $proof = Get-Content (Join-Path $root 'recovery-authorised.json') -Raw | ConvertFrom-Json
    if ($proof.runId -ne $state.runId -or $proof.kind -ne 'verified-preflight-no-storage-effects' -or $proof.priorWorkerSha256 -ne '8C4B65A8299101ABA4ADEC3A6513432DFA0785571FA34322D6E7929749B490B0' -or (Get-FileHash (Join-Path $root 'worker.before-recovery.ps1')).Hash -ne $proof.priorWorkerSha256 -or -not (Test-Path (Join-Path $root 'execution.started'))) { $mutex.ReleaseMutex(); $mutex.Dispose(); exit 4 }
}
$attemptMarker = if ($ResumeVerified) { 'recovery-01.started' } else { 'execution.started' }
try { $started = [IO.File]::Open((Join-Path $root $attemptMarker), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); $started.Dispose() }
catch { $mutex.ReleaseMutex(); $mutex.Dispose(); exit 3 }
$heartbeatStarted = $false
try {
    if ($env:COMPUTERNAME -ne 'LocalBox-Client') { throw 'Unexpected target' }
    if ((Get-FileHash (Join-Path $root 'manifest.json') -Algorithm SHA256).Hash -ne '__MANIFEST_SHA256__') { throw 'Manifest differs' }
    $m = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
    if ($m.runId -ne $state.runId -or $m.scope -ne 'storage-only' -or $m.approvedByHuman -ne $true -or $m.disks.Count -ne 8 -or $m.resiliency -ne 'Simple' -or $m.driveLetter -ne 'V') { throw 'Unapproved storage profile' }
    if (-not (Get-NetIPAddress -IPAddress 10.200.16.4 -AddressFamily IPv4 -ErrorAction SilentlyContinue)) { throw 'Expected private address absent' }
    $metadata = [Net.HttpWebRequest]::Create('http://169.254.169.254/metadata/instance/compute/resourceId?api-version=2021-02-01&format=text')
    $metadata.Proxy = $null
    $metadata.Headers['Metadata'] = 'true'
    $metadata.Timeout = 5000
    $metadataResponse = $metadata.GetResponse()
    try { $reader = [IO.StreamReader]::new($metadataResponse.GetResponseStream()); try { $vmId = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() } } finally { $metadataResponse.Close() }
    if ($vmId -ine $m.azureVmResourceId) { throw 'Azure VM identity differs' }
    $initial = Get-Content $statePath -Raw | ConvertFrom-Json
    if ($initial.sourceCommit -notmatch '^[a-f0-9]{40}$') { throw 'Source commit evidence missing' }
    $state.sourceCommit = $initial.sourceCommit
    if ($ResumeVerified) {
        if ($proof.sourceCommit -notmatch '^[a-f0-9]{40}$') { throw 'Recovery source evidence missing' }
        $state.previousSourceCommit = $initial.sourceCommit
        $state.sourceCommit = $proof.sourceCommit
        $state.resumedAfterVerifiedNoEffects = $true
    }
    $state.workerSha256 = (Get-FileHash $PSCommandPath -Algorithm SHA256).Hash
    Save-State
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
public static class LocalBoxStorageHeartbeat {
    static Timer timer; static string path; static int pid; static int busy;
    public static void Start(string directory, int processId) {
        path = Path.Combine(directory, "heartbeat.json"); pid = processId;
        timer = new Timer(_ => {
            if (Interlocked.Exchange(ref busy, 1) != 0) return;
            try {
                string temporary = path + ".tmp";
                File.WriteAllText(temporary, "{\"processId\":" + pid + ",\"atUtc\":\"" + DateTime.UtcNow.ToString("o") + "\"}", new UTF8Encoding(false));
                if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
            } catch { } finally { Interlocked.Exchange(ref busy, 0); }
        }, null, 0, 15000);
    }
    public static void Stop() { if (timer != null) timer.Dispose(); }
}
'@
    [LocalBoxStorageHeartbeat]::Start($root, $PID)
    $heartbeatStarted = $true
    $state.phase = 'preflight'
    Save-State
    if ((Get-MpComputerStatus).RealTimeProtectionEnabled -ne $true) { throw 'Defender protection absent' }
    if (Get-Volume -DriveLetter V -ErrorAction SilentlyContinue) { throw 'V: already exists' }
    if (Get-StoragePool -FriendlyName $m.poolName -ErrorAction SilentlyContinue) { throw 'Storage pool name already exists' }
    if (Get-VirtualDisk -FriendlyName $m.virtualDiskName -ErrorAction SilentlyContinue) { throw 'Virtual disk name already exists' }
    $cBefore = Get-Partition -DriveLetter C
    $bootId = (Get-Disk -Number $cBefore.DiskNumber).UniqueId
    $allDisks = @(Get-Disk)
    $allPhysical = @(Get-PhysicalDisk)
    $win32 = @(Get-CimInstance Win32_DiskDrive)
    $ids = @($m.disks | ForEach-Object guestUniqueId)
    if (@($ids | Select-Object -Unique).Count -ne 8 -or @($m.disks | ForEach-Object lun | Sort-Object -Unique).Count -ne 8) { throw 'Duplicate storage identity' }
    $selected = @(foreach ($expected in $m.disks) {
        if ($expected.lun -lt 0 -or $expected.lun -gt 7 -or $expected.namespaceId -ne ($expected.lun + 1) -or $expected.sizeBytes -ne 256GB) { throw 'Unapproved LUN/namespace/size profile' }
        $disk = @($allDisks | Where-Object UniqueId -CEQ $expected.guestUniqueId)
        $physical = @($allPhysical | Where-Object UniqueId -CEQ $expected.guestUniqueId)
        if ($disk.Count -ne 1 -or $physical.Count -ne 1) { throw 'Ambiguous approved disk identity' }
        $drive = @($win32 | Where-Object Index -EQ $disk[0].Number)
        if ($drive.Count -ne 1 -or $drive[0].Model -cne 'Virtual_Disk NVMe Premium' -or $drive[0].SCSILogicalUnit -ne ($expected.lun + 1)) { throw 'NVMe namespace changed' }
        if ($disk[0].IsBoot -or $disk[0].IsSystem -or $disk[0].UniqueId -ceq $bootId -or $disk[0].PartitionStyle.ToString() -ne 'RAW' -or $disk[0].IsOffline -or $disk[0].IsReadOnly -or $disk[0].BusType.ToString() -ne 'NVMe' -or $disk[0].Size -ne 256GB -or $disk[0].SerialNumber -cne $expected.serialNumber -or $physical[0].SerialNumber -cne $expected.serialNumber -or $physical[0].Size -ne 256GB -or $physical[0].CanPool -ne $true) { throw 'Approved RAW data disk state changed' }
        $physical[0]
    })
    $subsystem = @(Get-StorageSubSystem | Where-Object FriendlyName -like 'Windows Storage*')
    if ($subsystem.Count -ne 1) { throw 'Storage subsystem is ambiguous' }
    $state.phase = 'pool-create-pending'
    $state.selectedPhysicalUniqueIds = $ids
    Save-State
    $pool = New-StoragePool -FriendlyName $m.poolName -StorageSubSystemUniqueId $subsystem[0].UniqueId -PhysicalDisks $selected -ResiliencySettingNameDefault Simple
    $state.poolUniqueId = $pool.UniqueId
    $state.phase = 'virtual-disk-create-pending'
    Save-State
    $vd = New-VirtualDisk -StoragePoolUniqueId $pool.UniqueId -FriendlyName $m.virtualDiskName -ResiliencySettingName Simple -NumberOfColumns 8 -UseMaximumSize -ProvisioningType Fixed
    $state.virtualDiskUniqueId = $vd.UniqueId
    $target = @($vd | Get-Disk)
    if ($target.Count -ne 1 -or $target[0].IsBoot -or $target[0].IsSystem -or $target[0].UniqueId -ceq $bootId -or $target[0].PartitionStyle.ToString() -ne 'RAW' -or $target[0].Size -lt 1800GB) { throw 'New owned virtual disk cannot be safely initialised' }
    $state.targetDiskUniqueId = $target[0].UniqueId
    $state.targetDiskNumber = $target[0].Number
    $state.phase = 'owned-volume-format-pending'
    Save-State
    $null = Initialize-Disk -Number $target[0].Number -PartitionStyle GPT -PassThru
    $fresh = Get-Disk -Number $target[0].Number
    if ($fresh.UniqueId -cne $state.targetDiskUniqueId -or $fresh.IsBoot -or $fresh.IsSystem) { throw 'Virtual disk identity changed before partitioning' }
    $partition = New-Partition -DiskNumber $fresh.Number -DriveLetter V -UseMaximumSize
    $null = $partition | Format-Volume -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel LocalBoxData -Confirm:$false -Force
    $state.phase = 'verify'
    Save-State
    $members = @($pool | Get-PhysicalDisk | ForEach-Object UniqueId)
    $volume = Get-Volume -DriveLetter V
    $cAfter = Get-Partition -DriveLetter C
    if ($members.Count -ne 8 -or (Compare-Object ($ids | Sort-Object) ($members | Sort-Object)) -or $volume.FileSystem -ne 'NTFS' -or $volume.HealthStatus.ToString() -ne 'Healthy' -or $volume.Size -lt 1800GB -or $cAfter.Size -ne $cBefore.Size -or (Get-Disk -Number $cAfter.DiskNumber).UniqueId -cne $bootId) { throw 'Storage/OS preservation verification failed' }
    $state.volume = @{ letter = 'V'; fileSystem = $volume.FileSystem; sizeBytes = $volume.Size; freeBytes = $volume.SizeRemaining; health = $volume.HealthStatus.ToString() }
    $state.osDiskAndPartitionUnchanged = $true
    $state.status = 'storage-complete'
    $state.phase = 'storage-verified'
    Save-State
} catch {
    $state.status = 'failed-inspect-before-resume'
    $state.errorType = $_.Exception.GetType().Name
    Save-State
} finally {
    if ($heartbeatStarted) { [LocalBoxStorageHeartbeat]::Stop() }
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
if ($state.status -ne 'storage-complete') { exit 1 }
