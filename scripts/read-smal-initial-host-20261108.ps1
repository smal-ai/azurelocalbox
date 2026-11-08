# Fixed outer profiles and route selection. No key-protector/VHD or session dump.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Wrong outer host' }
$began = [datetime]::UtcNow.ToString('o')
$targets = @{
    'LB-DC01' = 'f94c71f1-6854-48b9-a9f1-8238c99366d0'
    'LB-NODE01' = '3adff629-2f67-449b-ab32-8a8748c46f34'
    'LB-NODE02' = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3'
    'LB-NODE03' = '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9'
}
$queries = @()
$queries += Read-InitialQuery 'hostCapacity' {
    $system = Get-CimInstance Win32_ComputerSystem; $os = Get-CimInstance Win32_OperatingSystem
    @{ logicalProcessors = (Get-VMHost).LogicalProcessorCount; memoryBytes = $system.TotalPhysicalMemory; freeMemoryBytes = [long]$os.FreePhysicalMemory * 1KB }
}
$queries += Read-InitialQuery 'fourGuestProfiles' {
    foreach ($name in ($targets.Keys | Sort-Object)) {
        $vm = Get-VM -Id $targets[$name]
        if ($vm.Name -cne $name) { throw 'Guest identity differs' }
        $memory = Get-VMMemory -VM $vm; $processor = Get-VMProcessor -VM $vm
        @{ name = $vm.Name; id = $vm.Id.ToString(); state = $vm.State.ToString(); cpu = $vm.ProcessorCount; fixedMemoryBytes = $vm.MemoryStartup
            assignedMemoryBytes = $vm.MemoryAssigned; dynamicMemory = $memory.DynamicMemoryEnabled; nestedExtensions = $processor.ExposeVirtualizationExtensions; heartbeat = $vm.Heartbeat.ToString()
            adapters = @(Get-VMNetworkAdapter -VM $vm | ForEach-Object { $vlan = $_ | Get-VMNetworkAdapterVlan
                @{ id = $_.Id; name = $_.Name; mac = $_.MacAddress; switchId = $_.SwitchId.ToString(); switchName = $_.SwitchName
                    vlanMode = $vlan.OperationMode.ToString(); accessVlanId = $vlan.AccessVlanId; nativeVlanId = $vlan.NativeVlanId } }) }
    }
}
$queries += Read-InitialQuery 'ipv4' { Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object { Select-InitialFields $_ @('InterfaceIndex','InterfaceAlias','IPAddress','PrefixLength') } }
$queries += Read-InitialQuery 'routes' { Get-NetRoute -AddressFamily IPv4 | ForEach-Object { Select-InitialFields $_ @('InterfaceIndex','InterfaceAlias','DestinationPrefix','NextHop','RouteMetric') } }
foreach ($address in @('10.64.0.100','10.64.0.180')) {
    $queries += Read-InitialQuery ('selectedRoute:' + $address) { Find-NetRoute -RemoteIPAddress $address | ForEach-Object { Select-InitialFields $_ @('InterfaceIndex','InterfaceAlias','IPAddress','PrefixLength','DestinationPrefix','NextHop','RouteMetric') } }
}
$queries += Read-InitialQuery 'nat' { Get-NetNat | ForEach-Object { Select-InitialFields $_ @('Name','InternalIPInterfaceAddressPrefix','Active') } }
$queries += Read-InitialQuery 'natStaticMappings' { Get-NetNatStaticMapping | ForEach-Object { Select-InitialFields $_ @('NatName','Protocol','ExternalIPAddress','ExternalPort','InternalIPAddress','InternalPort') } }
$queries += Read-InitialQuery 'currentPlatformSsh22PeerAddresses' { Get-NetTCPConnection -LocalPort 22 -State Established | Select-Object -ExpandProperty RemoteAddress -Unique }
$queries += Read-InitialQuery 'outerVolumes' { Get-Volume | Where-Object DriveLetter -In @('C','V','W','X') | ForEach-Object { Select-InitialFields $_ @('DriveLetter','UniqueId','Size','SizeRemaining','HealthStatus') } }
@{ status = $(if (@($queries | Where-Object complete -EQ $false).Count) { 'partial-read-only' } else { 'complete' }); scope = 'LocalBox-Client-only'; beganAtUtc = $began; finishedAtUtc = [datetime]::UtcNow.ToString('o'); mutationPerformed = $false; queries = $queries } | ConvertTo-Json -Depth 18 -Compress
