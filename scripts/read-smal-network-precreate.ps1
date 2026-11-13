$ErrorActionPreference='Stop'
$ComputeCapacityLibraryOnly=$true
$entry=$null
$plan=ConvertFrom-Json @'
{"guestIds": {"LB-DC01": "f94c71f1-6854-48b9-a9f1-8238c99366d0", "LB-NODE01": "3adff629-2f67-449b-ab32-8a8748c46f34", "LB-NODE02": "12a44e0c-cc08-4c4c-a812-fa0b56efdbc3", "LB-NODE03": "5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9"}}
'@
function Assert-Compute([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
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
function Read-NetworkDc {
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

            $ErrorActionPreference='Stop'
            if ($env:COMPUTERNAME -cne 'LB-DC01' -or -not [Security.Principal.WindowsIdentity]::GetCurrent().User.Value.EndsWith('-500')) {throw 'Exact DC/RID500 required'}
            $domain=Get-ADDomain
            if($domain.DNSRoot -cne 'ad.localbox.test'){throw 'Known domain differs'}
            $role=Get-WindowsFeature -Name DHCP -ErrorAction Stop
            if($null -eq $role -or $role.Installed -isnot [bool]){throw 'DHCP role applicability not reported'}
            $scopes=@();$leases=@();$reservations=@();$exclusions=@()
            if($role.Installed){
                $scopes=@(Get-DhcpServerv4Scope -ErrorAction Stop)
                if($scopes.Count -gt 8){throw 'DHCP scope read bound exceeded'}
                foreach($scope in $scopes){
                    # Preserve every scope extent but only read leases for this authorised subnet.
                    if([string]$scope.ScopeId -cne '10.64.0.0'){throw 'Foreign DHCP scope; no widened lease inventory authority'}
                    $leases+=@(Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -AllLeases -ErrorAction Stop | ForEach-Object {@{IPAddress=[string]$_.IPAddress;AddressState=[string]$_.AddressState;ClientId=$_.ClientId}})
                    $reservations+=@(Get-DhcpServerv4Reservation -ScopeId $scope.ScopeId -ErrorAction Stop | ForEach-Object {@{IPAddress=[string]$_.IPAddress;ClientId=$_.ClientId}})
                    $exclusions+=@(Get-DhcpServerv4ExclusionRange -ScopeId $scope.ScopeId -ErrorAction Stop | ForEach-Object {@{StartRange=[string]$_.StartRange;EndRange=[string]$_.EndRange}})
                    if($leases.Count -gt 256 -or $reservations.Count -gt 256){throw 'DHCP object bound exceeded'}
                }
            }
            $clusterFqdn='smal-localbox01.'+$domain.DNSRoot
            @{ name=$env:COMPUTERNAME; domain=$domain.DNSRoot; clusterFqdn=$clusterFqdn
               ipv4=@(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceIndex,InterfaceAlias,IPAddress,PrefixLength)
               neighbours=@(Get-NetNeighbor -AddressFamily IPv4 | ForEach-Object {@{InterfaceIndex=$_.InterfaceIndex;IPAddress=$_.IPAddress;LinkLayerAddress=$_.LinkLayerAddress;State=[string]$_.State}})
               dnsA=@(Get-DnsServerResourceRecord -ZoneName ad.localbox.test -RRType A -ErrorAction Stop | ForEach-Object {@{name=$_.HostName;address=$_.RecordData.IPv4Address.IPAddressToString}})
               forwarders=@((Get-DnsServerForwarder -ErrorAction Stop).IPAddress | ForEach-Object { [string]$_ })
               clusterAnswers=@(Resolve-DnsName -Name $clusterFqdn -Type A -Server '10.64.0.10' -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object IPAddress | Select-Object -ExpandProperty IPAddress)
               dhcp=@{installed=[bool]$role.Installed;applicabilityBasis='actual Get-WindowsFeature DHCP Installed flag';scopes=@($scopes|ForEach-Object {@{ScopeId=[string]$_.ScopeId;StartRange=[string]$_.StartRange;EndRange=[string]$_.EndRange;State=[string]$_.State}});leases=$leases;reservations=$reservations;exclusions=$exclusions;enumerationCompleted=$true} }
        }
    } finally { if ($session) { Remove-PSSession $session }; $secure.Dispose() }
}

