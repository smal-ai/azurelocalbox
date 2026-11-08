__THREE_NODE_PRELUDE__
# Two exact existing guests only. No replacement VM/OS, registration or data format.
$ErrorActionPreference = 'Stop'
if ($approval.existingNodeGracefulStopsAnd64GiB8VcpuProfilesApproved -ne $true) { throw 'Existing guest resize approval missing' }
$diskProof = Get-Content (Join-Path $threeRoot 'new-disk-format.json') -Raw | ConvertFrom-Json
if ($diskProof.status -cne 'complete-new-lun8-only-formatted-w' -or (Get-Volume -DriveLetter W).UniqueId -cne $diskProof.volumeId -or (Get-Volume -DriveLetter W).SizeRemaining -lt 1258GB -or (Get-Volume -DriveLetter V).SizeRemaining -lt 200GB) { throw 'New W capacity/identity differs' }
$boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
$secret = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
$helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
if ($secret.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $secret[0].sha256) { throw 'Secret helper differs' }
. $helper
$store = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'
$bindings = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw | ConvertFrom-Json
$targets = @(@{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34' }, @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' })
if (@(Get-VM).Count -ne 3) { throw 'Unexpected guest set before approved existing-node phase' }
foreach ($target in $targets) {
    $vm = Get-VM -Id $target.id; $binding = $bindings.nodes.PSObject.Properties[$target.name].Value
    if ($vm.Name -cne $target.name -or $vm.State.ToString() -ne 'Running' -or $vm.MemoryStartup -ne 96GB -or $vm.ProcessorCount -ne 12 -or $binding.vmId -ine $target.id -or $binding.loginVerified -ne $true -or $binding.role -cne 'cluster-node-admin' -or $binding.secretDirectory -cne $store) { throw 'Exact current VM profile/credential binding differs' }
}
$move = $proposal.existingVhdRelocation
if ($move.vmName -cne 'LB-NODE01' -or $move.vmId -ine $targets[0].id -or $move.lun -ne 4 -or (Test-Path -LiteralPath $move.destination)) { throw 'Exact relocation target differs or destination exists' }
$sourceVhd = Get-VHD -Path $move.source
if ($sourceVhd.DiskIdentifier.ToString() -ine $move.diskIdPreserved -or $sourceVhd.Size -ne 170GB -or $sourceVhd.ParentPath) { throw 'Exact existing VHD identity differs' }
$marker = [IO.File]::Open((Join-Path $threeRoot 'existing-node-resize.started'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); $marker.Dispose()
$statePath = Join-Path $threeRoot 'existing-node-resize.json'
$state = @{ sourceCommit = $sourceCommit; status = 'running'; phase = 'prechecks'; nodes = @{}; registrationInvoked = $false; osReinstallPerformed = $false; dataFormattingPerformed = $false; dcChanged = $false }
function Save-ResizeState([string]$phase) { $state.phase = $phase; $state.atUtc = [datetime]::UtcNow.ToString('o'); [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 9), [Text.UTF8Encoding]::new($false)) }
function Wait-ExistingNode([object]$vm, [Security.SecureString]$secure) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 600) {
        $s = $null
        try {
            $s = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($vm.Name + '\Administrator'), $secure)) -ErrorAction Stop
            $ready = Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock { @{ name = $env:COMPUTERNAME; bootstrap = [string](Get-ArcBootstrapStatus).Response.Status; runningArcServices = @(Get-Service -Name himds,GCArcService,ExtensionService | Where-Object Status -EQ Running).Count } }
            if ($ready.name -cne $vm.Name) { throw 'Existing node identity differs' }
            if ($ready.bootstrap -eq 'Succeeded' -and $ready.runningArcServices -eq 3) { return $s }
        } catch { if ($_.CategoryInfo.Category.ToString() -in @('AuthenticationError','SecurityError') -or $_.FullyQualifiedErrorId -match 'InvalidCredential|AccessDenied|LogonFailure') { if ($s) { Remove-PSSession $s }; throw 'Authentication failed. No repeated login attempts.' } }
        if ($s) { Remove-PSSession $s }; Start-Sleep -Seconds 5
    }
    throw 'Existing node bootstrap/Arc readiness limit reached. Inspect state, do not replay resize.'
}
$session = $null; $secure = $null
try {
    Save-ResizeState 'verify-current-standalone-node-disks'
    $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'
    foreach ($target in $targets) {
        $vm = Get-VM -Id $target.id
        $session = Wait-ExistingNode $vm $secure
        $before = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ne 2 -or @(Get-StoragePool | Where-Object IsPrimordial -EQ $false).Count -ne 0) { throw 'Node no longer standalone/blank' }
            @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem } | ForEach-Object { @{ uniqueId = $_.UniqueId; style = $_.PartitionStyle.ToString(); size = $_.Size } })
        }
        if ($before.Count -ne 4 -or @($before | Where-Object { $_.style -ne 'RAW' -or $_.size -ne 170GB }).Count -ne 0) { throw 'Existing data disks are not four blank 170 GiB devices' }
        $oldProposal = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\arc-console-20261028-01\approval.json' -Raw | ConvertFrom-Json
        $allow = if ($target.name -eq 'LB-NODE01') { @('6002248018A9EA3E37A91804553ABFEE','60022480D47B1977B201A09A9AD85C7E','600224805454A96E242F3C38305128AC','600224801E3FB24517D8C5F2124F7E30') } else { @('6002248065ACD99B54C87E76586527CA','600224801933BE540257E4937DA41512','6002248037A2A230372B3EC87A9D3377','600224802DF5A6C7E8F6062832A93BAC') }
        if (@(Compare-Object @($allow | Sort-Object) @($before.uniqueId | Sort-Object)).Count -ne 0) { throw 'Original exact data-disk allowlist differs' }
        Remove-PSSession $session; $session = $null
        Save-ResizeState ($target.name + '-graceful-stop-pending')
        Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop
        $vm = Get-VM -Id $target.id
        if ($vm.State.ToString() -ne 'Off') { throw 'Guest did not gracefully stop. No forced turn-off.' }
        Save-ResizeState ($target.name + '-set-approved-64gib-8vcpu')
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes 64GB
        Set-VMProcessor -VM $vm -Count 8 -ExposeVirtualizationExtensions $true
        if ($target.name -eq 'LB-NODE01') {
            $attached = @(Get-VMHardDiskDrive -VM $vm | Where-Object { $_.ControllerNumber -eq 0 -and $_.ControllerLocation -eq 4 })
            if ($attached.Count -ne 1 -or $attached[0].Path -cne $move.source) { throw 'Exact LUN4 source attachment differs' }
            $parent = Split-Path $move.destination
            if (Test-Path -LiteralPath $parent) { throw 'Relocation directory already exists' }
            $null = New-Item $parent -ItemType Directory -Force
            Set-Acl $parent (Get-Acl $threeRoot)
            $state.relocationSourceSha256 = (Get-FileHash -LiteralPath $move.source).Hash
            Save-ResizeState 'LB-NODE01-only-approved-vhd-move-pending'
            Move-VMStorage -VM $vm -Vhds @(@{ SourceFilePath = $move.source; DestinationFilePath = $move.destination }) -RetainVhdCopiesOnSource -ErrorAction Stop
            $destination = Get-VHD -Path $move.destination
            $attached = @(Get-VMHardDiskDrive -VM $vm | Where-Object { $_.ControllerNumber -eq 0 -and $_.ControllerLocation -eq 4 })
            if ($destination.DiskIdentifier.ToString() -ine $move.diskIdPreserved -or $destination.Size -ne 170GB -or $attached.Count -ne 1 -or $attached[0].Path -cne $move.destination -or (Get-FileHash -LiteralPath $move.destination).Hash -cne $state.relocationSourceSha256) { throw 'Moved file/attachment identity/hash differs' }
        }
        Save-ResizeState ($target.name + '-start-and-verify-original-identity')
        Start-VM -VM $vm
        $session = Wait-ExistingNode (Get-VM -Id $target.id) $secure
        $verified = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            $hostInfo = Get-VMHost
            @{ name = $env:COMPUTERNAME; memoryBytes = $hostInfo.MemoryCapacity; logicalProcessors = $hostInfo.LogicalProcessorCount; bootstrap = [string](Get-ArcBootstrapStatus).Response.Status; disks = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem } | ForEach-Object { @{ uniqueId = $_.UniqueId; style = $_.PartitionStyle.ToString(); size = $_.Size } }) }
        }
        Remove-PSSession $session; $session = $null
        if ($verified.name -cne $target.name -or $verified.memoryBytes -lt 60GB -or $verified.logicalProcessors -ne 8 -or $verified.bootstrap -ne 'Succeeded' -or @(Compare-Object @($allow | Sort-Object) @($verified.disks.uniqueId | Sort-Object)).Count -ne 0 -or @($verified.disks | Where-Object style -NE RAW).Count -ne 0) { throw 'Resized node original identity/storage/bootstrap check failed' }
        if ($target.name -eq 'LB-NODE01' -and (Test-Path -LiteralPath $move.source)) {
            if ((Get-VHD -Path $move.source).Attached -or (Get-FileHash -LiteralPath $move.source).Hash -cne $state.relocationSourceSha256 -or @(Get-VM | Get-VMHardDiskDrive | Where-Object Path -CEQ $move.source).Count -ne 0) { throw 'Retained exact old copy is not eligible for approved post-verify cleanup' }
            Save-ResizeState 'remove-only-verified-detached-original-blank-copy'
            Remove-Item -LiteralPath $move.source -Force -ErrorAction Stop
            $state.originalBlankCopyRemovedAfterVerification = $true
        }
        $state.nodes[$target.name] = @{ vmId = $target.id; memoryBytes = 64GB; processors = 8; guest = $verified; originalDataIdsPreserved = $true }
        Save-ResizeState ($target.name + '-verified')
    }
    $v = Get-Volume -DriveLetter V; $w = Get-Volume -DriveLetter W
    if ($v.Size -lt 1874GB -or $w.Size -lt 1258GB -or $v.SizeRemaining -lt 200GB -or $w.SizeRemaining -lt 1088GB) { throw 'Approved volume growth/reserve budgets differ' }
    $state.status = 'complete-existing-nodes-64gib-8vcpu-and-one-vhd-relocated'; Save-ResizeState 'existing-identity-and-storage-preserved'
} catch { $state.status = 'failed-or-uncertain-inspect-before-resume'; $state.errorType = $_.Exception.GetType().Name; $state.errorLine = $_.InvocationInfo.ScriptLineNumber; Save-ResizeState $state.phase }
finally { if ($session) { Remove-PSSession $session }; if ($secure) { $secure.Dispose() } }
$state | ConvertTo-Json -Depth 9 -Compress
if ($state.status -ne 'complete-existing-nodes-64gib-8vcpu-and-one-vhd-relocated') { throw 'Resize/move incomplete. Preserve state and markers; do not replay.' }
