# Deployed as exact hash-pinned support source by the approved capacity worker only.
# No VM command is issued here. Normal startup with no capacity state is unchanged.
$capacityRoot = 'C:\ProgramData\AzureLocalBox\ComputeCapacity-R2-20261108-01'
function Read-CapacityJson([string]$path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
function Write-CapacityEvent($record, [string]$path) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($record | ConvertTo-Json -Depth 20 -Compress))
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Assert-CapacityRemoteSettled {
    foreach ($path in @(Get-ChildItem $capacityRoot -Filter 'worker-*.state.json' -File)) {
        $worker = Read-CapacityJson $path.FullName
        $process = Get-Process -Id $worker.pid -ErrorAction SilentlyContinue
        if ($process -and $process.StartTime.ToUniversalTime().ToString('o') -ceq $worker.processStartedUtc) { throw 'Capacity worker still alive. No startup.' }
        if ($worker.phase -cne 'returned') { throw 'Remote capacity RPC phase not settled. No startup.' }
    }
    foreach ($path in @(Get-ChildItem $capacityRoot -Filter 'startup-*.state.json' -File)) {
        $worker = Read-CapacityJson $path.FullName
        $process = Get-Process -Id $worker.pid -ErrorAction SilentlyContinue
        if ($process -and $process.StartTime.ToUniversalTime().ToString('o') -ceq $worker.processStartedUtc) { throw 'Capacity startup worker still alive.' }
        if ($worker.phase -cne 'returned') { throw 'Earlier startup RPC not settled.' }
    }
}
function Open-CapacityStartupGate {
    $statePath = Join-Path $capacityRoot 'operation.json'
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    $state = Read-CapacityJson $statePath
    if ($state.operationId -cne 'smal-compute-capacity-20261108-01') { throw 'Remote operation identity differs' }
    Assert-CapacityRemoteSettled
    if ($state.active -eq $false) {
        $complete = Read-CapacityJson (Join-Path $capacityRoot 'completion.json')
        if ($complete.planSha256 -cne $state.planSha256 -or $complete.allHealthyAndOk -ne $true -or $complete.noActiveStorageJobs -ne $true) { throw 'Inactive flag is not completion proof' }
        return $null
    }
    $grant = Read-CapacityJson (Join-Path $capacityRoot 'startup-grant.json')
    if ($grant.operationId -cne $state.operationId -or $grant.planSha256 -cne $state.planSha256 -or $grant.sourceCommit -cne $state.sourceCommit -or $grant.allPriorRemoteEffectsSettled -ne $true) { throw 'Exact remote startup handover missing' }
    $consumed = Join-Path $capacityRoot ('startup-' + $grant.key + '.state.json')
    if (Test-Path -LiteralPath $consumed) { throw 'Startup grant already consumed. Inspect original outcome.' }
    if ((Get-VMHost).LogicalProcessorCount -ne $grant.expectedHostLogicalProcessors) { throw 'Actual host capacity differs from handover' }
    $vms = @(Get-VM)
    if ($vms.Count -ne 4) { throw 'Unexpected guest set during capacity handover' }
    foreach ($vm in $vms) {
        $expected = @($grant.guests | Where-Object id -IEQ $vm.Id.ToString())
        if ($expected.Count -ne 1 -or $expected[0].name -cne $vm.Name -or $expected[0].cpu -ne $vm.ProcessorCount -or $expected[0].memory -ne $vm.MemoryStartup -or $vm.State.ToString() -cnotin @('Off', 'Running')) { throw 'Handover guest identity/profile/state differs' }
    }
    $gate = @{ key = $grant.key; planSha256 = $grant.planSha256; phase = 'begin'; pid = $PID
        processStartedUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); sequence = 0; statePath = $consumed }
    Write-CapacityEvent $gate $consumed
    return $gate
}
function Set-CapacityStartupPhase($gate, [string]$phase, [string]$vmId = '') {
    if ($null -eq $gate) { return }
    $gate.sequence++; $gate.phase = $phase; $gate.vmId = $vmId
    Write-CapacityEvent $gate (Join-Path $capacityRoot ('startup-' + $gate.key + '-event-' + $gate.sequence + '.json'))
    # State is only a projection. Original begin and every phase event are retained.
    [IO.File]::WriteAllText($gate.statePath, ($gate | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
}
