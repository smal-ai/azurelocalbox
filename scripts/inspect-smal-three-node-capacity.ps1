# Read-only sizing evidence for a proposed third node. No resize/move/creation.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected host' }
$os = Get-CimInstance Win32_OperatingSystem
$hostInfo = Get-VMHost
$targets = @(
    @{ name = 'LB-DC01'; id = 'f94c71f1-6854-48b9-a9f1-8238c99366d0' },
    @{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34' },
    @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' }
)
$guests = @(foreach ($target in $targets) {
    $vm = Get-VM -Id $target.id
    if ($vm.Name -cne $target.name) { throw 'Existing guest identity differs' }
    $images = @(Get-VMHardDiskDrive -VM $vm | ForEach-Object {
        $vhd = Get-VHD -Path $_.Path
        @{ path = $_.Path; controller = $_.ControllerNumber; lun = $_.ControllerLocation; virtualSizeBytes = $vhd.Size; allocatedFileBytes = $vhd.FileSize; diskId = $vhd.DiskIdentifier.ToString(); parentPath = $vhd.ParentPath }
    })
    $directory = 'V:\AzureLocalBox\Guests\local-guests-20261028-01\' + $target.name
    $other = @(Get-ChildItem -LiteralPath $directory -File -Recurse | Where-Object Extension -NE '.vhdx' | Group-Object Extension | ForEach-Object { @{ extension = $_.Name; count = $_.Count; fileBytes = ($_.Group | Measure-Object Length -Sum).Sum } })
    @{ name = $vm.Name; vmId = $vm.Id.ToString(); state = $vm.State.ToString(); memoryStartupBytes = $vm.MemoryStartup; memoryAssignedBytes = $vm.MemoryAssigned; dynamicMemory = $vm.DynamicMemoryEnabled; processors = $vm.ProcessorCount; configurationLocation = $vm.ConfigurationLocation; smartPagingPath = $vm.SmartPagingFilePath; automaticStopAction = $vm.AutomaticStopAction.ToString(); automaticStartAction = $vm.AutomaticStartAction.ToString(); disks = $images; nonVhdFiles = $other }
})
$volumes = @(Get-Volume | Where-Object DriveLetter -In @('C','V','W') | ForEach-Object { @{ letter = [string]$_.DriveLetter; sizeBytes = $_.Size; freeBytes = $_.SizeRemaining; fileSystem = $_.FileSystem; health = $_.HealthStatus.ToString() } })
$pool = Get-StoragePool -FriendlyName LocalBoxPool
$vd = Get-VirtualDisk -FriendlyName LocalBoxData
@{ atUtc = [datetime]::UtcNow.ToString('o'); computer = $env:COMPUTERNAME; hostMemoryBytes = $hostInfo.MemoryCapacity; logicalProcessors = $hostInfo.LogicalProcessorCount; freePhysicalBytes = ([long]$os.FreePhysicalMemory * 1KB);
   guests = $guests; allVmNames = @(Get-VM | ForEach-Object Name); volumes = $volumes;
   pool = @{ uniqueId = $pool.UniqueId; sizeBytes = $pool.Size; allocatedBytes = $pool.AllocatedSize; health = $pool.HealthStatus.ToString(); memberCount = @($pool | Get-PhysicalDisk).Count };
   virtualDisk = @{ uniqueId = $vd.UniqueId; sizeBytes = $vd.Size; columns = $vd.NumberOfColumns; resiliency = $vd.ResiliencySettingName; provisioning = $vd.ProvisioningType.ToString(); health = $vd.HealthStatus.ToString() };
   thirdNodeNamePresent = [bool](Get-VM -Name LB-NODE03 -ErrorAction SilentlyContinue); proposedWDrivePresent = [bool](Get-Volume -DriveLetter W -ErrorAction SilentlyContinue); mutationPerformed = $false } | ConvertTo-Json -Depth 9 -Compress
