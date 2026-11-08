__CAPACITY_PRELUDE__
# Format only the single new, blank, non-boot attachment admitted by exact delta.
$before = Get-Content (Join-Path $capacityRoot 'baseline.json') -Raw | ConvertFrom-Json
if ($before.status -cne 'complete-pre-attachment-baseline' -or $before.planSha256 -cne $approval.planSha256 -or $before.azureDiskId -ine $plan.newDisk.id -or $before.hostBootUtc -cne (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') -or (Get-Volume -DriveLetter X -ErrorAction SilentlyContinue)) { throw 'Exact baseline/boot epoch differs or X exists' }
$null = [guid]::Parse($context.azureDiskUniqueId)
Assert-CapacityHost; $null = Read-CapacityOriginalVhds
$marker = [IO.File]::Open((Join-Path $capacityRoot 'format.started'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None); $marker.Dispose()
$path = Join-Path $capacityRoot 'format.json'
$record = @{ status = 'inspecting-one-new-device'; sourceCommit = $sourceCommit; azureDiskId = $plan.newDisk.id; azureDiskUniqueId = $context.azureDiskUniqueId; existingPoolsOrOsChanged = $false }
try {
    Save-CapacityState $path $record
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $all = @(Get-Disk); $physical = @(Get-PhysicalDisk)
        $new = @($all | Where-Object { $_.UniqueId -notin @($before.disks.uniqueId) }); $newPhysical = @($physical | Where-Object { $_.UniqueId -notin @($before.physicalDisks.uniqueId) })
        if ($new.Count -eq 1 -and $newPhysical.Count -eq 1) { break }
        if ($timer.Elapsed.TotalSeconds -gt 120) { throw 'Exact single new device not observed' }; Start-Sleep -Seconds 3
    } while ($true)
    if ($all.Count -ne 4 -or $physical.Count -ne 11 -or @(Compare-Object @($before.disks.uniqueId | Sort-Object) @($all | Where-Object { $_.UniqueId -in @($before.disks.uniqueId) } | ForEach-Object UniqueId | Sort-Object)).Count -ne 0 -or @(Compare-Object @($before.physicalDisks.uniqueId | Sort-Object) @($physical | Where-Object { $_.UniqueId -in @($before.physicalDisks.uniqueId) } | ForEach-Object UniqueId | Sort-Object)).Count -ne 0) { throw 'Unexpected new or changed existing devices' }
    $disk = $new[0]
    if ($disk.UniqueId -cne $newPhysical[0].UniqueId -or $disk.Size -ne 4096GB -or $newPhysical[0].Size -ne $disk.Size -or -not $newPhysical[0].CanPool -or $disk.IsBoot -or $disk.IsSystem -or $disk.Number -eq 0 -or $disk.PartitionStyle.ToString() -ne 'RAW' -or $disk.IsReadOnly -or $disk.IsOffline -or @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue).Count -ne 0) { throw 'New device is not the exact online blank non-boot attachment' }
    $record.windowsUniqueId = $disk.UniqueId; $record.windowsDiskNumber = $disk.Number; $record.status = 'initialise-one-admitted-new-disk-pending'; Save-CapacityState $path $record
    $null = Initialize-Disk -UniqueId $disk.UniqueId -PartitionStyle GPT -PassThru
    $disk = Get-Disk -UniqueId $record.windowsUniqueId
    if ($disk.IsBoot -or $disk.IsSystem -or $disk.Size -ne 4096GB) { throw 'Admitted new disk changed before partition' }
    $record.status = 'new-only-partition-and-ntfs-format-pending'; Save-CapacityState $path $record
    $partition = New-Partition -DiskNumber $disk.Number -DriveLetter X -UseMaximumSize
    $null = Format-Volume -Partition $partition -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel LocalBoxCapacity -Confirm:$false
    Assert-CapacityHost
    foreach ($old in $before.volumes) { $now = Get-Volume -DriveLetter $old.letter; if ($now.UniqueId -cne $old.uniqueId -or $now.Size -ne $old.size) { throw 'Existing volume changed' } }
    $x = Get-Volume -DriveLetter X
    if ($x.FileSystem -cne 'NTFS' -or $x.HealthStatus.ToString() -cne 'Healthy' -or $x.Size -lt 4095GB -or $x.SizeRemaining -lt 3000GB) { throw 'New X capacity/health differs' }
    $record.volumeId = $x.UniqueId; $record.volumeSize = $x.Size; $record.status = 'complete-new-only-4tib-x-volume'; Save-CapacityState $path $record
} catch { $record.status = 'failed-or-uncertain-inspect-do-not-repeat'; $record.errorType = $_.Exception.GetType().Name; $record.errorLine = $_.InvocationInfo.ScriptLineNumber; Save-CapacityState $path $record }
$record | ConvertTo-Json -Depth 8 -Compress
