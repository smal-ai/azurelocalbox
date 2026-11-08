# Read-only DC DNS/DHCP/L2 observations. No address allocation or network repair.
$ErrorActionPreference = 'Stop'
$session = $null; $secure = $null
try {
    if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Wrong host' }
    $dc = Get-VM -Id 'f94c71f1-6854-48b9-a9f1-8238c99366d0'
    if ($dc.Name -cne 'LB-DC01' -or $dc.State.ToString() -cne 'Running') { throw 'Exact Running DC required' }
    $boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
    $old = Get-Content (Join-Path $boot 'state.json') -Raw | ConvertFrom-Json
    if ($old.status -cne 'local-bootstrap-configured-and-checked' -or $old.newCredentialLoginVerified.'LB-DC01' -ne $true) { throw 'Existing DC credential proof differs' }
    $bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
    $entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
    $helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
    if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Existing secret helper differs' }
    . $helper
    $secure = Read-LabGuestSecureSecret -SecretDirectory 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01\secrets' -Role 'dc-admin'
    $session = New-PSSession -VMId $dc.Id -Credential ([pscredential]::new('LOCALBOX\Administrator', $secure)) -ErrorAction Stop
    $result = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -cne 'LB-DC01' -or -not [Security.Principal.WindowsIdentity]::GetCurrent().User.Value.EndsWith('-500') -or (Get-ADDomain).DNSRoot -cne 'ad.localbox.test') { throw 'Exact DC domain/RID 500 differs' }
        $dhcp = Get-Service DHCPServer -ErrorAction SilentlyContinue
        $r = @{ ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceIndex, InterfaceAlias, IPAddress, PrefixLength)
            neighbors = @(Get-NetNeighbor -AddressFamily IPv4 | Select-Object InterfaceIndex, IPAddress, LinkLayerAddress, State)
            dnsA = @(Get-DnsServerResourceRecord -ZoneName ad.localbox.test -RRType A | ForEach-Object { @{ name = $_.HostName; address = $_.RecordData.IPv4Address.IPAddressToString } })
            dhcpInstalled = $null -ne $dhcp; dhcpScopes = @(); dhcpLeases = @(); dhcpReservations = @()
            addressReservationVerified = $false; limitation = 'Absence of echo or neighbour/DNS/DHCP data does not prove an address unused. Authoritative NETWORK ownership reconciliation remains necessary.' }
        if ($dhcp) {
            $scopes = @(Get-DhcpServerv4Scope)
            $r.dhcpScopes = @($scopes | Select-Object ScopeId, StartRange, EndRange, State)
            $r.dhcpLeases = @($scopes | ForEach-Object { Get-DhcpServerv4Lease -ScopeId $_.ScopeId } | Select-Object IPAddress, AddressState, ClientId)
            $r.dhcpReservations = @($scopes | ForEach-Object { Get-DhcpServerv4Reservation -ScopeId $_.ScopeId } | Select-Object IPAddress, ClientId)
        }
        $addresses = @((100..180) + (200..209) + (1, 10, 11, 12, 13) | ForEach-Object { '10.64.0.' + $_ })
        $probes = @($addresses | ForEach-Object { $ping = [Net.NetworkInformation.Ping]::new(); @{ address = $_; ping = $ping; task = $ping.SendPingAsync($_, 500) } })
        try {
            [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($probes.task), 3000) | Out-Null
            $r.echo = @($probes | ForEach-Object { @{ address = $_.address; completed = $_.task.IsCompleted; status = $(if ($_.task.Status.ToString() -ceq 'RanToCompletion') { $_.task.Result.Status.ToString() } else { 'Unknown' }) } })
        } finally { foreach ($probe in $probes) { $probe.ping.Dispose() } }
        $r.neighborsAfter = @(Get-NetNeighbor -AddressFamily IPv4 | Select-Object InterfaceIndex, IPAddress, LinkLayerAddress, State)
        return $r
    }
    @{ status = 'complete'; atUtc = [datetime]::UtcNow.ToString('o'); observerPart = 'dc'; mutationPerformed = $false; dcNetwork = $result } | ConvertTo-Json -Depth 12 -Compress
} catch {
    @{ status = 'failed-read-only'; atUtc = [datetime]::UtcNow.ToString('o'); mutationPerformed = $false; errorType = $_.Exception.GetType().Name; errorLine = $_.InvocationInfo.ScriptLineNumber } | ConvertTo-Json -Compress
} finally { if ($session) { Remove-PSSession $session }; if ($secure) { $secure.Dispose() } }
