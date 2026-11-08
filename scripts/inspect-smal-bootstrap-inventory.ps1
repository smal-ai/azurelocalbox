# Read-only identity collection. No disk mapping is inferred from size or disk order.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ne 'LocalBox-Client') { throw 'Unexpected target' }
$drives = @(Get-CimInstance Win32_DiskDrive)
$disks = @(foreach ($disk in (Get-Disk | Sort-Object Number)) {
    $drive = @($drives | Where-Object Index -eq $disk.Number)
    if ($drive.Count -ne 1) { throw 'Ambiguous Win32/Storage disk identity' }
    [ordered]@{
        number = $disk.Number
        uniqueId = $disk.UniqueId
        serialNumber = $disk.SerialNumber
        busType = $disk.BusType.ToString()
        location = $disk.Location
        sizeBytes = $disk.Size
        isBoot = $disk.IsBoot
        isSystem = $disk.IsSystem
        partitionStyle = $disk.PartitionStyle.ToString()
        offline = $disk.IsOffline
        readOnly = $disk.IsReadOnly
        win32 = @{ index = $drive[0].Index; model = $drive[0].Model; serialNumber = $drive[0].SerialNumber; scsiPort = $drive[0].SCSIPort; scsiBus = $drive[0].SCSIBus; scsiTargetId = $drive[0].SCSITargetId; scsiLogicalUnit = $drive[0].SCSILogicalUnit }
    }
})
$iso = 'C:\ProgramData\AzureLocalBox\Artifacts\2610\AzureLocal24H2.26100.32230.LCM.12.2610.0.3098.x64.en-us.iso'
$image = Get-Item -LiteralPath $iso
$diskImage = Get-DiskImage -ImagePath $iso
[ordered]@{
    computer = $env:COMPUTERNAME
    atUtc = (Get-Date).ToUniversalTime().ToString('o')
    lastBootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    vmms = (Get-Service vmms).Status.ToString()
    defenderRealTimeProtection = (Get-MpComputerStatus).RealTimeProtectionEnabled
    disks = $disks
    physicalDisks = @(Get-PhysicalDisk | ForEach-Object { @{ deviceId = $_.DeviceId; uniqueId = $_.UniqueId; serialNumber = $_.SerialNumber; busType = $_.BusType.ToString(); sizeBytes = $_.Size; canPool = $_.CanPool; physicalLocation = $_.PhysicalLocation } })
    nestedVms = @(Get-VM | Select-Object Name, Id, State)
    switches = @(Get-VMSwitch | Select-Object Name, SwitchType)
    nat = @(Get-NetNat | Select-Object Name, InternalIPInterfaceAddressPrefix)
    existingLocalBoxTasks = @(Get-ScheduledTask | Where-Object TaskName -like 'LocalBox*' | Select-Object TaskName, State)
    iso = @{ bytes = $image.Length; lastWriteTimeUtc = $image.LastWriteTimeUtc.ToString('o'); attached = $diskImage.Attached; hashReverifiedThisInspection = $false }
    inspectionReadOnly = $true
} | ConvertTo-Json -Depth 7 -Compress
