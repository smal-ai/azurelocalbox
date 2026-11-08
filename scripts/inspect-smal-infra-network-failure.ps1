# Read-only network diagnosis. No addresses, adapters, rules or routes are changed.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected host' }
$targets = @(@{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34' }, @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' }, @{ name = 'LB-NODE03'; id = '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9' })
$boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
$entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1'); $helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Secret helper differs' }
. $helper
$store = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'
$bindings = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw | ConvertFrom-Json
$icmpRules = @(Get-NetFirewallPortFilter -PolicyStore ActiveStore | Where-Object { [string]$_.Protocol -in @('ICMPv4','1') } | ForEach-Object {
    $port = $_
    foreach ($rule in @($port | Get-NetFirewallRule | Where-Object Direction -EQ Inbound)) {
        $address = $rule | Get-NetFirewallAddressFilter; $iface = $rule | Get-NetFirewallInterfaceFilter
        @{ name = $rule.Name; enabled = [string]$rule.Enabled; action = [string]$rule.Action; profile = [string]$rule.Profile;
           protocol = [string]$port.Protocol; icmpType = @($port.IcmpType); localAddress = @($address.LocalAddress); remoteAddress = @($address.RemoteAddress);
           interfaceAlias = @($iface.InterfaceAlias); policySourceType = [string]$rule.PolicyStoreSourceType }
    }
})
$nodes = @(foreach ($target in $targets) {
    $vm = Get-VM -Id $target.id; $binding = $bindings.nodes.PSObject.Properties[$target.name].Value
    if ($vm.Name -cne $target.name -or $vm.State.ToString() -ne 'Running' -or $binding.vmId -ine $target.id -or $binding.loginVerified -ne $true -or $binding.secretDirectory -cne $store -or $binding.role -cne 'cluster-node-admin') { throw 'Exact VM/credential binding differs' }
    $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'; $session = $null
    try {
        $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($vm.Name + '\Administrator'), $secure)) -ErrorAction Stop
        $guest = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $mgmt = @(Get-NetIPAddress -InterfaceAlias MGMT1 -AddressFamily IPv4 | Where-Object IPAddress -Like '10.64.0.*')
            if ($mgmt.Count -ne 1) { throw 'Exact management source differs' }
            $probes = @(foreach ($address in @('10.64.0.1','10.64.0.10')) {
                $null = & ping.exe -4 -n 2 -w 1000 -S $mgmt[0].IPAddress $address
                @{ source = $mgmt[0].IPAddress; destination = $address; echoReplyReceived = ($LASTEXITCODE -eq 0) }
            })
            @{ name = $env:COMPUTERNAME; probes = $probes;
               adapters = @(Get-NetAdapter -IncludeHidden | Select-Object Name,InterfaceDescription,Status,MacAddress,ifIndex);
               ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias,IPAddress,PrefixLength,AddressState);
               routes = @(Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -or $_.DestinationPrefix -like '10.64.*' } | Select-Object InterfaceAlias,DestinationPrefix,NextHop,RouteMetric);
               neighbors = @(Get-NetNeighbor -AddressFamily IPv4 | Where-Object IPAddress -In @('10.64.0.1','10.64.0.10') | Select-Object InterfaceAlias,IPAddress,LinkLayerAddress,State);
               switches = @(Get-VMSwitch | Select-Object Name,Id,SwitchType);
               firewallProfiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction) }
        }
        @{ name = $vm.Name; vmId = $vm.Id.ToString(); guest = $guest;
           adapters = @(Get-VMNetworkAdapter -VM $vm | Select-Object Name,MacAddress,SwitchId,MacAddressSpoofing,AllowTeaming);
           vlans = @(Get-VMNetworkAdapter -VM $vm | Get-VMNetworkAdapterVlan | Select-Object VMName,VMNetworkAdapterName,OperationMode,NativeVlanId,AllowedVlanIdList,AccessVlanId) }
    } finally { if ($session) { Remove-PSSession $session }; $secure.Dispose() }
})
@{ atUtc = [datetime]::UtcNow.ToString('o'); nodes = $nodes; hostIcmpInboundRules = $icmpRules;
   hostProfiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction);
   hostNetworkProfiles = @(Get-NetConnectionProfile | Select-Object InterfaceAlias,NetworkCategory,IPv4Connectivity);
   hostAdapters = @(Get-NetAdapter | Select-Object Name,ifIndex,MacAddress,Status);
   hostIpv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias,IPAddress,PrefixLength,AddressState);
   hostNat = @(Get-NetNat | Select-Object Name,InternalIPInterfaceAddressPrefix,Active);
   hostRoutes = @(Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -or $_.DestinationPrefix -like '10.64.*' } | Select-Object InterfaceAlias,DestinationPrefix,NextHop,RouteMetric);
   mutationPerformed = $false; validationInvoked = $false } | ConvertTo-Json -Depth 13 -Compress
