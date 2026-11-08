# Read-only post-deployment inspection. Never resets credentials, storage or services.
$ErrorActionPreference = 'Stop'
$phase = 'host-identity'
try {
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected host' }
$targets = @(@{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34' }, @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' }, @{ name = 'LB-NODE03'; id = '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9' })
$boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
$entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1'); $helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Secret helper differs' }
. $helper
$store = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'
$bindings = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw | ConvertFrom-Json
$nodes = @(foreach ($target in $targets) {
    $vm = Get-VM -Id $target.id; $binding = $bindings.nodes.PSObject.Properties[$target.name].Value
    if ($vm.Name -cne $target.name -or $vm.State.ToString() -ne 'Running' -or $binding.vmId -ine $target.id -or $binding.role -cne 'cluster-node-admin' -or $binding.secretDirectory -cne $store -or $binding.loginVerified -ne $true) { throw 'Exact running guest/credential binding differs' }
    $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'; $session = $null
    try {
        $phase = $target.name + '-credential-session'
        # Documented post-deployment name of RID 500. One attempt, no fallback or reset.
        $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($vm.Name + '\ASBuiltInAdmin'), $secure)) -ErrorAction Stop
        $phase = $target.name + '-cluster-storage-inspection'
        $guest = Invoke-Command -Session $session -ArgumentList $target.name -ErrorAction Stop -ScriptBlock {
            param($ExpectedName)
            $ErrorActionPreference = 'Stop'
            if ($env:COMPUTERNAME -cne $ExpectedName) { throw 'Guest identity differs' }
            $admin = Get-LocalUser -Name ASBuiltInAdmin
            if (-not $admin.Enabled -or -not $admin.SID.Value.EndsWith('-500') -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $admin.SID.Value) { throw 'Expected existing RID 500 identity differs' }
            $cluster = Get-Cluster -Name smal-localbox01 -ErrorAction Stop
            $quorum = Get-ClusterQuorum -Cluster $cluster
            $s2d = Get-ClusterStorageSpacesDirect -Node $ExpectedName
            $pools = @(Get-StoragePool | Where-Object IsPrimordial -EQ $false | ForEach-Object {
                $pool = $_
                @{ name = $pool.FriendlyName; uniqueId = $pool.UniqueId; health = $pool.HealthStatus.ToString(); operationalStatus = @($pool.OperationalStatus | ForEach-Object ToString); size = $pool.Size; allocated = $pool.AllocatedSize;
                   members = @($pool | Get-PhysicalDisk | ForEach-Object { @{ uniqueId = $_.UniqueId; size = $_.Size; usage = $_.Usage.ToString(); health = $_.HealthStatus.ToString(); mediaType = $_.MediaType.ToString() } }) }
            })
            @{ name = $env:COMPUTERNAME; observedAdmin = @{ name = $admin.Name; sid = $admin.SID.Value; enabled = $admin.Enabled }; domain = (Get-CimInstance Win32_ComputerSystem).Domain; domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole;
               clusterName = $cluster.Name; clusterNodes = @(Get-ClusterNode -Cluster $cluster | ForEach-Object { @{ name = $_.Name; state = $_.State.ToString(); nodeWeight = $_.NodeWeight; dynamicWeight = $_.DynamicWeight } });
               quorumType = $quorum.QuorumType.ToString(); quorumResourceName = $(if ($quorum.QuorumResource) { [string]$quorum.QuorumResource.Name } else { $null });
               storageSpacesDirectState = [string]$s2d.State; storagePools = $pools;
               virtualDisks = @(Get-VirtualDisk | ForEach-Object { @{ name = $_.FriendlyName; uniqueId = $_.UniqueId; health = $_.HealthStatus.ToString(); size = $_.Size; footprint = $_.FootprintOnPool; resiliency = $_.ResiliencySettingName; dataCopies = $_.NumberOfDataCopies; provisioning = $_.ProvisioningType.ToString() } });
               csv = @(Get-ClusterSharedVolume -Cluster $cluster | ForEach-Object { @{ name = $_.Name; state = $_.State.ToString(); owner = [string]$_.OwnerNode.Name;
                   volumes = @($_.SharedVolumeInfo | ForEach-Object { @{ path = $_.FriendlyVolumeName; size = $_.Partition.Size; free = $_.Partition.FreeSpace } }) } });
               storageJobs = @(Get-StorageJob | ForEach-Object { @{ name = $_.Name; state = [string]$_.JobState; percentComplete = $_.PercentComplete } });
               localDisks = @(Get-Disk | ForEach-Object { @{ uniqueId = $_.UniqueId; size = $_.Size; isBoot = $_.IsBoot; isSystem = $_.IsSystem } });
               encryption = @(Get-BitLockerVolume | ForEach-Object { @{ mountPoint = $_.MountPoint; volumeType = [string]$_.VolumeType; protectionStatus = [string]$_.ProtectionStatus; encryptionPercentage = $_.EncryptionPercentage; volumeStatus = [string]$_.VolumeStatus } });
               clusterGroups = @(Get-ClusterGroup -Cluster $cluster | ForEach-Object { @{ name = $_.Name; state = $_.State.ToString(); owner = [string]$_.OwnerNode.Name } });
               nestedVms = @(Get-VM | ForEach-Object { @{ name = $_.Name; id = $_.Id.ToString(); state = $_.State.ToString(); memoryBytes = $_.MemoryAssigned } });
               defenderEnabled = (Get-MpComputerStatus).RealTimeProtectionEnabled; firewallEnabled = @(Get-NetFirewallProfile | Where-Object Enabled -NE $true).Count -eq 0;
               services = @(Get-Service -Name himds,GCArcService,ExtensionService,vmms,clussvc -ErrorAction SilentlyContinue | ForEach-Object { @{ name = $_.Name; state = $_.Status.ToString() } }) }
        }
        @{ name = $vm.Name; vmId = $vm.Id.ToString(); state = $vm.State.ToString(); guest = $guest }
    } finally { if ($session) { Remove-PSSession $session }; $secure.Dispose() }
})
$phase = 'outer-storage-inspection'
@{ atUtc = [datetime]::UtcNow.ToString('o'); observationStatus = 'complete-read-only'; nodes = $nodes; outerPool = @(Get-StoragePool -FriendlyName LocalBoxPool | ForEach-Object { @{ uniqueId = $_.UniqueId; health = $_.HealthStatus.ToString(); memberCount = @($_ | Get-PhysicalDisk).Count } });
   volumes = @(Get-Volume | Where-Object DriveLetter -In @('C','V','W','X') | ForEach-Object { @{ letter = [string]$_.DriveLetter; uniqueId = $_.UniqueId; size = $_.Size; free = $_.SizeRemaining; health = $_.HealthStatus.ToString() } });
   credentialsReset = $false; mutationPerformed = $false; platformReadinessVerified = $false } | ConvertTo-Json -Depth 14 -Compress
} catch {
    # Never emit raw exception messages, command arguments or credential objects.
    @{ observationStatus = 'failed-safe-diagnostic'; phase = $phase; errorType = $_.Exception.GetType().Name;
       errorCategory = [string]$_.CategoryInfo.Category; sourceLine = $_.InvocationInfo.ScriptLineNumber;
       credentialsReset = $false; mutationPerformed = $false; platformReadinessVerified = $false } | ConvertTo-Json -Compress
}
