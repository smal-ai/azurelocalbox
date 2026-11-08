# Restore only the four approved existing guests after an outer-host shutdown.
# No registration, marker deletion, VM reconfiguration or bootstrap invocation.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected outer host' }
$targets = @(
    @{ name = 'LB-DC01'; id = 'f94c71f1-6854-48b9-a9f1-8238c99366d0' },
    @{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34' },
    @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' },
    @{ name = 'LB-NODE03'; id = '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9' }
)
# Validate every identity/state before starting any guest. Never reset a bad state.
foreach ($target in $targets) {
    $vm = Get-VM -Id $target.id
    if ($vm.Name -cne $target.name -or $vm.State.ToString() -notin @('Off', 'Saved', 'Running')) { throw 'Exact approved guest identity or restorable state differs' }
}
$results = @(foreach ($target in $targets) {
    $vm = Get-VM -Id $target.id
    $before = $vm.State.ToString()
    if ($before -ne 'Running') { Start-VM -VM $vm -ErrorAction Stop }
    $vm = Get-VM -Id $target.id
    if ($vm.Name -cne $target.name -or $vm.State.ToString() -ne 'Running') { throw 'Guest did not reach Running' }
    @{ name = $vm.Name; id = $vm.Id.ToString(); before = $before; after = $vm.State.ToString(); startRequested = ($before -ne 'Running'); heartbeatReady = $false }
})
# Heartbeat is an OS-liveness check, not AD/Arc/cluster/application acceptance.
$deadline = [datetime]::UtcNow.AddSeconds(240)
do {
    foreach ($row in $results) {
        $vm = Get-VM -Id $row.id
        if ($vm.Name -cne $row.name -or $vm.State.ToString() -ne 'Running') { throw 'Guest stopped or identity changed during startup' }
        $row.heartbeatReady = $vm.Heartbeat.ToString() -in @('OkApplicationsUnknown', 'OkApplicationsHealthy')
    }
    if (@($results | Where-Object { -not $_.heartbeatReady }).Count -eq 0) { break }
    if ([datetime]::UtcNow -ge $deadline) { throw 'Guest heartbeat readiness timed out. Inspect before retrying.' }
    Start-Sleep -Seconds 5
} while ($true)
@{ atUtc = [datetime]::UtcNow.ToString('o'); guests = $results; registrationInvoked = $false; registrationMarkersChanged = $false; guestOsReadinessVerified = $false; guestHeartbeatVerified = $true } | ConvertTo-Json -Depth 4 -Compress
