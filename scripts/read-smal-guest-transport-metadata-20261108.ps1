# Outer-only metadata. No guest authentication, service change, secret or session dump.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Wrong outer host' }
$began = [datetime]::UtcNow.ToString('o')
$targets = @{
    'LB-NODE01' = '3adff629-2f67-449b-ab32-8a8748c46f34'
    'LB-NODE02' = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3'
    'LB-NODE03' = '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9'
}
$queries = @()
$queries += Read-InitialQuery 'currentExactGuestAndIntegrationMetadata' {
    foreach ($name in ($targets.Keys | Sort-Object)) {
        $vm = Get-VM -Id $targets[$name]
        if ($vm.Name -cne $name) { throw 'Exact guest identity differs' }
        @{ name = $name; id = $vm.Id.ToString(); state = $vm.State.ToString(); cpu = $vm.ProcessorCount
            fixedMemoryBytes = $vm.MemoryStartup; assignedMemoryBytes = $vm.MemoryAssigned
            dynamicMemory = $vm.DynamicMemoryEnabled; heartbeat = $vm.Heartbeat.ToString()
            integrationServices = @(Get-VMIntegrationService -VM $vm | ForEach-Object {
                @{ name = $_.Name; enabled = $_.Enabled; primaryStatus = $_.PrimaryStatusDescription; secondaryStatus = $_.SecondaryStatusDescription }
            }) }
    }
}
$queries += Read-InitialQuery 'outerServiceMetadata' {
    Get-CimInstance Win32_Service -Filter "Name='vmms' OR Name='vmcompute'" | ForEach-Object {
        Select-InitialFields $_ @('Name','State','StartMode','ExitCode','ServiceSpecificExitCode')
    }
}
$queries += Read-InitialQuery 'existingBindingAndSelectorMetadata' {
    $boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
    $bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
    $entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
    $helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
    if ($entry.Count -ne 1 -or (Get-FileHash -LiteralPath $helper).Hash -cne $entry[0].sha256) { throw 'Existing uploaded helper differs' }
    $bindings = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw | ConvertFrom-Json
    foreach ($name in ($targets.Keys | Sort-Object)) {
        $binding = $bindings.nodes.PSObject.Properties[$name].Value
        @{ name = $name; expectedVmId = $targets[$name]; boundVmId = $binding.vmId
            role = $binding.role; secretDirectory = $binding.secretDirectory; loginVerified = $binding.loginVerified
            canonicalUserSelector = $name + '\ASBuiltInAdmin'; uploadedHelperSha256 = $entry[0].sha256
            secretValueRead = $false; authenticationAttempted = $false }
    }
}
$queries += Read-InitialQuery 'processLocalClientSessionState' {
    Get-PSSession | Where-Object { $_.VMId -and $_.VMId.ToString() -in @($targets.Values) } | ForEach-Object {
        @{ vmId = $_.VMId.ToString(); state = $_.State.ToString(); availability = $_.Availability.ToString()
            scope = 'current-outer-PowerShell-process-only-not-guest-server-session-inventory' }
    }
}
$queries += Read-InitialQuery 'installedPSDirectParameterMetadata' {
    $command = Get-Command New-PSSession
    @{ name = $command.Name; module = $command.ModuleName; vmIdParameterPresent = $command.Parameters.ContainsKey('VMId')
        vmNameParameterPresent = $command.Parameters.ContainsKey('VMName'); credentialParameterPresent = $command.Parameters.ContainsKey('Credential') }
}
foreach ($log in @('Microsoft-Windows-Hyper-V-VMMS-Admin','Microsoft-Windows-Hyper-V-Worker-Admin')) {
    $queries += Read-InitialQuery ('retainedFailureWindow:' + $log) {
        $events = @()
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = [datetime]::Parse('2026-11-08T15:20:00Z').ToLocalTime(); EndTime = [datetime]::Parse('2026-11-08T15:32:00Z').ToLocalTime() } -MaxEvents 40 -ErrorAction Stop)
        } catch {
            if ($_.FullyQualifiedErrorId -notmatch '^NoMatchingEventsFound') { throw }
        }
        $rows = @(foreach ($event in $events) {
            $xml = $event.ToXml()
            $ids = @($targets.Values | Where-Object { $xml -imatch [regex]::Escape($_) })
            if ($ids.Count) {
                @{ eventId = $event.Id; provider = $event.ProviderName; level = $event.Level; timeCreated = $event.TimeCreated.ToUniversalTime().ToString('o')
                    recordId = $event.RecordId; matchedVmIds = $ids
                    hexCodeSelectors = @([regex]::Matches($xml, '0x[0-9a-fA-F]{8}') | ForEach-Object Value | Sort-Object -Unique) }
            }
        })
        @{ log = $log; captureLimit = 40; inspectedEventCount = $events.Count; traversalComplete = $events.Count -lt 40
            relevantEventCount = $rows.Count; events = $rows; rawMessageOrXmlExported = $false }
    }
}
@{ status = $(if (@($queries | Where-Object complete -EQ $false).Count) { 'partial-read-only' } else { 'complete' })
    scope = 'LocalBox-Client-outer-metadata-only'; beganAtUtc = $began; finishedAtUtc = [datetime]::UtcNow.ToString('o')
    mutationPerformed = $false; guestAuthenticationAttempted = $false
    qualification = 'Guest Service Interface metadata does not by itself establish PowerShell Direct service state. Process-local session absence is not global absence.'
    queries = $queries } | ConvertTo-Json -Depth 18 -Compress
