# Exact human-approved host-local echo permission only. No existing rule changes.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected host' }
$request = [Net.HttpWebRequest]::Create('http://169.254.169.254/metadata/instance/compute/resourceId?api-version=2021-02-01&format=text')
$request.Proxy = $null; $request.Headers['Metadata'] = 'true'; $request.Timeout = 5000
$response = $request.GetResponse()
try { $reader = [IO.StreamReader]::new($response.GetResponseStream()); try { $hostId = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() } } finally { $response.Close() }
if ($hostId -ine '/subscriptions/8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea/resourceGroups/rg-localbox-nodes-san-1/providers/Microsoft.Compute/virtualMachines/LocalBox-Client') { throw 'Exact Azure host differs' }
$approvalBytes = [Convert]::FromBase64String('__GATEWAY_ECHO_APPROVAL_BASE64__')
$hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($approvalBytes)).Replace('-','')
if ($hash -cne '__GATEWAY_ECHO_APPROVAL_SHA256__') { throw 'Exact echo approval hash differs' }
$approval = [Text.Encoding]::UTF8.GetString($approvalBytes) | ConvertFrom-Json
$ruleName = 'AzureLocalBox-InternalGateway-Echo-v4'; $interface = 'vEthernet (LB-Fabric)'
$sources = @('10.64.0.11-10.64.0.13','10.64.0.20-10.64.0.30')
if ($approval.approved -ne $true -or $approval.humanAnswer -cne 'Approve scoped echo rule' -or $approval.ruleName -cne $ruleName -or $approval.interfaceAlias -cne $interface -or $approval.localAddress -cne '10.64.0.1' -or $approval.protocol -cne 'ICMPv4' -or $approval.icmpType -ne 8 -or ($approval.remoteAddress -join ',') -cne ($sources -join ',') -or $approval.direction -cne 'Inbound' -or $approval.action -cne 'Allow') { throw 'Exact scoped human approval differs' }
$gateway = @(Get-NetIPAddress -IPAddress '10.64.0.1' -AddressFamily IPv4)
$nat = @(Get-NetNat); $switch = Get-VMSwitch -Name LB-Fabric
if ($gateway.Count -ne 1 -or $gateway[0].InterfaceAlias -cne $interface -or $gateway[0].PrefixLength -ne 24 -or $switch.SwitchType.ToString() -cne 'Internal' -or $switch.Id.ToString() -cne '995f5a7a-d229-4ca0-bb2a-9b34529c6934' -or $nat.Count -ne 1 -or $nat[0].Name -cne 'LB-NAT' -or $nat[0].InternalIPInterfaceAddressPrefix -cne '10.64.0.0/20') { throw 'Exact owned internal gateway topology differs' }
if (@(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object { [string]$_.Enabled -ne 'True' }).Count -ne 0) { throw 'Firewall is not enabled on all profiles' }
function Read-ExactEchoRule {
    param([string]$PolicyStore)
    $rules = @(Get-NetFirewallRule -PolicyStore $PolicyStore -Name $ruleName -ErrorAction SilentlyContinue)
    if ($rules.Count -ne 1) { throw 'Exact one echo rule required' }
    $r = $rules[0]; $port = $r | Get-NetFirewallPortFilter; $addr = $r | Get-NetFirewallAddressFilter; $iface = $r | Get-NetFirewallInterfaceFilter
    if ([string]$r.Enabled -cne 'True' -or [string]$r.Direction -cne 'Inbound' -or [string]$r.Action -cne 'Allow' -or [string]$r.Profile -cne 'Any' -or [string]$port.Protocol -cne 'ICMPv4' -or (@($port.IcmpType) -join ',') -cne '8' -or (@($addr.LocalAddress) -join ',') -cne '10.64.0.1' -or (@($addr.RemoteAddress | Sort-Object) -join ',') -cne (@($sources | Sort-Object) -join ',') -or (@($iface.InterfaceAlias) -join ',') -cne $interface) { throw 'Echo rule scope differs. Never widen or overwrite it.' }
    @{ name = $r.Name; enabled = [string]$r.Enabled; direction = [string]$r.Direction; action = [string]$r.Action; profile = [string]$r.Profile; protocol = [string]$port.Protocol; icmpType = @($port.IcmpType); localAddress = @($addr.LocalAddress); remoteAddress = @($addr.RemoteAddress); interfaceAlias = @($iface.InterfaceAlias) }
}
$beforeIds = @(Get-NetFirewallRule -PolicyStore PersistentStore | ForEach-Object Name | Sort-Object)
$existing = @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $ruleName -ErrorAction SilentlyContinue)
$created = $false
if ($existing.Count -eq 0) {
    if (@(Get-NetFirewallRule -PolicyStore PersistentStore -Name $ruleName -ErrorAction SilentlyContinue).Count -ne 0) { throw 'Conflicting persistent rule exists' }
    $null = New-NetFirewallRule -PolicyStore PersistentStore -Name $ruleName -DisplayName 'AzureLocalBox internal gateway echo' -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol ICMPv4 -IcmpType 8 -InterfaceAlias $interface -LocalAddress '10.64.0.1' -RemoteAddress $sources
    $created = $true
} else { $null = Read-ExactEchoRule -PolicyStore PersistentStore }
$persistent = Read-ExactEchoRule -PolicyStore PersistentStore; $active = Read-ExactEchoRule -PolicyStore ActiveStore
$afterOtherIds = @(Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object Name -NE $ruleName | ForEach-Object Name | Sort-Object)
if ((@($beforeIds | Where-Object { $_ -cne $ruleName }) -join ',') -cne ($afterOtherIds -join ',')) { throw 'Unexpected other firewall rule identity effect' }
@{ atUtc = [datetime]::UtcNow.ToString('o'); status = 'exact-approved-echo-rule-verified'; created = $created; persistent = $persistent; effective = $active;
   approvalSha256 = $hash; existingRuleIdentitiesPreserved = $true; firewallProfilesChanged = $false; outerOrSharedNetworkChanged = $false; validationInvoked = $false } | ConvertTo-Json -Depth 7 -Compress
