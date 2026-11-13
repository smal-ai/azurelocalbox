param(
    [ValidateSet('Inspect', 'Expand', 'Recover', 'Continue', 'StorageInspect', 'GrowStorage', 'RestoreNested', 'QuickInspect', 'OuterStorage', 'NodeStatus', 'ReadDiagnostics')][string]$Action = 'Inspect',
    [Parameter(Mandatory = $true)][string]$ConfigurationBase64,
    [Parameter(Mandatory = $true)][string]$CapacityBase64,
    [string]$OriginalOperationId,
    [ValidateSet('LB-NODE01', 'LB-NODE02', 'LB-NODE03')][string]$NodeName
)
$ErrorActionPreference = 'Stop'
$config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ConfigurationBase64)) | ConvertFrom-Json
$capacity = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CapacityBase64)) | ConvertFrom-Json
if ($env:COMPUTERNAME -cne $config.hostName -or $capacity.nodeName -cne 'LB-NODE03' -or
    $capacity.nodeId -cne '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9' -or $capacity.cpu -ne 20 -or $capacity.memoryGiB -ne 96 -or
    $config.guestIds.'LB-NODE03' -cne $capacity.nodeId) { throw 'Fixed host, node identity or selected profile differs' }
$mutex = [Threading.Mutex]::new($false, 'Global\AzureLocalBoxComputeCapacityR2')
$held = $false
$peer = $null
$state = $null
$root = 'C:\ProgramData\AzureLocalBox\Operations'
$statePath = Join-Path $root 'smal-capacity-node03.json'
$nodeNames = @('LB-NODE01', 'LB-NODE02', 'LB-NODE03')

function Save-State {
    $state.updatedAt = [datetime]::UtcNow.ToString('o')
    $temporary = $statePath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Depth 25), [Text.UTF8Encoding]::new($false))
    # Windows PowerShell 5.1 converts a null backup name to an invalid empty path.
    if (Test-Path $statePath) { [IO.File]::Replace($temporary, $statePath, ($statePath + '.previous')) }
    else { [IO.File]::Move($temporary, $statePath) }
}

function Open-NodeSession([string]$name) {
    $vm = Get-VM -Id $config.guestIds.PSObject.Properties[$name].Value
    if ($vm.Name -cne $name -or $vm.State.ToString() -cne 'Running') { throw 'Expected existing running HCI guest' }
    $bundle = Get-Content (Join-Path $config.guestHelperDirectory 'bundle.json') -Raw | ConvertFrom-Json
    $entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
    $helper = Join-Path $config.guestHelperDirectory 'smal-guest-secret-functions.ps1'
    if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Protected guest helper differs' }
    . $helper
    $store = Join-Path $config.credentialDirectory 'secrets'
    $bindings = Get-Content (Join-Path $config.credentialDirectory 'credential-bindings.json') -Raw | ConvertFrom-Json
    $binding = $bindings.nodes.PSObject.Properties[$name].Value
    if ($binding.vmId -ine $vm.Id.ToString() -or $binding.role -cne 'cluster-node-admin' -or $binding.secretDirectory -cne $store -or $binding.loginVerified -ne $true) {
        throw 'Existing guest credential binding differs'
    }
    $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'
    try { New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($name + '\ASBuiltInAdmin'), $secure)) }
    finally { $secure.Dispose() }
}

function Read-Profile {
    $vm = Get-VM -Id $capacity.nodeId
    $processor = Get-VMProcessor -VM $vm
    $memory = Get-VMMemory -VM $vm
    @{ id = $vm.Id.ToString(); name = $vm.Name; cpu = $vm.ProcessorCount; memoryBytes = $vm.MemoryStartup;
       state = $vm.State.ToString(); dynamicMemory = $memory.DynamicMemoryEnabled;
       preserved = (@{ id = $vm.Id.ToString(); generation = $vm.Generation; version = $vm.Version.ToString();
           path = $vm.Path; automaticStart = $vm.AutomaticStartAction.ToString(); automaticStop = $vm.AutomaticStopAction.ToString();
           nested = $processor.ExposeVirtualizationExtensions; reserve = $processor.Reserve; maximum = $processor.Maximum; weight = $processor.RelativeWeight;
           dynamicMemory = $memory.DynamicMemoryEnabled; minimumBytes = $memory.Minimum; maximumBytes = $memory.Maximum;
           disks = @($vm | Get-VMHardDiskDrive | Sort-Object ControllerType, ControllerNumber, ControllerLocation | ForEach-Object {
               $disk = Get-VHD -Path $_.Path
               @{ path = $_.Path; id = $disk.DiskIdentifier.ToString(); sizeBytes = $disk.Size;
                  controller = $_.ControllerType.ToString(); number = $_.ControllerNumber; lun = $_.ControllerLocation }
           }); adapters = @($vm | Get-VMNetworkAdapter | Sort-Object Name | ForEach-Object {
               $vlan = $_ | Get-VMNetworkAdapterVlan
               @{ name = $_.Name; mac = $_.MacAddress; switchId = $_.SwitchId.ToString(); switch = $_.SwitchName;
                  dynamicMac = $_.DynamicMacAddressEnabled; vlan = $vlan.OperationMode.ToString(); access = $vlan.AccessVlanId; native = $vlan.NativeVlanId }
           }) } | ConvertTo-Json -Depth 15 -Compress) }
}

function Convert-OrderedValue($value) {
    if ($value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($value.Keys | Sort-Object)) { $result[$key] = Convert-OrderedValue $value[$key] }
        return $result
    }
    if ($value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($key in @($value.PSObject.Properties.Name | Sort-Object)) { $result[$key] = Convert-OrderedValue $value.$key }
        return $result
    }
    if ($value -is [Collections.IList]) { return ,@($value | ForEach-Object { Convert-OrderedValue $_ }) }
    return $value
}

function Same-Preserved([string]$left, [string]$right) {
    $a = Convert-OrderedValue ($left | ConvertFrom-Json)
    $b = Convert-OrderedValue ($right | ConvertFrom-Json)
    ($a | ConvertTo-Json -Depth 20 -Compress) -ceq ($b | ConvertTo-Json -Depth 20 -Compress)
}

