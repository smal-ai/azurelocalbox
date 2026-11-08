# HUMAN TTY ONLY. One approved NODE3, official device authentication, no exported token.
param([switch]$InspectOnly)
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\arc-node03-console-20261029-01'
$approvalPath = Join-Path $root 'approval.json'
if ($env:COMPUTERNAME -cne 'LocalBox-Client' -or (Get-FileHash $approvalPath).Hash -cne '__NODE03_APPROVAL_SHA256__') { throw 'Exact approved NODE3 console context differs' }
$approval = Get-Content $approvalPath -Raw | ConvertFrom-Json
if ($approval.approved -ne $true -or $approval.node03HumanDeviceCodeAuthenticationAndScopedRolesApproved -ne $true) { throw 'Explicit NODE3 device authentication approval missing' }
$vm = Get-VM -Id '__NODE03_VM_ID__'
if ($vm.Name -cne 'LB-NODE03' -or $vm.State.ToString() -ne 'Running' -or $vm.MemoryStartup -ne 64GB -or $vm.ProcessorCount -ne 8) { throw 'Exact running NODE3 identity/profile differs' }
$job = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\node03-20261029-01\state.json' -Raw | ConvertFrom-Json
if ($job.status -cne 'complete-node03-local-bootstrap-cleanup-and-common-login' -or $job.vm.vmId -ine $vm.Id.ToString() -or $job.commonCredentialLoginVerified -ne $true -or $job.cleanup.setupLogsNeedReview -or $job.cleanup.answerFileCleanupNeedsReview) { throw 'Verified NODE3 local preparation/cleanup proof missing' }
$boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
$secret = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
$helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
if ($secret.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $secret[0].sha256) { throw 'Secret helper differs' }
. $helper
$store = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'
$binding = (Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw | ConvertFrom-Json).nodes.'LB-NODE03'
if ($binding.vmId -ine $vm.Id.ToString() -or $binding.role -cne 'cluster-node-admin' -or $binding.secretDirectory -cne $store -or $binding.loginVerified -ne $true) { throw 'Exact public NODE3 credential binding differs' }
$secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'; $session = $null; $attemptCreated = $false
$statePath = Join-Path $root 'LB-NODE03.state.json'
$state = @{ sourceCommit = '__SOURCE_COMMIT__'; node = 'LB-NODE03'; vmId = $vm.Id.ToString(); auth = 'human-device-code'; explicitOwnerTokenProvided = $false }
try {
    $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new('LB-NODE03\Administrator', $secure)) -ErrorAction Stop
    if (-not $InspectOnly) {
        $marker = [IO.File]::Open((Join-Path $root 'LB-NODE03.registration.started'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); $marker.Dispose(); $attemptCreated = $true
        $state.status = 'invoking-official-registration-human-auth-required'; $state.atUtc = [datetime]::UtcNow.ToString('o')
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        Write-Host 'Authenticate only in the official Microsoft browser flow with the approved tenant/account. Do not copy codes or credentials into chat/files.'
        # Authentication output stays in the human terminal. Never capture/transcribe it.
        Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            if ($env:COMPUTERNAME -cne 'LB-NODE03' -or (Get-CimInstance Win32_ComputerSystem).DomainRole -ne 2) { throw 'Exact standalone NODE3 differs' }
            $command = Get-Command Invoke-AzStackHciArcInitialization
            if ($command.Module.Version.ToString() -ne '1.0.0' -or (Get-FileHash $command.Module.Path).Hash -cne '70B11110F8483898A5CB3667A92F26315361847437832826C58DE53320746F0F' -or -not $command.Parameters.ContainsKey('TargetSolutionVersion')) { throw 'Pinned supported bootstrap component differs' }
            Invoke-AzStackHciArcInitialization -TenantID 'c6e67968-af25-4557-ab8b-06b693048d3b' -SubscriptionID '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea' -ResourceGroup 'rg-localbox-platform-weu-1' -Region 'westeurope' -Cloud 'AzureCloud' -TargetSolutionVersion '12.2610.1004.41'
        }
    }
    $observed = Invoke-Command -Session $session -ScriptBlock { @{ computer = $env:COMPUTERNAME; bootstrapStatus = [string](Get-ArcBootstrapStatus).Response.Status; atUtc = [datetime]::UtcNow.ToString('o') } } -ErrorAction Stop
    $observed | ConvertTo-Json -Compress
    if ($attemptCreated) { $state.status = 'command-returned-independent-arm-verification-required'; $state.observed = $observed; $state.atUtc = [datetime]::UtcNow.ToString('o'); [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false)) }
} catch {
    if ($attemptCreated) { $state.status = 'failed-or-interrupted-inspect-before-resume'; $state.errorType = $_.Exception.GetType().Name; $state.atUtc = [datetime]::UtcNow.ToString('o'); [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false)) }
    throw 'NODE3 registration not independently verified. Preserve its marker and use --inspect before any continuation.'
} finally { if ($session) { Remove-PSSession $session }; $secure.Dispose() }
