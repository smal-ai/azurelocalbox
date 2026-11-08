# Requested existing-disk conversion prerequisite only. Graceful shutdown, no force.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected host' }
if ((Get-Volume -DriveLetter V).HealthStatus.ToString() -ne 'Healthy' -or (Get-VirtualDisk -FriendlyName LocalBoxData).UniqueId -cne 'D0CDB2F96D0E244E8B532E096F97FBBF') { throw 'Expected healthy V storage differs' }
$targets = @(
    @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' },
    @{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34' },
    @{ name = 'LB-DC01'; id = 'f94c71f1-6854-48b9-a9f1-8238c99366d0' }
)
if (@(Get-VM).Count -ne 3) { throw 'Unexpected additional guests. Do not stop unknown VMs.' }
foreach ($target in $targets) {
    $vm = Get-VM -Id $target.id
    if ($vm.Name -cne $target.name -or $vm.State.ToString() -notin @('Running','Off')) { throw 'Exact guest identity or restorable state differs' }
}
$results = @(foreach ($target in $targets) {
    $vm = Get-VM -Id $target.id; $before = $vm.State.ToString()
    if ($before -eq 'Running') { Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop }
    $after = Get-VM -Id $target.id
    if ($after.Name -cne $target.name -or $after.State.ToString() -ne 'Off') { throw 'Guest did not shut down. No forced turn-off allowed.' }
    @{ name = $after.Name; id = $after.Id.ToString(); before = $before; after = $after.State.ToString(); gracefulStopRequested = ($before -eq 'Running') }
})
@{ atUtc = [datetime]::UtcNow.ToString('o'); guests = $results; forcedPowerOffRequested = $false; registrationInvoked = $false; configurationOrStorageChanged = $false } | ConvertTo-Json -Depth 4 -Compress
