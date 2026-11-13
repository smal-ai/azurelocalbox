param([Parameter(Mandatory = $true)][string]$ConfigurationBase64)
$ErrorActionPreference = 'Stop'
$config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ConfigurationBase64)) | ConvertFrom-Json
if ($env:COMPUTERNAME -cne $config.hostName) { throw 'Wrong outer host' }
$mutex = [Threading.Mutex]::new($false, 'Global\AzureLocalBoxComputeCapacityR2')
$held = $false
try {
    try { $held = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another platform operation is currently running' }
    $targets = @($config.guestIds.PSObject.Properties | Sort-Object Name)
    foreach ($target in $targets) {
        $vm = Get-VM -Id $target.Value
        if ($vm.Name -cne $target.Name -or $vm.State.ToString() -notin @('Off', 'Saved', 'Running')) {
            throw 'Unexpected guest identity or transitional state'
        }
    }
    $results = @(foreach ($target in $targets) {
        $vm = Get-VM -Id $target.Value
        $before = $vm.State.ToString()
        if ($before -cne 'Running') { Start-VM -VM $vm }
        @{ name = $target.Name; id = $target.Value; before = $before; startRequested = ($before -cne 'Running'); heartbeatReady = $false }
    })
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        foreach ($row in $results) {
            $vm = Get-VM -Id $row.id
            $row.after = $vm.State.ToString()
            $row.heartbeatReady = $vm.Heartbeat.ToString() -in @('OkApplicationsUnknown', 'OkApplicationsHealthy')
        }
        if (@($results | Where-Object { $_.after -cne 'Running' -or -not $_.heartbeatReady }).Count -eq 0) { break }
        if ($watch.Elapsed.TotalSeconds -ge 240) { throw 'Guest heartbeat wait timed out. Inspect current state' }
        Start-Sleep -Seconds 5
    } while ($true)
    @{ guests = $results; observedAt = [datetime]::UtcNow.ToString('o'); registrationInvoked = $false } | ConvertTo-Json -Depth 5 -Compress
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