function Read-Cluster {
    Invoke-Command -Session $peer -ArgumentList $config.clusterName, $config.mocLocation -ScriptBlock {
        param($name, $location)
        $ErrorActionPreference = 'Stop'
        if ((Get-Cluster).Name -ine $name) { throw 'Wrong cluster' }
        $pools = @(Get-StoragePool -IsPrimordial $false)
        if ($pools.Count -ne 1) { throw 'Expected one S2D pool' }
        $quorum = Get-ClusterQuorum
        Import-Module Moc -ErrorAction Stop
        function Read-Names($value) {
            if ($value -is [Collections.IList]) { foreach ($item in $value) { Read-Names $item } }
            else { if ($value.location -cne $location -or -not $value.name) { throw 'Invalid MOC membership' }; $value.name.ToUpperInvariant() }
        }
        $moc = @()
        $mocError = $null
        try { $moc = @(Read-Names (Get-MocNode -location $location -timeoutSeconds 30) | Sort-Object -Unique) }
        catch { $mocError = $_.Exception.Message }
        @{ nodes = @(Get-ClusterNode | Sort-Object Name | ForEach-Object { @{ name = $_.Name; state = $_.State.ToString(); drainStatus = [string]$_.DrainStatus; vote = $_.NodeWeight; dynamicVote = $_.DynamicWeight } });
           quorum = @{ type = $quorum.QuorumType.ToString(); resource = [string]$quorum.QuorumResource; state = [string]$quorum.QuorumResource.State };
           pool = @{ id = $pools[0].UniqueId; health = $pools[0].HealthStatus.ToString(); sizeBytes = $pools[0].Size; allocatedBytes = $pools[0].AllocatedSize };
           disks = @($pools[0] | Get-PhysicalDisk | ForEach-Object { @{ id = $_.UniqueId; sizeBytes = $_.Size; health = $_.HealthStatus.ToString(); operational = @($_.OperationalStatus | ForEach-Object ToString) } });
           virtualDisks = @(Get-VirtualDisk | Sort-Object FriendlyName | ForEach-Object { @{ name = $_.FriendlyName; health = $_.HealthStatus.ToString(); operational = @($_.OperationalStatus | ForEach-Object ToString); sizeBytes = $_.Size; footprintBytes = $_.FootprintOnPool; copies = $_.NumberOfDataCopies } });
           csvs = @(Get-ClusterSharedVolume | Sort-Object Name | ForEach-Object { @{ name = $_.Name; owner = $_.OwnerNode.Name; state = $_.State.ToString(); paths = @($_.SharedVolumeInfo | ForEach-Object { @{ path = $_.FriendlyVolumeName; sizeBytes = $_.Partition.Size; freeBytes = $_.Partition.FreeSpace } }) } });
           jobs = @(Get-StorageJob | Where-Object JobState -NotIn @('Completed', 'Terminated') | ForEach-Object { @{ name = $_.Name; state = $_.JobState.ToString(); percent = $_.PercentComplete } });
           mocMembers = $moc; mocError = $mocError;
           groups = @(Get-ClusterGroup | ForEach-Object { @{ name = $_.Name; state = [string]$_.State; owner = $_.OwnerNode.Name } });
           resources = @(Get-ClusterResource | ForEach-Object { @{ name = $_.Name; type = [string]$_.ResourceType; state = [string]$_.State; owner = $_.OwnerNode.Name } }) }
    }
}

function Assert-Healthy($cluster, [bool]$storageOnly = $false) {
    if ($cluster.nodes.Count -ne 3 -or @($cluster.nodes | Where-Object { $_.name -cnotin $nodeNames -or $_.state -cne 'Up' -or $_.vote -ne 1 }).Count -or
        $cluster.pool.health -cne 'Healthy' -or $cluster.disks.Count -ne 24 -or @($cluster.disks | Where-Object { $_.health -cne 'Healthy' -or @($_.operational | Where-Object { $_ -cne 'OK' }).Count }).Count -or
        $cluster.virtualDisks.Count -lt 4 -or @($cluster.virtualDisks | Where-Object { $_.health -cne 'Healthy' -or @($_.operational | Where-Object { $_ -cne 'OK' }).Count }).Count -or
        $cluster.csvs.Count -ne 4 -or @($cluster.csvs | Where-Object state -CNE 'Online').Count -or $cluster.jobs.Count -or
        (-not $storageOnly -and ($cluster.mocMembers.Count -ne 3 -or @($cluster.mocMembers | Where-Object { $_ -cnotin $nodeNames }).Count)) -or
        ($cluster.quorum.resource -and $cluster.quorum.state -cne 'Online')) { throw 'Current three-node quorum/storage/MOC health is not admissible' }
}

function Read-Inventory {
    $system = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $outer = @(Get-VM | Sort-Object Name | ForEach-Object { @{ name = $_.Name; id = $_.Id.ToString(); state = $_.State.ToString(); cpu = $_.ProcessorCount; memoryBytes = $_.MemoryStartup } })
    $nested = @(foreach ($name in $nodeNames) {
        $session = Open-NodeSession $name
        try {
            Invoke-Command -Session $session -ScriptBlock {
                $os = Get-CimInstance Win32_OperatingSystem
                @{ node = $env:COMPUTERNAME; os = $os.Caption; build = [int]$os.BuildNumber; freeMemoryBytes = [long]$os.FreePhysicalMemory * 1KB;
                   vms = @(Get-VM | Sort-Object Name | ForEach-Object {
                       $vm = $_
                       @{ name = $vm.Name; id = $vm.Id.ToString(); cpu = $vm.ProcessorCount; memoryBytes = $vm.MemoryStartup; state = $vm.State.ToString();
                          status = $vm.Status; heartbeat = $vm.Heartbeat.ToString(); uptimeSeconds = $vm.Uptime.TotalSeconds;
                          disks = @($vm | Get-VMHardDiskDrive | ForEach-Object {
                              $disk = Get-VHD -Path $_.Path
                              @{ path = $_.Path; sizeBytes = $disk.Size; fileBytes = $disk.FileSize; parent = $disk.ParentPath; type = $disk.VhdType.ToString() }
                          }) }
                   }) }
            }
        } finally { Remove-PSSession $session }
    })
    @{ outerCpu = $system.NumberOfLogicalProcessors; outerMemoryBytes = $system.TotalPhysicalMemory;
       outerFreeMemoryBytes = [long]$os.FreePhysicalMemory * 1KB; outerVms = $outer; nested = $nested;
       cluster = Read-Cluster; profile = Read-Profile }
}

