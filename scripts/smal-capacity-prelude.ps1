# Public approved context only. Importing this prelude changes nothing.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected outer host' }
$contextBytes = [Convert]::FromBase64String('__CAPACITY_CONTEXT_BASE64__')
if ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($contextBytes)).Replace('-','') -cne '__CAPACITY_CONTEXT_SHA256__') { throw 'Capacity context hash differs' }
$context = [Text.Encoding]::UTF8.GetString($contextBytes) | ConvertFrom-Json
$planBytes = [Convert]::FromBase64String($context.planBase64); $approvalBytes = [Convert]::FromBase64String($context.approvalBase64)
$plan = [Text.Encoding]::UTF8.GetString($planBytes) | ConvertFrom-Json
$approval = [Text.Encoding]::UTF8.GetString($approvalBytes) | ConvertFrom-Json
if ($approval.approved -ne $true -or $approval.humanAnswer -cne 'Approve supported addition' -or $approval.activeStorageTier -cne 'Standard_LRS' -or $approval.one4TiBDiskAndTwelve170GiBVhdxApproved -ne $true -or $approval.onlyNewBlankDiskFormattingApproved -ne $true -or $approval.oldDisksOrOsResizeApproved -ne $false -or [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($planBytes)).Replace('-','').ToLowerInvariant() -cne $approval.planSha256) { throw 'Exact additive capacity approval differs' }
if ($plan.newDisk.name -cne 'LocalBox-Client-Capacity-20261030' -or $plan.newDisk.sizeGiB -ne 4096 -or $plan.newDisk.sku -cne 'Standard_LRS' -or $plan.newDisk.lun -ne 9 -or $plan.newDisk.driveLetter -cne 'X' -or $plan.newDisk.joinOuterPool -ne $false -or $plan.targetDataDeviceCount -ne 24) { throw 'Exact approved disk/capacity effect differs' }
$capacityRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\capacity-expansion-20261030-01'
$sourceCommit = '__CAPACITY_SOURCE_COMMIT__'
$boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
$entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1'); $helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Secret helper differs' }
. $helper
function Assert-CapacityHost {
    if (@(Get-VM).Count -ne 4 -or (Get-VM -Id 'f94c71f1-6854-48b9-a9f1-8238c99366d0').Name -cne 'LB-DC01') { throw 'Exact four outer guests differ' }
    $pool = @(Get-StoragePool -FriendlyName LocalBoxPool)
    if ($pool.Count -ne 1 -or $pool[0].UniqueId -cne $plan.originalOuterPoolId -or $pool[0].HealthStatus.ToString() -cne 'Healthy' -or @($pool[0] | Get-PhysicalDisk).Count -ne 8 -or (Get-VirtualDisk -FriendlyName LocalBoxData).UniqueId -cne $plan.originalOuterVirtualDiskId) { throw 'Original outer pool identity/health differs' }
    foreach ($letter in @('C','V','W')) { if ((Get-Volume -DriveLetter $letter).HealthStatus.ToString() -cne 'Healthy') { throw 'Original outer volume is not Healthy' } }
}
function Read-CapacityOriginalVhds {
    $rows = @(foreach ($property in $plan.nodes.PSObject.Properties) {
        $name = $property.Name; $binding = $property.Value; $vm = Get-VM -Id $binding.vmId
        if ($vm.Name -cne $name -or $vm.State.ToString() -cne 'Running') { throw 'Exact running node differs' }
        $attached = @(Get-VMHardDiskDrive -VM $vm)
        if ($attached.Count -ne 5) { throw 'Original five-VHD topology differs' }
        foreach ($expected in $binding.originalDisks) {
            $drive = @($attached | Where-Object { $_.ControllerType.ToString() -eq 'SCSI' -and $_.ControllerNumber -eq 0 -and $_.ControllerLocation -eq $expected.lun })
            if ($drive.Count -ne 1 -or $drive[0].Path -ine $expected.path) { throw 'Original VHD attachment differs' }
            $vhd = Get-VHD -Path $drive[0].Path
            if ($vhd.DiskIdentifier.ToString() -ine $expected.vhdId -or $vhd.Size -ne $expected.sizeBytes -or $vhd.ParentPath) { throw 'Original VHD identity/size differs' }
            @{ name = $name; vmId = $vm.Id.ToString(); lun = $expected.lun; path = $vhd.Path; diskId = $vhd.DiskIdentifier.ToString(); size = $vhd.Size;
               type = $vhd.VhdType.ToString(); blockSize = $vhd.BlockSize; logicalSectorSize = $vhd.LogicalSectorSize; physicalSectorSize = $vhd.PhysicalSectorSize }
        }
    })
    return $rows
}
function Read-CapacityClusterBaseline {
    $store = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'
    $bindings = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw | ConvertFrom-Json
    $rows = @(foreach ($property in $plan.nodes.PSObject.Properties) {
        $name = $property.Name; $vm = Get-VM -Id $property.Value.vmId; $bound = $bindings.nodes.PSObject.Properties[$name].Value
        if ($bound.vmId -ine $vm.Id.ToString() -or $bound.role -cne 'cluster-node-admin' -or $bound.secretDirectory -cne $store -or $bound.loginVerified -ne $true) { throw 'Existing credential binding differs' }
        $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'; $session = $null
        try {
            $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($name + '\ASBuiltInAdmin'),$secure)) -ErrorAction Stop
            Invoke-Command -Session $session -ArgumentList $name -ErrorAction Stop -ScriptBlock {
                param($ExpectedName)
                $ErrorActionPreference = 'Stop'
                if ($env:COMPUTERNAME -cne $ExpectedName) { throw 'Guest identity differs' }
                $admin = Get-LocalUser ASBuiltInAdmin
                if (-not $admin.SID.Value.EndsWith('-500') -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $admin.SID.Value) { throw 'Expected existing RID 500 identity differs' }
                $pools = @(Get-StoragePool | Where-Object IsPrimordial -EQ $false)
                if ($pools.Count -ne 1) { throw 'Exactly one S2D pool required' }
                $pool = $pools[0]; $cluster = Get-Cluster -Name smal-localbox01
                @{ name = $env:COMPUTERNAME; clusterName = $cluster.Name; poolId = $pool.UniqueId; poolHealth = $pool.HealthStatus.ToString(); poolSize = $pool.Size;
                   members = @($pool | Get-PhysicalDisk | ForEach-Object { @{ uniqueId = $_.UniqueId; size = $_.Size; health = $_.HealthStatus.ToString() } });
                   clusterNodes = @(Get-ClusterNode -Cluster $cluster | ForEach-Object { @{ name = $_.Name; state = $_.State.ToString() } });
                   virtualDisks = @(Get-VirtualDisk | ForEach-Object { @{ name = $_.FriendlyName; uniqueId = $_.UniqueId; size = $_.Size; health = $_.HealthStatus.ToString() } });
                   storageJobs = @(Get-StorageJob | ForEach-Object { @{ name = $_.Name; state = [string]$_.JobState } }) }
            }
        } finally { if ($session) { Remove-PSSession $session }; $secure.Dispose() }
    })
    $oldIds = @($plan.nodes.PSObject.Properties | ForEach-Object { $_.Value.originalDisks | Where-Object eligibleForS2D -EQ $true | ForEach-Object guestUniqueId } | Sort-Object)
    foreach ($row in $rows) {
        if ($row.poolId -ine $plan.expectedS2dPoolId -or $row.poolHealth -cne 'Healthy' -or $row.members.Count -ne 12 -or @(Compare-Object $oldIds @($row.members.uniqueId | Sort-Object)).Count -ne 0 -or @($row.members | Where-Object health -NE 'Healthy').Count -ne 0 -or $row.clusterNodes.Count -ne 3 -or @($row.clusterNodes | Where-Object state -NE 'Up').Count -ne 0 -or @($row.virtualDisks | Where-Object health -NE 'Healthy').Count -ne 0 -or $row.storageJobs.Count -ne 0) { throw 'Original exact healthy idle cluster baseline differs' }
    }
    return $rows
}
function Save-CapacityState {
    param([string]$Path,$Record)
    $Record.atUtc = [datetime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($Path,($Record | ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
}
