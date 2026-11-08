__THREE_NODE_PRELUDE__
# Only the single new device admitted by a before/after attachment identity proof.
$before = Get-Content (Join-Path $threeRoot 'disk-baseline.json') -Raw | ConvertFrom-Json
if ($before.status -cne 'baseline-before-azure-lun8-attachment' -or $before.azureDiskId -ine $context.diskId -or $before.azureDiskUniqueId -ine $context.azureDiskUniqueId -or $before.lun -ne 8 -or $before.hostBootUtc -cne (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') -or (Get-Volume -DriveLetter W -ErrorAction SilentlyContinue)) { throw 'Exact pre-attachment admission proof or boot epoch differs' }
$marker = [IO.File]::Open((Join-Path $threeRoot 'new-disk-format.started'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); $marker.Dispose()
$record = @{ status = 'inspecting-new-device-delta'; sourceCommit = $sourceCommit; azureDiskId = $context.diskId; azureDiskUniqueId = $context.azureDiskUniqueId; lun = 8; existingPoolChanged = $false; osDiskChanged = $false }
$path = Join-Path $threeRoot 'new-disk-format.json'
function Save-NewDiskProof { $record.atUtc = [datetime]::UtcNow.ToString('o'); [IO.File]::WriteAllText($path, ($record | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false)) }
try {
    Save-NewDiskProof
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $all = @(Get-Disk); $physical = @(Get-PhysicalDisk)
        $new = @($all | Where-Object { $_.UniqueId -notin @($before.disks.uniqueId) })
        $newPhysical = @($physical | Where-Object { $_.UniqueId -notin @($before.physicalDisks.uniqueId) })
        if ($new.Count -eq 1 -and $newPhysical.Count -eq 1) { break }
        if ($timer.Elapsed.TotalSeconds -gt 120) { throw 'Exactly one newly attached Windows/physical device was not observed' }
        Start-Sleep -Seconds 3
    } while ($true)
    if ($all.Count -ne 3 -or $physical.Count -ne 10 -or @(Compare-Object @($before.disks.uniqueId | Sort-Object) @($all | Where-Object { $_.UniqueId -in @($before.disks.uniqueId) } | ForEach-Object UniqueId | Sort-Object)).Count -ne 0 -or @(Compare-Object @($before.physicalDisks.uniqueId | Sort-Object) @($physical | Where-Object { $_.UniqueId -in @($before.physicalDisks.uniqueId) } | ForEach-Object UniqueId | Sort-Object)).Count -ne 0) { throw 'Existing device identity set changed or extra devices appeared' }
    $disk = $new[0]
    if ($disk.UniqueId -cne $newPhysical[0].UniqueId -or $disk.Size -ne 2048GB -or $newPhysical[0].Size -ne $disk.Size -or -not $newPhysical[0].CanPool -or $disk.IsBoot -or $disk.IsSystem -or $disk.Number -eq 0 -or $disk.PartitionStyle.ToString() -ne 'RAW' -or @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue).Count -ne 0) { throw 'New device is not the exact blank non-boot attachment' }
    $record.windowsUniqueId = $disk.UniqueId; $record.windowsDiskNumber = $disk.Number; $record.size = $disk.Size; $record.status = 'initialise-only-admitted-new-disk-pending'; Save-NewDiskProof
    $null = Initialize-Disk -UniqueId $record.windowsUniqueId -PartitionStyle GPT -PassThru
    $disk = Get-Disk -UniqueId $record.windowsUniqueId
    if ($disk.IsBoot -or $disk.IsSystem -or $disk.Size -ne 2048GB) { throw 'New disk identity changed before partition' }
    $record.status = 'new-partition-and-ntfs-format-pending'; Save-NewDiskProof
    $partition = New-Partition -DiskNumber $disk.Number -DriveLetter W -UseMaximumSize
    $null = Format-Volume -Partition $partition -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel LocalBoxNode03 -Confirm:$false -Force
    $w = Get-Volume -DriveLetter W; $v = Get-Volume -DriveLetter V; $c = Get-Volume -DriveLetter C
    if ($w.FileSystem -ne 'NTFS' -or $w.HealthStatus.ToString() -ne 'Healthy' -or $w.Size -lt 2047GB -or $w.SizeRemaining -lt 1258GB -or $v.UniqueId -cne $before.vVolumeId -or $v.Size -ne $before.vSize -or $c.UniqueId -cne $before.cVolumeId -or $c.Size -ne $before.cSize -or (Get-VirtualDisk -FriendlyName LocalBoxData).UniqueId -cne 'D0CDB2F96D0E244E8B532E096F97FBBF') { throw 'New capacity or preservation readback differs' }
    $record.volumeId = $w.UniqueId; $record.volumeSize = $w.Size; $record.status = 'complete-new-lun8-only-formatted-w'; Save-NewDiskProof
} catch { $record.status = 'failed-or-uncertain-inspect-before-resume'; $record.errorType = $_.Exception.GetType().Name; $record.errorLine = $_.InvocationInfo.ScriptLineNumber; Save-NewDiskProof }
$record | ConvertTo-Json -Depth 6 -Compress
if ($record.status -ne 'complete-new-lun8-only-formatted-w') { throw 'New disk stage incomplete. Inspect marker and state; never repeat formatting.' }
