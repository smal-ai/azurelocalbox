# Read-only hardware metadata discriminator. No inferred NUMA property names/units.
$ErrorActionPreference = 'Stop'
$session = $null; $secure = $null
$read = {
    $ErrorActionPreference = 'Stop'
    $h = Get-VMHost
    @{ logicalProcessors = $h.LogicalProcessorCount; memoryBytes = $h.MemoryCapacity
       cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
       numa = @(Get-VMHostNumaNode | ForEach-Object {
           @{ properties = @($_.PSObject.Properties | ForEach-Object {
               $v = $_.Value
               @{ name = $_.Name; type = $_.TypeNameOfValue
                  scalar = $(if ($null -eq $v -or $v -is [string] -or $v -is [ValueType]) { $v } else { $null })
                  count = $(if ($v -is [Collections.IEnumerable] -and $v -isnot [string]) { @($v).Count } else { $null })
                  primitiveItems = $(if ($v -is [array] -and @($v | Where-Object { $_ -isnot [ValueType] -and $_ -isnot [string] }).Count -eq 0) { @($v) } else { @() }) }
           }) }
       }) }
}
try {
    if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Wrong outer host' }
    $result = @{ host = (& $read); nodes = @{} }
    $boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
    $bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
    $entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
    $helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
    if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Existing secret helper differs' }
    . $helper
    $store = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'
    $bindings = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw | ConvertFrom-Json
    $targets = @(@{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34' }, @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' }, @{ name = 'LB-NODE03'; id = '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9' })
    foreach ($target in $targets) {
        $vm = Get-VM -Id $target.id; $binding = $bindings.nodes.PSObject.Properties[$target.name].Value
        if ($vm.Name -cne $target.name -or $vm.State.ToString() -cne 'Running' -or $binding.vmId -ine $target.id -or $binding.role -cne 'cluster-node-admin' -or $binding.secretDirectory -cne $store -or $binding.loginVerified -ne $true) { throw 'Exact node/credential binding differs' }
        $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'
        $session = New-PSSession -VMId $target.id -Credential ([pscredential]::new(($target.name + '\ASBuiltInAdmin'), $secure)) -ErrorAction Stop
        $who = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock { @{ name = $env:COMPUTERNAME; sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } }
        if ($who.name -cne $target.name -or -not $who.sid.EndsWith('-500')) { throw 'RID 500 identity differs' }
        $result.nodes[$target.name] = Invoke-Command -Session $session -ScriptBlock $read -ErrorAction Stop
        Remove-PSSession $session; $session = $null; $secure.Dispose(); $secure = $null
    }
    @{ status = 'complete'; atUtc = [datetime]::UtcNow.ToString('o'); observerPart = 'topology'; mutationPerformed = $false; result = $result } | ConvertTo-Json -Depth 15 -Compress
} catch {
    @{ status = 'failed-read-only'; atUtc = [datetime]::UtcNow.ToString('o'); mutationPerformed = $false; errorType = $_.Exception.GetType().Name; errorLine = $_.InvocationInfo.ScriptLineNumber } | ConvertTo-Json -Compress
} finally { if ($session) { Remove-PSSession $session }; if ($secure) { $secure.Dispose() } }