function Read-UserStorage {
    $targetSession = Open-NodeSession 'LB-NODE03'
    try { Invoke-Command -Session $targetSession -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        @(Get-VirtualDisk | Where-Object FriendlyName -Match '^UserStorage_[123]$' | Sort-Object FriendlyName | ForEach-Object {
            $virtual = $_
            $disks = @($virtual | Get-Disk)
            if ($disks.Count -ne 1) {
                @{ name = $virtual.FriendlyName; virtualDiskId = $virtual.UniqueId; diskCount = $disks.Count;
                   disks = @(Get-Disk | ForEach-Object { @{ number = $_.Number; id = $_.UniqueId; path = $_.Path; friendlyName = $_.FriendlyName } });
                   csvs = @(Get-ClusterSharedVolume | ForEach-Object { @{ name = $_.Name; owner = $_.OwnerNode.Name; info = @($_.SharedVolumeInfo | ForEach-Object { @{ path = $_.FriendlyVolumeName; partition = $_.Partition.Name } }) } }) }
                return
            }
            $disk = $disks[0]
            $partitions = @($disk | Get-Partition | Where-Object Type -NE 'Reserved')
            if ($partitions.Count -ne 1) { throw 'User disk must bind exactly one data partition' }
            $partition = $partitions[0]
            $volumes = @($partition | Get-Volume)
            if ($volumes.Count -ne 1) { throw 'User partition must bind exactly one volume' }
            $volume = $volumes[0]
            $supported = $partition | Get-PartitionSupportedSize
            $tiers = @($virtual | Get-StorageTier)
            $csvs = @(Get-ClusterSharedVolume | Where-Object { @($_.SharedVolumeInfo | Where-Object { $_.Partition.Name -ieq $volume.Path }).Count })
            @{ name = $virtual.FriendlyName; virtualDiskId = $virtual.UniqueId; virtualSizeBytes = $virtual.Size;
               footprintBytes = $virtual.FootprintOnPool; copies = $virtual.NumberOfDataCopies;
               resiliency = $virtual.ResiliencySettingName; provisioning = $virtual.ProvisioningType.ToString(); tiers = @($tiers | ForEach-Object { @{ id = $_.UniqueId; name = $_.FriendlyName; sizeBytes = $_.Size } });
               diskId = $disk.UniqueId; diskNumber = $disk.Number; diskSizeBytes = $disk.Size; partitionStyle = $disk.PartitionStyle.ToString();
               partitionGuid = [string]$partition.Guid; partitionNumber = $partition.PartitionNumber; partitionOffsetBytes = $partition.Offset;
               partitionSizeBytes = $partition.Size; supportedMinimumBytes = $supported.SizeMin; supportedMaximumBytes = $supported.SizeMax;
               volumeId = $volume.UniqueId; volumePath = $volume.Path; filesystem = $volume.FileSystemType.ToString(); label = $volume.FileSystemLabel;
               volumeSizeBytes = $volume.Size; freeBytes = $volume.SizeRemaining; health = $volume.HealthStatus.ToString();
               operational = @($volume.OperationalStatus | ForEach-Object ToString);
               csvs = @($csvs | ForEach-Object { @{ name = $_.Name; id = $_.Id.ToString(); state = $_.State.ToString(); owner = $_.OwnerNode.Name; paths = @($_.SharedVolumeInfo.FriendlyVolumeName) } }) }
        })
    } } finally { Remove-PSSession $targetSession }
}

function Restore-Service {
    # Recovery never repeats shutdown, resize or drain. It honours the original operation.
    $vm = Get-VM -Id $capacity.nodeId
    if ($vm.State.ToString() -ceq 'Off') { Start-VM -VM $vm | Out-Null }
    elseif ($vm.State.ToString() -cne 'Running') { throw 'Guest is transitioning. No forced power action is allowed' }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $session = $null
        try { $session = Open-NodeSession $capacity.nodeName; break } catch { Start-Sleep 10 }
    } while ($timer.Elapsed.TotalSeconds -lt 360)
    if (-not $session) { throw 'Guest has not returned to authenticated service' }
    Remove-PSSession $session
    $timer.Restart()
    do {
        $nodeState = Invoke-Command -Session $peer -ScriptBlock { (Get-ClusterNode -Name LB-NODE03).State.ToString() }
        if ($nodeState -cin @('Up', 'Paused')) { break }
        Start-Sleep 10
    } while ($timer.Elapsed.TotalSeconds -lt 300)
    if ($nodeState -ceq 'Paused') {
        Invoke-Command -Session $peer -ScriptBlock { Resume-ClusterNode -Name LB-NODE03 -Failback NoFailback | Out-Null }
    } elseif ($nodeState -cne 'Up') { throw 'NODE03 has not rejoined the cluster' }
    $timer.Restart()
    do {
        try { $cluster = Read-Cluster; Assert-Healthy $cluster $true; break }
        catch { if ($timer.Elapsed.TotalSeconds -ge 600) { throw }; Start-Sleep 15 }
    } while ($true)
    foreach ($csv in $state.before.cluster.csvs) {
        Invoke-Command -Session $peer -ArgumentList $csv.name, $csv.owner -ScriptBlock {
            param($name, $owner)
            $current = Get-ClusterSharedVolume -Name $name
            if ($current.OwnerNode.Name -ine $owner) { Move-ClusterSharedVolume -Name $name -Node $owner | Out-Null }
        }
    }
    $cluster = Read-Cluster
    Assert-Healthy $cluster $true
    foreach ($csv in $state.before.cluster.csvs) {
        if (@($cluster.csvs | Where-Object { $_.name -ceq $csv.name -and $_.owner -ceq $csv.owner }).Count -ne 1) { throw 'Original CSV ownership not restored' }
    }
    $profile = Read-Profile
    if (-not (Same-Preserved $profile.preserved $state.before.profile.preserved)) { throw 'Guest disk/network/non-compute profile changed' }
    $timer.Restart()
    do {
        try { $cluster = Read-Cluster; Assert-Healthy $cluster; break }
        catch { if ($timer.Elapsed.TotalSeconds -ge 600) { throw }; Start-Sleep 15 }
    } while ($true)
    @{ cluster = $cluster; profile = $profile }
}

