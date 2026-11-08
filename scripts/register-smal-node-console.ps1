# HUMAN CONSOLE ONLY. Official device-code authentication, no exported ARM token.
param(
    [Parameter(Mandatory=$true)][ValidateSet('LB-NODE01','LB-NODE02')][string]$NodeName,
    [switch]$InspectOnly,
    [switch]$RetryAfterAuthorizationFailure
)
$ErrorActionPreference = 'Stop'
if ($RetryAfterAuthorizationFailure -and ($InspectOnly -or $NodeName -cne 'LB-NODE02')) { throw 'Recovery is only for the diagnosed NODE2 authorization failure' }
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\arc-console-20261028-01'
$approvalPath = Join-Path $root 'approval.json'
if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or (Get-FileHash $approvalPath).Hash -cne '__APPROVAL_SHA256__') { throw 'Approved registration context differs' }
$approval = Get-Content $approvalPath -Raw | ConvertFrom-Json
if ($approval.approved -ne $true -or $approval.humanDeviceCodeAuthenticationApproved -ne $true -or $approval.existingArmTokenForwardingApproved -ne $false) { throw 'Explicit device-code scope missing' }
$ids = @{ 'LB-NODE01' = '3adff629-2f67-449b-ab32-8a8748c46f34'; 'LB-NODE02' = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' }
$vm = Get-VM -Id $ids[$NodeName]
if ($vm.Name -cne $NodeName -or $vm.State.ToString() -ne 'Running') { throw 'Exact running node differs' }
$boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
$secret = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
$helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
if ($secret.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $secret[0].sha256) { throw 'Secret helper differs' }
. $helper
$store = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'
$binding = (Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw | ConvertFrom-Json).nodes.PSObject.Properties[$NodeName].Value
if ($binding.loginVerified -ne $true -or $binding.vmId -ine $vm.Id.ToString() -or $binding.secretDirectory -cne $store -or $binding.role -cne 'cluster-node-admin') { throw 'Verified node credential binding differs' }
$secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'; $session = $null
$statePath = Join-Path $root ($NodeName + '.state.json')
if ($RetryAfterAuthorizationFailure) { $statePath = Join-Path $root ($NodeName + '.authorization-retry-20261029.state.json') }
$attemptCreated = $false
$state = @{ sourceCommit = '__SOURCE_COMMIT__'; node = $NodeName; vmId = $vm.Id.ToString(); tenant = 'c6e67968-af25-4557-ab8b-06b693048d3b'; subscription = '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea'; resourceGroup = 'rg-localbox-platform-weu-1'; region = 'westeurope'; solution = '12.2610.1004.41'; auth = 'human-device-code'; explicitOwnerTokenProvided = $false }
try {
    $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($NodeName + '\Administrator'), $secure)) -ErrorAction Stop
    if (-not $InspectOnly) {
        $markerPath = Join-Path $root ($NodeName + '.registration.started')
        if ($RetryAfterAuthorizationFailure) {
            if (-not (Test-Path -LiteralPath $markerPath) -or (Test-Path -LiteralPath $statePath)) { throw 'Original registration marker missing or recovery state already exists' }
            $eligible = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                $s = Get-ArcBootstrapStatus
                $arc = @($s.Response.DetailedResponse | Where-Object Name -EQ 'ArcConfiguration')
                $reg = @($arc.DetailedResponse | Where-Object Name -EQ 'ArcRegistration')
                $connectivity = @($arc.DetailedResponse | Where-Object Name -EQ 'ConnectivityValidation')
                $log = Get-Content -LiteralPath 'C:\ProgramData\AzureConnectedMachineAgent\Log\azcmagent.log' -Tail 3000
                [bool]($s.Response.Status -eq 'Failed' -and $reg.Count -eq 1 -and $reg[0].Status -eq 'Failed' -and $connectivity.Count -eq 1 -and $connectivity[0].Status -eq 'Succeeded' -and ($log -match 'AuthorizationFailed' -match 'Microsoft.HybridCompute/machines/write').Count -gt 0)
            }
            if ($eligible -ne $true) { throw 'Current node state does not match the diagnosed authorization failure' }
            $markerPath = Join-Path $root ($NodeName + '.authorization-retry-20261029.started')
        }
        $marker = [IO.File]::Open($markerPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); $marker.Dispose()
        $attemptCreated = $true
        $state.status = 'invoking-official-registration-human-auth-required'; $state.atUtc = [datetime]::UtcNow.ToString('o')
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        Write-Host 'Authenticate only in the official Microsoft browser flow, using the approved tenant/account. Do not copy codes or credentials into files/chat.'
        # Output remains in this human console. It is not captured into job/state/transcript files.
        Invoke-Command -Session $session -ArgumentList $NodeName -ErrorAction Stop -ScriptBlock {
            param($ExpectedName)
            $ErrorActionPreference = 'Stop'
            if ($env:COMPUTERNAME -cne $ExpectedName -or (Get-CimInstance Win32_ComputerSystem).DomainRole -ne 2) { throw 'Expected standalone node differs' }
            $command = Get-Command Invoke-AzStackHciArcInitialization
            if ($command.Module.Version.ToString() -ne '1.0.0' -or (Get-FileHash $command.Module.Path).Hash -cne '70B11110F8483898A5CB3667A92F26315361847437832826C58DE53320746F0F' -or -not $command.Parameters.ContainsKey('TargetSolutionVersion')) { throw 'Pinned supported bootstrap component differs' }
            Invoke-AzStackHciArcInitialization -TenantID 'c6e67968-af25-4557-ab8b-06b693048d3b' -SubscriptionID '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea' -ResourceGroup 'rg-localbox-platform-weu-1' -Region 'westeurope' -Cloud 'AzureCloud' -TargetSolutionVersion '12.2610.1004.41'
        }
    }
    $observed = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $status = Get-ArcBootstrapStatus
        @{ computer = $env:COMPUTERNAME; bootstrapStatus = [string]$status.Response.Status; atUtc = [datetime]::UtcNow.ToString('o') }
    }
    $observed | ConvertTo-Json -Compress
    if (-not $InspectOnly) { $state.status = 'command-returned-independent-arm-verification-required'; $state.observed = $observed; $state.atUtc = [datetime]::UtcNow.ToString('o'); [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false)) }
} catch {
    if ($attemptCreated) { $state.status = 'interrupted-or-failed-inspect-before-resume'; $state.errorType = $_.Exception.GetType().Name; $state.atUtc = [datetime]::UtcNow.ToString('o'); [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false)) }
    throw 'Registration was not independently verified. Keep its marker; inspect status before any retry or documented reboot continuation.'
} finally { if ($session) { Remove-PSSession -Session $session }; $secure.Dispose() }
