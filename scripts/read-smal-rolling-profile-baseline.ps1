# Fixed GET-only initial rolling-profile baseline. No execution approval or effects.
$ErrorActionPreference = 'Stop'
$ComputeCapacityLibraryOnly = $true
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Wrong outer host' }
$readDeadline = [DateTimeOffset]::Parse('2026-11-10T15:00:00+02:00')
if ([DateTimeOffset](Get-Date) -ge $readDeadline) { throw 'Fixed baseline read window closed' }
$commonSourceSha256 = '0e58f64f888c897a48b1d4f28bd6faec22346e9d8f1c36e4c92da29f0a2b6b86'
$hash = [Security.Cryptography.SHA256]::Create()
try { $readerSourceSha256 = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($MyInvocation.MyCommand.ScriptBlock.ToString()))).Replace('-', '').ToLowerInvariant() } finally { $hash.Dispose() }
$rootPresence = @('C:\ProgramData\AzureLocalBox\ComputeCapacity-20261108-01', 'C:\ProgramData\AzureLocalBox\ComputeCapacity-R2-20261108-01', 'C:\ProgramData\AzureLocalBox\FoundationProfile-20261109-01') | ForEach-Object { @{ path = $_; present = (Test-Path -LiteralPath $_ -ErrorAction Stop) } }
if (@($rootPresence | Where-Object present -EQ $true).Count -gt 0) {
    @{ status = 'blocked-retained-root-present'; mutationPerformed = $false; atUtc = (Get-Date).ToUniversalTime().ToString('o'); commonSourceSha256 = $commonSourceSha256; readerSourceSha256 = $readerSourceSha256; rootPresence = @($rootPresence) } | ConvertTo-Json -Depth 40 -Compress
    return
}
if ([DateTimeOffset](Get-Date) -ge $readDeadline) { throw 'Fixed baseline read window closed' }
$plan = [pscustomobject]@{
    guestIds = [pscustomobject]@{
        'LB-DC01' = 'f94c71f1-6854-48b9-a9f1-8238c99366d0'
        'LB-NODE01' = '3adff629-2f67-449b-ab32-8a8748c46f34'
        'LB-NODE02' = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3'
        'LB-NODE03' = '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9'
    }
    transitionContract = [pscustomobject]@{ deviceOwners = [pscustomobject]@{} }
}
$entry = $null