# Appended to exact protected AzureLocalBox observer/session slices by render_precreate.py.
# Read-only proposal. Existing transport approval is separate. No AKS API/Pod probes.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Wrong outer host' }
$clock = [Diagnostics.Stopwatch]::StartNew()
$snapshotId = [guid]::NewGuid().ToString()
# Canonical transport streams an executing ScriptBlock. PSCommandPath can be empty,
# or inherited from its caller, and is not the observer's source identity.
$executingSource = $MyInvocation.MyCommand.ScriptBlock.ToString()
if ([string]::IsNullOrEmpty($executingSource)) { throw 'Executing observer ScriptBlock source unavailable' }
$sourceHasher = [Security.Cryptography.SHA256]::Create()
try { $observerSourceSha256 = [BitConverter]::ToString($sourceHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($executingSource))).Replace('-', '').ToLowerInvariant() }
finally { $sourceHasher.Dispose() }
$observerSourceHashBasis = 'actual-executing-ScriptBlock.ToString-UTF8-sha256'
function Check-NetworkBudget { if ($clock.Elapsed.TotalSeconds -gt 180) { throw '180-second network read budget exceeded; no retry' } }
function Read-NetworkPart([scriptblock]$read) {
    Check-NetworkBudget
    try { $value = & $read; Check-NetworkBudget; return @{ status = 'read'; value = $value } }
    catch { return @{ status = 'failed'; errorType = $_.Exception.GetType().FullName; errorLine = $_.InvocationInfo.ScriptLineNumber } }
}
function Select-NetworkRoute([string]$destination) {
    $found = @(Find-NetRoute -RemoteIPAddress $destination -ErrorAction Stop)
    $address = @($found | Where-Object { $null -ne $_.PSObject.Properties['IPAddress'] })
    $route = @($found | Where-Object { $null -ne $_.PSObject.Properties['DestinationPrefix'] })
    if ($address.Count -ne 1 -or $route.Count -ne 1) { throw 'Find-NetRoute did not return one address and one route' }
    if ($address[0].InterfaceIndex -ne $route[0].InterfaceIndex) { throw 'Selected source/route interface mismatch' }
    @{ destination = $destination; selectedSource = [string]$address[0].IPAddress; prefixLength = $address[0].PrefixLength
       interfaceIndex = [int]$route[0].InterfaceIndex; routePrefix = [string]$route[0].DestinationPrefix
       nextHop = [string]$route[0].NextHop; basis = 'actual Find-NetRoute address and route objects' }
}
$outer = Read-NetworkPart {
    $vms = @(Get-VM)
    if ($vms.Count -ne 4) { throw 'Four known outer guests required' }
    $guests = @(foreach ($vm in $vms) {
        if ($plan.guestIds.PSObject.Properties[$vm.Name].Value -ine $vm.Id.ToString() -or [string]$vm.State -cne 'Running') { throw 'Exact Running outer guest identity differs' }
        @{ name = $vm.Name; id = $vm.Id.ToString(); state = [string]$vm.State
           nics = @(Get-VMNetworkAdapter -VM $vm | ForEach-Object { @{ id = [string]$_.Id; mac = $_.MacAddress; switchId = [string]$_.SwitchId; switchName = $_.SwitchName } }) }
    })
    @{ name = $env:COMPUTERNAME; state = 'Running'; guests = $guests
       ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceIndex, InterfaceAlias, IPAddress, PrefixLength, AddressState)
       neighbours = @(Get-NetNeighbor -AddressFamily IPv4 | ForEach-Object {@{InterfaceIndex=$_.InterfaceIndex;IPAddress=$_.IPAddress;LinkLayerAddress=$_.LinkLayerAddress;State=[string]$_.State}})
       nat = @(Get-NetNat | Select-Object Name, InternalIPInterfaceAddressPrefix)
       forward = @('10.64.0.100','10.64.0.180' | ForEach-Object { Select-NetworkRoute $_ }) }
}
$nodes = [ordered]@{}
foreach ($node in @('LB-NODE01','LB-NODE02','LB-NODE03')) {
    Check-NetworkBudget
    $nodes[$node] = Read-NetworkPart {
        $session = New-ComputeSession $node
        try {
            Invoke-Command -Session $session -ArgumentList $node, $outer, ${function:Select-NetworkRoute}.ToString() -ErrorAction Stop -ScriptBlock {
                param($expected, $outerRead, $routeSource)
                $ErrorActionPreference = 'Stop'
                if ($env:COMPUTERNAME -cne $expected -or -not [Security.Principal.WindowsIdentity]::GetCurrent().User.Value.EndsWith('-500')) { throw 'Exact node/RID500 required' }
                function Select-NetworkRoute { param([string]$destination) & ([scriptblock]::Create($routeSource)) $destination }
                $system = Get-CimInstance Win32_ComputerSystem
                if ($system.Domain -cne 'ad.localbox.test') { throw 'Known management domain differs' }
                $ip = @{'LB-NODE01'='10.64.0.11';'LB-NODE02'='10.64.0.12';'LB-NODE03'='10.64.0.13'}[$expected]
                $addresses = @(Get-NetIPAddress -AddressFamily IPv4)
                $management = @($addresses | Where-Object IPAddress -CEQ $ip)
                if ($management.Count -ne 1) { throw 'Unique current management interface required' }
                $adapters = @(Get-NetAdapter -IncludeHidden | Where-Object ifIndex -EQ $management[0].InterfaceIndex)
                if($adapters.Count -ne 1){throw 'Unique current management adapter required'}
                $adapter = $adapters[0]
                $switch = Get-VMSwitch -Name 'ConvergedSwitch(managementcompute)' -ErrorAction Stop
                $switchNics = @(Get-VMNetworkAdapter -ManagementOS | Where-Object SwitchId -EQ $switch.Id)
                $fabric = @($switchNics | Where-Object { $_.MacAddress.Replace('-','').Replace(':','') -ieq $adapter.MacAddress.Replace('-','').Replace(':','') })
                if ($fabric.Count -ne 1) { throw 'Management interface/switch MAC join ambiguous within current management-OS inventory' }
                $vlan = $fabric[0] | Get-VMNetworkAdapterVlan
                $gateways = @(Get-NetRoute -InterfaceIndex $management[0].InterfaceIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Select-Object -ExpandProperty NextHop -Unique)
                $dns = @(Get-DnsClientServerAddress -InterfaceIndex $management[0].InterfaceIndex -AddressFamily IPv4 | Select-Object -ExpandProperty ServerAddresses)
                $gatewaySelection=Select-NetworkRoute '10.64.0.1'
                $dnsSelection=Select-NetworkRoute '10.64.0.10'
                if($gatewaySelection.selectedSource -cne $ip -or $dnsSelection.selectedSource -cne $ip){throw 'OS-selected base-probe source differs from management IP'}
                $ping = [Net.NetworkInformation.Ping]::new()
                try { $reply = $ping.Send('10.64.0.1', 1500); $gatewayResult = [string]$reply.Status } finally { $ping.Dispose() }
                $query = $expected.ToLowerInvariant() + '.' + $system.Domain
                $answers = @(Resolve-DnsName -Name $query -Type A -Server '10.64.0.10' -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object IPAddress | Select-Object -ExpandProperty IPAddress)
                $cluster = Get-Cluster -Name smal-localbox01 -ErrorAction Stop
                $clusterNodes = @(Get-ClusterNode -Cluster $cluster | Sort-Object Name)
                if ((($clusterNodes.Name | Sort-Object) -join '|') -cne 'LB-NODE01|LB-NODE02|LB-NODE03') { throw 'Exact cluster node set differs' }
                $vmResources = @(Get-ClusterResource -Cluster $cluster | Where-Object ResourceType -CEQ 'Virtual Machine')
                $clusterVms = @(foreach ($resource in $vmResources) { $id = ($resource | Get-ClusterParameter -Name VmId -ErrorAction Stop).Value; @{ vmId = [string]$id; resourceId = [string]$resource.Id; ownerNode = [string]$resource.OwnerNode; state = [string]$resource.State } })
                $nested = @(Get-VM | ForEach-Object {
                    if ($_.Id.ToString() -ine '4c6ca5cc-8c9a-499b-8ffe-c029bbfd3522') { throw 'Unknown nested VM; no widened inventory authority' }
                    @{ vmId = $_.Id.ToString(); name = $_.Name; hostNode = $expected; state = [string]$_.State
                       paths = @(Get-VMHardDiskDrive -VM $_ | Select-Object -ExpandProperty Path)
                       nics = @(Get-VMNetworkAdapter -VM $_ | ForEach-Object { @{ id = [string]$_.Id; mac = $_.MacAddress; switchId = [string]$_.SwitchId; addresses = @($_.IPAddresses) } }) }
                })
                $returnSelection = $null
                if ($outerRead.status -ceq 'read') {
                    $sources = @($outerRead.value.forward.selectedSource | Select-Object -Unique)
                    if ($sources.Count -ne 1) { throw 'Outer source not uniquely selected' }
                    $returnSelection = Select-NetworkRoute $sources[0]
                }
                @{ node = $expected; domain = $system.Domain; ipv4 = @($addresses | Select-Object InterfaceIndex, InterfaceAlias, IPAddress, PrefixLength)
                   neighbours = @(Get-NetNeighbor -AddressFamily IPv4 | ForEach-Object {@{InterfaceIndex=$_.InterfaceIndex;IPAddress=$_.IPAddress;LinkLayerAddress=$_.LinkLayerAddress;State=[string]$_.State}})
                   fabric = @{ name=$expected; address=$ip; prefixLength=$management[0].PrefixLength; switchName=$switch.Name; switchId=[string]$switch.Id; switchType=[string]$switch.SwitchType
                       vlanMode=[string]$vlan.OperationMode; vlanId=$vlan.AccessVlanId; nativeVlan=$vlan.NativeVlanId; gatewayCandidates=$gateways; dnsServers=$dns; linkState=[string]$adapter.Status }
                   probes = @(@{ sourceNode=$expected;sourceIp=$gatewaySelection.selectedSource;probeKind='gateway-l2';destinationIp='10.64.0.1';method='icmp';nativeStatus=$gatewayResult;sourceSelection=$gatewaySelection;packetCapturePerformed=$false },
                       @{ sourceNode=$expected;sourceIp=$dnsSelection.selectedSource;probeKind='dns53';destinationIp='10.64.0.10';port=53;queryName=$query;answerIps=$answers;result='answer';sourceSelection=$dnsSelection;packetCapturePerformed=$false })
                   cluster = @{ name=$cluster.Name; fqdn=($cluster.Name+'.'+$system.Domain); fqdnBasis='actual cluster name plus actual domain; verified separately by DC resolution'; nodes=@($clusterNodes | ForEach-Object {@{name=$_.Name;state=[string]$_.State}}) }
                   nestedVms=$nested; clusterVms=$clusterVms; returnSelection=$returnSelection }
            }
        } finally { Remove-PSSession $session }
    }
}
$dc = Read-NetworkPart { Read-NetworkDc }
$moc = Read-NetworkPart {
    $session = New-ComputeSession 'LB-NODE01'
    try { Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference='Stop'
        if ($env:COMPUTERNAME -cne 'LB-NODE01' -or -not [Security.Principal.WindowsIdentity]::GetCurrent().User.Value.EndsWith('-500')) {throw 'Exact MOC observer required'}
        $watch=[Diagnostics.Stopwatch]::StartNew();$script:calls=0
        function Moc-Field($item,[string]$name) {
            if($null -eq $item){return @{present=$false;value=$null}}
            if($item -is [Collections.IDictionary]){
                $keys=@($item.Keys|Where-Object {$_ -is [string] -and $_ -ieq $name})
                if($keys.Count -gt 1){throw 'Ambiguous MOC dictionary key'}
                if($keys.Count -eq 1){return @{present=$true;value=$item[$keys[0]]}}
            }else{
                $property=$item.PSObject.Properties[$name]
                if($null -ne $property){return @{present=$true;value=$property.Value}}
            }
            @{present=$false;value=$null}
        }
        function Metadata($command) { @{name=$command.Name;module=$command.ModuleName;version=[string]$command.Module.Version;guid=[string]$command.Module.Guid;path=$command.Module.Path;sha256=(Get-FileHash $command.Module.Path -Algorithm SHA256).Hash.ToLowerInvariant();parameters=@($command.Parameters.Keys);parameterSets=@($command.ParameterSets|ForEach-Object {@{name=$_.Name;mandatory=@($_.Parameters|Where-Object IsMandatory|Select-Object -ExpandProperty Name)}})} }
        # Exact bounded array/list handling retained from the qualified MOC reader.
        # Dictionaries and objects remain records, never flattened by their fields.
        function OuterItems($Value) {
            $flat=[Collections.Generic.List[object]]::new();$limit=@{visited=0}
            function AddOuter($Value,[int]$Depth) {
                $limit.visited++;if ($limit.visited -gt 256) {throw 'Outer collection traversal bound exceeded'}
                if ($Value -is [Collections.IList] -and $Value -isnot [Collections.IDictionary]) {
                    if ($Depth -ge 4 -or $Value.Count -gt 64) {throw 'Outer collection depth/count exceeded'}
                    foreach($entry in $Value) {AddOuter $entry ($Depth+1)}
                } else {
                    if ($flat.Count -ge 64) {throw 'Normalised item count exceeded'}
                    $flat.Add($Value)
                }
            }
            AddOuter $Value 0
            return ,$flat.ToArray()
        }
        function Moc-Items($Records,[string]$Envelope) {
            $data=OuterItems $Records
            for($depth=0;$depth -lt 3 -and $data.Count -eq 1;$depth++) {
                if((Moc-Field $data[0] 'nextLink').value){throw 'Paged MOC getter cannot establish complete extent in this fixed read'}
                $members=@(@('value',$Envelope)|Select-Object -Unique|ForEach-Object {Moc-Field $data[0] $_}|Where-Object {$_.present})
                if ($members.Count -gt 1) {throw 'Ambiguous vendor collection envelope'}
                if ($members.Count -eq 0) {break}
                $collection=$members[0].value
                if ($null -eq $collection -or $collection -is [Collections.IDictionary] -or $collection -isnot [Collections.IList]) {throw 'Vendor envelope is not an explicit array/list'}
                $data=OuterItems $collection
            }
            if ($data.Count -gt 32 -or @($data|Where-Object {$null -eq $_ -or $_ -is [string] -or $_ -is [ValueType]}).Count) {throw 'Unsupported or oversized vendor result shape'}
            if ($data.Count -eq 1 -and ((Moc-Field $data[0] 'value').present -or (Moc-Field $data[0] $Envelope).present)) {throw 'Vendor envelope depth exceeded'}
            foreach($row in $data){if((Moc-Field $row 'nextLink').value){throw 'Unsettled vendor continuation'}}
            return ,$data
        }
        function Read-MocList([string]$name,[string]$envelope,[hashtable]$arguments) {
            $script:lastMocBinding=$null
            if ($watch.Elapsed.TotalSeconds -gt 60 -or $script:calls -ge 8) {throw 'MOC eight-getter/60-second budget reached'}
            $command=@(Get-Command -Name $name -All -ErrorAction Stop)
            if ($command.Count -ne 1 -or $command[0].ModuleName -cne 'Moc' -or [string]$command[0].Module.Version -cne '1.2.161') {throw 'Observed Moc 1.2.161 getter binding differs'}
            foreach($key in $arguments.Keys){if(-not $command[0].Parameters.ContainsKey($key)){throw 'Installed getter parameter missing'}}
            $script:lastMocBinding=Metadata $command[0]
            if($script:lastMocBinding.guid -ine 'f6cfb7b2-99e9-47f7-8000-7390756ee89b' -or $script:lastMocBinding.sha256 -cne 'b9dbda4ab8c0ce6c77d8fa219a153983114afc859f5bb10689f6f3cf71025b7f'){throw 'Previously observed public Moc module identity/source changed'}
            $eligible=@($script:lastMocBinding.parameterSets|Where-Object {@($_.mandatory|Where-Object {-not $arguments.ContainsKey($_)}).Count -eq 0})
            if($eligible.Count -eq 0 -or @($command[0].Parameters.Keys|Where-Object {$_ -match '^(ContinuationToken|NextLink|PageSize|SkipToken|MaxResults)$'}).Count){throw 'Installed owning-list signature cannot establish this unpaged scope'}
            $script:calls++
            $raw=Moc-Items -Records @(& $command[0] @arguments -ErrorAction Stop) -Envelope $envelope
            # Only known non-secret network/identity fields. No VM userData, credentials or full vendor streams.
            $items=@(foreach($row in $raw){
                if($row.name -isnot [string] -or [string]::IsNullOrEmpty($row.name) -or ($null -ne $row.location -and $row.location -isnot [string]) -or ($null -ne $row.group -and $row.group -isnot [string])){throw 'Native MOC name/location/group must be scalar; no member-enumeration identity inference'}
                $props=$row.properties;if($name -ceq 'Get-MocVirtualMachine'){$props=$row.virtualmachineproperties}
                @{id=$row.id;name=$row.name;group=$row.group;location=$row.location
                  macAddress=$props.macAddress;ipConfigurations=@($props.ipConfigurations|ForEach-Object {@{subnetId=$_.properties.subnet.id;address=$_.properties.privateIPAddress;prefixLength=$_.properties.prefixLength;gateway=$_.properties.gateway}})
                  subnets=@($props.subnets|ForEach-Object {@{name=$_.name;id=$_.id;addressPrefix=$_.properties.addressPrefix}})
                  vmIds=@($props.vmId,$props.virtualMachineId,$props.hyperVVmId,$props.instanceId,$row.tags.hyperVVmId|Where-Object {$_})
                  nicReferences=@($props.networkProfile.networkInterfaces|ForEach-Object {[string]$_.id})
                  paths=@($props.storageProfile.osDisk.vhd.path,$props.storageProfile.osDisk.vhd.filePath|Where-Object {$_})
                  macPoolName=$props.macPoolName
                  vipExtentFields=@{start=$props.start;end=$props.end;startAddress=$props.startAddress;endAddress=$props.endAddress;addressPrefix=$props.addressPrefix
                      ranges=@($props.ranges|ForEach-Object {@{start=$_.start;end=$_.end;startAddress=$_.startAddress;endAddress=$_.endAddress;addressPrefix=$_.addressPrefix}})}
                  state=$props.statuses.powerState }
            })
            @{status='read';items=$items;count=$items.Count;binding=(Metadata $command[0]);enumeration=@{type='unpaged';installedApiEvidence=(Metadata $command[0]);noContinuationObserved=$true;scopeArguments=$arguments}}
        }
        function Try-MocList([string]$name,[string]$envelope,[hashtable]$arguments) {
            try {Read-MocList $name $envelope $arguments}
            catch {@{status='failed';getter=$name;arguments=$arguments;binding=$script:lastMocBinding;errorType=$_.Exception.GetType().FullName;absenceNotEstablished=$true}}
        }
        $groups=Try-MocList 'Get-MocGroup' 'groups' @{location='MocLocation';timeoutSeconds=15}
        $result=[ordered]@{groups=$groups;vipPools=$null;vm=@{};nic=@{};vnet=@{}}
        if($groups.status -cne 'read' -or (@($groups.items.name|Sort-Object)-join '|') -cne 'Default_Group|management'){
            $result.coverage='scope-incomplete';$result.getterCalls=$script:calls;return $result
        }
        # Observed Moc 1.2.161 declaration, not an invented subnet.ipPools field.
        # This location-scoped getter covers VIP pools only, never VM pool ranges.
        $result.vipPools=Try-MocList 'Get-MocVipPool' 'vipPools' @{location='MocLocation';timeoutSeconds=15}
        foreach($group in @('management','Default_Group')){
            $result.vm[$group]=Try-MocList 'Get-MocVirtualMachine' 'virtualMachines' @{group=$group;timeoutSeconds=15}
            $result.nic[$group]=Try-MocList 'Get-MocNetworkInterface' 'networkInterfaces' @{group=$group}
            $result.vnet[$group]=Try-MocList 'Get-MocVirtualNetwork' 'virtualNetworks' @{group=$group}
        }
        $result.getterCalls=$script:calls;$result.poolCoverage='ARM logical-network configured IP pools plus current location-scoped Get-MocVipPool; neither an inferred subnet field nor a global allocator claim'
        $result
    }} finally {Remove-PSSession $session}
}
Check-NetworkBudget
$capture=@{schemaVersion=1;collectorContract='smal-network-precreate-read-v1';observerSourceSha256=$observerSourceSha256;observerSourceHashBasis=$observerSourceHashBasis;snapshotId=$snapshotId;startedAtUtc=[datetime]::UtcNow.AddMilliseconds(-$clock.ElapsedMilliseconds).ToString('o');capturedAtUtc=[datetime]::UtcNow.ToString('o')
    outer=$outer;nodes=$nodes;dc=$dc;moc=$moc;resourceWritesRequested=$false;runtimeTrafficVerified=$false;packetProof=$false
    limitations=@('No neighbour absence or echo failure proves an address free','ARM control-plane identity/connection facts and owner caller requirements are separate source-bound inputs','Vendor GET implementations may use their existing authentication/log/cache behaviour; no new client or resource writer is implemented')}
$capture|ConvertTo-Json -Depth 40 -Compress
