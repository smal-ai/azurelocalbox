# Activate only the already accepted Windows Server Evaluation licence on the DC.
# No key installation, rearm, paid licence, HCI registration or cloud subscription.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\eval-activation-20261028-01'
$bootRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$imageRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01'
if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or (Test-Path $root)) { throw 'Target differs or activation attempt exists. Inspect, never repeat blindly.' }
$bundle = Get-Content (Join-Path $bootRoot 'bundle.json') -Raw | ConvertFrom-Json
$secret = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
$helper = Join-Path $bootRoot 'smal-guest-secret-functions.ps1'
if ($secret.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $secret[0].sha256) { throw 'Secret helper differs' }
. $helper
$vm = Get-VM -Id 'f94c71f1-6854-48b9-a9f1-8238c99366d0'
if ($vm.Name -cne 'LB-DC01' -or $vm.State.ToString() -ne 'Running') { throw 'Exact DC differs' }
$null = New-Item $root -ItemType Directory
Set-Acl -Path $root -AclObject (Get-Acl $bootRoot)
$statePath = Join-Path $root 'state.json'
$state = @{ runId = 'eval-activation-20261028-01'; sourceCommit = '__SOURCE_COMMIT__'; scope = 'accepted-dc-evaluation-activation-only'; status = 'pending'; atUtc = [datetime]::UtcNow.ToString('o'); paidLicencePurchased = $false; productKeyChanged = $false; azureRegistrationPerformed = $false }
[IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$secure = Read-LabGuestSecureSecret -SecretDirectory (Join-Path $imageRoot 'secrets') -Role 'dc-admin'; $session = $null
try {
    $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new('LOCALBOX\Administrator', $secure)) -ErrorAction Stop
    $state.result = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        if ($env:COMPUTERNAME -cne 'LB-DC01' -or $version.EditionID -cne 'ServerStandardEval') { throw 'Accepted Evaluation OS differs' }
        $licenseId = '753c53a2-4274-4339-8c2e-f66c0b9646c5'
        $product = Get-CimInstance SoftwareLicensingProduct -Filter ("ID='" + $licenseId + "'")
        if ($product.Description -notlike '*TIMEBASED_EVAL*' -or $product.Name -notlike '*ServerStandardEval*') { throw 'Evaluation licence identity differs' }
        $before = $product.LicenseStatus
        $performed = $false; $returnCode = 0
        if ($before -ne 1) {
            if ($before -ne 2) { throw 'Unexpected licence state. No activation attempt.' }
            $activation = Invoke-CimMethod -InputObject $product -MethodName Activate -ErrorAction Stop
            $returnCode = $activation.ReturnValue; $performed = $true
        }
        $after = Get-CimInstance SoftwareLicensingProduct -Filter ("ID='" + $licenseId + "'")
        # This provider may expose Activate as a void method. No thrown exception
        # plus independently re-read Licensed state is success, not a null-code failure.
        @{ computer = $env:COMPUTERNAME; licenceId = $licenseId; beforeStatus = $before; afterStatus = $after.LicenseStatus; graceMinutes = $after.GracePeriodRemaining; activationPerformed = $performed; returnCode = $returnCode; returnCodeProvided = ($null -ne $returnCode); activated = ($after.LicenseStatus -eq 1 -and ($null -eq $returnCode -or $returnCode -eq 0)); keyValueExported = $false }
    }
    $state.status = if ($state.result.activated) { 'evaluation-activated' } else { 'activation-not-verified-inspect-before-resume' }
} catch { $state.status = 'failed-or-uncertain-inspect-before-resume'; $state.errorType = $_.Exception.GetType().Name }
finally {
    if ($session) { Remove-PSSession -Session $session }; $secure.Dispose()
    $state.atUtc = [datetime]::UtcNow.ToString('o')
    $temporary = Join-Path $root 'state.json.tmp'
    [IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    [IO.File]::Replace($temporary, $statePath, (Join-Path $root 'state.before-result.json'))
}
$state | ConvertTo-Json -Depth 5 -Compress