# Template only. Rendered stages contain the exact sealed public plan and this source.
# Existing protected secret/guardian material is referenced in place, never exported.
function Assert-Compute([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function Get-ComputeKeys($value) {
    if ($value -is [Collections.IDictionary]) { return @($value.Keys | Sort-Object) }
    return @($value.PSObject.Properties.Name | Sort-Object)
}
function Get-ComputeField($value, [string]$key) {
    if ($value -is [Collections.IDictionary]) { return $value[$key] }
    return $value.PSObject.Properties[$key].Value
}
function Assert-ComputeEqual($actual, $expected, [string]$label) {
    if ($null -eq $actual -or $null -eq $expected) {
        Assert-Compute (($null -eq $actual) -and ($null -eq $expected)) $label
        return
    }
    $aObject = ($actual -is [Collections.IDictionary] -or $actual -is [pscustomobject])
    $eObject = ($expected -is [Collections.IDictionary] -or $expected -is [pscustomobject])
    if ($aObject -or $eObject) {
        Assert-Compute ($aObject -and $eObject) $label
        $aKeys = @(Get-ComputeKeys $actual); $eKeys = @(Get-ComputeKeys $expected)
        Assert-Compute (($aKeys -join '|') -ceq ($eKeys -join '|')) $label
        foreach ($key in $aKeys) { Assert-ComputeEqual (Get-ComputeField $actual $key) (Get-ComputeField $expected $key) ($label + '.' + $key) }
    } elseif ($actual -is [array] -or $expected -is [array]) {
        Assert-Compute (($actual -is [array]) -and ($expected -is [array]) -and $actual.Count -eq $expected.Count) $label
        for ($i = 0; $i -lt $actual.Count; $i++) { Assert-ComputeEqual $actual[$i] $expected[$i] ($label + '[' + $i + ']') }
    } else {
        Assert-Compute ([string]$actual -ceq [string]$expected) $label
    }
}
function Read-ComputeGuestStatic($vm) {
    $processor = Get-VMProcessor -VM $vm
    $memory = Get-VMMemory -VM $vm
    $security = Get-VMSecurity -VM $vm
    $firmware = Get-VMFirmware -VM $vm
    # Hash the existing encrypted protector. Never return protector or certificate bytes.
    $protector = Get-VMKeyProtector -VM $vm
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $protectorHash = if ($protector) { [BitConverter]::ToString($hash.ComputeHash([byte[]]$protector)).Replace('-', '') } else { 'absent' } }
    finally { $hash.Dispose(); $protector = $null }
    return @{
        name = $vm.Name; id = $vm.Id.ToString(); cpu = $vm.ProcessorCount; memory = $vm.MemoryStartup
        dynamicMemory = $memory.DynamicMemoryEnabled; generation = $vm.Generation; version = $vm.Version.ToString()
        path = $vm.Path; configurationLocation = $vm.ConfigurationLocation; snapshotLocation = $vm.SnapshotFileLocation
        smartPagingLocation = $vm.SmartPagingFilePath; checkpointType = $vm.CheckpointType.ToString()
        automaticStart = $vm.AutomaticStartAction.ToString(); automaticStop = $vm.AutomaticStopAction.ToString()
        secureBoot = $firmware.SecureBoot.ToString(); tpm = $security.TpmEnabled; protectorHash = $protectorHash
        memorySettings = @{ minimum = $memory.Minimum; maximum = $memory.Maximum; buffer = $memory.Buffer; priority = $memory.Priority; maximumNumaMemory = $memory.MaximumPerNumaNode }
        processorSettings = @{ nested = $processor.ExposeVirtualizationExtensions; reserve = $processor.Reserve; maximum = $processor.Maximum
            weight = $processor.RelativeWeight; compatibilityMigration = $processor.CompatibilityForMigrationEnabled
            compatibilityOlderOs = $processor.CompatibilityForOlderOperatingSystemsEnabled
            maximumNumaProcessors = $processor.MaximumCountPerNumaNode; maximumNumaSockets = $processor.MaximumCountPerNumaSocket; hardwareThreadsPerCore = $processor.HwThreadCountPerCore }
        disks = @(Get-VMHardDiskDrive -VM $vm | Sort-Object ControllerNumber, ControllerLocation | ForEach-Object {
            $vhd = Get-VHD -Path $_.Path
            @{ path = $_.Path; controllerType = $_.ControllerType.ToString(); controllerNumber = $_.ControllerNumber
               controllerLocation = $_.ControllerLocation; id = $vhd.DiskIdentifier.ToString(); size = $vhd.Size
               vhdType = $vhd.VhdType.ToString(); parentPath = $vhd.ParentPath; blockSize = $vhd.BlockSize
               logicalSectorSize = $vhd.LogicalSectorSize; physicalSectorSize = $vhd.PhysicalSectorSize }
        })
        nics = @(Get-VMNetworkAdapter -VM $vm | Sort-Object Name | ForEach-Object {
            $vlan = $_ | Get-VMNetworkAdapterVlan
            @{ name = $_.Name; id = $_.Id; switchId = $_.SwitchId.ToString(); mac = $_.MacAddress
               dynamicMac = $_.DynamicMacAddressEnabled; spoofing = $_.MacAddressSpoofing.ToString()
               teaming = $_.AllowTeaming.ToString(); vlan = @{ mode = $vlan.OperationMode.ToString(); native = $vlan.NativeVlanId; allowed = $vlan.AllowedVlanIdList } }
        })
    }
}
function New-ComputeSession([string]$name) {
    $id = $plan.guestIds.PSObject.Properties[$name].Value
    $vm = Get-VM -Id $id
    Assert-Compute ($vm.Name -ceq $name -and $vm.State.ToString() -ceq 'Running') 'Exact Running node required'
    $boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
    $bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
    $entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
    $helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
    Assert-Compute ($entry.Count -eq 1 -and (Get-FileHash $helper).Hash -ceq $entry[0].sha256) 'Existing secret helper differs'
    . $helper
    $store = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'
    $bindings = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw | ConvertFrom-Json
    $binding = $bindings.nodes.PSObject.Properties[$name].Value
    Assert-Compute ($binding.vmId -ieq $id -and $binding.role -ceq 'cluster-node-admin' -and $binding.secretDirectory -ceq $store -and $binding.loginVerified -eq $true) 'Existing credential binding differs'
    $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'
    try {
        # Exactly one authentication attempt. No old account-name fallback.
        return New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($name + '\ASBuiltInAdmin'), $secure)) -ErrorAction Stop
    } finally { $secure.Dispose() }
}
function Read-ComputeSnapshot([bool]$readCluster = $true) {
    Assert-Compute ($env:COMPUTERNAME -ceq 'LocalBox-Client') 'Wrong outer host'
    $vms = @(Get-VM | Sort-Object Name)
    Assert-Compute ($vms.Count -eq 4) 'Unexpected VM count, no blanket shutdown'
    foreach ($vm in $vms) { Assert-Compute ($plan.guestIds.PSObject.Properties[$vm.Name].Value -ieq $vm.Id.ToString()) 'Guest identity mismatch' }
    $guests = @($vms | ForEach-Object { Read-ComputeGuestStatic $_ })
    $states = @{}; foreach ($vm in $vms) { $states[$vm.Name] = $vm.State.ToString() }
    $volumes = @(Get-Volume | Where-Object DriveLetter -In @('C', 'V', 'W', 'X') | Sort-Object DriveLetter | ForEach-Object {
        @{ letter = [string]$_.DriveLetter; uniqueId = $_.UniqueId; size = $_.Size; free = $_.SizeRemaining; health = $_.HealthStatus.ToString() }
    })
    Assert-Compute ($volumes.Count -eq 4) 'Four exact outer volumes required'
    $system = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = @(Get-CimInstance Win32_Processor)
    $hostCapacity = @{ logicalProcessors = (Get-VMHost).LogicalProcessorCount; physicalCores = ($cpu | Measure-Object NumberOfCores -Sum).Sum
        memoryBytes = $system.TotalPhysicalMemory; freeMemoryBytes = $os.FreePhysicalMemory * 1KB
        numa = @(Get-VMHostNumaNode | Sort-Object NodeId | ForEach-Object { @{ nodeId = $_.NodeId; logicalProcessors = @($_.ProcessorsAvailability).Count; memoryBytes = [long]$_.MemoryTotal * 1MB; processorAvailabilityPercent = @($_.ProcessorsAvailability) } }) }
    $hostStatic = @{
        outerPools = @(Get-StoragePool | Where-Object IsPrimordial -EQ $false | Sort-Object UniqueId | ForEach-Object {
            @{ id = $_.UniqueId; size = $_.Size; members = @($_ | Get-PhysicalDisk | Sort-Object UniqueId | ForEach-Object { @{ id = $_.UniqueId; size = $_.Size } }) }
        })
        switches = @(Get-VMSwitch | Sort-Object Id | ForEach-Object { @{ name = $_.Name; id = $_.Id.ToString(); type = $_.SwitchType.ToString() } })
        nat = @(Get-NetNat | Sort-Object Name | ForEach-Object { @{ name = $_.Name; prefix = $_.InternalIPInterfaceAddressPrefix } })
    }
    $snapshot = @{ atUtc = [datetime]::UtcNow.ToString('o'); mutationPerformed = $false
        hostStatic = $hostStatic; hostCapacity = $hostCapacity; guestsStatic = $guests; states = $states; volumes = $volumes
        volumesStatic = @($volumes | ForEach-Object { @{ letter = $_.letter; uniqueId = $_.uniqueId; size = $_.size } })
        clusterStatic = $null; clusterHealth = $null; nodeCapacity = @{} }
    if ($readCluster) {
        $running = @($vms | Where-Object { $_.Name -cne 'LB-DC01' -and $_.State.ToString() -ceq 'Running' })
        Assert-Compute ($running.Count -ge 2) 'Two surviving nodes required for cluster observation'
        $session = New-ComputeSession $running[0].Name
        try {
            $selectedNode = if ($entry) { $entry.node } else { $null }
            $selectedOff = ($selectedNode -and $states[$selectedNode] -ceq 'Off')
            $drainEvidence = $null
            if ($selectedNode -and (Test-Path ('C:\ProgramData\AzureLocalBox\FoundationProfile-20261109-01\drain-proof-' + $selectedNode + '.json'))) {
                $drainEvidence = Get-Content ('C:\ProgramData\AzureLocalBox\FoundationProfile-20261109-01\drain-proof-' + $selectedNode + '.json') -Raw | ConvertFrom-Json
            }
            $cluster = Invoke-Command -Session $session -ArgumentList $plan.transitionContract.deviceOwners, $selectedNode, $selectedOff, $drainEvidence -ErrorAction Stop -ScriptBlock {
                param($FrozenOwners, $SelectedNode, $SelectedOff, $DrainEvidence)
                $admin = Get-LocalUser -Name ASBuiltInAdmin
                if (-not $admin.Enabled -or -not $admin.SID.Value.EndsWith('-500') -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $admin.SID.Value) { throw 'RID 500 binding differs' }
                $c = Get-Cluster -Name smal-localbox01 -ErrorAction Stop
                $q = Get-ClusterQuorum -Cluster $c
                $pools = @(Get-StoragePool | Where-Object IsPrimordial -EQ $false)
                if ($pools.Count -ne 1) { throw 'One deployed pool required' }
                $pool = $pools[0]; $csv = @(Get-ClusterSharedVolume -Cluster $c); $vd = @(Get-VirtualDisk)
                $members = @($pool | Get-PhysicalDisk)
                $ownerMap = @{}
                foreach ($storageNode in @(Get-StorageNode)) {
                    $ownerName = ([string]$storageNode.Name).Split('.')[0].ToUpperInvariant()
                    if ($ownerName -cnotin @('LB-NODE01', 'LB-NODE02', 'LB-NODE03')) { continue }
                    foreach ($device in @(Get-PhysicalDisk -StorageNode $storageNode -PhysicallyConnected)) {
                        if ($device.UniqueId -notin @($members.UniqueId)) { continue }
                        if ($ownerMap.ContainsKey($device.UniqueId)) { throw 'Ambiguous physical-device ownership' }
                        $ownerMap[$device.UniqueId] = $ownerName
                    }
                }
                if ($ownerMap.Count -ne 24) {
                    # The selected OFF node may be absent from live physically-connected
                    # enumeration. Only its exact eight previously proven devices may use
                    # the sealed pre-off owner map, after settled verified maintenance.
                    $missing = @($members | Where-Object { -not $ownerMap.ContainsKey($_.UniqueId) })
                    if (-not $SelectedOff -or $missing.Count -ne 8 -or $DrainEvidence.selectedNode -cne $SelectedNode -or $DrainEvidence.rpcReturned -ne $true -or $DrainEvidence.eightDevicesMaintenanceVerified -ne $true) { throw 'Complete device owner evidence unproved' }
                    foreach ($device in $missing) {
                        if ($FrozenOwners.PSObject.Properties[$device.UniqueId].Value -cne $SelectedNode -or $device.UniqueId -cnotin $DrainEvidence.deviceIds) { throw 'Missing device is not owned selected-node maintenance' }
                        $ownerMap[$device.UniqueId] = $SelectedNode
                    }
                }
                $nodes = @(Get-ClusterNode -Cluster $c)
                @{ static = @{ name = $c.Name; poolId = $pool.UniqueId; poolSize = $pool.Size
                        members = @($members | Sort-Object UniqueId | ForEach-Object { @{ id = $_.UniqueId; size = $_.Size } })
                        virtualDisks = @($vd | Sort-Object UniqueId | ForEach-Object { @{ id = $_.UniqueId; size = $_.Size; copies = $_.NumberOfDataCopies; resiliency = $_.ResiliencySettingName } })
                        csv = @($csv | Sort-Object Name | ForEach-Object { @{ name = $_.Name; id = $_.Id.ToString(); volumes = @($_.SharedVolumeInfo | ForEach-Object { @{ path = $_.FriendlyVolumeName; size = $_.Partition.Size } }) } }) }
                   health = @{ allNodesUp = @($nodes | Where-Object State -NE Up).Count -eq 0
                        nodeStates = @($nodes | Sort-Object Name | ForEach-Object { @{ name = $_.Name; state = $_.State.ToString() } })
                        allCsvOnline = $csv.Count -eq 4 -and @($csv | Where-Object State -NE Online).Count -eq 0
                        allMirrorsHealthy = $vd.Count -eq 5 -and @($vd | Where-Object { $_.HealthStatus.ToString() -cne 'Healthy' -or $_.NumberOfDataCopies -ne 3 -or (@($_.OperationalStatus | ForEach-Object ToString) -join '|') -cne 'OK' }).Count -eq 0
                        poolHealthy = $pool.HealthStatus.ToString() -ceq 'Healthy' -and (@($pool.OperationalStatus | ForEach-Object ToString) -join '|') -ceq 'OK' -and $members.Count -eq 24 -and @($members | Where-Object { $_.HealthStatus.ToString() -cne 'Healthy' -or (@($_.OperationalStatus | ForEach-Object ToString) -join '|') -cne 'OK' }).Count -eq 0
                        poolHealth = $pool.HealthStatus.ToString(); poolOperational = @($pool.OperationalStatus | ForEach-Object ToString)
                        devices = @($members | Sort-Object UniqueId | ForEach-Object { $ops = @($_.OperationalStatus | ForEach-Object ToString); @{ id = $_.UniqueId; owner = $ownerMap[$_.UniqueId]; health = $_.HealthStatus.ToString(); operational = $ops; maintenance = @($ops | Where-Object { $_ -cin @('In Maintenance Mode', 'InMaintenanceMode', 'Starting Maintenance Mode', 'StartingMaintenanceMode') }).Count -gt 0 } })
                        virtualDiskStates = @($vd | Sort-Object UniqueId | ForEach-Object { @{ id = $_.UniqueId; health = $_.HealthStatus.ToString(); operational = @($_.OperationalStatus | ForEach-Object ToString); copies = $_.NumberOfDataCopies } })
                        csvStates = @($csv | Sort-Object Name | ForEach-Object { @{ id = $_.Id.ToString(); state = $_.State.ToString(); accessible = @($_.SharedVolumeInfo | Where-Object { -not (Test-Path -LiteralPath $_.FriendlyVolumeName) }).Count -eq 0 } })
                        unrelatedFailures = @()
                        quorumType = $q.QuorumType.ToString(); witness = $(if ($q.QuorumResource) { $q.QuorumResource.Name } else { $null })
                        activeStorageJobs = @(Get-StorageJob | Where-Object JobState -NE Completed | ForEach-Object {
                            $job = $_
                            $affectedVd = @(Get-CimAssociatedInstance -InputObject $job -ResultClassName MSFT_VirtualDisk -ErrorAction Stop)
                            $affectedPd = @(Get-CimAssociatedInstance -InputObject $job -ResultClassName MSFT_PhysicalDisk -ErrorAction Stop)
                            $affectedPool = @(Get-CimAssociatedInstance -InputObject $job -ResultClassName MSFT_StoragePool -ErrorAction Stop)
                            @{ name = $job.Name; state = [string]$job.JobState
                               poolId = $(if ($affectedPool.Count -eq 1) { $affectedPool[0].UniqueId } else { $null })
                               affectedVirtualDiskIds = @($affectedVd.UniqueId); affectedDeviceIds = @($affectedPd.UniqueId) }
                        })
                        physicalFreeBytes = $pool.Size - $pool.AllocatedSize }
                }
            }
            $snapshot.clusterStatic = $cluster.static; $snapshot.clusterHealth = $cluster.health
        } finally { Remove-PSSession $session }
        $nested = @()
        foreach ($node in $running) {
            $session = New-ComputeSession $node.Name
            try {
                $capacity = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                    $hostInfo = Get-VMHost; $systemInfo = Get-CimInstance Win32_ComputerSystem; $osInfo = Get-CimInstance Win32_OperatingSystem
                    @{ logicalProcessors = $hostInfo.LogicalProcessorCount; memoryBytes = $systemInfo.TotalPhysicalMemory
                       freeMemoryBytes = $osInfo.FreePhysicalMemory * 1KB
                       cpuUtilisationPercent = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor | Where-Object Name -EQ '_Total').PercentProcessorTime
                       numa = @(Get-VMHostNumaNode | Sort-Object NodeId | ForEach-Object { @{ nodeId = $_.NodeId; logicalProcessors = @($_.ProcessorsAvailability).Count; memoryBytes = [long]$_.MemoryTotal * 1MB; processorAvailabilityPercent = @($_.ProcessorsAvailability) } })
                       network = @{ switches = @(Get-VMSwitch | Sort-Object Name | ForEach-Object { @{ name = $_.Name; id = $_.Id.ToString(); type = $_.SwitchType.ToString() } })
                           adapters = @(Get-NetAdapter | Sort-Object InterfaceIndex | Select-Object InterfaceIndex, Name, Status, MacAddress, InterfaceDescription, LinkSpeed)
                           ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Sort-Object InterfaceIndex, IPAddress | Select-Object InterfaceIndex, InterfaceAlias, IPAddress, PrefixLength, AddressState)
                           routes = @(Get-NetRoute -AddressFamily IPv4 | Sort-Object InterfaceIndex, DestinationPrefix | Select-Object InterfaceIndex, DestinationPrefix, NextHop, RouteMetric)
                           neighbors = @(Get-NetNeighbor -AddressFamily IPv4 | Sort-Object InterfaceIndex, IPAddress | Select-Object InterfaceIndex, IPAddress, LinkLayerAddress, State)
                           dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object InterfaceIndex, ServerAddresses)
                           adapterVlans = @(Get-VMNetworkAdapter -ManagementOS | ForEach-Object { $v = $_ | Get-VMNetworkAdapterVlan; @{ name = $_.Name; switchName = $_.SwitchName; mode = $v.OperationMode.ToString(); accessVlanId = $v.AccessVlanId; nativeVlanId = $v.NativeVlanId } }) }
                       nestedVms = @(Get-VM | Sort-Object Id | ForEach-Object {
                           $vm = $_; $p = Get-VMProcessor -VM $vm; $m = Get-VMMemory -VM $vm
                           @{ id = $vm.Id.ToString(); name = $vm.Name; cpu = $vm.ProcessorCount; memory = $vm.MemoryStartup
                              generation = $vm.Generation; version = $vm.Version.ToString(); path = $vm.Path
                              configurationLocation = $vm.ConfigurationLocation; automaticStart = $vm.AutomaticStartAction.ToString(); automaticStop = $vm.AutomaticStopAction.ToString()
                              processor = @{ nested = $p.ExposeVirtualizationExtensions; reserve = $p.Reserve; maximum = $p.Maximum; weight = $p.RelativeWeight }
                              dynamicMemory = $m.DynamicMemoryEnabled
                              disks = @(Get-VMHardDiskDrive -VM $vm | Sort-Object ControllerNumber, ControllerLocation | ForEach-Object { $d = Get-VHD -Path $_.Path; @{ path = $_.Path; id = $d.DiskIdentifier.ToString(); size = $d.Size; controller = $_.ControllerNumber; lun = $_.ControllerLocation } })
                              adapters = @(Get-VMNetworkAdapter -VM $vm | Sort-Object Name | ForEach-Object { $v = $_ | Get-VMNetworkAdapterVlan; @{ name = $_.Name; mac = $_.MacAddress; switchName = $_.SwitchName; dynamicMac = $_.DynamicMacAddressEnabled; vlan = $v.OperationMode.ToString(); accessVlanId = $v.AccessVlanId; nativeVlanId = $v.NativeVlanId } }) }
                       })
                       bridgePlacement = @(Get-VM | ForEach-Object { @{ id = $_.Id.ToString(); state = $_.State.ToString(); hciNode = $env:COMPUTERNAME } }) }
                }
                $nested += @($capacity.nestedVms)
                $snapshot.nodeCapacity[$node.Name] = $capacity
            } finally { Remove-PSSession $session }
        }
        # Existing resource-bridge VMs are admitted by identity, never treated as new workload authority.
        $snapshot.clusterStatic.nestedVms = @($nested | Sort-Object id)
        Assert-Compute ($nested.Count -eq 1 -and $nested[0].id -ieq '4c6ca5cc-8c9a-499b-8ffe-c029bbfd3522') 'Unlisted nested VM or missing infrastructure identity'
    }
    return $snapshot
}

