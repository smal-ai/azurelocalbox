param(
    [ValidateSet('Inspect', 'Shutdown', 'Restore')][string]$Action = 'Inspect',
    [Parameter(Mandatory = $true)][string]$ConfigurationBase64,
    [Parameter(Mandatory = $true)][string]$PerformanceBase64,
    [Parameter(Mandatory = $true)][string]$OperationId,
    [bool]$ConfirmationRetry = $false,
    [bool]$GuestStopBindingRetry = $false
)
$ErrorActionPreference = 'Stop'
$platform = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ConfigurationBase64)) | ConvertFrom-Json
$config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PerformanceBase64)) | ConvertFrom-Json
if ($env:COMPUTERNAME -cne $platform.hostName -or $config.hostId -cne $platform.hostId -or
    $config.capacityOperationId -cne '92490377-59ca-4f7c-b553-d65330495cde') { throw 'Exact existing host/capacity binding differs' }
$root = 'C:\ProgramData\AzureLocalBox\Operations'
$path = Join-Path $root 'smal-disk-performance.json'
$capacityPath = Join-Path $root 'smal-capacity-node03.json'
$mutex = [Threading.Mutex]::new($false, 'Global\AzureLocalBoxDiskPerformance')
$held = $false
$sessions = @{}
$state = $null
function Save-State {
    $state.updatedAt = [datetime]::UtcNow.ToString('o')
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    if (Test-Path $path) { [IO.File]::Replace($temporary, $path, ($path + '.previous')) }
    else { [IO.File]::Move($temporary, $path) }
}
function Open-Node([string]$name) {
    if ($sessions.ContainsKey($name)) { return $sessions[$name] }
    $vm = Get-VM -Id $platform.guestIds.PSObject.Properties[$name].Value
    if ($vm.Name -cne $name -or $vm.State.ToString() -cne 'Running') { throw 'Exact HCI guest is not Running' }
    $bundle = Get-Content (Join-Path $platform.guestHelperDirectory 'bundle.json') -Raw | ConvertFrom-Json
    $helper = Join-Path $platform.guestHelperDirectory 'smal-guest-secret-functions.ps1'
    $entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
    if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Protected guest helper differs' }
    . $helper
    $store = Join-Path $platform.credentialDirectory 'secrets'
    $bindings = Get-Content (Join-Path $platform.credentialDirectory 'credential-bindings.json') -Raw | ConvertFrom-Json
    $binding = $bindings.nodes.PSObject.Properties[$name].Value
    if ($binding.vmId -ine $vm.Id.ToString() -or $binding.role -cne 'cluster-node-admin' -or $binding.secretDirectory -cne $store -or -not $binding.loginVerified) { throw 'Existing credential binding differs' }
    $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'
    try { $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($name + '\ASBuiltInAdmin'), $secure)) }
    finally { $secure.Dispose() }
    $sessions[$name] = $session
    return $session
}
function Read-Cluster {
    Invoke-Command -Session (Open-Node 'LB-NODE03') -ArgumentList $platform.clusterName, $platform.mocLocation -ScriptBlock {
        param($name, $location)
        $ErrorActionPreference = 'Stop'
        if ((Get-Cluster).Name -ine $name) { throw 'Wrong cluster' }
        $pools = @(Get-StoragePool -IsPrimordial $false)
        if ($pools.Count -ne 1) { throw 'Expected one S2D pool' }
        $q = Get-ClusterQuorum
        Import-Module Moc -ErrorAction Stop
        function Names($rows) { if ($rows -is [Collections.IList]) { foreach ($row in $rows) { Names $row } } else { if ($rows.location -cne $location) { throw 'MOC identity differs' }; $rows.name.ToUpperInvariant() } }
        @{ nodes = @(Get-ClusterNode | Sort-Object Name | ForEach-Object { @{ name = $_.Name; state = [string]$_.State; vote = $_.NodeWeight } });
           pool = @{ id = $pools[0].UniqueId; sizeBytes = $pools[0].Size; allocatedBytes = $pools[0].AllocatedSize; health = [string]$pools[0].HealthStatus };
           physicalDisks = @($pools[0] | Get-PhysicalDisk | ForEach-Object { @{ id = $_.UniqueId; health = [string]$_.HealthStatus; operational = @($_.OperationalStatus | ForEach-Object ToString) } });
           virtualDisks = @(Get-VirtualDisk | ForEach-Object { @{ id = $_.UniqueId; name = $_.FriendlyName; sizeBytes = $_.Size; copies = $_.NumberOfDataCopies; health = [string]$_.HealthStatus; operational = @($_.OperationalStatus | ForEach-Object ToString) } });
           csvs = @(Get-ClusterSharedVolume | ForEach-Object { @{ name = $_.Name; id = $_.Id.ToString(); state = [string]$_.State; owner = $_.OwnerNode.Name; paths = @($_.SharedVolumeInfo | ForEach-Object { @{ path = $_.FriendlyVolumeName; freeBytes = $_.Partition.FreeSpace } }) } });
           jobs = @(Get-StorageJob | Where-Object JobState -NotIn @('Completed', 'Terminated') | ForEach-Object { @{ name = $_.Name; state = [string]$_.JobState } });
           quorum = @{ type = [string]$q.QuorumType; state = [string]$q.QuorumResource.State; resource = [string]$q.QuorumResource };
           moc = @(Names (Get-MocNode -location $location -timeoutSeconds 30) | Sort-Object -Unique) }
    }
}
function Assert-Healthy($cluster) {
    $expected = @('LB-NODE01', 'LB-NODE02', 'LB-NODE03')
    if ($cluster.nodes.Count -ne 3 -or @($cluster.nodes | Where-Object { $_.state -cne 'Up' -or $_.name -cnotin $expected -or $_.vote -ne 1 }).Count -or
        $cluster.pool.health -cne 'Healthy' -or $cluster.physicalDisks.Count -ne 24 -or
        @($cluster.physicalDisks | Where-Object { $_.health -cne 'Healthy' -or @($_.operational | Where-Object { $_ -cne 'OK' }).Count }).Count -or
        @($cluster.virtualDisks | Where-Object { $_.health -cne 'Healthy' -or @($_.operational | Where-Object { $_ -cne 'OK' }).Count }).Count -or
        $cluster.csvs.Count -ne 4 -or @($cluster.csvs | Where-Object state -CNE 'Online').Count -or $cluster.jobs.Count -or
        $cluster.moc.Count -ne 3 -or @($cluster.moc | Where-Object { $_ -cnotin $expected }).Count -or
        ($cluster.quorum.resource -and $cluster.quorum.state -cne 'Online')) { throw 'Full-lab lifecycle requires healthy current three-node quorum/MOC/S2D/CSV and no storage job' }
}
function Read-Nested {
    @(foreach ($name in @('LB-NODE01', 'LB-NODE02', 'LB-NODE03')) {
        Invoke-Command -Session (Open-Node $name) -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            @(Get-VM | ForEach-Object {
                $vm = $_
                $resources = @(Get-ClusterResource | Where-Object ResourceType -EQ 'Virtual Machine' | Where-Object {
                    @($_ | Get-ClusterParameter | Where-Object { $_.Name -ieq 'VmId' -and ([guid]$_.Value) -eq $vm.Id }).Count
                })
                if ($resources.Count -ne 1) {
                    @{ id = $vm.Id.ToString(); name = $vm.Name; node = $env:COMPUTERNAME; state = [string]$vm.State; bindingCount = $resources.Count;
                       resourceBindings = @(Get-ClusterResource | Where-Object ResourceType -EQ 'Virtual Machine' | ForEach-Object {
                           @{ name = $_.Name; group = $_.OwnerGroup.Name; parameters = @($_ | Get-ClusterParameter | Where-Object Name -Match '^VmId$' | Select-Object Name, Value) }
                       }) }
                    return
                }
                $resource = $resources[0]
                $offline = @($resource | Get-ClusterParameter | Where-Object Name -CEQ 'OfflineAction')
                $shutdown = @($vm | Get-VMIntegrationService | Where-Object Name -CEQ 'Shutdown')
                @{ id = $vm.Id.ToString(); name = $vm.Name; node = $env:COMPUTERNAME; state = [string]$vm.State; heartbeat = [string]$vm.Heartbeat;
                   cpu = $vm.ProcessorCount; memoryBytes = $vm.MemoryStartup; resource = $resource.Name; group = $resource.OwnerGroup.Name;
                   groupState = [string](Get-ClusterGroup -Name $resource.OwnerGroup.Name).State;
                   offlineAction = $(if ($offline.Count -eq 1) { $offline[0].Value } else { $null });
                   shutdownEnabled = ($shutdown.Count -eq 1 -and $shutdown[0].Enabled);
                   autoStart = [string]$vm.AutomaticStartAction; autoStop = [string]$vm.AutomaticStopAction;
                   disks = @($vm | Get-VMHardDiskDrive | ForEach-Object { @{ path = $_.Path; controller = $_.ControllerNumber; location = $_.ControllerLocation } }) }
            })
        }
    })
}
function Read-Outer {
    @(Get-VM | Sort-Object Name | ForEach-Object { @{ id = $_.Id.ToString(); name = $_.Name; state = [string]$_.State;
       heartbeat = [string]$_.Heartbeat; cpu = $_.ProcessorCount; memoryBytes = $_.MemoryStartup;
       autoStart = [string]$_.AutomaticStartAction; autoStop = [string]$_.AutomaticStopAction;
       shutdownEnabled = (@($_ | Get-VMIntegrationService | Where-Object { $_.Name -ceq 'Shutdown' -and $_.Enabled }).Count -eq 1) } })
}
function Complete-OuterShutdown {
    foreach ($name in @('LB-NODE01', 'LB-NODE02', 'LB-NODE03')) {
        Invoke-Command -Session (Open-Node $name) -ScriptBlock {
            if ((Get-Service clussvc).Status.ToString() -cne 'Stopped') { throw 'Cluster service not cleanly stopped on every node' }
            if (@(Get-VM | Where-Object { $_.State.ToString() -cne 'Off' }).Count) { throw 'Nested VM is not cleanly Off' }
        }
    }
    $state.phase = 'cluster-stopped'; Save-State
    foreach ($name in @('LB-NODE01', 'LB-NODE02', 'LB-NODE03', 'LB-DC01')) {
        $id = $platform.guestIds.PSObject.Properties[$name].Value
        $vm = Get-VM -Id $id
        if ($vm.Name -cne $name) { throw 'Original outer guest identity differs' }
        if ($vm.State.ToString() -ceq 'Off') { continue }
        if ($vm.State.ToString() -cne 'Running') { throw 'Original outer guest shutdown is transitioning; no repeated or forced stop' }
        $state.phase = 'outer-guest-shutdown-intent'; $state.outerGuest = $name; Save-State
        Stop-VM -VM $vm -Confirm:$false
        if ((Get-VM -Id $id).State.ToString() -cne 'Off') { throw 'Outer guest graceful shutdown did not complete' }
    }
    $state.phase = 'all-guests-cleanly-off'; Save-State
}
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another disk-performance lifecycle operation is running' }
    if (Test-Path $path) { $loaded = Get-Content $path -Raw | ConvertFrom-Json; $state = @{}; foreach ($property in $loaded.PSObject.Properties) { $state[$property.Name] = $property.Value }; if ($state.id -cne $OperationId) { throw 'Original disk-performance operation differs' } }
    if ($Action -ceq 'Inspect') {
        $outer = Read-Outer
        if (@($outer | Where-Object state -CNE 'Off').Count -eq 0) {
            @{ action = $Action; originalOperation = $state; outer = $outer } | ConvertTo-Json -Depth 30 -Compress
            return
        }
        $services = @(foreach ($name in @('LB-NODE01', 'LB-NODE02', 'LB-NODE03')) {
            Invoke-Command -Session (Open-Node $name) -ScriptBlock { @{ node = $env:COMPUTERNAME; clusterService = [string](Get-Service clussvc).Status } }
        })
        if (@($services | Where-Object clusterService -CNE 'Running').Count) {
            @{ action = $Action; originalOperation = $state; outer = $outer; clusterServices = $services } | ConvertTo-Json -Depth 30 -Compress
            return
        }
        $roles = Invoke-Command -Session (Open-Node 'LB-NODE03') -ScriptBlock {
            @(Get-ClusterResource | Where-Object { $_.ResourceType -in @('Virtual Machine', 'Virtual Machine Configuration') } | ForEach-Object {
                @{ name = $_.Name; type = [string]$_.ResourceType; state = [string]$_.State; group = $_.OwnerGroup.Name; owner = $_.OwnerNode.Name;
                   parameters = @($_ | Get-ClusterParameter | Where-Object Name -Match '^(VmId|OfflineAction)$' | Select-Object Name, Value) }
            })
        }
        @{ action = $Action; originalOperation = $state; outer = $outer; clusterServices = $services; cluster = Read-Cluster; nested = @(Read-Nested); roles = $roles; observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 30 -Compress
        return
    }
    if ($Action -ceq 'Shutdown') {
        if ($state -and $state.phase -ceq 'outer-guest-shutdown-intent') {
            if (-not $GuestStopBindingRetry) { throw 'Original outer guest stop is unresolved. No repeat' }
            # The caller verified the original invalid-parameter failure occurred
            # before dispatch. Complete-OuterShutdown still verifies every cluster
            # service Stopped before any corrected graceful guest request.
            $state.guestStopBindingRetryAt = [datetime]::UtcNow.ToString('o'); Save-State
            Complete-OuterShutdown
            @{ action = $Action; operation = $state; outer = Read-Outer } | ConvertTo-Json -Depth 30 -Compress
            return
        }
        if ($state -and $state.phase -ceq 'cluster-stop-intent') {
            $services = @(foreach ($name in @('LB-NODE01', 'LB-NODE02', 'LB-NODE03')) {
                Invoke-Command -Session (Open-Node $name) -ScriptBlock { [string](Get-Service clussvc).Status }
            })
            if (@($services | Where-Object { $_ -cne 'Stopped' }).Count) {
                if (-not $ConfirmationRetry -or @($services | Where-Object { $_ -cne 'Running' }).Count) { throw 'Original cluster stop state unresolved; no replay' }
                # This retry is admitted only after the original non-interactive
                # confirmation failed BEFORE effect and all services remain Running.
                $roles = Invoke-Command -Session (Open-Node 'LB-NODE03') -ArgumentList (,$config.nestedVmIds) -ScriptBlock {
                    param($ids)
                    @(Get-ClusterResource | Where-Object ResourceType -EQ 'Virtual Machine' | Where-Object {
                        @($_ | Get-ClusterParameter | Where-Object { $_.Name -ieq 'VmId' -and ([guid]$_.Value).ToString() -in $ids }).Count
                    } | ForEach-Object { [string]$_.State })
                }
                if ($roles.Count -ne 5 -or @($roles | Where-Object { $_ -cne 'Offline' }).Count) { throw 'All exact nested roles must already be cleanly Offline' }
                $state.confirmationRetryAt = [datetime]::UtcNow.ToString('o'); Save-State
                # Stop-Cluster -Force ONLY suppresses confirmation, per its docs.
                # It does not force power-off or bypass quorum/storage sequencing.
                Invoke-Command -Session (Open-Node 'LB-NODE03') -ScriptBlock { Stop-Cluster -Wait 600 -Force }
            }
            Complete-OuterShutdown
            @{ action = $Action; operation = $state; outer = Read-Outer } | ConvertTo-Json -Depth 30 -Compress
            return
        }
        if ($state -and $state.phase -ceq 'all-guests-cleanly-off') {
            $outer = Read-Outer
            if (@($outer | Where-Object state -CNE 'Off').Count) { throw 'Original clean-off state no longer matches current guests' }
            @{ action = $Action; operation = $state; outer = $outer; status = 'observed-already-off' } | ConvertTo-Json -Depth 30 -Compress
            return
        }
        if ($state -and $state.phase -cne 'admitted') { throw 'Original shutdown phase is unresolved. Inspect actual state rather than repeat' }
        $capacity = Get-Content $capacityPath -Raw | ConvertFrom-Json
        if ($capacity.id -cne $config.capacityOperationId -or $capacity.status -cnotin @('service-restored', 'complete')) { throw 'Original capacity operation is not reconciled' }
        $cluster = Read-Cluster; Assert-Healthy $cluster
        $nested = $(if ($state) { @($state.before.nested) } else { @(Read-Nested) }); $outer = Read-Outer
        if ($outer.Count -ne 4 -or @($outer | Where-Object { $_.id -cnotin @($platform.guestIds.PSObject.Properties.Value) -or $_.state -cne 'Running' -or -not $_.shutdownEnabled }).Count) { throw 'Unexpected outer guest/power/shutdown capability' }
        if ($nested.Count -ne 5 -or @($nested | Where-Object { $_.id -cnotin $config.nestedVmIds -or $_.state -cne 'Running' -or $_.groupState -cne 'Online' -or -not $_.shutdownEnabled -or $_.offlineAction -notin @(0, 1, 2, 3) }).Count) { throw 'Exact owned five nested VMs must be Running with Online roles and supported graceful shutdown' }
        if (-not $state) {
            $state = @{ id = $OperationId; phase = 'admitted'; updatedAt = $null; startedAt = [datetime]::UtcNow.ToString('o'); before = @{ outer = $outer; nested = $nested; cluster = $cluster }; steps = @{} }
        } else {
            $steps = @{}; foreach ($property in $state.steps.PSObject.Properties) { $steps[$property.Name] = $property.Value }; $state.steps = $steps
        }
        Save-State
        foreach ($id in $config.shutdownOrder) {
            $vm = @($nested | Where-Object id -CEQ $id)[0]
            $hasOriginalIntent = $state.steps.ContainsKey($id)
            if (-not $hasOriginalIntent) { $state.steps[$id] = @{ phase = 'shutdown-policy-intent'; originalOfflineAction = $vm.offlineAction; at = [datetime]::UtcNow.ToString('o') }; Save-State }
            $owner = Invoke-Command -Session (Open-Node 'LB-NODE03') -ArgumentList $vm.group -ScriptBlock { param($group) (Get-ClusterGroup -Name $group).OwnerNode.Name }
            Invoke-Command -Session (Open-Node $owner) -ArgumentList $vm.resource, $vm.group, $id, $vm.offlineAction, $hasOriginalIntent -ScriptBlock {
                param($resourceName, $groupName, $id, $originalAction, $hasOriginalIntent)
                $ErrorActionPreference = 'Stop'
                $resource = Get-ClusterResource -Name $resourceName
                $binding = @($resource | Get-ClusterParameter | Where-Object { $_.Name -ieq 'VmId' -and ([guid]$_.Value) -eq ([guid]$id) })
                if ($binding.Count -ne 1) { throw 'Exact VM/resource identity changed before shutdown' }
                $group = Get-ClusterGroup -Name $groupName
                if ($group.State.ToString() -ceq 'Offline' -and $resource.State.ToString() -ceq 'Offline' -and $hasOriginalIntent) {
                    # Offline VM configuration resources can unregister their VM.
                    # The completed orderly role shutdown remains the original action.
                    $resource | Set-ClusterParameter -Name OfflineAction -Value $originalAction
                    return
                }
                if ($hasOriginalIntent) { throw 'Original nested shutdown intent is unresolved; no repeat' }
                if ((Get-VM -Id $id).State.ToString() -cne 'Running' -or $group.State.ToString() -cne 'Online') { throw 'Exact VM state changed before original shutdown' }
                # Documented OfflineAction 2 = OS shutdown, never forced shutdown.
                $resource | Set-ClusterParameter -Name OfflineAction -Value 2
                Stop-ClusterGroup -Name $groupName -Wait 600 | Out-Null
                $currentVm = Get-VM -Id $id -ErrorAction SilentlyContinue
                if ((Get-ClusterGroup -Name $groupName).State.ToString() -cne 'Offline' -or
                    (Get-ClusterResource -Name $resourceName).State.ToString() -cne 'Offline' -or
                    ($currentVm -and $currentVm.State.ToString() -cne 'Off')) { throw 'Original graceful nested shutdown has not settled; no force allowed' }
                $resource | Set-ClusterParameter -Name OfflineAction -Value $originalAction
                if (($resource | Get-ClusterParameter -Name OfflineAction).Value -ne $originalAction) { throw 'Original offline-action policy not restored' }
            }
            $state.steps[$id].phase = 'off-original-policy-restored'; Save-State
        }
        $state.phase = 'cluster-stop-intent'; Save-State
        Invoke-Command -Session (Open-Node 'LB-NODE03') -ScriptBlock { Stop-Cluster -Wait 600 -Force }
        Complete-OuterShutdown
        @{ action = $Action; operation = $state; outer = Read-Outer } | ConvertTo-Json -Depth 30 -Compress
        return
    }
    if (-not $state -or $state.phase -cnotin @('all-guests-cleanly-off', 'restoring', 'restored')) { throw 'Original full-lab shutdown is not confirmed; inspect rather than manufacture restore' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do { try { $cluster = Read-Cluster; Assert-Healthy $cluster; break } catch { if ($watch.Elapsed.TotalSeconds -ge 600) { throw }; Start-Sleep 10 } } while ($true)
    $state.phase = 'restoring'; Save-State
    foreach ($id in $config.startupOrder) {
        $original = @($state.before.nested | Where-Object id -CEQ $id)[0]
        $role = Invoke-Command -Session (Open-Node 'LB-NODE03') -ArgumentList $original.group, $original.resource -ScriptBlock {
            param($group, $resource)
            $role = Get-ClusterGroup -Name $group
            @{ group = $role.Name; resource = $resource; node = $role.OwnerNode.Name; groupState = [string]$role.State }
        }
        if ($role.groupState -ceq 'Online') { continue }
        if ($role.groupState -cnotin @('Offline', 'Failed')) { throw 'Original nested group has an unresolved transition' }
        Invoke-Command -Session (Open-Node $role.node) -ArgumentList $role.group, $role.resource, $id, $original.offlineAction -ScriptBlock {
            param($group, $resource, $id, $action)
            $binding = @(Get-ClusterResource -Name $resource | Get-ClusterParameter | Where-Object { $_.Name -ieq 'VmId' -and ([guid]$_.Value) -eq ([guid]$id) })
            if ($binding.Count -ne 1) { throw 'Original VM/resource binding changed' }
            Get-ClusterResource -Name $resource | Set-ClusterParameter -Name OfflineAction -Value $action
            Start-ClusterGroup -Name $group -Wait 600 | Out-Null
            if ((Get-VM -Id $id).State.ToString() -cne 'Running') { throw 'Original nested VM did not return Running' }
        }
    }
    $cluster = Read-Cluster; Assert-Healthy $cluster
    $nested = @(Read-Nested)
    foreach ($old in $state.before.nested) {
        $vm = @($nested | Where-Object id -CEQ $old.id)
        if ($vm.Count -ne 1 -or $vm[0].state -cne 'Running' -or $vm[0].groupState -cne 'Online' -or
            $vm[0].cpu -ne $old.cpu -or $vm[0].memoryBytes -ne $old.memoryBytes -or $vm[0].offlineAction -ne $old.offlineAction -or
            $vm[0].autoStart -cne $old.autoStart -or $vm[0].autoStop -cne $old.autoStop) { throw 'Original nested profile/power/policies not restored' }
    }
    $state.phase = 'restored'; Save-State
    @{ action = $Action; operation = $state; cluster = $cluster; nested = $nested; outer = Read-Outer } | ConvertTo-Json -Depth 30 -Compress
} finally {
    foreach ($session in $sessions.Values) { Remove-PSSession $session }
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
