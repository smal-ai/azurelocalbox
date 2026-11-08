# Renderer supplies exact reviewed context, common library and pinned worker bytes.
$ErrorActionPreference = 'Stop'
$capacityRoot = 'C:\ProgramData\AzureLocalBox\ComputeCapacity-R2-20261108-01'
$entry = $plan.transitionContract.stages.PSObject.Properties[$stage].Value
function Read-R2Json([string]$path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
function Write-R2Json([string]$path, $row) {
    Write-ComputeNewJson $path $row
}
function Test-R2Alive($row) {
    if (-not $row.pid -or -not $row.processStartedUtc) { return $null }
    $p = Get-Process -Id $row.pid -ErrorAction SilentlyContinue
    return ($null -ne $p -and $p.StartTime.ToUniversalTime().ToString('o') -ceq (Get-ComputeUtcStamp $row.processStartedUtc))
}
function Read-R2Worker([string]$name) {
    $events = @(Get-ChildItem $capacityRoot -Filter ('worker-' + $name + '-event-*.json') -File | ForEach-Object { Read-R2Json $_.FullName } | Sort-Object sequence)
    if (-not $events.Count) { return $null }
    for ($i = 0; $i -lt $events.Count; $i++) { if ($events[$i].sequence -ne ($i + 1)) { throw 'Remote event sequence gap' } }
    return $events[-1]
}
Assert-Compute ($env:COMPUTERNAME -ceq 'LocalBox-Client' -and $plan.transitionContract.version -eq 2 -and $plan.executionApproval.parentGo -eq $true) 'Exact sealed R2 context required'
if ($mode -ceq 'observe') {
    if ($entry.effect -cin @('canonical-startup', 'converge')) {
        $snapshot = Read-ComputeSnapshot
        $remote = $null; $begin = $null
        if ($entry.effect -ceq 'canonical-startup') {
            $begin = Read-R2Json (Join-Path $capacityRoot ('startup-begin-' + $stage + '.json'))
            $events = @(Get-ChildItem $capacityRoot -Filter ('startup-' + $stage + '-event-*.json') -File | ForEach-Object { Read-R2Json $_.FullName } | Sort-Object sequence)
            if ($events.Count -eq 0) { throw 'Startup event history missing' }
            for ($i = 0; $i -lt $events.Count; $i++) { if ($events[$i].sequence -ne ($i + 1)) { throw 'Startup event sequence gap' } }
            $remote = $events[-1]
            Assert-Compute ($remote.key -ceq $stage -and $remote.planSha256 -ceq $planSha -and $remote.sourceCommit -ceq $sourceCommit -and $remote.helperSha256 -ceq $startupHelperSha256) 'Exact startup identity/source differs'
        }
        @{ status = 'complete'; mutationPerformed = $false; atUtc = [datetime]::UtcNow.ToString('o'); operationId = $plan.operationId
            planSha256 = $planSha; sourceCommit = $sourceCommit; stage = $stage; key = $effectKey; snapshot = $snapshot
            remoteStartup = $remote; outcome = $(if ($remote -and $remote.phase -ceq 'returned') { 'applied' } else { 'unknown' }); dispatcherAlive = $(if ($begin) { Test-R2Alive $begin } else { $false })
            workerAlive = $(if ($begin) { Test-R2Alive $begin } else { $false }); rpcPhase = $(if ($remote) { $remote.phase } else { 'read-only' })
            workerIdentityVerified = $null -ne $remote; workerSourceVerified = $null -ne $remote } | ForEach-Object { ConvertTo-ComputeJson $_ }
        return
    }
    $request = Read-R2Json (Join-Path $capacityRoot ('request-' + $stage + '.json'))
    $worker = Read-R2Worker $stage
    $workerFile = Join-Path $capacityRoot ('worker-' + $stage + '.ps1')
    Assert-Compute ($request.operationId -ceq $plan.operationId -and $request.stage -ceq $stage -and $request.key -ceq $effectKey -and $request.sourceCommit -ceq $sourceCommit -and $request.planSha256 -ceq $planSha -and (Get-FileHash $workerFile).Hash -ceq $workerSha256) 'Original request/source differs'
    if ($worker) { Assert-Compute ($worker.operationId -ceq $plan.operationId -and $worker.stage -ceq $stage -and $worker.key -ceq $effectKey -and $worker.sourceCommit -ceq $sourceCommit -and $worker.planSha256 -ceq $planSha -and $worker.sourceSha256 -ceq $workerSha256) 'Worker identity/source differs' }
    $notApplied = ($worker -and $worker.rpcInvoked -eq $false -and $worker.phase -ceq 'returned')
    $snapshot = Read-ComputeSnapshot ($(if ($notApplied) { $entry.health } else { $entry.observeHealth }) -cne 'stopped')
    $services = @{}
    if ($entry.effect -ceq 'cluster-stop') {
        foreach ($n in @('LB-NODE01', 'LB-NODE02', 'LB-NODE03')) {
            $s = New-ComputeSession $n
            try { $services[$n] = Invoke-Command -Session $s -ScriptBlock { (Get-Service ClusSvc -ErrorAction Stop).Status.ToString() } -ErrorAction Stop }
            finally { Remove-PSSession $s }
        }
    }
    @{ status = 'complete'; mutationPerformed = $false; atUtc = [datetime]::UtcNow.ToString('o'); operationId = $plan.operationId
       planSha256 = $planSha; sourceCommit = $sourceCommit; stage = $stage; key = $effectKey
       dispatcherAlive = Test-R2Alive $request; workerAlive = Test-R2Alive $worker; workerIdentityVerified = $null -ne $worker
       workerSourceVerified = $true; rpcPhase = $(if ($worker) { $worker.phase } else { 'unknown' })
        worker = $worker; request = $request; snapshot = $snapshot; clusterServices = $services
        outcome = $(if ($worker -and $worker.phase -ceq 'returned' -and $worker.rpcSucceeded -eq $true) { 'applied' } elseif ($notApplied) { 'not-applied' } else { 'unknown' })
        remoteCompletion = $(if (Test-Path (Join-Path $capacityRoot 'completion.json')) { Read-R2Json (Join-Path $capacityRoot 'completion.json') } else { $null }) } | ForEach-Object { ConvertTo-ComputeJson $_ }
} elseif ($mode -ceq 'dispatch') {
    Assert-Compute ($CapacityEffectsEnabled -eq $true) 'Remote R2 effects disabled in preparation source'
    Assert-Compute ($entry.key -ceq $effectKey) 'Sealed immutable key differs'
    $mutex = [Threading.Mutex]::new($false, 'Global\AzureLocalBoxComputeCapacityR2'); $held = $false
    try {
        $held = $mutex.WaitOne(0)
        if (-not $held) { throw 'Remote operation mutex unavailable' }
        if (-not (Test-Path -LiteralPath $capacityRoot)) {
            $null = New-Item -Path $capacityRoot -ItemType Directory
            Set-Acl $capacityRoot (Get-Acl 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01')
            $b = [Convert]::FromBase64String($startupHelperBase64)
            $s = [IO.File]::Open((Join-Path $capacityRoot 'startup-interlock.ps1'), [IO.FileMode]::CreateNew)
            try { $s.Write($b, 0, $b.Length); $s.Flush($true) } finally { $s.Dispose() }
            Write-R2Json (Join-Path $capacityRoot 'operation.json') @{ operationId = $plan.operationId; planSha256 = $planSha; sourceCommit = $sourceCommit; startupHelperSha256 = $startupHelperSha256 }
        }
        $operation = Read-R2Json (Join-Path $capacityRoot 'operation.json')
        Assert-Compute ($operation.operationId -ceq $plan.operationId -and $operation.planSha256 -ceq $planSha -and $operation.sourceCommit -ceq $sourceCommit -and $operation.startupHelperSha256 -ceq $startupHelperSha256 -and (Get-FileHash (Join-Path $capacityRoot 'startup-interlock.ps1')).Hash -ceq $startupHelperSha256) 'Remote source/operation fence differs'
        if (Test-Path (Join-Path $capacityRoot 'completion.json')) { throw 'Operation completed. No new effects' }
        # Controller provides exact independently validated settlements. Persist acknowledgements
        # only after re-reading original process/event identity. Returned alone never admits work.
        foreach ($file in @(Get-ChildItem $capacityRoot -Filter 'request-*.json' -File)) {
            $r = Read-R2Json $file.FullName; $w = Read-R2Worker $r.stage
            $resolution = $settlements.PSObject.Properties[$r.key].Value
            Assert-Compute ($null -ne $resolution -and $resolution.proof.outcome -cin @('applied', 'not-applied') -and $resolution.proof.key -ceq $r.key -and $resolution.proof.planSha256 -ceq $planSha -and $resolution.proof.sourceCommit -ceq $sourceCommit) 'Exact remote effect settlement absent'
            $outcomeProved = if ($resolution.proof.outcome -ceq 'applied') { $w.rpcSucceeded -eq $true } else { $w.rpcInvoked -eq $false }
            Assert-Compute ($outcomeProved -and (Test-R2Alive $r) -eq $false -and (Test-R2Alive $w) -eq $false -and $w.phase -ceq 'returned' -and $w.sequence -eq $resolution.proof.observation.worker.sequence -and $w.processStartedUtc -ceq $resolution.proof.observation.worker.processStartedUtc -and $w.sourceSha256 -ceq $resolution.proof.observation.worker.sourceSha256) 'Original process/event/effect reconciliation differs'
            Assert-ComputeEqual $w $resolution.proof.observation.worker 'Exact original worker event changed'
            Assert-ComputeEqual $r $resolution.proof.observation.request 'Exact original dispatcher request changed'
            Assert-Compute ((Get-FileHash (Join-Path $capacityRoot ('worker-' + $r.stage + '.ps1'))).Hash -ceq $w.sourceSha256) 'Original worker file changed'
            $ack = Join-Path $capacityRoot ('settlement-' + $r.key + '.json')
            if (Test-Path $ack) { Assert-ComputeEqual (Read-R2Json $ack) $resolution 'Prior acknowledgement changed' }
            else { Write-R2Json $ack $resolution }
        }
        foreach ($file in @(Get-ChildItem $capacityRoot -Filter 'startup-begin-*.json' -File)) {
            $begin = Read-R2Json $file.FullName
            $events = @(Get-ChildItem $capacityRoot -Filter ('startup-' + $begin.key + '-event-*.json') -File | ForEach-Object { Read-R2Json $_.FullName } | Sort-Object sequence)
            $resolution = $settlements.PSObject.Properties[$begin.key].Value
            Assert-Compute ($events.Count -gt 0 -and $null -ne $resolution -and $resolution.proof.outcome -ceq 'applied' -and $events[-1].phase -ceq 'returned' -and (Test-R2Alive $begin) -eq $false -and $resolution.proof.observation.remoteStartup.sequence -eq $events[-1].sequence) 'Canonical startup unresolved'
            Assert-ComputeEqual $events[-1] $resolution.proof.observation.remoteStartup 'Exact original startup event changed'
            $ack = Join-Path $capacityRoot ('settlement-' + $begin.key + '.json')
            if (Test-Path $ack) { Assert-ComputeEqual (Read-R2Json $ack) $resolution 'Startup acknowledgement differs' } else { Write-R2Json $ack $resolution }
        }
        & {
            $workerFile = Join-Path $capacityRoot ('worker-' + $stage + '.ps1')
            $b = [Convert]::FromBase64String($workerBase64)
            $h = [Security.Cryptography.SHA256]::Create()
            try { Assert-Compute ([BitConverter]::ToString($h.ComputeHash($b)).Replace('-', '') -ceq $workerSha256) 'Worker bytes differ' } finally { $h.Dispose() }
            $s = [IO.File]::Open($workerFile, [IO.FileMode]::CreateNew)
            try { $s.Write($b, 0, $b.Length); $s.Flush($true) } finally { $s.Dispose() }
            Write-R2Json (Join-Path $capacityRoot ('request-' + $stage + '.json')) @{ operationId = $plan.operationId; planSha256 = $planSha; sourceCommit = $sourceCommit; stage = $stage; key = $effectKey; pid = $PID; processStartedUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') }
            $p = Start-Process powershell.exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $workerFile) -PassThru -WindowStyle Hidden
            Write-R2Json (Join-Path $capacityRoot ('launch-' + $stage + '.json')) @{ pid = $p.Id; stage = $stage; key = $effectKey; planSha256 = $planSha }
            @{ status = 'complete'; launchReturned = $true; effectSettled = $false; closingSshSettlesRpc = $false; key = $effectKey; planSha256 = $planSha } | ForEach-Object { ConvertTo-ComputeJson $_ }
        }
    } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
} else { throw 'Unknown R2 mode' }