function Read-ComputeDcNetwork {
    $dc = Get-VM -Id 'f94c71f1-6854-48b9-a9f1-8238c99366d0'
    Assert-Compute ($dc.Name -ceq 'LB-DC01' -and $dc.State.ToString() -ceq 'Running') 'Exact Running DC required'
    $boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
    $old = Get-Content (Join-Path $boot 'state.json') -Raw | ConvertFrom-Json
    Assert-Compute ($old.status -ceq 'local-bootstrap-configured-and-checked' -and $old.newCredentialLoginVerified.'LB-DC01' -eq $true) 'Existing DC credential login proof differs'
    $bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
    $entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
    $helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
    Assert-Compute ($entry.Count -eq 1 -and (Get-FileHash $helper).Hash -ceq $entry[0].sha256) 'Existing DC secret helper differs'
    . $helper
    $secure = Read-LabGuestSecureSecret -SecretDirectory 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01\secrets' -Role 'dc-admin'
    $session = $null
    try {
        $session = New-PSSession -VMId $dc.Id -Credential ([pscredential]::new('LOCALBOX\Administrator', $secure)) -ErrorAction Stop
        return Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            if ($env:COMPUTERNAME -cne 'LB-DC01' -or -not [Security.Principal.WindowsIdentity]::GetCurrent().User.Value.EndsWith('-500')) { throw 'Exact DC RID 500 identity differs' }
            if ((Get-ADDomain).DNSRoot -cne 'ad.localbox.test') { throw 'DC domain differs' }
            $dhcp = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
            $result = @{ ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceIndex, InterfaceAlias, IPAddress, PrefixLength)
                neighbors = @(Get-NetNeighbor -AddressFamily IPv4 | Select-Object InterfaceIndex, IPAddress, LinkLayerAddress, State)
                dnsA = @(Get-DnsServerResourceRecord -ZoneName ad.localbox.test -RRType A -ErrorAction Stop | ForEach-Object { @{ name = $_.HostName; address = $_.RecordData.IPv4Address.IPAddressToString } })
                dhcpInstalled = $null -ne $dhcp; dhcpScopes = @(); dhcpLeases = @(); dhcpReservations = @()
                probeLimitations = 'No ICMP response or absent neighbor does not prove an address unused. Reconcile with authoritative allocation ownership.' }
            if ($dhcp) {
                $scopes = @(Get-DhcpServerv4Scope -ErrorAction Stop)
                $result.dhcpScopes = @($scopes | Select-Object ScopeId, StartRange, EndRange, State)
                $result.dhcpLeases = @($scopes | ForEach-Object { Get-DhcpServerv4Lease -ScopeId $_.ScopeId -ErrorAction Stop } | Select-Object IPAddress, AddressState, ClientId)
                $result.dhcpReservations = @($scopes | ForEach-Object { Get-DhcpServerv4Reservation -ScopeId $_.ScopeId -ErrorAction Stop } | Select-Object IPAddress, ClientId)
            }
            # Bounded parallel echo probes. No address allocation, neighbour flushing or network repair.
            $targets = @((100..180) + (200..209) + (1, 10, 11, 12, 13) | ForEach-Object { '10.64.0.' + $_ })
            $probes = @($targets | ForEach-Object { $ping = [Net.NetworkInformation.Ping]::new(); @{ address = $_; ping = $ping; task = $ping.SendPingAsync($_, 500) } })
            try {
                [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($probes.task), 3000) | Out-Null
                $result.echo = @($probes | ForEach-Object { @{ address = $_.address; completed = $_.task.IsCompleted; status = $(if ($_.task.Status.ToString() -ceq 'RanToCompletion') { $_.task.Result.Status.ToString() } else { 'Unknown' }) } })
            } finally { foreach ($probe in $probes) { $probe.ping.Dispose() } }
            $result.neighborsAfter = @(Get-NetNeighbor -AddressFamily IPv4 | Select-Object InterfaceIndex, IPAddress, LinkLayerAddress, State)
            return $result
        }
    } finally { if ($session) { Remove-PSSession $session }; $secure.Dispose() }
}

