# Read-only bounded node/cluster inventory. No host profile scan or DC queries here.
$ErrorActionPreference = 'Stop'
$targets = @(
    @{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34' },
    @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' },
    @{ name = 'LB-NODE03'; id = '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9' }
)
$session = $null; $secure = $null; $phase = 'host'
try {
    if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Wrong outer host' }
    $boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
    $bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
    $entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
    $helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
    if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Existing secret helper differs' }
    . $helper
    $store = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'
    $bindings = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw | ConvertFrom-Json
    foreach ($target in $targets) {
        $vm = Get-VM -Id $target.id; $binding = $bindings.nodes.PSObject.Properties[$target.name].Value
        if ($vm.Name -cne $target.name -or $vm.State.ToString() -cne 'Running' -or $binding.vmId -ine $target.id -or $binding.role -cne 'cluster-node-admin' -or $binding.secretDirectory -cne $store -or $binding.loginVerified -ne $true) { throw 'Exact node/credential binding differs' }
    }
    $nodes = @{}
    foreach ($target in $targets) {
        $phase = $target.name
        $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'
        $session = New-PSSession -VMId $target.id -Credential ([pscredential]::new(($target.name + '\ASBuiltInAdmin'), $secure)) -ErrorAction Stop
        $nodes[$target.name] = Invoke-Command -Session $session -ArgumentList $target.name -ErrorAction Stop -ScriptBlock {
            param($expected)
            $ErrorActionPreference = 'Stop'
            $admin = Get-LocalUser ASBuiltInAdmin
            if ($env:COMPUTERNAME -cne $expected -or -not $admin.Enabled -or -not $admin.SID.Value.EndsWith('-500') -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $admin.SID.Value) { throw 'Exact RID 500 identity differs' }
            $h = Get-VMHost; $system = Get-CimInstance Win32_ComputerSystem; $os = Get-CimInstance Win32_OperatingSystem
            $result = @{ logicalProcessors = $h.LogicalProcessorCount; memoryBytes = $system.TotalPhysicalMemory; freeMemoryBytes = $os.FreePhysicalMemory * 1KB
                numa = @(Get-VMHostNumaNode | ForEach-Object { @{ nodeId = $_.NodeId; logicalProcessors = @($_.ProcessorsAvailability).Count; memoryBytes = [long]$_.MemoryTotal * 1MB; processorAvailabilityPercent = @($_.ProcessorsAvailability) } })
                cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
                cpuUtilisationPercent = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor | Where-Object Name -EQ '_Total').PercentProcessorTime
                switches = @(Get-VMSwitch | Select-Object Name, Id, SwitchType, NetAdapterInterfaceDescription)
                managementAdapters = @(Get-VMNetworkAdapter -ManagementOS | ForEach-Object { $v = $_ | Get-VMNetworkAdapterVlan; @{ name = $_.Name; switchName = $_.SwitchName; mode = $v.OperationMode.ToString(); accessVlanId = $v.AccessVlanId; nativeVlanId = $v.NativeVlanId } })
                adapters = @(Get-NetAdapter | Select-Object InterfaceIndex, Name, Status, MacAddress, InterfaceDescription, LinkSpeed)
                ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceIndex, InterfaceAlias, IPAddress, PrefixLength, AddressState)
                routes = @(Get-NetRoute -AddressFamily IPv4 | Select-Object InterfaceIndex, DestinationPrefix, NextHop, RouteMetric)
                neighbors = @(Get-NetNeighbor -AddressFamily IPv4 | Select-Object InterfaceIndex, IPAddress, LinkLayerAddress, State)
                dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object InterfaceIndex, ServerAddresses)
                services = @(Get-Service -Name clussvc, vmms, himds, GCArcService, ExtensionService | Select-Object Name, Status)
                nestedVms = @(Get-VM | ForEach-Object {
                    $vm = $_; $p = Get-VMProcessor -VM $vm; $m = Get-VMMemory -VM $vm
                    @{ id = $vm.Id.ToString(); name = $vm.Name; cpu = $vm.ProcessorCount; memory = $vm.MemoryStartup
                       generation = $vm.Generation; version = $vm.Version.ToString(); path = $vm.Path; configurationLocation = $vm.ConfigurationLocation
                       automaticStart = $vm.AutomaticStartAction.ToString(); automaticStop = $vm.AutomaticStopAction.ToString()
                       processor = @{ nested = $p.ExposeVirtualizationExtensions; reserve = $p.Reserve; maximum = $p.Maximum; weight = $p.RelativeWeight }; dynamicMemory = $m.DynamicMemoryEnabled
                       disks = @(Get-VMHardDiskDrive -VM $vm | Sort-Object ControllerNumber, ControllerLocation | ForEach-Object { $d = Get-VHD -Path $_.Path; @{ path = $_.Path; id = $d.DiskIdentifier.ToString(); size = $d.Size; controller = $_.ControllerNumber; lun = $_.ControllerLocation } })
                       adapters = @(Get-VMNetworkAdapter -VM $vm | Sort-Object Name | ForEach-Object { $v = $_ | Get-VMNetworkAdapterVlan; @{ name = $_.Name; mac = $_.MacAddress; switchName = $_.SwitchName; dynamicMac = $_.DynamicMacAddressEnabled; vlan = $v.OperationMode.ToString(); accessVlanId = $v.AccessVlanId; nativeVlanId = $v.NativeVlanId } }) }
                })
                placement = @(Get-VM | ForEach-Object { @{ id = $_.Id.ToString(); state = $_.State.ToString(); hciNode = $env:COMPUTERNAME; ipv4 = @(Get-VMNetworkAdapter -VM $_ | ForEach-Object { @($_.IPAddresses) }); heartbeat = $_.Heartbeat.ToString() } })
                cluster = $null }
            # One full cluster view only, rather than three duplicated storage scans.
            if ($expected -ceq 'LB-NODE01') {
                $c = Get-Cluster -Name smal-localbox01; $q = Get-ClusterQuorum -Cluster $c
                $pool = @(Get-StoragePool | Where-Object IsPrimordial -EQ $false)
                if ($pool.Count -ne 1) { throw 'Exact one S2D pool required' }
                $p = $pool[0]
                $result.cluster = @{ name = $c.Name; poolId = $p.UniqueId; poolSize = $p.Size; allocated = $p.AllocatedSize
                    health = $p.HealthStatus.ToString(); operationalStatus = @($p.OperationalStatus | ForEach-Object ToString)
                    members = @($p | Get-PhysicalDisk | Sort-Object UniqueId | ForEach-Object { @{ id = $_.UniqueId; size = $_.Size; health = $_.HealthStatus.ToString() } })
                    nodes = @(Get-ClusterNode -Cluster $c | Sort-Object Name | Select-Object Name, State, NodeWeight, DynamicWeight)
                    quorumType = $q.QuorumType.ToString(); witness = $(if ($q.QuorumResource) { $q.QuorumResource.Name } else { $null })
                    virtualDisks = @(Get-VirtualDisk | Sort-Object UniqueId | ForEach-Object { @{ id = $_.UniqueId; size = $_.Size; copies = $_.NumberOfDataCopies; resiliency = $_.ResiliencySettingName; health = $_.HealthStatus.ToString() } })
                    csv = @(Get-ClusterSharedVolume -Cluster $c | Sort-Object Name | ForEach-Object { @{ name = $_.Name; id = $_.Id.ToString(); state = $_.State.ToString(); volumes = @($_.SharedVolumeInfo | ForEach-Object { @{ path = $_.FriendlyVolumeName; size = $_.Partition.Size; free = $_.Partition.FreeSpace } }) } })
                    jobs = @(Get-StorageJob | Where-Object JobState -NE Completed | ForEach-Object { @{ name = $_.Name; state = [string]$_.JobState } })
                    groups = @(Get-ClusterGroup -Cluster $c | ForEach-Object { @{ name = $_.Name; state = $_.State.ToString(); ownerNode = $_.OwnerNode.Name; type = $_.GroupType.ToString() } })
                    vmResources = @(Get-ClusterResource -Cluster $c | Where-Object ResourceType -EQ 'Virtual Machine' | ForEach-Object { @{ name = $_.Name; ownerGroup = $_.OwnerGroup.Name; ownerNode = $_.OwnerNode.Name; state = $_.State.ToString(); vmIdentity = @($_ | Get-ClusterParameter | Where-Object Name -EQ 'VmId' | Select-Object Name, Value) } }) }
            }
            return $result
        }
        Remove-PSSession $session; $session = $null; $secure.Dispose(); $secure = $null
    }
    $nested = @($nodes.Values | ForEach-Object { @($_.nestedVms) })
    if ($nested.Count -ne 1 -or $nested[0].id -ine '4c6ca5cc-8c9a-499b-8ffe-c029bbfd3522') { throw 'Unknown or missing infrastructure VM' }
    @{ status = 'complete'; atUtc = [datetime]::UtcNow.ToString('o'); observerPart = 'nodes'; mutationPerformed = $false; nodes = $nodes } | ConvertTo-Json -Depth 20 -Compress
} catch {
    @{ status = 'failed-read-only'; atUtc = [datetime]::UtcNow.ToString('o'); mutationPerformed = $false; phase = $phase; errorType = $_.Exception.GetType().Name; errorLine = $_.InvocationInfo.ScriptLineNumber } | ConvertTo-Json -Compress
} finally { if ($session) { Remove-PSSession $session }; if ($secure) { $secure.Dispose() } }
