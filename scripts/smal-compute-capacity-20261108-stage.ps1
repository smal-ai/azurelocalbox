# Source template: no mutation until a parent-reviewed inventory-sealed stage is pushed.
$operationRoot = 'C:\ProgramData\AzureLocalBox\ComputeCapacity-20261108-01'
$record = @{ status = 'preflight'; stage = $stage; planSha256 = $planSha; mutationRequested = $false; mutationPerformed = $false }
$session = $null
try {
    if ($stage -cin @('inspect', 'inventory')) {
        $runningNodes = @(Get-VM | Where-Object { $_.Name -in @('LB-NODE01', 'LB-NODE02', 'LB-NODE03') -and $_.State.ToString() -ceq 'Running' })
        $record.snapshot = Read-ComputeSnapshot ($runningNodes.Count -ge 2)
        $record.status = 'complete'
    } else {
        Assert-Compute ($plan.executionApproval.parentGo -eq $true) 'Exact execution approval missing'
        $off = @()
        if ($stage -match '^resize-(LB-NODE0[123])$') { $off = @($Matches[1]) }
        $resuming = $stage.StartsWith('resume-')
        $before = Read-ComputeSnapshot
        Assert-ComputeSnapshot $before $off (($off.Count -eq 0) -and -not $resuming) ($stage -cne 'shutdown')
        if ($off.Count -gt 0) { Assert-ComputeMaintenanceHealth $before $off[0] }
        if ($resuming) { Assert-ComputeMaintenanceHealth $before $stage.Substring(7) }
        if ($off.Count -gt 0) {
            Assert-Compute (Test-Path (Join-Path $operationRoot ('stop-' + $off[0] + '.json'))) 'Exact preceding stop receipt missing'
            $stopped = Get-Content (Join-Path $operationRoot ('stop-' + $off[0] + '.json')) -Raw | ConvertFrom-Json
            Assert-Compute ($stopped.status -ceq 'complete' -and $stopped.planSha256 -ceq $planSha) 'Preceding stop failed/uncertain'
        }
        if (-not (Test-Path $operationRoot)) { $null = New-Item $operationRoot -ItemType Directory }
        $marker = Join-Path $operationRoot ($stage + '.started')
        $handle = [IO.File]::Open($marker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $handle.Dispose()
        $recordPath = Join-Path $operationRoot ($stage + '.json')
        Assert-Compute (-not (Test-Path $recordPath)) 'Existing stage receipt, do not replay'
        function Save-ComputeRecord {
            $record.atUtc = [datetime]::UtcNow.ToString('o')
            [IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        }
        $record.mutationRequested = $true; $record.status = 'pending-effect'; Save-ComputeRecord
        if ($stage -ceq 'shutdown') {
            $session = New-ComputeSession 'LB-NODE01'
            $stopped = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                $c = Get-Cluster -Name smal-localbox01
                Stop-Cluster -Cluster $c -ErrorAction Stop
                # Independent service reads on every node before any Hyper-V guest shutdown.
                $services = @(Get-Service -ComputerName LB-NODE01, LB-NODE02, LB-NODE03 -Name clussvc -ErrorAction Stop)
                if ($services.Count -ne 3 -or @($services | Where-Object Status -NE Stopped).Count -ne 0) { throw 'Cluster shutdown not converged' }
                return $true
            }
            Assert-Compute ($stopped -eq $true) 'Cluster graceful shutdown unproved'
            Remove-PSSession $session; $session = $null
            foreach ($name in @('LB-NODE01', 'LB-NODE02', 'LB-NODE03')) {
                $session = New-ComputeSession $name
                Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                    if (@(Get-VM | Where-Object State -NE Off).Count -ne 0) { throw 'Nested VM shutdown not converged' }
                } | Out-Null
                Remove-PSSession $session; $session = $null
            }
            foreach ($name in @('LB-NODE01', 'LB-NODE02', 'LB-NODE03', 'LB-DC01')) {
                $vm = Get-VM -Id $plan.guestIds.PSObject.Properties[$name].Value
                Assert-Compute ($vm.Name -ceq $name -and $vm.State.ToString() -ceq 'Running') 'Exact Running guest required'
                $record.phase = 'shutdown-' + $name; Save-ComputeRecord
                Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop
                Assert-Compute ((Get-VM -Id $vm.Id).State.ToString() -ceq 'Off') 'Graceful shutdown did not reach Off'
            }
            $record.snapshot = Read-ComputeSnapshot $false
            Assert-ComputeSnapshot $record.snapshot @('LB-DC01', 'LB-NODE01', 'LB-NODE02', 'LB-NODE03') $false $false
            $record.snapshot.clusterStopped = $true
        } elseif ($stage -match '^stop-(LB-NODE0[123])$') {
            $name = $Matches[1]
            $session = New-ComputeSession $name
            Invoke-Command -Session $session -ArgumentList $name -ErrorAction Stop -ScriptBlock {
                param($name)
                $c = Get-Cluster -Name smal-localbox01
                if (@(Get-ClusterNode -Cluster $c | Where-Object State -NE Up).Count -ne 0) { throw 'Another node is not Up' }
                Suspend-ClusterNode -Cluster $c -Name $name -Drain -ErrorAction Stop | Out-Null
                if (@(Get-ClusterGroup -Cluster $c | Where-Object { $_.OwnerNode.Name -eq $name -and $_.State.ToString() -eq 'Online' -and $_.Name -ne 'Available Storage' }).Count -ne 0) { throw 'Cluster roles not drained' }
            } | Out-Null
            Remove-PSSession $session; $session = $null
            $vm = Get-VM -Id $plan.guestIds.PSObject.Properties[$name].Value
            Assert-Compute ($vm.Name -ceq $name -and $vm.State.ToString() -ceq 'Running') 'Exact node state changed'
            Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop
            Assert-Compute ((Get-VM -Id $vm.Id).State.ToString() -ceq 'Off') 'Graceful node stop incomplete'
            $record.snapshot = Read-ComputeSnapshot
            Assert-ComputeSnapshot $record.snapshot @($name) $false $true
            Assert-ComputeMaintenanceHealth $record.snapshot $name
        } elseif ($stage -match '^resize-(LB-NODE0[123])$') {
            $name = $Matches[1]
            $vm = Get-VM -Id $plan.guestIds.PSObject.Properties[$name].Value
            Assert-Compute ($vm.Name -ceq $name -and $vm.State.ToString() -ceq 'Off') 'Off prerequisite not proved'
            $record.phase = 'memory-pending'; Save-ComputeRecord
            Set-VMMemory -VM $vm -StartupBytes 128GB -ErrorAction Stop
            Assert-Compute ((Get-VM -Id $vm.Id).State.ToString() -ceq 'Off') 'Off prerequisite changed'
            $record.phase = 'processor-pending'; Save-ComputeRecord
            Set-VMProcessor -VM $vm -Count 16 -ErrorAction Stop
            $record.snapshot = Read-ComputeSnapshot
            $after = @($record.snapshot.guestsStatic | Where-Object name -CEQ $name)[0]
            Assert-Compute ($after.cpu -eq 16 -and $after.memory -eq 128GB -and -not $after.dynamicMemory) 'New static profile differs'
            # Compare every captured non-profile field after the change.
            $after.cpu = 8; $after.memory = 64GB
            Assert-ComputeSnapshot $record.snapshot @($name) $false $true
            Assert-ComputeMaintenanceHealth $record.snapshot $name
            $after.cpu = 16; $after.memory = 128GB
        } elseif ($stage -match '^resume-(LB-NODE0[123])$') {
            $name = $Matches[1]
            $resized = Get-Content (Join-Path $operationRoot ('resize-' + $name + '.json')) -Raw | ConvertFrom-Json
            Assert-Compute ($resized.status -ceq 'complete' -and $resized.planSha256 -ceq $planSha) 'Exact successful resize not proved'
            $session = New-ComputeSession $name
            Invoke-Command -Session $session -ArgumentList $name -ErrorAction Stop -ScriptBlock {
                param($name)
                $c = Get-Cluster -Name smal-localbox01
                $others = @(Get-ClusterNode -Cluster $c | Where-Object Name -NE $name)
                if ($others.Count -ne 2 -or @($others | Where-Object State -NE Up).Count -ne 0) { throw 'Two healthy survivors required' }
                Resume-ClusterNode -Cluster $c -Name $name -Failback NoFailback -ErrorAction Stop | Out-Null
            } | Out-Null
            Remove-PSSession $session; $session = $null
            $record.snapshot = Read-ComputeSnapshot
            Assert-ComputeSnapshot $record.snapshot @() $true $true
        } else { throw 'Unknown sealed stage' }
        $record.mutationPerformed = $true; $record.status = 'complete'; Save-ComputeRecord
    }
} catch {
    $record.status = 'failed-or-uncertain-inspect-before-continuation'
    $record.errorType = $_.Exception.GetType().Name
    $record.errorLine = $_.InvocationInfo.ScriptLineNumber
    if ($recordPath -and (Test-Path $recordPath)) { Save-ComputeRecord }
} finally { if ($session) { Remove-PSSession $session } }
$record | ConvertTo-Json -Depth 30 -Compress