# Direct use through the existing canonical transport is read-only inventory only.
# Rendered mutation stages set LibraryOnly before including these function definitions.
if ($ComputeCapacityLibraryOnly -ne $true) {
    $plan = [pscustomobject]@{ guestIds = [pscustomobject]@{
        'LB-DC01' = 'f94c71f1-6854-48b9-a9f1-8238c99366d0'
        'LB-NODE01' = '3adff629-2f67-449b-ab32-8a8748c46f34'
        'LB-NODE02' = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3'
        'LB-NODE03' = '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9'
    } }
    $ErrorActionPreference = 'Stop'
    try {
        $snapshot = Read-ComputeSnapshot $false
        $snapshot.outerNetwork = @{
            ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Sort-Object InterfaceIndex, IPAddress | Select-Object InterfaceIndex, InterfaceAlias, IPAddress, PrefixLength, AddressState)
            routes = @(Get-NetRoute -AddressFamily IPv4 | Sort-Object InterfaceIndex, DestinationPrefix | Select-Object InterfaceIndex, DestinationPrefix, NextHop, RouteMetric)
            neighbors = @(Get-NetNeighbor -AddressFamily IPv4 | Sort-Object InterfaceIndex, IPAddress | Select-Object InterfaceIndex, IPAddress, LinkLayerAddress, State)
            dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object InterfaceIndex, ServerAddresses)
            nat = @(Get-NetNat | Select-Object Name, InternalIPInterfaceAddressPrefix, Active)
            natStaticMappings = @(Get-NetNatStaticMapping | Select-Object NatName, Protocol, ExternalIPAddress, ExternalPort, InternalIPAddress, InternalPort)
        }
        $snapshot.observerPart = 'host-only'
        $snapshot.powershellProcesses = @(Get-Process -Name powershell -ErrorAction SilentlyContinue | Select-Object Id, StartTime, CPU, WorkingSet64)
        @{ status = 'complete'; mutationPerformed = $false; snapshot = $snapshot } | ConvertTo-Json -Depth 30 -Compress
    } catch {
        @{ status = 'failed-read-only'; mutationPerformed = $false; errorType = $_.Exception.GetType().Name; errorLine = $_.InvocationInfo.ScriptLineNumber } | ConvertTo-Json -Compress
    }
}
function Assert-ComputeSnapshot($snapshot, [string[]]$off = @(), [bool]$clusterHealthy = $true, [bool]$expanded = $false) {
    Assert-ComputeEqual $snapshot.hostStatic $plan.baseline.hostStatic 'Outer storage/switch/NAT drift'
    Assert-ComputeEqual $snapshot.volumesStatic $plan.baseline.volumesStatic 'Volume identities drift'
    foreach ($guest in $snapshot.guestsStatic) {
        $old = @($plan.baseline.guestsStatic | Where-Object name -CEQ $guest.name)
        Assert-Compute ($old.Count -eq 1) 'Guest identity absent'
        # Before each serial node, earlier nodes are enlarged. Current node stays original until resize.
        $expectedCpu = $old[0].cpu; $expectedMemory = $old[0].memory
        if ($guest.name -cne 'LB-DC01' -and $stage -match '^(stop|resize|resume)-LB-NODE0([123])$') {
            $current = [int]$Matches[2]; $number = [int]$guest.name.Substring($guest.name.Length - 1)
            if ($number -lt $current -or ($stage.StartsWith('resume-') -and $number -eq $current)) { $expectedCpu = 16; $expectedMemory = 128GB }
        }
        Assert-Compute ($guest.cpu -eq $expectedCpu -and $guest.memory -eq $expectedMemory) 'Guest profile/order differs'
        $copy = @{}; foreach ($key in $guest.Keys) { $copy[$key] = $guest[$key] }
        $copy.cpu = $old[0].cpu; $copy.memory = $old[0].memory
        Assert-ComputeEqual $copy $old[0] 'Guest non-profile configuration drift'
        $expectedState = if ($guest.name -cin $off) { 'Off' } else { 'Running' }
        Assert-Compute ($snapshot.states[$guest.name] -ceq $expectedState) 'Required guest state differs'
    }
    foreach ($volume in $snapshot.volumes) {
        $budget = $plan.admission.volumeBudgets.PSObject.Properties[$volume.letter].Value
        Assert-Compute ($null -ne $budget -and $volume.health -ceq 'Healthy' -and $volume.free -ge $budget.freeFloorBytes) 'Volume free floor failed'
        Assert-Compute (($budget.maximumVhdBytes + $budget.runtimeBytes + $budget.metadataBytes + $budget.freeFloorBytes) -le $volume.size) 'Runtime-state reserve does not fit'
    }
    if ($expanded) {
        $capacity = $snapshot.hostCapacity
        Assert-Compute ($capacity.logicalProcessors -eq 64 -and $capacity.physicalCores -eq 32 -and $capacity.memoryBytes -ge 500GB -and $capacity.freeMemoryBytes -ge $plan.minimumOuterFreeMemoryBytes) 'Actual enlarged host capacity differs'
        Assert-Compute ($capacity.numa.Count -gt 0 -and ($capacity.numa | Measure-Object logicalProcessors -Sum).Sum -eq 64) 'NUMA topology unproved'
    }
    if ($clusterHealthy) {
        Assert-ComputeEqual $snapshot.clusterStatic $plan.baseline.clusterStatic 'Pool/CSV/member/VD identity drift'
        $h = $snapshot.clusterHealth
        Assert-Compute ($h.allNodesUp -and $h.allCsvOnline -and $h.allMirrorsHealthy -and $h.poolHealthy -and $h.quorumType -ceq 'Majority' -and $null -eq $h.witness -and $h.activeStorageJobs.Count -eq 0) 'Cluster health/quorum/storage job gate failed'
        Assert-Compute ($h.physicalFreeBytes -ge ($plan.admission.requiredPhysicalFreeBytes + $plan.admission.repairReserveBytes)) 'Physical S2D headroom insufficient'
    }
}
function Assert-ComputeMaintenanceHealth($snapshot, [string]$node, $drainProof, [bool]$compensating = $false) {
    Assert-ComputeEqual $snapshot.clusterStatic $plan.baseline.clusterStatic 'Maintenance pool/CSV/VD/bridge identity drift'
    $h = $snapshot.clusterHealth
    $owners = $plan.transitionContract.deviceOwners
    Assert-Compute ($null -ne $owners -and $h.devices.Count -eq 24) 'Sealed per-device ownership required'
    $expected = @($owners.PSObject.Properties | Where-Object Value -CEQ $node | ForEach-Object Name)
    Assert-Compute ($expected.Count -eq 8 -and $drainProof.selectedNode -ceq $node -and $drainProof.rpcReturned -eq $true -and $drainProof.eightDevicesMaintenanceVerified -eq $true) 'Exact original settled drain proof missing'
    Assert-ComputeEqual @($expected | Sort-Object) @($drainProof.deviceIds | Sort-Object) 'Drain proof device set differs'
    $survivors = @($h.nodeStates | Where-Object name -CNE $node)
    Assert-Compute ($survivors.Count -eq 2 -and @($survivors | Where-Object state -CNE 'Up').Count -eq 0) 'Two Up survivors required'
    $current = @($h.nodeStates | Where-Object name -CEQ $node)
    Assert-Compute ($current.Count -eq 1 -and $current[0].state -cin @('Down', 'Paused', 'Up')) 'Expected maintenance node state differs'
    if (-not $compensating -and $current[0].state -cne 'Down') {
        Assert-Compute ($current[0].state -ceq 'Paused') 'Current selected node is not paused for stop'
        $selected = @($h.devices | Where-Object owner -CEQ $node)
        Assert-Compute ($selected.Count -eq 8 -and @($selected | Where-Object maintenance -NE $true).Count -eq 0) 'Current selected eight devices are not in maintenance'
        Assert-ComputeEqual @($selected.id | Sort-Object) @($expected | Sort-Object) 'Current maintenance device set differs'
    }
    Assert-Compute ($h.allCsvOnline -and $h.quorumType -ceq 'Majority' -and $null -eq $h.witness -and $h.unrelatedFailures.Count -eq 0) 'Unrelated storage/quorum failure'
    Assert-Compute ($h.csvStates.Count -eq 4 -and @($h.csvStates | Where-Object { $_.state -cne 'Online' -or $_.accessible -ne $true }).Count -eq 0) 'CSV inaccessible during maintenance'
    Assert-Compute ($h.poolHealth -cin @('Healthy', 'Warning') -and $h.poolOperational.Count -gt 0 -and @($h.poolOperational | Where-Object { $_ -cnotin @('OK', 'Degraded', 'Incomplete', 'InService', 'In Service') }).Count -eq 0) 'Pool failure outside exact maintenance profile'
    foreach ($device in $h.devices) {
        Assert-Compute ($owners.PSObject.Properties[$device.id].Value -ceq $device.owner) 'Per-device owner drift'
        if ($device.owner -cne $node) {
            Assert-Compute ($device.health -ceq 'Healthy' -and ($device.operational -join '|') -ceq 'OK' -and -not $device.maintenance) 'Surviving-node device failure is not maintenance'
        } else {
            Assert-Compute ($device.health -cin @('Healthy', 'Warning') -and $device.operational.Count -gt 0 -and @($device.operational | Where-Object { $_ -cnotin @('OK', 'In Maintenance Mode', 'InMaintenanceMode', 'Starting Maintenance Mode', 'StartingMaintenanceMode', 'Lost Communication', 'LostCommunication') }).Count -eq 0) 'Unknown or unrelated selected-device failure'
        }
    }
    Assert-Compute ($h.virtualDiskStates.Count -eq 5 -and @($h.virtualDiskStates | Where-Object { $_.copies -ne 3 -or $_.health -cnotin @('Healthy', 'Warning') -or $_.operational.Count -eq 0 -or @($_.operational | Where-Object { $_ -cnotin @('OK', 'Degraded', 'Incomplete', 'InService', 'In Service') }).Count -gt 0 }).Count -eq 0) 'Virtual disk fault outside planned maintenance'
    # No arbitrary job allowance. Any jobs remain a next-node blocker. Compensation can
    # be admitted only by the R2 controller's verified pool/device/VD Repair association.
    if ($h.activeStorageJobs.Count -gt 0) {
        Assert-Compute $compensating 'No active jobs before another offline/resize effect'
        $virtualIds = @($plan.baseline.clusterStatic.virtualDisks.id)
        foreach ($job in $h.activeStorageJobs) {
            Assert-Compute ($job.name -ceq 'Repair' -and $job.poolId -ceq $plan.baseline.clusterStatic.poolId -and $job.affectedVirtualDiskIds.Count -gt 0 -and $job.affectedDeviceIds.Count -gt 0) 'Unassociated/unrelated repair job'
            Assert-Compute (@($job.affectedVirtualDiskIds | Where-Object { $_ -cnotin $virtualIds }).Count -eq 0 -and @($job.affectedDeviceIds | Where-Object { $_ -cnotin $expected }).Count -eq 0) 'Repair job outside exact selected eight devices'
        }
    }
    Assert-Compute ($h.physicalFreeBytes -ge ($plan.admission.requiredPhysicalFreeBytes + $plan.admission.repairReserveBytes)) 'Maintenance physical headroom insufficient'
}