try {
    if ($Action -ceq 'ReadDiagnostics') {
        $directory = Join-Path $root 'aks-node-7deb3788-0d92-4b8d-a1e3-66c7ceb4fad7'
        $checks = @(foreach ($name in @('pressure', 'vmstat', 'runtime-state', 'kubelet-journal')) {
            $path = Join-Path $directory ($name + '-last.json')
            if (Test-Path $path) {
                $item = Get-Item $path
                if ($item.Length -gt 262144) { throw 'Diagnostic result exceeds bounded public read size' }
                $text = Get-Content $path -Raw
                if ($text -match '(?i)-----BEGIN|"(?:password|access_token|refresh_token|client_secret)"\s*:') { throw 'Sensitive diagnostic output suppressed' }
                @{ name = $name; modifiedAt = $item.LastWriteTimeUtc.ToString('o'); result = ($text | ConvertFrom-Json) }
            } else { @{ name = $name; status = 'not-recorded' } }
        })
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='ssh.exe'" -OperationTimeoutSec 15 | ForEach-Object { @{ name = $_.Name; id = $_.ProcessId; parentId = $_.ParentProcessId; createdAt = $_.CreationDate.ToUniversalTime().ToString('o') } })
        @{ action = $Action; checks = $checks; processes = $processes; observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 15 -Compress
        return
    }
    if ($Action -ceq 'NodeStatus') {
        $peer = Open-NodeSession $NodeName
        $result = Invoke-Command -Session $peer -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $results = @{}
            foreach ($query in @(
                @{ key = 'virtualMachines'; namespace = 'root\virtualization\v2'; class = 'Msvm_ComputerSystem'; fields = @('Name', 'ElementName', 'EnabledState', 'RequestedState', 'HealthState', 'OperationalStatus', 'Status', 'ProcessID') },
                @{ key = 'vmHeartbeat'; namespace = 'root\virtualization\v2'; class = 'Msvm_HeartbeatComponent'; fields = @('SystemName', 'OperationalStatus', 'HealthState', 'Status') },
                @{ key = 'clusterGroups'; namespace = 'root\MSCluster'; class = 'MSCluster_ResourceGroup'; fields = @('Name', 'State', 'OwnerNode') },
                @{ key = 'storageJobs'; namespace = 'root\Microsoft\Windows\Storage'; class = 'MSFT_StorageJob'; fields = @('Name', 'JobState', 'PercentComplete', 'BytesProcessed', 'BytesTotal', 'ElapsedTime') },
                @{ key = 'ioProcesses'; namespace = 'root\cimv2'; class = 'Win32_PerfFormattedData_PerfProc_Process'; fields = @('Name', 'IDProcess', 'IODataBytesPersec', 'IOReadBytesPersec', 'IOWriteBytesPersec', 'PercentProcessorTime') },
                @{ key = 'storagePool'; namespace = 'root\Microsoft\Windows\Storage'; class = 'MSFT_StoragePool'; fields = @('FriendlyName', 'UniqueId', 'HealthStatus', 'OperationalStatus', 'Size', 'AllocatedSize', 'IsPrimordial') },
                @{ key = 'volumes'; namespace = 'root\Microsoft\Windows\Storage'; class = 'MSFT_Volume'; fields = @('UniqueId', 'FileSystemLabel', 'HealthStatus', 'OperationalStatus', 'Size', 'SizeRemaining') }
            )) {
                $timer = [Diagnostics.Stopwatch]::StartNew()
                try {
                    $rows = @(Get-CimInstance -Namespace $query.namespace -ClassName $query.class -OperationTimeoutSec 15 | Select-Object -Property $query.fields)
                    if ($query.key -ceq 'ioProcesses') { $rows = @($rows | Where-Object { $_.Name -match '^(vmwp|System|moc|clussvc|svchost)' } | Sort-Object IODataBytesPersec -Descending | Select-Object -First 12) }
                    $results[$query.key] = @{ elapsedSeconds = $timer.Elapsed.TotalSeconds; rows = $rows; status = 'complete' }
                } catch { $results[$query.key] = @{ elapsedSeconds = $timer.Elapsed.TotalSeconds; status = 'failed'; error = $_.Exception.Message } }
            }
            @{ node = $env:COMPUTERNAME; results = $results; observedAt = [datetime]::UtcNow.ToString('o') }
        }
        @{ action = $Action; result = $result } | ConvertTo-Json -Depth 20 -Compress
        return
    }
    if ($Action -ceq 'OuterStorage') {
        # Remote NVMe Windows namespace/SCSI logical unit is Azure LUN + 1.
        # https://learn.microsoft.com/azure/virtual-machines/enable-nvme-remote-faqs
        $windows = @(Get-CimInstance Win32_DiskDrive -OperationTimeoutSec 15 | Where-Object { $_.Model -ceq 'Virtual_Disk NVMe Premium' -and $_.SCSILogicalUnit -in @(9, 10) } | ForEach-Object {
            $drive = $_
            $disk = Get-Disk -Number $drive.Index
            @{ index = $drive.Index; namespaceId = $drive.SCSILogicalUnit; azureLun = $drive.SCSILogicalUnit - 1; scsiPort = $drive.SCSIPort; scsiTarget = $drive.SCSITargetId;
               model = $drive.Model; serial = $drive.SerialNumber; diskId = $disk.UniqueId; diskLocation = $disk.Location;
               diskPath = $disk.Path; sizeBytes = $disk.Size; partitions = @($disk | Get-Partition | ForEach-Object {
                   $partition = $_; $volumes = @($partition | Get-Volume)
                   @{ guid = [string]$partition.Guid; number = $partition.PartitionNumber; accessPaths = @($partition.AccessPaths);
                      volumes = @($volumes | ForEach-Object { @{ id = $_.UniqueId; path = $_.Path; letter = [string]$_.DriveLetter; label = $_.FileSystemLabel; freeBytes = $_.SizeRemaining; sizeBytes = $_.Size } }) }
               }) }
        })
        $attachments = @(foreach ($name in $nodeNames) {
            $vm = Get-VM -Id $config.guestIds.PSObject.Properties[$name].Value
            @{ name = $vm.Name; id = $vm.Id.ToString(); disks = @($vm | Get-VMHardDiskDrive | ForEach-Object { @{ path = $_.Path; number = $_.ControllerNumber; location = $_.ControllerLocation } }) }
        })
        $vms = @(Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -OperationTimeoutSec 15 | Select-Object Name, ElementName, EnabledState, ProcessID)
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -OperationTimeoutSec 15 | ForEach-Object { @{ id = $_.ProcessId; parentId = $_.ParentProcessId; createdAt = $_.CreationDate.ToUniversalTime().ToString('o') } })
        $io = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -OperationTimeoutSec 15 | Where-Object { $_.Name -match '^(vmwp|System)' } | Select-Object Name, IDProcess, IODataBytesPersec, IOReadBytesPersec, IOWriteBytesPersec)
        @{ action = $Action; windowsDisks = $windows; guestAttachments = $attachments; vmProcesses = $vms; powershellProcesses = $processes; ioProcesses = $io; observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 20 -Compress
        return
    }
    if ($Action -ceq 'QuickInspect') {
        # Read-only observer intentionally does not wait on a platform/read mutex.
        # No VHD scans, recursive image searches or resource modifications.
        $outer = @(Get-VM | ForEach-Object { @{ name = $_.Name; id = $_.Id.ToString(); state = $_.State.ToString(); heartbeat = $_.Heartbeat.ToString(); cpu = $_.ProcessorCount; memoryBytes = $_.MemoryStartup } })
        $sessions = @()
        $nested = @(foreach ($name in $nodeNames) {
            $session = Open-NodeSession $name; $sessions += $session
            Invoke-Command -Session $session -ScriptBlock {
                @{ node = $env:COMPUTERNAME; vms = @(Get-VM | ForEach-Object { @{ name = $_.Name; id = $_.Id.ToString(); state = $_.State.ToString(); heartbeat = $_.Heartbeat.ToString(); disks = @($_ | Get-VMHardDiskDrive | ForEach-Object { @{ path = $_.Path; location = $_.ControllerLocation } }) } });
                   storageJobs = @(Get-StorageJob | ForEach-Object { @{ name = $_.Name; state = [string]$_.JobState; percent = $_.PercentComplete; bytesTotal = $_.BytesTotal; bytesProcessed = $_.BytesProcessed } });
                   physicalDisks = @(Get-PhysicalDisk | ForEach-Object { @{ id = $_.UniqueId; deviceId = $_.DeviceId; health = [string]$_.HealthStatus; operational = @($_.OperationalStatus | ForEach-Object ToString) } }) }
            }
        })
        $peer = $sessions[0]
        $cluster = Read-Cluster
        foreach ($session in $sessions | Select-Object -Skip 1) { Remove-PSSession $session }
        @{ action = $Action; outer = $outer; nested = $nested; cluster = $cluster; observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 25 -Compress
        return
    }
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another platform operation is currently running' }
    $peer = Open-NodeSession 'LB-NODE01'
    if (Test-Path $statePath) {
        $loaded = Get-Content $statePath -Raw | ConvertFrom-Json
        $state = @{}
        foreach ($property in $loaded.PSObject.Properties) { $state[$property.Name] = $property.Value }
    }
    if ($Action -ceq 'Inspect') {
        @{ action = $Action; inventory = Read-Inventory; originalOperation = $state; observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 30 -Compress
        return
    }
    if ($Action -ceq 'StorageInspect') {
        @{ action = $Action; storage = @(Read-UserStorage); cluster = Read-Cluster; originalOperation = $state;
           observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 30 -Compress
        return
    }
    if ($Action -ceq 'RestoreNested') {
        if (-not $state -or $state.id -cne $OriginalOperationId -or $state.status -cnotin @('service-restored', 'complete')) { throw 'Nested startup requires the exact reconciled original operation' }
        $inventory = Read-Inventory
        Assert-Healthy $inventory.cluster
        $startup = @{}
        if ($state.nestedStartup) { foreach ($property in $state.nestedStartup.PSObject.Properties) { $startup[$property.Name] = $property.Value } }
        $state.nestedStartup = $startup
        foreach ($id in $capacity.knownNestedVmIds) {
            $placements = @($inventory.nested | ForEach-Object { $hostNode = $_.node; $_.vms | Where-Object id -CEQ $id | ForEach-Object { @{ node = $hostNode; vm = $_ } } })
            if ($placements.Count -ne 1) { throw 'Exact nested VM placement not found' }
            $placement = $placements[0]
            if ($placement.vm.state -ceq 'Running') { continue }
            if ($placement.vm.state -cin @('Starting', 'Resuming')) { continue }
            if ($placement.vm.state -cnotin @('Off', 'Saved')) { throw ('Nested VM is not in an admitted normal startup state: ' + $id + ':' + $placement.vm.state) }
            if ($startup.ContainsKey($id)) { throw ('Original nested startup intent exists. Inspect current state rather than repeat: ' + $id) }
            $startup[$id] = @{ phase = 'start-intent'; observedState = $placement.vm.state; node = $placement.node; vmName = $placement.vm.name; at = [datetime]::UtcNow.ToString('o') }
            Save-State
            $session = Open-NodeSession $placement.node
            try {
                Invoke-Command -Session $session -ArgumentList $id, $placement.vm.name -ScriptBlock {
                    param($id, $name)
                    $vm = Get-VM -Id $id
                    if ($vm.Name -cne $name -or $vm.State.ToString() -cnotin @('Off', 'Saved')) { throw 'Nested startup identity/state changed' }
                    $resources = @(Get-ClusterResource | Where-Object ResourceType -EQ 'Virtual Machine' | Where-Object {
                        @($_ | Get-ClusterParameter | Where-Object { $_.Name -ceq 'VmId' -and $_.Value -ieq $id }).Count
                    })
                    if ($resources.Count -ne 1) { throw 'Exact clustered VM resource binding missing' }
                    $group = Get-ClusterGroup -Name $resources[0].OwnerGroup.Name
                    if ($group.State.ToString() -cin @('Offline', 'Failed', 'PartialOnline')) {
                        Start-ClusterGroup -InputObject $group -Wait 180 | Out-Null
                    } elseif ($group.State.ToString() -ceq 'Online') {
                        Start-VM -VM $vm | Out-Null
                    } else { throw 'Exact nested cluster group has an unresolved transition' }
                }
                $startup[$id].phase = 'returned'; Save-State
            } finally { Remove-PSSession $session }
        }
        @{ action = $Action; operationId = $state.id; inventory = Read-Inventory; originalRequests = $startup } | ConvertTo-Json -Depth 30 -Compress
        return
    }
    if ($Action -ceq 'GrowStorage') {
        if (-not $state -or $state.id -cne $OriginalOperationId -or $state.nodeId -cne $capacity.nodeId -or
            $state.status -cnotin @('service-restored', 'complete')) { throw 'Storage growth requires the exact healthy reconciled original capacity operation' }
        $growth = $capacity.csvGrowth
        if ($growth.name -cne 'UserStorage_1' -or $growth.growthGiB -ne 32 -or $growth.minimumFreeGiB -ne 220 -or $growth.additionalOsDiskGiB -ne 200) { throw 'Selected bounded storage growth differs' }
        $cluster = Read-Cluster
        Assert-Healthy $cluster
        $storage = @(Read-UserStorage)
        $selected = @($storage | Where-Object name -CEQ $growth.name)
        if ($selected.Count -ne 1) { throw 'Selected existing user volume not uniquely found' }
        $volume = $selected[0]
        if ($volume.virtualDiskId -cne $growth.virtualDiskId -or $volume.diskId -cne $growth.virtualDiskId -or
            $volume.partitionGuid -ine $growth.partitionGuid -or $volume.volumeId -cne $growth.volumeId -or
            $volume.csvs.Count -ne 1 -or $volume.csvs[0].id -cne $growth.csvId -or $volume.csvs[0].state -cne 'Online' -or
            $volume.filesystem -cne 'CSVFS_ReFS' -or $volume.resiliency -cne 'Mirror' -or $volume.copies -ne 3 -or
            $volume.partitionStyle -cne 'GPT' -or $volume.tiers.Count -or $volume.health -cne 'Healthy') { throw 'Exact user virtual-disk/partition/CSV/ReFS/three-copy binding differs' }
        [long]$targetVirtual = $growth.originalVirtualSizeBytes + 32GB
        [long]$targetPartition = $growth.originalPartitionSizeBytes + 32GB
        if ($volume.virtualSizeBytes -notin @($growth.originalVirtualSizeBytes, $targetVirtual) -or
            $volume.partitionSizeBytes -notin @($growth.originalPartitionSizeBytes, $targetPartition)) { throw 'Storage sizes differ from the original bounded request' }
        if ($state.storageGrowth -and $state.storageGrowth.status -ceq 'complete' -and
            $volume.virtualSizeBytes -eq $targetVirtual -and $volume.partitionSizeBytes -eq $targetPartition) {
            @{ action = $Action; status = 'already-complete'; operationId = $state.id; growth = $state.storageGrowth;
               currentVolume = $volume; additionalNodeLogicalAdmission = ($volume.freeBytes -ge 220GB) } | ConvertTo-Json -Depth 30 -Compress
            return
        }
        if (-not $state.storageGrowth) {
            if ($volume.virtualSizeBytes -ne $growth.originalVirtualSizeBytes -or $volume.partitionSizeBytes -ne $growth.originalPartitionSizeBytes) { throw 'Existing growth is not bound to this original operation' }
            if ($volume.freeBytes + 32GB -lt 220GB) { throw 'Selected 32-GiB growth cannot leave 220 GiB free. No further growth authorised' }
            if (@($storage | Where-Object { $_.name -cne $growth.name -and $_.freeBytes -gt $volume.freeBytes }).Count) { throw 'Selected CSV is no longer largest free' }
            # Reserve the full three-copy growth AND full additional node OS footprint,
            # not just the current thin allocation, plus repair/metadata headroom.
            if ($cluster.pool.sizeBytes - $cluster.pool.allocatedBytes - (32GB + 200GB) * 3 -lt 526GB) { throw 'Physical mirror growth/OS/repair budget does not fit' }
            $state.storageGrowth = @{ id = ($state.id + '/userstorage1-grow32'); phase = 'admitted'; status = 'pending';
                startedAt = [datetime]::UtcNow.ToString('o'); before = $volume; clusterBefore = $cluster;
                targetVirtualBytes = $targetVirtual; targetPartitionBytes = $targetPartition }
            Save-State
        }
        $record = $state.storageGrowth
        if ($record -isnot [Collections.IDictionary]) {
            $copy = @{}; foreach ($property in $record.PSObject.Properties) { $copy[$property.Name] = $property.Value }; $record = $copy; $state.storageGrowth = $record
        }
        $session = Open-NodeSession $volume.csvs[0].owner
        try {
            if ($volume.virtualSizeBytes -eq $growth.originalVirtualSizeBytes) {
                if ($record.phase -cne 'admitted') { throw 'Original virtual-disk grow intent is unresolved. Inspect rather than repeat' }
                $record.phase = 'virtual-disk-grow-intent'; Save-State
                Invoke-Command -Session $session -ArgumentList $growth.virtualDiskId, $growth.originalVirtualSizeBytes, $targetVirtual -ScriptBlock {
                    param($id, $original, $target)
                    $disk = Get-VirtualDisk -UniqueId $id
                    if ($disk.Size -ne $original -or $disk.NumberOfDataCopies -ne 3 -or $disk.ResiliencySettingName -cne 'Mirror' -or $disk.HealthStatus.ToString() -cne 'Healthy' -or @($disk | Get-StorageTier).Count) { throw 'Virtual-disk binding changed immediately before grow' }
                    Resize-VirtualDisk -UniqueId $id -Size $target -Confirm:$false
                    if ((Get-VirtualDisk -UniqueId $id).Size -ne $target) { throw 'Virtual-disk growth not confirmed' }
                }
                $record.phase = 'virtual-disk-grown'; Save-State
            }
            $fresh = @(Read-UserStorage | Where-Object name -CEQ $growth.name)[0]
            if ($fresh.virtualSizeBytes -ne $targetVirtual) { throw 'Original virtual-disk target not observed' }
            if ($fresh.partitionSizeBytes -eq $growth.originalPartitionSizeBytes) {
                if ($record.phase -cnotin @('virtual-disk-grown', 'virtual-disk-grow-intent')) { throw 'Original partition grow intent is unresolved. Inspect rather than repeat' }
                if ($fresh.supportedMaximumBytes -lt $targetPartition -or $fresh.supportedMinimumBytes -gt $targetPartition) { throw 'Partition target outside native supported size. Retain grown virtual disk without further changes' }
                $record.phase = 'partition-grow-intent'; Save-State
                Invoke-Command -Session $session -ArgumentList $growth.virtualDiskId, $growth.partitionGuid, $growth.volumeId, $growth.originalPartitionSizeBytes, $targetPartition -ScriptBlock {
                    param($id, $guid, $volumeId, $original, $target)
                    $disk = Get-VirtualDisk -UniqueId $id | Get-Disk
                    $parts = @($disk | Get-Partition | Where-Object { $_.Guid -ieq $guid })
                    if ($parts.Count -ne 1 -or $parts[0].Size -ne $original -or ($parts[0] | Get-Volume).UniqueId -cne $volumeId) { throw 'Partition identity changed before grow' }
                    $supported = $parts[0] | Get-PartitionSupportedSize
                    if ($supported.SizeMax -lt $target -or $supported.SizeMin -gt $target) { throw 'Partition target unsupported' }
                    $parts[0] | Resize-Partition -Size $target -Confirm:$false
                }
                $record.phase = 'partition-grown'; Save-State
            }
        } finally { Remove-PSSession $session }
        $after = @(Read-UserStorage | Where-Object name -CEQ $growth.name)[0]
        $cluster = Read-Cluster
        Assert-Healthy $cluster
        if ($after.virtualSizeBytes -ne $targetVirtual -or $after.partitionSizeBytes -ne $targetPartition -or
            $after.freeBytes -lt 220GB -or $after.health -cne 'Healthy' -or $after.csvs[0].state -cne 'Online' -or
            $after.volumeId -cne $growth.volumeId -or $after.partitionGuid -ine $growth.partitionGuid -or
            $cluster.pool.sizeBytes - $cluster.pool.allocatedBytes - 200GB * 3 -lt 526GB) { throw 'Growth readback or retained OS/repair budget failed' }
        foreach ($old in $record.clusterBefore.virtualDisks) {
            $current = @($cluster.virtualDisks | Where-Object name -CEQ $old.name)
            if ($old.name -cne $growth.name -and ($current.Count -ne 1 -or $current[0].sizeBytes -ne $old.sizeBytes)) { throw 'Unselected virtual disk changed' }
        }
        $record.phase = 'verified'; $record.status = 'complete'; $record.after = $after; Save-State
        @{ action = $Action; operationId = $state.id; growth = $record; cluster = $cluster } | ConvertTo-Json -Depth 30 -Compress
        return
    }
    if ($Action -ceq 'Recover') {
        if (-not $state -or $state.nodeId -cne $capacity.nodeId) { throw 'No original operation to recover' }
        $result = Restore-Service
        $state.status = 'service-restored'; Save-State
        @{ action = $Action; operation = $state; result = $result } | ConvertTo-Json -Depth 30 -Compress
        return
    }
    $before = Read-Inventory
    Assert-Healthy $before.cluster
    if ($state) {
        if ($state.status -ceq 'complete' -and $before.profile.cpu -eq $capacity.cpu -and $before.profile.memoryBytes -eq $capacity.memoryGiB * 1GB) {
            @{ action = $Action; status = 'already-complete'; operation = $state; inventory = $before } | ConvertTo-Json -Depth 30 -Compress
            return
        }
        # A durable pre-maintenance record has no native intent yet. Resume only
        # this exact original operation, with its process gone and unchanged guest.
        $process = Get-Process -Id $state.processId -ErrorAction SilentlyContinue
        $unstarted = $Action -ceq 'Expand' -and $state.status -ceq 'admitted' -and $state.phase -ceq 'before-maintenance'
        $releasedContinuation = $Action -ceq 'Continue' -and $state.id -ceq $OriginalOperationId -and
            $state.status -ceq 'service-restored' -and $state.phase -ceq 'drain-intent' -and
            @($before.cluster.nodes | Where-Object { $_.state -cne 'Up' -or $_.drainStatus -cne 'NotInitiated' }).Count -eq 0 -and
            @($before.cluster.groups | Where-Object { $_.state -cne 'Online' -and $_.name -cne 'Available Storage' }).Count -eq 0
        if ((-not $unstarted -and -not $releasedContinuation) -or
            ($process -and $process.StartTime.ToUniversalTime().ToString('o') -ceq $state.processStartedAt) -or
            -not (Same-Preserved $before.profile.preserved $state.before.profile.preserved)) {
            throw 'Original capacity operation requires inspection/recovery, not a repeat'
        }
    } elseif ($Action -ceq 'Continue') {
        throw 'No original operation to continue'
    }
    if ($before.profile.cpu -ne 8 -or $before.profile.memoryBytes -ne 64GB -or $before.profile.state -cne 'Running' -or $before.profile.dynamicMemory) { throw 'Unexpected original NODE03 profile' }
    if (@($before.nested | Where-Object node -CEQ $capacity.nodeName | ForEach-Object vms).Count) { throw 'NODE03 is occupied. No VM shutdown or unbound migration is authorised' }
    $allNested = @($before.nested | ForEach-Object vms)
    # The peer-owned SMB VM may be provisioning on a surviving node. Its observed
    # identity is admission-only, never authority to start, stop, move or configure it.
    $smb = @($allNested | Where-Object id -CEQ $capacity.observedSmbVmId)
    if ($smb.Count -gt 1 -or @($smb | Where-Object { $_.name -cne 'smal-smb01' -or $_.cpu -ne 4 -or $_.memoryBytes -ne 8GB }).Count) { throw 'Observed peer SMB identity/profile differs' }
    $knownNested = @($allNested | Where-Object id -CNE $capacity.observedSmbVmId)
    if ($knownNested.Count -ne $capacity.knownNestedVmIds.Count -or @($knownNested | Where-Object { $_.id -cnotin $capacity.knownNestedVmIds -or $_.state -cne 'Running' }).Count) { throw 'Unknown, missing or stopped nested VM' }
    if (@($before.nested | Where-Object build -LT 20348).Count) { throw 'This operation requires automatic S2D maintenance on Server 2022/HCI 21H2 or later' }
    if ($before.outerVms.Count -ne 4 -or @($before.outerVms | Where-Object { $_.id -cnotin @($config.guestIds.PSObject.Properties.Value) -or $_.state -cne 'Running' }).Count) { throw 'Unknown or unavailable outer guest' }
    foreach ($expected in @(@{ name = 'LB-NODE01'; cpu = 8; memory = 64GB }, @{ name = 'LB-NODE02'; cpu = 20; memory = 96GB })) {
        $actual = @($before.outerVms | Where-Object name -CEQ $expected.name)
        if ($actual.Count -ne 1 -or $actual[0].cpu -ne $expected.cpu -or $actual[0].memoryBytes -ne $expected.memory) { throw 'Unselected peer profile changed' }
    }
    # Windows PowerShell 5.1 Measure-Object does not project local hashtable keys.
    [long]$afterCpu = -$before.profile.cpu + $capacity.cpu
    [long]$afterMemory = -$before.profile.memoryBytes + $capacity.memoryGiB * 1GB
    foreach ($outerVm in $before.outerVms) { $afterCpu += $outerVm.cpu; $afterMemory += $outerVm.memoryBytes }
    if ($before.outerCpu -ne 64 -or $before.outerCpu - $afterCpu -lt $capacity.outerCpuReserve -or
        $before.outerMemoryBytes - $afterMemory -lt $capacity.outerMemoryReserveGiB * 1GB -or
        $before.outerFreeMemoryBytes - ($capacity.memoryGiB * 1GB - $before.profile.memoryBytes) -lt $capacity.outerMemoryReserveGiB * 1GB) { throw 'Insufficient outer host CPU/memory headroom' }
    if ($before.cluster.pool.sizeBytes - $before.cluster.pool.allocatedBytes -lt ($capacity.physicalRepairReserveGiB + $capacity.physicalMetadataReserveGiB) * 1GB) { throw 'Physical storage repair reserve does not fit' }
    if (-not (Test-Path $root)) { $null = New-Item $root -ItemType Directory; Set-Acl $root (Get-Acl $config.credentialDirectory) }
    if (-not $state) {
        $state = @{ id = [guid]::NewGuid().ToString(); nodeId = $capacity.nodeId; status = 'admitted'; phase = 'before-maintenance';
                    processId = $PID; processStartedAt = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');
                    startedAt = [datetime]::UtcNow.ToString('o'); updatedAt = $null; before = $before }
    } else {
        $state.history = @($state.history) + @(@{ status = $state.status; phase = $state.phase; failure = $state.failure;
            recoveryFailure = $state.recoveryFailure; resumedAt = [datetime]::UtcNow.ToString('o') })
        $state.processId = $PID
        $state.processStartedAt = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    }
    Save-State
    try {
        $state.phase = 'csv-transfer-intent'; Save-State
        Invoke-Command -Session $peer -ScriptBlock {
            Get-ClusterSharedVolume | Where-Object { $_.OwnerNode.Name -ieq 'LB-NODE03' } | ForEach-Object { Move-ClusterSharedVolume -Name $_.Name -Node LB-NODE02 | Out-Null }
        }
        $state.phase = 'drain-intent'; Save-State
        Invoke-Command -Session $peer -ScriptBlock {
            Suspend-ClusterNode -Name LB-NODE03 -Drain | Out-Null
            $timer = [Diagnostics.Stopwatch]::StartNew()
            do {
                $node = Get-ClusterNode -Name LB-NODE03
                if ($node.DrainStatus.ToString() -cin @('Completed', 'Failed')) { break }
                if ($timer.Elapsed.TotalSeconds -ge 600) { throw 'Original cluster drain has not settled' }
                Start-Sleep 5
            } while ($true)
            if ($node.State.ToString() -cne 'Paused' -or $node.DrainStatus.ToString() -cne 'Completed') { throw 'Node drain incomplete' }
            if (@(Get-ClusterSharedVolume | Where-Object { $_.State.ToString() -cne 'Online' -or $_.OwnerNode.Name -ieq 'LB-NODE03' }).Count) { throw 'CSV transfer/health failed' }
        }
        $session = Open-NodeSession $capacity.nodeName
        try {
            Invoke-Command -Session $session -ScriptBlock { if (@(Get-VM).Count) { throw 'NODE03 became occupied during admission' } }
        } finally { Remove-PSSession $session }
        $state.phase = 'graceful-shutdown-intent'; Save-State
        Stop-VM -VM (Get-VM -Id $capacity.nodeId) -Confirm:$false
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ((Get-VM -Id $capacity.nodeId).State.ToString() -cne 'Off') {
            if ($timer.Elapsed.TotalSeconds -gt 180) { throw 'Graceful shutdown not completed. No forced shutdown permitted' }
            Start-Sleep 5
        }
        $state.phase = 'profile-change-intent'; Save-State
        try {
            Set-VMProcessor -VM (Get-VM -Id $capacity.nodeId) -Count $capacity.cpu
            Set-VMMemory -VM (Get-VM -Id $capacity.nodeId) -StartupBytes ($capacity.memoryGiB * 1GB)
            $profile = Read-Profile
            if ($profile.cpu -ne $capacity.cpu -or $profile.memoryBytes -ne $capacity.memoryGiB * 1GB -or -not (Same-Preserved $profile.preserved $before.profile.preserved)) { throw 'Selected profile readback differs' }
        } catch {
            Set-VMProcessor -VM (Get-VM -Id $capacity.nodeId) -Count $before.profile.cpu
            Set-VMMemory -VM (Get-VM -Id $capacity.nodeId) -StartupBytes $before.profile.memoryBytes
            throw
        }
        $state.phase = 'return-to-service'; Save-State
        $result = Restore-Service
        $state.phase = 'verified'; $state.status = 'complete'; Save-State
        @{ action = $Action; operation = $state; result = $result; observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 30 -Compress
    } catch {
        $original = $_
        $state.status = 'failed'; $state.failure = $original.Exception.Message; Save-State
        try { $state.recovery = Restore-Service; $state.status = 'failed-service-restored'; Save-State }
        catch { $state.recoveryFailure = $_.Exception.Message; Save-State }
        throw $original
    }
} finally {
    if ($peer) { Remove-PSSession $peer }
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
