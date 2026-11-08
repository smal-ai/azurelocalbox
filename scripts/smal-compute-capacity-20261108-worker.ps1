# Included in deterministic hash-pinned worker source, never executed in this preparation.
$ErrorActionPreference = 'Stop'
$capacityRoot = 'C:\ProgramData\AzureLocalBox\ComputeCapacity-R2-20261108-01'
$entry = $plan.transitionContract.stages.PSObject.Properties[$stage].Value
$state = @{ operationId = $plan.operationId; planSha256 = $planSha; sourceCommit = $sourceCommit
    key = $effectKey; stage = $stage; sourceSha256 = (Get-FileHash -LiteralPath $PSCommandPath).Hash
    pid = $PID; processStartedUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    phase = 'preflight'; sequence = 0; rpcInvoked = $false; rpcSucceeded = $false }
function Save-R2Worker([string]$phase) {
    $state.phase = $phase; $state.sequence++; $state.atUtc = [datetime]::UtcNow.ToString('o')
    $path = Join-Path $capacityRoot ('worker-' + $stage + '-event-' + $state.sequence + '.json')
    Write-ComputeNewJson $path $state
}
function Write-R2Completion($snapshot, [string]$path) {
    Assert-Compute ($snapshot.sourceCommit -ceq $sourceCommit) 'Completion snapshot execution source differs'
    $proof = @{ operationId = $plan.operationId; stage = $stage; key = $effectKey; planSha256 = $planSha; sourceCommit = $sourceCommit; atUtc = [datetime]::UtcNow.ToString('o')
        snapshot = $snapshot }
    Write-ComputeNewJson $path $proof
}
function Assert-R2Context($request, $operation) {
    Assert-Compute ($plan.operationId -ceq 'smal-compute-capacity-20261108-01' -and $request.operationId -ceq $plan.operationId -and $operation.operationId -ceq $plan.operationId -and $request.key -ceq $effectKey -and $request.stage -ceq $stage -and $request.planSha256 -ceq $planSha -and $request.sourceCommit -ceq $sourceCommit -and $operation.planSha256 -ceq $planSha -and $operation.sourceCommit -ceq $sourceCommit) 'Remote request/operation/source/writer fence differs'
}
function Assert-R2Snapshot($snapshot, $profiles, $states, $maintenanceProof = $null, [bool]$after = $false) {
    Assert-Compute ($snapshot.sourceCommit -ceq $sourceCommit) 'Snapshot execution source differs'
    $healthProfile = if ($after) { $entry.observeHealth } else { $entry.health }
    Assert-ComputeEqual $snapshot.hostStatic $plan.baseline.hostStatic 'Host static drift'
    Assert-ComputeEqual $snapshot.volumesStatic $plan.baseline.volumesStatic 'Volume drift'
    Assert-ComputeEqual @(Get-ComputeKeys $snapshot.states) @($plan.guestIds.PSObject.Properties.Name | Sort-Object) 'Guest identity set differs'
    foreach ($g in $snapshot.guestsStatic) {
        $expected = $profiles.PSObject.Properties[$g.name].Value
        Assert-Compute ($expected.cpu -eq $g.cpu -and $expected.memory -eq $g.memory -and $states.PSObject.Properties[$g.name].Value -ceq (Get-ComputeField $snapshot.states $g.name)) 'Profile/power stage differs'
        $original = @($plan.baseline.guestsStatic | Where-Object name -CEQ $g.name)[0]
        $copy = @{}; foreach ($key in (Get-ComputeKeys $g)) { $copy[$key] = Get-ComputeField $g $key }
        $copy.cpu = $original.cpu; $copy.memory = $original.memory
        Assert-ComputeEqual $copy $original 'VHD/NIC/TPM/non-profile drift'
    }
    foreach ($volume in $snapshot.volumes) {
        $budget = $plan.admission.volumeBudgets.PSObject.Properties[$volume.letter].Value
        Assert-Compute ($volume.health -ceq 'Healthy' -and $volume.free -ge $budget.freeFloorBytes -and ($budget.maximumVhdBytes + $budget.runtimeBytes + $budget.metadataBytes + $budget.freeFloorBytes) -le $volume.size) 'Maximum VHD/runtime/free admission failed'
    }
    $cap = $snapshot.hostCapacity
    $expectedCpu = if ($plan.route -ceq 'direct-full-outage-v1' -and $entry.recovery -eq $true -and $cap.logicalProcessors -cin @(32,64)) { $cap.logicalProcessors } else { $entry.hostCpu }
    $minimumMemory = if ($expectedCpu -eq 32) { 250GB } else { 500GB }
    Assert-Compute ($cap.logicalProcessors -eq $expectedCpu -and $cap.physicalCores -eq ($expectedCpu / 2) -and $cap.memoryBytes -ge $minimumMemory -and $cap.numa.Count -gt 0 -and ($cap.numa | Measure-Object logicalProcessors -Sum).Sum -eq $expectedCpu) 'Actual host CPU/RAM/NUMA differs'
    if ($entry.hostCpu -eq 64) { Assert-Compute ($cap.freeMemoryBytes -ge $plan.minimumOuterFreeMemoryBytes) 'Actual host free RAM insufficient' }
    Assert-Compute ($snapshot.volumes.Count -eq 4 -and $snapshot.guestsStatic.Count -eq 4) 'Exactly four volumes/guests required'
    if ($healthProfile -cne 'stopped') {
        if ($entry.node) {
            $current = @($snapshot.clusterHealth.nodeStates | Where-Object name -CEQ $entry.node)
            $clusterState = if ($after) { $entry.afterClusterState } else { $entry.beforeClusterState }
            Assert-Compute ($current.Count -eq 1 -and $current[0].state -ceq $clusterState) 'Selected-node phase differs'
        }
        $runningNames = @($plan.guestIds.PSObject.Properties.Name | Where-Object { $_ -cne 'LB-DC01' -and (Get-ComputeField $snapshot.states $_) -ceq 'Running' } | Sort-Object)
        Assert-ComputeEqual @(Get-ComputeKeys $snapshot.nodeCapacity) $runningNames 'Actual all-running-node capacity set differs'
        $placements = @()
        foreach ($name in $runningNames) {
            $capacity = Get-ComputeField $snapshot.nodeCapacity $name
            $expected = $profiles.PSObject.Properties[$name].Value
            Assert-Compute ($capacity.logicalProcessors -eq $expected.cpu -and $capacity.memoryBytes -ge ($expected.memory - 8GB) -and $capacity.numa.Count -gt 0 -and ($capacity.numa | Measure-Object logicalProcessors -Sum).Sum -eq $expected.cpu) 'Actual per-node CPU/RAM/NUMA differs'
            foreach ($vm in $capacity.bridgePlacement) { $placements += @{ node = $name; vm = $vm } }
        }
        Assert-Compute ($placements.Count -eq 1 -and $placements[0].vm.id -ceq $plan.infrastructureVmId -and $placements[0].vm.state -ceq 'Running') 'Global infrastructure placement differs'
        $resource = @($snapshot.clusterHealth.vmResources)
        Assert-Compute ($resource.Count -eq 1 -and $resource[0].vmIds.Count -eq 1 -and $resource[0].vmIds[0] -ceq $plan.infrastructureVmId -and $resource[0].ownerNode -ceq $placements[0].node -and $resource[0].state -ceq 'Online') 'Cluster VmID/actual owner mapping differs'
        foreach ($name in $runningNames) {
            $capacity = Get-ComputeField $snapshot.nodeCapacity $name
            $reserve = if ($name -ceq $placements[0].node) { 24GB } else { 16GB }
            Assert-Compute ($capacity.freeMemoryBytes -ge $reserve) 'Actual platform/infrastructure memory reserve insufficient'
        }
    }
    if ($healthProfile -ceq 'strict') {
        Assert-ComputeEqual $snapshot.clusterStatic $plan.baseline.clusterStatic 'Cluster/global infrastructure identity differs'
        $h = $snapshot.clusterHealth
        Assert-Compute ($h.devices.Count -eq 24 -and $h.nodeStates.Count -eq 3 -and $h.csvStates.Count -eq 4 -and $h.virtualDiskStates.Count -eq 5 -and $null -ne $h.activeStorageJobs -and $null -ne $h.unrelatedFailures) 'Complete exact storage-health observation required'
        Assert-ComputeEqual @($h.nodeStates.name | Sort-Object) @('LB-NODE01', 'LB-NODE02', 'LB-NODE03') 'Exact three node health identities required'
        Assert-ComputeEqual @($h.csvStates.id | Sort-Object) @($plan.baseline.clusterStatic.csv.id | Sort-Object) 'CSV health identities differ'
        Assert-ComputeEqual @($h.virtualDiskStates.id | Sort-Object) @($plan.baseline.clusterStatic.virtualDisks.id | Sort-Object) 'Mirror health identities differ'
        Assert-Compute ($h.poolHealth -ceq 'Healthy' -and @($h.nodeStates | Where-Object state -CNE 'Up').Count -eq 0 -and @($h.virtualDiskStates | Where-Object { $_.copies -ne 3 -or $_.health -cne 'Healthy' }).Count -eq 0) 'Actual pool/node/mirror health differs'
        Assert-Compute ($h.allNodesUp -and $h.allCsvOnline -and $h.allMirrorsHealthy -and $h.poolHealthy -and $h.quorumType -ceq 'Majority' -and $null -eq $h.witness -and $h.activeStorageJobs.Count -eq 0 -and $h.unrelatedFailures.Count -eq 0) 'Full health/no jobs required'
        Assert-Compute (@($h.devices | Where-Object { $_.health -cne 'Healthy' -or ($_.operational -join '|') -cne 'OK' -or $_.maintenance }).Count -eq 0 -and ($h.poolOperational -join '|') -ceq 'OK' -and @($h.virtualDiskStates | Where-Object { ($_.operational -join '|') -cne 'OK' }).Count -eq 0 -and @($h.csvStates | Where-Object accessible -NE $true).Count -eq 0) 'Healthy alone does not prove OK/accessibility'
        if ($plan.route -ceq 'direct-full-outage-v1') {
            Assert-ComputeEqual @($h.devices.id | Sort-Object) @($plan.baseline.clusterStatic.members.id | Sort-Object) 'Exact devices differ'
        } else {
            Assert-ComputeEqual @($h.devices.id | Sort-Object) @($plan.transitionContract.deviceOwners.PSObject.Properties.Name | Sort-Object) 'Exact devices differ'
            foreach ($d in $h.devices) { Assert-Compute ($plan.transitionContract.deviceOwners.PSObject.Properties[$d.id].Value -ceq $d.owner) 'Device ownership differs' }
        }
        Assert-Compute ($h.physicalFreeBytes -ge ($plan.admission.requiredPhysicalFreeBytes + $plan.admission.repairReserveBytes)) 'Physical reserve violated'
    } elseif ($healthProfile -ceq 'maintenance') {
        $proof = if ($null -ne $maintenanceProof) { $maintenanceProof } else { Get-Content (Join-Path $capacityRoot ('drain-proof-' + $entry.node + '.json')) -Raw | ConvertFrom-Json }
        Assert-ComputeMaintenanceHealth $snapshot $entry.node $proof ([bool]$entry.compensating)
    }
}
if ($ComputeCapacityWorkerLibraryOnly -eq $true) { return }
$ErrorActionPreference = 'Stop'
Assert-Compute ($CapacityEffectsEnabled -eq $true) 'Worker effects disabled in preparation source'
$mutex = [Threading.Mutex]::new($false, 'Global\AzureLocalBoxComputeCapacityR2')
$held = $false; $session = $null
try {
    $held = $mutex.WaitOne(10000)
    if (-not $held) { throw 'Remote operation mutex unavailable' }
    Save-R2Worker 'preflight'
    Assert-Compute ($env:COMPUTERNAME -ceq 'LocalBox-Client' -and $entry.key -ceq $effectKey) 'Exact approved worker context differs'
    Assert-ComputeExecutionAuthority $plan
    $request = Get-Content (Join-Path $capacityRoot ('request-' + $stage + '.json')) -Raw | ConvertFrom-Json
    $operation = Get-Content (Join-Path $capacityRoot 'operation.json') -Raw | ConvertFrom-Json
    Assert-R2Context $request $operation
    if ($entry.recovery -eq $true) { Assert-ComputeRecoveryAuthority $request.recoveryDirective $effectKey $planSha $sourceCommit }
    $before = Read-ComputeSnapshot ($entry.health -cne 'stopped')
    Assert-R2Snapshot $before $entry.beforeProfiles $entry.beforeStates
    if ($plan.route -ceq 'direct-full-outage-v1' -and $entry.effect -cin @('memory', 'cpu', 'startup-grant')) {
        Assert-Compute (@($before.states.Values | Where-Object { $_ -cne 'Off' }).Count -eq 0) 'Direct profile/grant effects require ALL FOUR guests Off'
    }
    if ($entry.health -ceq 'stopped') {
        foreach ($n in @('LB-NODE01', 'LB-NODE02', 'LB-NODE03')) {
            if ($before.states[$n] -cne 'Running') { continue }
            $check = New-ComputeSession $n
            try {
                $service = Invoke-Command -Session $check -ErrorAction Stop -ScriptBlock { (Get-Service ClusSvc -ErrorAction Stop).Status.ToString() }
                Assert-Compute ($service -ceq 'Stopped') 'Cluster restarted during graceful shutdown sequence'
            } finally { Remove-PSSession $check }
        }
    }
    if ($entry.effect -cin @('cluster-stop', 'drain', 'resume')) {
        $target = if ($entry.node) { $entry.node } else { 'LB-NODE01' }
        $session = New-ComputeSession $target
    }
    $state.rpcInvoked = $true; Save-R2Worker 'rpc-pending'
    switch -CaseSensitive ($entry.effect) {
        'cluster-stop' {
            # Microsoft Stop-Cluster: Force suppresses confirmation, Wait 0 only initiates.
            Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock { Stop-Cluster -Cluster smal-localbox01 -Force -Wait 0 -ErrorAction Stop } | Out-Null
        }
        'guest-stop' {
            $vm = Get-VM -Id $plan.guestIds.PSObject.Properties[$entry.guest].Value
            Assert-Compute ($vm.Name -ceq $entry.guest -and $vm.State.ToString() -ceq 'Running') 'Exact Running guest required'
            Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop
        }
        'memory' {
            $name = if ($entry.guest) { $entry.guest } else { $entry.node }
            $vm = Get-VM -Id $plan.guestIds.PSObject.Properties[$name].Value
            Assert-Compute ($name -cne 'LB-DC01' -and $vm.Name -ceq $name -and $vm.State.ToString() -ceq 'Off') 'Exact Off HCI guest required'
            $memory = if ($entry.targetMemoryBytes) { $entry.targetMemoryBytes } else { 128GB }
            Set-VMMemory -VM $vm -StartupBytes $memory -ErrorAction Stop
        }
        'cpu' {
            $name = if ($entry.guest) { $entry.guest } else { $entry.node }
            $vm = Get-VM -Id $plan.guestIds.PSObject.Properties[$name].Value
            Assert-Compute ($name -cne 'LB-DC01' -and $vm.Name -ceq $name -and $vm.State.ToString() -ceq 'Off') 'Exact Off HCI guest required'
            $count = if ($entry.targetCpu) { $entry.targetCpu } else { 16 }
            Set-VMProcessor -VM $vm -Count $count -ErrorAction Stop
        }
        'drain' {
            Invoke-Command -Session $session -ArgumentList $entry.node -ErrorAction Stop -ScriptBlock { param($n) Suspend-ClusterNode -Cluster smal-localbox01 -Name $n -Drain -Wait -ErrorAction Stop | Out-Null }
            $after = Read-ComputeSnapshot
            $devices = @($after.clusterHealth.devices | Where-Object owner -CEQ $entry.node)
            Assert-Compute ($devices.Count -eq 8 -and @($devices | Where-Object { -not $_.maintenance -or @($_.operational | Where-Object { $_ -cin @('In Maintenance Mode', 'InMaintenanceMode') }).Count -eq 0 }).Count -eq 0) 'Drain did not prove eight devices fully in maintenance. Starting maintenance is not settled'
            $proof = @{ selectedNode = $entry.node; deviceIds = @($devices.id); rpcReturned = $true; eightDevicesMaintenanceVerified = $true; planSha256 = $planSha; sourceCommit = $sourceCommit; key = $effectKey }
            Assert-ComputeMaintenanceHealth $after $entry.node $proof
            Write-ComputeNewJson (Join-Path $capacityRoot ('drain-proof-' + $entry.node + '.json')) $proof
            $state.drainProof = $proof
        }
        'resume' {
            # Compensation returns node to service BEFORE strict resync convergence.
            Invoke-Command -Session $session -ArgumentList $entry.node -ErrorAction Stop -ScriptBlock { param($n) Resume-ClusterNode -Cluster smal-localbox01 -Name $n -Failback NoFailback -ErrorAction Stop | Out-Null }
        }
        'startup-grant' {
            $grant = @{ operationId = $plan.operationId; planSha256 = $planSha; sourceCommit = $sourceCommit
                key = $entry.startupKey; stage = $entry.startupKey; grantStage = $stage; atUtc = [datetime]::UtcNow.ToString('o'); hostCpu = $(if ($entry.startupHostCpu) { $entry.startupHostCpu } else { $entry.hostCpu }); guests = $before.guestsStatic
                hostStatic = $before.hostStatic; volumesStatic = $before.volumesStatic; profiles = $entry.beforeProfiles; states = $entry.beforeStates }
            $grant.startupEntry = $plan.transitionContract.stages.PSObject.Properties[$entry.startupKey].Value
            $grant.capacityGuard = @{ hostCpu = $(if ($entry.startupHostCpu) { $entry.startupHostCpu } else { $entry.hostCpu }); physicalCores = $(if ($entry.startupHostCpu) { $entry.startupHostCpu / 2 } else { $entry.hostCpu / 2 })
                minimumMemoryBytes = 500GB; minimumFreeMemoryBytes = $plan.minimumOuterFreeMemoryBytes }
            $grant.maintenanceContext = if ($entry.node) {
                @{ baseline = @{ clusterStatic = $plan.baseline.clusterStatic }; admission = @{ requiredPhysicalFreeBytes = $plan.admission.requiredPhysicalFreeBytes; repairReserveBytes = $plan.admission.repairReserveBytes }
                   deviceOwners = $plan.transitionContract.deviceOwners }
            } else { $null }
            Write-ComputeNewJson (Join-Path $capacityRoot ('startup-grant-' + $entry.startupKey + '.json')) $grant
            $state.remoteGrant = $grant
        }
        'complete' {
            $state.completionSnapshot = $before
            Write-R2Completion $before (Join-Path $capacityRoot 'completion.json')
        }
        default { throw 'Unlisted single effect' }
    }
    $state.rpcSucceeded = $true
    Save-R2Worker 'returned'
} catch {
    $state.errorType = $_.Exception.GetType().Name; $state.errorLine = $_.InvocationInfo.ScriptLineNumber
    # An exception after RPC entry is uncertain. Even a returned cmdlet can leave work.
    Save-R2Worker $(if ($state.rpcInvoked) { 'uncertain' } else { 'returned' })
} finally {
    if ($session) { Remove-PSSession $session }
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
