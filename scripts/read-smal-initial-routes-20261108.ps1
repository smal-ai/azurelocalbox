# Return route to the protected outer fabric address, plus six base probes only.
# Join this literal target to the measured outer selected source before claiming coverage.
$ErrorActionPreference = 'Stop'
$plan = [pscustomobject]@{ guestIds = [pscustomobject]@{
    'LB-NODE01' = '3adff629-2f67-449b-ab32-8a8748c46f34'
    'LB-NODE02' = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3'
    'LB-NODE03' = '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9'
} }
$began = [datetime]::UtcNow.ToString('o')
$nodes = @{}
foreach ($name in @('LB-NODE01','LB-NODE02','LB-NODE03')) {
    $session = New-ComputeSession $name
    try {
        $nodes[$name] = Invoke-Command -Session $session -ArgumentList $name,${function:Read-InitialField}.ToString(),${function:Select-InitialFields}.ToString(),${function:Read-InitialQuery}.ToString(),${function:Assert-InitialNode}.ToString() -ScriptBlock {
            param($expected,$field,$select,$query,$assert)
            $ErrorActionPreference = 'Stop'
            Set-Item Function:Read-InitialField ([scriptblock]::Create($field)); Set-Item Function:Select-InitialFields ([scriptblock]::Create($select))
            Set-Item Function:Read-InitialQuery ([scriptblock]::Create($query)); Set-Item Function:Assert-InitialNode ([scriptblock]::Create($assert))
            Assert-InitialNode $expected
            $queries = @()
            $queries += Read-InitialQuery 'currentManagementFabric' {
                $address = '10.64.0.' + (10 + [int]$expected.Substring($expected.Length - 2))
                $ip = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -EQ $address)
                if ($ip.Count -ne 1) { throw 'Exact current management address differs' }
                @{ ipv4 = Select-InitialFields $ip[0] @('InterfaceIndex','InterfaceAlias','IPAddress','PrefixLength')
                    adapter = @(Get-NetAdapter | Where-Object InterfaceIndex -EQ $ip[0].InterfaceIndex | ForEach-Object { Select-InitialFields $_ @('InterfaceIndex','Name','Status','MacAddress','LinkSpeed') })
                    defaultRoutes = @(Get-NetRoute -AddressFamily IPv4 | Where-Object DestinationPrefix -EQ '0.0.0.0/0' | ForEach-Object { Select-InitialFields $_ @('InterfaceIndex','DestinationPrefix','NextHop','RouteMetric') })
                    dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object InterfaceIndex -EQ $ip[0].InterfaceIndex | ForEach-Object ServerAddresses)
                    switches = @(Get-VMSwitch | Where-Object Name -EQ 'ConvergedSwitch(managementcompute)' | ForEach-Object { @{ name = $_.Name; id = $_.Id.ToString(); type = $_.SwitchType.ToString() } })
                    managementVlans = @(Get-VMNetworkAdapter -ManagementOS | ForEach-Object { $vlan = $_ | Get-VMNetworkAdapterVlan; @{ name = $_.Name; switchName = $_.SwitchName; mode = $vlan.OperationMode.ToString(); accessVlanId = $vlan.AccessVlanId; nativeVlanId = $vlan.NativeVlanId } }) }
            }
            $queries += Read-InitialQuery 'returnSelectionToProtectedOuterFabricAddress' { Find-NetRoute -RemoteIPAddress '10.64.0.1' | ForEach-Object { Select-InitialFields $_ @('InterfaceIndex','InterfaceAlias','IPAddress','PrefixLength','DestinationPrefix','NextHop','RouteMetric') } }
            $queries += Read-InitialQuery 'baseGatewayEcho' { $ping = [Net.NetworkInformation.Ping]::new(); try { $reply = $ping.Send('10.64.0.1',1000); @{ target = '10.64.0.1'; status = $reply.Status.ToString(); roundtripMilliseconds = $reply.RoundtripTime } } finally { $ping.Dispose() } }
            $queries += Read-InitialQuery 'baseDnsOwnFqdn' { Resolve-DnsName -Name ($expected + '.ad.localbox.test') -Server '10.64.0.10' -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object IPAddress | ForEach-Object { @{ server = '10.64.0.10'; name = $_.Name; address = $_.IPAddress } } }
            return @{ scope = $expected; targetOuterFabricAddress = '10.64.0.1'; queries = $queries }
        } -ErrorAction Stop
    } finally { Remove-PSSession -Session $session }
}
@{ status = $(if (@($nodes.Values | ForEach-Object queries | Where-Object complete -EQ $false).Count) { 'partial-read-only' } else { 'complete' }); beganAtUtc = $began; finishedAtUtc = [datetime]::UtcNow.ToString('o'); mutationPerformed = $false; nodes = $nodes } | ConvertTo-Json -Depth 18 -Compress
