# Exact outer-Hyper-V VM metadata only. No sessions, credentials or configuration writes.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine 'LocalBox-Client' -or $env:OS -cne 'Windows_NT') { throw 'Exact LocalBox-Client Windows host required' }
$targets = @(
    @{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34' },
    @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' },
    @{ name = 'LB-NODE03'; id = '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9' }
)
$rows = @(foreach ($target in $targets) {
    $vm = Get-VM -Id ([guid]$target.id) -ErrorAction Stop
    if ($vm.Name -cne $target.name -or $vm.Id.ToString() -ine $target.id) { throw 'Exact HCI VM identity mismatch' }
    @{ name = $target.name; id = $vm.Id.ToString(); cpu = [int]$vm.ProcessorCount
       startupMemoryBytes = [long]$vm.MemoryStartup; assignedMemoryBytes = [long]$vm.MemoryAssigned; state = $vm.State.ToString() }
})
@{ status = 'exact-hci-assigned-memory-read'; hostName = $env:COMPUTERNAME
   atUtc = [datetime]::UtcNow.ToString('o'); rows = $rows; writesPerformed = $false } | ConvertTo-Json -Depth 4 -Compress
