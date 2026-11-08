# Approved local Internal switch and WinNAT only. No outer adapter/route changes.
$ErrorActionPreference = 'Stop'
function Test-LabPrefixOverlap {
    param([string]$Prefix)
    $parts = $Prefix.Split('/')
    $bits = [int]$parts[1]
    if ($bits -eq 0) { return $false }
    if ($bits -lt 1 -or $bits -gt 32) { throw 'Invalid IPv4 route prefix' }
    $bytes = [Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
    if ($bytes.Length -ne 4) { throw 'IPv4 prefix required' }
    $address = [uint64]$bytes[0] * 16777216 + [uint64]$bytes[1] * 65536 + [uint64]$bytes[2] * 256 + [uint64]$bytes[3]
    $mask = [uint64]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $bits))
    $first = $address -band $mask
    $last = $first + [uint64]([math]::Pow(2, 32 - $bits) - 1)
    $labFirst = [uint64](10 * 16777216 + 64 * 65536)
    $labLast = $labFirst + 4095
    return ($first -le $labLast -and $last -ge $labFirst)
}
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\local-network-20261028-01'
$switchName = 'LB-Fabric'; $natName = 'LB-NAT'
if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or (Test-Path $root)) { throw 'Unexpected target or existing network attempt. Inspect, never replay.' }
$request = [Net.HttpWebRequest]::Create('http://169.254.169.254/metadata/instance/compute/resourceId?api-version=2021-02-01&format=text')
$request.Proxy = $null; $request.Headers['Metadata'] = 'true'; $request.Timeout = 5000
$response = $request.GetResponse()
try { $reader = [IO.StreamReader]::new($response.GetResponseStream()); try { $vmId = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() } } finally { $response.Close() }
if ($vmId -ine '/subscriptions/8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea/resourceGroups/rg-localbox-nodes-san-1/providers/Microsoft.Compute/virtualMachines/LocalBox-Client') { throw 'Azure VM identity differs' }
if (@(Get-NetNat).Count -ne 0 -or @(Get-VMSwitch).Count -ne 0 -or @(Get-VM).Count -ne 0) { throw 'Existing NAT, switch or VM conflicts with approved initial state' }
# There must be no active or persisted container/HNS network to collide with WinNAT.
if ((Get-Service -Name hns -ErrorAction SilentlyContinue) -or (Test-Path 'C:\ProgramData\Microsoft\Windows\HNS\HNS.data')) { throw 'HNS requires separate reconciled network inventory' }
$outer = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -EQ '10.200.16.4')
if ($outer.Count -ne 1 -or $outer[0].PrefixLength -ne 24) { throw 'Outer source differs' }
$defaultsBefore = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Select-Object InterfaceIndex, NextHop, RouteMetric)
if ($defaultsBefore.Count -ne 1 -or $defaultsBefore[0].InterfaceIndex -ne $outer[0].InterfaceIndex -or $defaultsBefore[0].NextHop -ne '10.200.16.1') { throw 'Outer default route differs' }
$dnsBefore = (Get-DnsClientServerAddress -InterfaceIndex $outer[0].InterfaceIndex -AddressFamily IPv4).ServerAddresses -join ','
if ($dnsBefore -ne '10.204.0.4') { throw 'Outer DNS differs' }
foreach ($route in @(Get-NetRoute -AddressFamily IPv4)) { if (Test-LabPrefixOverlap $route.DestinationPrefix) { throw 'Existing route overlaps local infrastructure allocation' } }
if (-not (Get-MpComputerStatus).RealTimeProtectionEnabled) { throw 'Defender is not active' }
$null = New-Item $root -ItemType Directory
$acl = [Security.AccessControl.DirectorySecurity]::new(); $acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) { $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')) }
$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')); Set-Acl -Path $root -AclObject $acl
$statePath = Join-Path $root 'state.json'
$state = [ordered]@{ runId = 'local-network-20261028-01'; sourceCommit = '__SOURCE_COMMIT__'; scope = 'approved-local-internal-switch-and-nat-only'; status = 'running'; phase = 'prechecked'; atUtc = $null; switchId = $null; natInstanceId = $null; errorType = $null; defaultRouteAndDnsUnchanged = $false; nestedTrafficVerified = $false; clusterBootstrapComplete = $false }
function Save-NetworkState {
    param([string]$Phase)
    $state.phase = $Phase; $state.atUtc = (Get-Date).ToUniversalTime().ToString('o')
    $temporary = Join-Path $root 'state.json.tmp'
    [IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    if (Test-Path $statePath) { [IO.File]::Replace($temporary, $statePath, (Join-Path $root 'state.previous.json')) } else { [IO.File]::Move($temporary, $statePath) }
}
try {
    Save-NetworkState 'switch-create'
    $created = New-VMSwitch -Name $switchName -SwitchType Internal
    $state.switchId = $created.Id.ToString()
    if ($created.SwitchType.ToString() -ne 'Internal') { throw 'Created switch differs' }
    Save-NetworkState 'gateway-address-create'
    $adapter = Get-NetAdapter -Name ('vEthernet (' + $switchName + ')')
    if ($adapter.ifIndex -eq $outer[0].InterfaceIndex -or $adapter.HardwareInterface) { throw 'Internal switch interface identity differs' }
    $null = New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress '10.64.0.1' -PrefixLength 24 -AddressFamily IPv4
    # No default gateway, global router flag or DNS rewrite on the host's internal NIC.
    Save-NetworkState 'nat-create'
    $nat = New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix '10.64.0.0/20'
    $state.natInstanceId = $nat.InstanceID
    Save-NetworkState 'verify'
    $defaultsAfter = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Select-Object InterfaceIndex, NextHop, RouteMetric)
    $dnsAfter = (Get-DnsClientServerAddress -InterfaceIndex $outer[0].InterfaceIndex -AddressFamily IPv4).ServerAddresses -join ','
    if (($defaultsBefore | ConvertTo-Json -Compress) -cne ($defaultsAfter | ConvertTo-Json -Compress) -or $dnsBefore -cne $dnsAfter) { throw 'Outer route/DNS changed. Preserve and inspect.' }
    $actualNat = @(Get-NetNat)
    if ($actualNat.Count -ne 1 -or $actualNat[0].Name -cne $natName -or $actualNat[0].InternalIPInterfaceAddressPrefix -cne '10.64.0.0/20' -or @(Get-VMSwitch).Count -ne 1 -or (Get-VMSwitch -Name $switchName).Id -ne $created.Id) { throw 'Final local network identity differs' }
    if (@(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count -ne 0) { throw 'Unexpected internal default gateway' }
    $state.defaultRouteAndDnsUnchanged = $true; $state.status = 'local-network-created'; Save-NetworkState 'local-network-verified-no-guests'
    $state | ConvertTo-Json -Compress
} catch {
    $state.status = 'failed-inspect-before-resume'; $state.errorType = $_.Exception.GetType().Name
    try { Save-NetworkState $state.phase } catch { }
    throw
}