function Assert-ProfileInfrastructurePlacement($snapshot) {
    $capacities = if ($snapshot.nodeCapacity -is [Collections.IDictionary]) { @($snapshot.nodeCapacity.Values) } else { @($snapshot.nodeCapacity.PSObject.Properties | ForEach-Object Value) }
    $placements = @($capacities | ForEach-Object { $_.bridgePlacement } | Where-Object id -IEQ '4c6ca5cc-8c9a-499b-8ffe-c029bbfd3522')
    Assert-Compute ($placements.Count -eq 1 -and $placements[0].state -ceq 'Running' -and $placements[0].hciNode -cin @('LB-NODE02','LB-NODE03')) 'Infrastructure is not Running once on an expanded survivor'
    $owner = $placements[0].hciNode
    $guest = @($snapshot.guestsStatic | Where-Object name -CEQ $owner)
    Assert-Compute ($guest.Count -eq 1 -and $guest[0].cpu -eq 20 -and $guest[0].memory -eq 96GB -and $snapshot.states.$owner -ceq 'Running') 'Infrastructure survivor is not the admitted expanded Running guest'
}

# Initial read only. The existing helper requires all exact guests and live owners.
$snapshot = Read-ComputeSnapshot $true
Assert-Compute ($snapshot.states.Count -eq 4 -and @($snapshot.states.Values | Where-Object { $_ -cne 'Running' }).Count -eq 0) 'Initial baseline requires all four guests Running'
if ([DateTimeOffset](Get-Date) -ge $readDeadline) { throw 'Fixed baseline read window closed after snapshot' }
$numaSpanningEnabled = (Get-VMHost -ErrorAction Stop).NumaSpanningEnabled
$atUtc = (Get-Date).ToUniversalTime().ToString('o')
if ([DateTimeOffset]::Parse($atUtc) -ge $readDeadline) { throw 'Fixed baseline read window closed after host read' }
@{ status = 'complete'; mutationPerformed = $false; atUtc = $atUtc; readDeadline = $readDeadline.ToString('o'); commonSourceSha256 = $commonSourceSha256; readerSourceSha256 = $readerSourceSha256; rootPresence = @($rootPresence); numaSpanningEnabled = $numaSpanningEnabled; snapshot = $snapshot } | ConvertTo-Json -Depth 40 -Compress
