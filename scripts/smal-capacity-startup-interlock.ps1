# Additive canonical startup guard. Common library is hash-pinned into this helper.
$capacityRoot = 'C:\ProgramData\AzureLocalBox\ComputeCapacity-R2-20261108-01'
function Write-CapacityStartupEvent($row, [string]$path) {
    Write-ComputeNewJson $path $row
}
function Assert-CapacityStartupSnapshot($snapshot, $grant, $maintenanceProof = $null) {
    Assert-Compute ($snapshot.sourceCommit -ceq $grant.sourceCommit) 'Startup snapshot execution source differs'
    Assert-ComputeEqual $snapshot.guestsStatic $grant.guests 'Full guest VHD/TPM/NIC/profile identity differs'
    Assert-ComputeEqual $snapshot.hostStatic $grant.hostStatic 'Outer storage/network differs'
    Assert-ComputeEqual $snapshot.volumesStatic $grant.volumesStatic 'Outer volume identities differ'
    Assert-ComputeEqual $snapshot.states $grant.states 'Exact Off/Running handover states differ'
    $entry = $grant.startupEntry
    Assert-Compute ($entry.key -ceq $grant.key -and $entry.effect -ceq 'canonical-startup') 'Exact sealed startup entry differs'
    if ($entry.health -ceq 'maintenance') {
        $context = $grant.maintenanceContext
        Assert-Compute ($null -ne $context) 'Sealed startup maintenance context missing'
        $plan = [pscustomobject]@{ baseline = $context.baseline; admission = $context.admission; transitionContract = [pscustomobject]@{ deviceOwners = $context.deviceOwners } }
        $sourceCommit = $grant.sourceCommit; $planSha = $grant.planSha256
        $proof = if ($null -ne $maintenanceProof) { $maintenanceProof } else { Get-Content (Join-Path $capacityRoot ('drain-proof-' + $entry.node + '.json')) -Raw | ConvertFrom-Json }
        $node = @($snapshot.clusterHealth.nodeStates | Where-Object name -CEQ $entry.node)
        Assert-Compute ($node.Count -eq 1 -and $node[0].state -ceq $entry.beforeClusterState) 'Selected pre-start cluster state differs'
        Assert-ComputeMaintenanceHealth $snapshot $entry.node $proof ([bool]$entry.compensating)
    } else { Assert-Compute ($entry.health -ceq 'stopped' -and $null -eq $grant.maintenanceContext) 'Unsealed startup health mode' }
}
function Assert-CapacityRuntime($snapshot, $grant) {
    $guard = $grant.capacityGuard
    $cpu = $snapshot.hostCapacity
    Assert-Compute ($guard.hostCpu -eq 64 -and $guard.physicalCores -eq 32 -and $guard.minimumMemoryBytes -ge 500GB -and $cpu.logicalProcessors -eq 64 -and $cpu.physicalCores -eq 32 -and $cpu.memoryBytes -ge $guard.minimumMemoryBytes -and $cpu.numa.Count -gt 0 -and ($cpu.numa | Measure-Object logicalProcessors -Sum).Sum -eq 64) 'Actual E64 CPU/RAM/NUMA required before any guest start'
    $needed = [long]$guard.minimumFreeMemoryBytes
    foreach ($g in $snapshot.guestsStatic) {
        $state = Get-ComputeField $snapshot.states $g.name
        Assert-Compute ($state -cin @('Off','Running')) 'No startup from Saved/Paused/unknown state in capacity handover'
        if ($state -ceq 'Off') { $needed += $g.memory }
    }
    Assert-Compute ($guard.minimumFreeMemoryBytes -ge 64GB -and $cpu.freeMemoryBytes -ge $needed) 'Actual available RAM cannot admit remaining guest starts plus host floor'
}
function Assert-CapacityRuntimeGate($gate) {
    $plan = [pscustomobject]@{ guestIds = [pscustomobject]@{} }; $sourceCommit = $gate.record.sourceCommit
    foreach ($g in $gate.grant.guests) { $plan.guestIds | Add-Member -NotePropertyName $g.name -NotePropertyValue $g.id }
    $snapshot = Read-ComputeSnapshot $false
    Assert-ComputeEqual $snapshot.guestsStatic $gate.grant.guests 'Capacity guest configuration changed between starts'
    Assert-CapacityRuntime $snapshot $gate.grant
}
function Open-CapacityStartupGate {
    $operation = Get-Content (Join-Path $capacityRoot 'operation.json') -Raw | ConvertFrom-Json
    Assert-Compute ($operation.operationId -ceq 'smal-compute-capacity-20261108-01') 'Remote startup operation identity differs'
    if (Test-Path (Join-Path $capacityRoot 'completion.json')) {
        $complete = Get-Content (Join-Path $capacityRoot 'completion.json') -Raw | ConvertFrom-Json
        if ($null -eq $CapacityCompletionSettlement -or $CapacityCompletionSettlement.proof.outcome -cne 'applied' -or $CapacityCompletionSettlement.proof.sourceCommit -cne $operation.sourceCommit -or $CapacityCompletionSettlement.proof.planSha256 -cne $operation.planSha256) { throw 'Remote completion alone does not settle the operation' }
        Assert-ComputeEqual $complete $CapacityCompletionSettlement.proof.observation.remoteCompletion 'Original remote completion certificate differs'
        $events = @(Get-ChildItem $capacityRoot -Filter 'worker-complete-event-*.json' -File | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Sort-Object sequence)
        if ($events.Count -eq 0) { throw 'Completion process history missing' }
        $w = $events[-1]; $p = Get-Process -Id $w.pid -ErrorAction SilentlyContinue
        if ($w.phase -cne 'returned' -or $w.rpcSucceeded -ne $true -or $w.sequence -ne $CapacityCompletionSettlement.proof.observation.worker.sequence -or ($p -and $p.StartTime.ToUniversalTime().ToString('o') -ceq (Get-ComputeUtcStamp $w.processStartedUtc))) { throw 'Completion worker not settled' }
        return $null
    }
    if (-not $CapacityStartupKey -or $CapacityPlanSha -cne $operation.planSha256 -or $CapacitySourceCommit -cne $operation.sourceCommit) { throw 'Exact local/remote startup handover missing' }
    $mutex = [Threading.Mutex]::new($false, 'Global\AzureLocalBoxComputeCapacityR2')
    if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); throw 'Remote capacity worker/startup active' }
    # Keep mutex until process exit or explicit successful close. History survives either.
    foreach ($file in @(Get-ChildItem $capacityRoot -Filter 'request-*.json' -File)) {
        $request = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $events = @(Get-ChildItem $capacityRoot -Filter ('worker-' + $request.stage + '-event-*.json') -File | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Sort-Object sequence)
        $resolution = $CapacitySettlements.PSObject.Properties[$request.key].Value
        if ($events.Count -eq 0 -or $null -eq $resolution -or $resolution.proof.outcome -cnotin @('applied', 'not-applied')) { throw 'Original capacity effect has no exact settlement' }
        $w = $events[-1]; $process = Get-Process -Id $w.pid -ErrorAction SilentlyContinue
        $dispatcher = Get-Process -Id $request.pid -ErrorAction SilentlyContinue
        $outcomeProved = if ($resolution.proof.outcome -ceq 'applied') { $w.rpcSucceeded -eq $true } else { $w.rpcInvoked -eq $false }
        if (-not $outcomeProved -or ($process -and $process.StartTime.ToUniversalTime().ToString('o') -ceq (Get-ComputeUtcStamp $w.processStartedUtc)) -or ($dispatcher -and $dispatcher.StartTime.ToUniversalTime().ToString('o') -ceq (Get-ComputeUtcStamp $request.processStartedUtc)) -or $w.phase -cne 'returned' -or $w.sequence -ne $resolution.proof.observation.worker.sequence -or $w.sourceSha256 -cne $resolution.proof.observation.worker.sourceSha256 -or $w.planSha256 -cne $operation.planSha256) { throw 'Capacity process/event/source reconciliation differs' }
        Assert-ComputeEqual $w $resolution.proof.observation.worker 'Original worker settlement event changed'
        Assert-ComputeEqual $request $resolution.proof.observation.request 'Original dispatcher settlement request changed'
        if ((Get-FileHash (Join-Path $capacityRoot ('worker-' + $request.stage + '.ps1'))).Hash -cne $w.sourceSha256) { throw 'Original worker source file changed' }
    }
    foreach ($file in @(Get-ChildItem $capacityRoot -Filter 'startup-begin-*.json' -File)) {
        $old = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $resolution = $CapacitySettlements.PSObject.Properties[$old.key].Value
        $events = @(Get-ChildItem $capacityRoot -Filter ('startup-' + $old.key + '-event-*.json') -File | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Sort-Object sequence)
        $process = Get-Process -Id $old.pid -ErrorAction SilentlyContinue
        if ($null -eq $resolution -or $events.Count -eq 0 -or $events[-1].phase -cne 'returned' -or $resolution.proof.observation.remoteStartup.sequence -ne $events[-1].sequence -or ($process -and $process.StartTime.ToUniversalTime().ToString('o') -ceq (Get-ComputeUtcStamp $old.processStartedUtc))) { throw 'Earlier canonical startup unresolved' }
        Assert-ComputeEqual $events[-1] $resolution.proof.observation.remoteStartup 'Original startup event changed'
    }
    $grant = Get-Content (Join-Path $capacityRoot ('startup-grant-' + $CapacityStartupKey + '.json')) -Raw | ConvertFrom-Json
    Assert-ComputeEqual $grant $CapacityRemoteGrant 'Exact one-use local/remote grant differs'
    if (($grant.atUtc -as [datetime]).ToUniversalTime() -gt [datetime]::UtcNow -or ([datetime]::UtcNow - ([datetime]$grant.atUtc).ToUniversalTime()).TotalSeconds -gt 600) { throw 'Remote startup grant expired or future' }
    if ($grant.key -cne $CapacityStartupKey -or $grant.planSha256 -cne $CapacityPlanSha -or $grant.sourceCommit -cne $CapacitySourceCommit) { throw 'Startup grant identity differs' }
    $plan = [pscustomobject]@{ guestIds = [pscustomobject]@{} }
    foreach ($g in $grant.guests) { $plan.guestIds | Add-Member -NotePropertyName $g.name -NotePropertyValue $g.id }
    $entry = $grant.startupEntry
    $sourceCommit = $CapacitySourceCommit; $planSha = $CapacityPlanSha
    if ($null -ne $grant.maintenanceContext) { $plan | Add-Member -NotePropertyName transitionContract -NotePropertyValue ([pscustomobject]@{ deviceOwners = $grant.maintenanceContext.deviceOwners }) }
    $snapshot = Read-ComputeSnapshot ($entry.health -ceq 'maintenance')
    Assert-CapacityStartupSnapshot $snapshot $grant
    $gate = @{ operationId = $operation.operationId; planSha256 = $CapacityPlanSha; sourceCommit = $CapacitySourceCommit
        key = $CapacityStartupKey; stage = $CapacityStartupKey; pid = $PID; processStartedUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        phase = 'begin'; sequence = 0; helperSha256 = $operation.startupHelperSha256; guestRpcInvoked = $false }
    Write-CapacityStartupEvent $gate (Join-Path $capacityRoot ('startup-begin-' + $gate.key + '.json'))
    $result = @{ record = $gate; mutex = $mutex; grant = $grant }
    try { Assert-CapacityRuntime $snapshot $grant }
    catch {
        $gate.refusal = 'capacity-refused-before-guests'; Set-CapacityStartupPhase $result 'returned'
        $mutex.ReleaseMutex(); $mutex.Dispose(); throw 'Capacity refused before guest RPC. Original handover remains consumed and requires exact independent reconciliation'
    }
    return $result
}
function Set-CapacityStartupPhase($gate, [string]$phase, [string]$vmId = '') {
    $row = $gate.record; $row.sequence++; $row.phase = $phase; $row.vmId = $vmId
    if ($phase -ceq 'rpc-pending') { $row.guestRpcInvoked = $true }
    $row.atUtc = [datetime]::UtcNow.ToString('o')
    Write-CapacityStartupEvent $row (Join-Path $capacityRoot ('startup-' + $row.key + '-event-' + $row.sequence + '.json'))
}
function Close-CapacityStartupGate($gate) {
    Set-CapacityStartupPhase $gate 'returned'
    $gate.mutex.ReleaseMutex(); $gate.mutex.Dispose()
}
