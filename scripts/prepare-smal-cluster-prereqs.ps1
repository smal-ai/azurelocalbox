# Approved local cluster prerequisites only. No Arc/cloud registration or formatting.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01'
$bootRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$imageRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01'
if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or (Test-Path $root)) { throw 'Target differs or prerequisite attempt exists. Inspect, never replay.' }
$old = Get-Content (Join-Path $bootRoot 'state.json') -Raw | ConvertFrom-Json
if ($old.status -ne 'local-bootstrap-configured-and-checked' -or @($old.newCredentialLoginVerified.PSObject.Properties | Where-Object Value -EQ $true).Count -ne 3) { throw 'Completed verified guest bootstrap required' }
$bundle = Get-Content (Join-Path $bootRoot 'bundle.json') -Raw | ConvertFrom-Json
$secret = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
$helper = Join-Path $bootRoot 'smal-guest-secret-functions.ps1'
if ($secret.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $secret[0].sha256) { throw 'Secret helper differs' }
. $helper
$null = New-Item $root -ItemType Directory; Set-Acl -Path $root -AclObject (Get-Acl $bootRoot)
$store = Join-Path $root 'secrets'; $null = New-Item $store -ItemType Directory
$statePath = Join-Path $root 'state.json'; $bindingsPath = Join-Path $root 'credential-bindings.json'
$state = [ordered]@{ runId = 'cluster-prereqs-20261028-01'; sourceCommit = '__SOURCE_COMMIT__'; scope = 'approved-local-ou-and-common-node-credential-only'; status = 'running'; phase = 'prechecks'; atUtc = $null; ad = $null; nodes = @{}; errorType = $null; azureRegistrationPerformed = $false }
$bindings = @{ schemaVersion = 1; runId = $state.runId; sourceCommit = $state.sourceCommit; nodes = @{} }
function Save-ClusterPrereq {
    param([string]$Phase)
    $state.phase = $Phase; $state.atUtc = [datetime]::UtcNow.ToString('o')
    $temporary = $statePath + '.tmp'
    [IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Depth 7), [Text.UTF8Encoding]::new($false))
    if (Test-Path $statePath) { [IO.File]::Replace($temporary, $statePath, (Join-Path $root 'state.previous.json')) } else { [IO.File]::Move($temporary, $statePath) }
    [IO.File]::AppendAllText((Join-Path $root 'events.jsonl'), ((@{ atUtc = $state.atUtc; phase = $Phase; status = $state.status } | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}
$session = $null; $secure = $null; $lcm = $null; $common = $null
try {
    Save-ClusterPrereq 'create-cluster-only-encrypted-secret'
    $value = New-LabGuestSecretText
    Write-LabGuestSecret -SecretDirectory $store -Role 'cluster-node-admin' -Value $value; $value = $null
    $common = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'
    $dc = Get-VM -Id 'f94c71f1-6854-48b9-a9f1-8238c99366d0'
    if ($dc.Name -cne 'LB-DC01' -or $dc.State.ToString() -ne 'Running') { throw 'Exact DC differs' }
    $secure = Read-LabGuestSecureSecret -SecretDirectory (Join-Path $imageRoot 'secrets') -Role 'dc-admin'
    $lcm = Read-LabGuestSecureSecret -SecretDirectory (Join-Path $imageRoot 'secrets') -Role 'deployment-user'
    $session = New-PSSession -VMId $dc.Id -Credential ([pscredential]::new('LOCALBOX\Administrator', $secure)) -ErrorAction Stop
    Save-ClusterPrereq 'prepare-new-owned-cluster-ou-and-lcm'
    $state.ad = Invoke-Command -Session $session -ArgumentList $lcm -ErrorAction Stop -ScriptBlock {
        param($LcmValue)
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -cne 'LB-DC01') { throw 'DC identity differs' }
        Import-Module ActiveDirectory
        if ((Get-ADDomain).DNSRoot -cne 'ad.localbox.test') { throw 'Domain identity differs' }
        if (-not (Get-Command Get-GPInheritance -ErrorAction SilentlyContinue)) {
            $feature = Install-WindowsFeature -Name GPMC -IncludeManagementTools
            if (-not $feature.Success -or $feature.RestartNeeded.ToString() -eq 'Yes') { throw 'GPO tooling requires inspection before OU changes' }
        }
        Import-Module GroupPolicy
        $domainDn = 'DC=ad,DC=localbox,DC=test'; $parentDn = 'OU=AzureLocal,' + $domainDn; $ouDn = 'OU=SMAL01,' + $parentDn
        if ((Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$parentDn'") -or (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDn'") -or (Get-ADUser -Filter "SamAccountName -eq 'lboxdeploy'")) { throw 'Existing AD objects conflict. No reset or deletion allowed.' }
        if (@((Get-GPInheritance -Target $domainDn).GpoLinks | Where-Object Enforced -EQ $true).Count -ne 0) { throw 'Enforced domain GPOs require review, not bypass filters' }
        $policy = Get-ADDefaultDomainPasswordPolicy
        $before = @{ complexity = $policy.ComplexityEnabled; minLength = $policy.MinPasswordLength; maxAgeTicks = $policy.MaxPasswordAge.Ticks; lockoutThreshold = $policy.LockoutThreshold }
        $null = New-ADOrganizationalUnit -Name AzureLocal -Path $domainDn -ProtectedFromAccidentalDeletion $true
        $null = New-ADOrganizationalUnit -Name SMAL01 -Path $parentDn -ProtectedFromAccidentalDeletion $true
        New-ADUser -Name lboxdeploy -SamAccountName lboxdeploy -UserPrincipalName 'lboxdeploy@ad.localbox.test' -AccountPassword $LcmValue -Enabled $true -PasswordNeverExpires $false -Path $ouDn
        $user = Get-ADUser lboxdeploy -Properties PasswordNeverExpires, MemberOf, msDS-UserPasswordExpiryTimeComputed
        $acl = Get-Acl ('AD:\' + $ouDn)
        $sid = [Security.Principal.SecurityIdentifier]$user.SID
        $allow = [Security.AccessControl.AccessControlType]::Allow
        $all = [DirectoryServices.ActiveDirectorySecurityInheritance]::All
        $computer = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2'; $recovery = [guid]'ea715d30-8f53-40d0-bd1e-6109186d782c'
        $child = [DirectoryServices.ActiveDirectoryRights]::CreateChild -bor [DirectoryServices.ActiveDirectoryRights]::DeleteChild
        $acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new($sid, $child, $allow, $computer, $all))
        $acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new($sid, [DirectoryServices.ActiveDirectoryRights]::ReadProperty, $allow, [guid]::Empty, $all))
        $acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new($sid, [DirectoryServices.ActiveDirectoryRights]::GenericAll, $allow, $all, $recovery))
        Set-Acl -Path ('AD:\' + $ouDn) -AclObject $acl
        $null = Set-GPInheritance -Target $ouDn -IsBlocked Yes
        $policy = Get-ADDefaultDomainPasswordPolicy
        $after = @{ complexity = $policy.ComplexityEnabled; minLength = $policy.MinPasswordLength; maxAgeTicks = $policy.MaxPasswordAge.Ticks; lockoutThreshold = $policy.LockoutThreshold }
        foreach ($key in $before.Keys) { if ($before[$key] -ne $after[$key]) { throw 'Default domain account policy changed unexpectedly' } }
        if ($user.PasswordNeverExpires -or @($user.MemberOf).Count -ne 0 -or -not (Get-GPInheritance -Target $ouDn).GpoInheritanceBlocked) { throw 'LCM expiry/group or OU inheritance result differs' }
        $grants = @((Get-Acl ('AD:\' + $ouDn)).Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $sid.Value } | Select-Object ActiveDirectoryRights, ObjectType, InheritedObjectType, InheritanceType)
        if ($grants.Count -ne 3) { throw 'Expected three scoped OU ACEs missing or unexpected' }
        @{ ou = $ouDn; user = 'lboxdeploy'; upn = 'lboxdeploy@ad.localbox.test'; userSid = $sid.Value; normalExpiryRetained = $true; inheritanceBlockedOnlyOnNewClusterOu = $true; domainAccountPolicyUnchanged = $true; scopedAces = $grants; enforcedGpoBypassApplied = $false }
    }
    Remove-PSSession -Session $session; $session = $null; $secure.Dispose(); $secure = $null; $lcm.Dispose(); $lcm = $null
    foreach ($row in @(@{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34'; role = 'node01-admin' }, @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3'; role = 'node02-admin' })) {
        $vm = Get-VM -Id $row.id
        if ($vm.Name -cne $row.name -or $vm.State.ToString() -ne 'Running') { throw 'Node identity differs' }
        $secure = Read-LabGuestSecureSecret -SecretDirectory (Join-Path $imageRoot 'secrets') -Role $row.role
        $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($row.name + '\Administrator'), $secure)) -ErrorAction Stop
        Save-ClusterPrereq ($row.name + '-set-approved-common-node-credential')
        $null = Invoke-Command -Session $session -ArgumentList $row.name, $common -ErrorAction Stop -ScriptBlock { param($Name, $Value); $ErrorActionPreference = 'Stop'; if ($env:COMPUTERNAME -cne $Name -or (Get-CimInstance Win32_ComputerSystem).DomainRole -ne 2) { throw 'Standalone node identity differs' }; Set-LocalUser -Name Administrator -Password $Value }
        Remove-PSSession -Session $session; $session = $null; $secure.Dispose(); $secure = $null
        Save-ClusterPrereq ($row.name + '-verify-common-credential-login')
        $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($row.name + '\Administrator'), $common)) -ErrorAction Stop
        $name = Invoke-Command -Session $session -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
        if ($name -cne $row.name) { throw 'New node login identity differs' }
        Remove-PSSession -Session $session; $session = $null
        $bindings.nodes[$row.name] = @{ vmId = $vm.Id.ToString(); secretDirectory = $store; role = 'cluster-node-admin'; loginVerified = $true }
        $temporary = $bindingsPath + '.tmp'
        [IO.File]::WriteAllText($temporary, ($bindings | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        if (Test-Path $bindingsPath) { [IO.File]::Replace($temporary, $bindingsPath, (Join-Path $root 'credential-bindings.previous.json')) } else { [IO.File]::Move($temporary, $bindingsPath) }
        $state.nodes[$row.name] = @{ vmId = $vm.Id.ToString(); commonCredentialLoginVerified = $true; legacyEncryptedRoleRetainedInactive = $true }
        Save-ClusterPrereq ($row.name + '-binding-committed')
    }
    $state.status = 'local-cluster-prerequisites-prepared'; Save-ClusterPrereq 'ou-and-common-node-credential-verified'
} catch { $state.status = 'failed-or-uncertain-inspect-before-resume'; $state.errorType = $_.Exception.GetType().Name; $state.errorLine = $_.InvocationInfo.ScriptLineNumber; try { Save-ClusterPrereq $state.phase } catch { } }
finally { if ($session) { Remove-PSSession -Session $session }; if ($secure) { $secure.Dispose() }; if ($lcm) { $lcm.Dispose() }; if ($common) { $common.Dispose() } }
$state | ConvertTo-Json -Depth 7 -Compress
