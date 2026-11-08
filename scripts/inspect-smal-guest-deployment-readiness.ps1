# Read-only guest/licensing/onboarding inventory through exact VM IDs.
# No activation, update search/install, AD change, registration or token retrieval.
$ErrorActionPreference = 'Stop'
$bootRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$imageRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01'
$state = Get-Content (Join-Path $bootRoot 'state.json') -Raw | ConvertFrom-Json
if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or $state.status -ne 'local-bootstrap-configured-and-checked' -or (Get-ScheduledTaskInfo -TaskName 'LocalBox-GuestBootstrap-20261028-01').LastTaskResult -ne 0) { throw 'Completed local bootstrap proof missing' }
$bundle = Get-Content (Join-Path $bootRoot 'bundle.json') -Raw | ConvertFrom-Json
$secret = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
$helper = Join-Path $bootRoot 'smal-guest-secret-functions.ps1'
if ($secret.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $secret[0].sha256) { throw 'Secret helper source differs' }
. $helper
$targets = @(
    @{ name = 'LB-DC01'; id = 'f94c71f1-6854-48b9-a9f1-8238c99366d0'; role = 'dc-admin'; user = 'LOCALBOX\Administrator' },
    @{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34'; role = 'node01-admin'; user = 'LB-NODE01\Administrator' },
    @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3'; role = 'node02-admin'; user = 'LB-NODE02\Administrator' }
)
$results = @()
foreach ($target in $targets) {
    $vm = Get-VM -Id $target.id
    if ($vm.Name -cne $target.name -or $vm.State.ToString() -ne 'Running') { throw 'Guest identity/state differs' }
    $secretDirectory = Join-Path $imageRoot 'secrets'; $secretRole = $target.role
    $bindingPath = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json'
    if ($target.name -ne 'LB-DC01' -and (Test-Path $bindingPath)) {
        $bindings = Get-Content $bindingPath -Raw | ConvertFrom-Json
        $binding = $bindings.nodes.PSObject.Properties[$target.name].Value
        if ($binding) {
            if ($bindings.runId -ne 'cluster-prereqs-20261028-01' -or $binding.vmId -ine $target.id -or $binding.loginVerified -ne $true -or $binding.role -cne 'cluster-node-admin' -or $binding.secretDirectory -cne 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets') { throw 'Verified cluster credential binding differs' }
            $secretDirectory = $binding.secretDirectory; $secretRole = $binding.role
        }
    }
    $secure = Read-LabGuestSecureSecret -SecretDirectory $secretDirectory -Role $secretRole
    $session = $null
    try {
        $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new($target.user, $secure)) -ErrorAction Stop
        $results += Invoke-Command -Session $session -ArgumentList $target.name -ErrorAction Stop -ScriptBlock {
            param($ExpectedName)
            $ErrorActionPreference = 'Stop'
            if ($env:COMPUTERNAME -cne $ExpectedName) { throw 'Guest name differs' }
            $version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
            $licenses = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" | Where-Object { $_.PartialProductKey } | ForEach-Object {
                # Installed-key presence selects the OS record. Never return the key.
                @{ name = $_.Name; description = $_.Description; id = $_.ID; licenseStatus = $_.LicenseStatus; graceMinutes = $_.GracePeriodRemaining; statusReasonHex = $_.LicenseStatusReason.ToString('X8') }
            })
            $commands = @('Invoke-AzStackHciArcInitialization', 'Get-ArcBootstrapStatus', 'Get-VMHost', 'Get-NetIntent', 'New-HciAdObjectsPreCreation') | ForEach-Object {
                $command = Get-Command $_ -ErrorAction SilentlyContinue
                @{ name = $_; available = [bool]$command; module = $command.ModuleName; version = $(if ($command.Module) { $command.Module.Version.ToString() } else { $null }); sourceSha256 = $(if ($command.Module -and $command.Module.Path -and (Test-Path $command.Module.Path)) { (Get-FileHash $command.Module.Path).Hash } else { $null }); parameters = $(if ($command) { @($command.Parameters.Keys | Where-Object { $_ -notmatch '(?i:password|access_token|refresh_token|ArmAccessToken)' } | Sort-Object) } else { @() }) }
            }
            $result = @{ name = $env:COMPUTERNAME; atUtc = [datetime]::UtcNow.ToString('o'); product = $version.ProductName; edition = $version.EditionID; build = ($version.CurrentBuild + '.' + $version.UBR); licenses = $licenses; commands = @($commands); updatesInstalled = @(Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 8 HotFixID, InstalledOn); updateApplicabilityAssessed = $false; defenderEnabled = (Get-MpComputerStatus).RealTimeProtectionEnabled; firewallProfilesEnabled = @(Get-NetFirewallProfile | Where-Object Enabled -NE $true).Count -eq 0; domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole }
            $result.platformPrivateEndpoints = @()
            foreach ($endpoint in @(@{ name = 'kv-lbox-weu-4766ea.vault.azure.net'; ip = '10.200.17.11' }, @{ name = 'stlboxdiagweu4766ea.blob.core.windows.net'; ip = '10.200.17.9' }, @{ name = 'stlboxwitweu4766ea.blob.core.windows.net'; ip = '10.200.17.10' })) {
                $row = @{ fqdn = $endpoint.name; expectedIp = $endpoint.ip; actualIps = @(); privateDnsMatched = $false; httpsStatus = $null; normalTlsHttpResponseVerified = $false; authenticatedDataAccessTested = $false }
                try { $row.actualIps = @(Resolve-DnsName -Name $endpoint.name -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object IPAddress | ForEach-Object IPAddress); $row.privateDnsMatched = $row.actualIps.Count -eq 1 -and $row.actualIps[0] -ceq $endpoint.ip } catch { }
                if ($row.privateDnsMatched) {
                    $request = [Net.HttpWebRequest]::Create('https://' + $endpoint.name + '/')
                    $request.Method = 'HEAD'; $request.AllowAutoRedirect = $false; $request.UseDefaultCredentials = $false; $request.Timeout = 15000
                    try { $response = $request.GetResponse(); try { $row.httpsStatus = [int]$response.StatusCode } finally { $response.Close() } }
                    catch [Net.WebException] { if ($_.Exception.Response) { $row.httpsStatus = [int]$_.Exception.Response.StatusCode; $_.Exception.Response.Close() } }
                    $row.normalTlsHttpResponseVerified = $null -ne $row.httpsStatus
                }
                $result.platformPrivateEndpoints += $row
            }
            if ($ExpectedName -eq 'LB-DC01') {
                Import-Module ActiveDirectory
                $result.preexistingTargetOu = @(Get-ADOrganizationalUnit -Filter "Name -eq 'AzureLocal' -or Name -eq 'LocalBox'" | Select-Object Name, DistinguishedName)
                $result.preexistingDeploymentUser = @(Get-ADUser -Filter "SamAccountName -eq 'lboxdeploy'" | Select-Object SamAccountName, Enabled, DistinguishedName)
                $result.dnsForwarders = @((Get-DnsServerForwarder).IPAddress | ForEach-Object { $_.ToString() })
                $result.useRootHints = (Get-DnsServerForwarder).UseRootHint
            } else {
                $result.disks = @(Get-Disk | Select-Object Number, UniqueId, Size, IsBoot, IsSystem, PartitionStyle)
                $result.nonPrimordialStoragePoolCount = @(Get-StoragePool -ErrorAction SilentlyContinue | Where-Object IsPrimordial -EQ $false).Count
                if (Get-Command Get-NetIntent -ErrorAction SilentlyContinue) { $result.networkIntents = @(Get-NetIntent -ErrorAction SilentlyContinue | Select-Object IntentName) }
            }
            return $result
        }
    } finally { if ($session) { Remove-PSSession -Session $session }; $secure.Dispose() }
}
@{ hostUtc = [datetime]::UtcNow.ToString('o'); guests = $results; activationPerformed = $false; updateInstallPerformed = $false; registrationPerformed = $false; credentialsExported = $false; clusterBootstrapComplete = $false } | ConvertTo-Json -Depth 9 -Compress
