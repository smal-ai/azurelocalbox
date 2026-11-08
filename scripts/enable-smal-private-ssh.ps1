# Owner-approved one-off access setup. No bootstrap, WinRM, RBAC or shared-network writes.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,31}$')][string]$AdminUser,
    [Parameter(Mandatory)][ValidatePattern('^ssh-ed25519 [A-Za-z0-9+/]+={0,3}( [a-zA-Z0-9@._-]+)?$')][string]$PublicKey,
    [ValidateSet('Initial', 'ResumeVerified')][string]$Operation = 'Initial'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dir = 'C:\ProgramData\ssh'
$config = Join-Path $dir 'sshd_config'
$keys = Join-Path $dir 'administrators_authorized_keys'
$marker = Join-Path $dir 'localbox-private-ssh.json'
$backup = Join-Path $dir 'sshd_config.before-localbox-private-ssh'
$sshd = 'C:\Windows\System32\OpenSSH\sshd.exe'
$keygen = 'C:\Windows\System32\OpenSSH\ssh-keygen.exe'
$ruleName = 'LocalBox-SSH-From-Private-Bastion'
$admin = $AdminUser.ToLowerInvariant()
$keyHash = [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($PublicKey)))

function Get-AccessEvidence {
    $effective = @(& $sshd -T -C "user=$admin,host=LocalBox-Client,addr=10.202.0.4")
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect effective sshd configuration' }
    foreach ($required in @('passwordauthentication no', 'pubkeyauthentication yes', 'authenticationmethods publickey', 'allowtcpforwarding no', 'allowagentforwarding no')) {
        if ($effective -notcontains $required) { throw "Effective SSH safety check failed: $required" }
    }
    if ($effective -notcontains "allowusers $admin") { throw 'SSH user scope differs' }
    $rule = Get-NetFirewallRule -Name $ruleName
    $remote = @($rule | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty RemoteAddress)
    # Windows returns a dotted subnet mask even when configured with CIDR.
    if ($rule.Enabled.ToString() -ne 'True' -or $rule.Action.ToString() -ne 'Allow' -or $remote.Count -ne 1 -or $remote[0] -notin @('10.202.0.0/26', '10.202.0.0/255.255.255.192')) { throw 'Guest firewall scope differs' }
    $publicHostKey = (Get-Content (Join-Path $dir 'ssh_host_ed25519_key.pub') -Raw).Trim()
    if ($publicHostKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+=*( .*)?$') { throw 'Invalid host PUBLIC key' }
    [ordered]@{
        computer = $env:COMPUTERNAME
        service = (Get-Service sshd).Status.ToString()
        adminUser = $admin
        passwordAuthentication = $false
        publicKeyAuthentication = $true
        forwarding = $false
        remoteAddress = '10.202.0.0/26'
        remoteAddressObserved = $remote[0]
        defaultShell = (Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell).DefaultShell
        hostPublicKey = $publicHostKey
        configSha256 = (Get-FileHash $config -Algorithm SHA256).Hash
        rebootPerformed = $false
        bootstrapApplied = $false
    }
}

if ($env:COMPUTERNAME -ne 'LocalBox-Client') { throw 'Unexpected target host' }
if (-not (Get-NetIPAddress -AddressFamily IPv4 -IPAddress 10.200.16.4 -ErrorAction SilentlyContinue)) { throw 'Expected private address absent' }
$user = Get-LocalUser -Name $AdminUser
if (-not $user.Enabled) { throw 'Approved existing admin account disabled' }
$members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' | Select-Object -ExpandProperty SID | ForEach-Object Value)
if ($members -notcontains $user.SID.Value) { throw 'Expected existing local administrator membership absent' }

if (Test-Path $marker) {
    $previous = Get-Content $marker -Raw | ConvertFrom-Json
    if ($Operation -eq 'ResumeVerified') {
        # Resume ONLY the inspected, fully configured but fail-closed service.
        # Do not rewrite config, keys, ACLs or firewall, and never remove a marker.
        if ($previous.status -ne 'pending' -or $previous.keyHash -ne $keyHash -or $previous.adminUser -ne $admin) { throw 'Pending operation identity differs' }
        if ((Get-FileHash $config -Algorithm SHA256).Hash -ne '52ADEA08D10405087D4DC9091710C399328AE598C594B4CB70245B03D8FA44B4') { throw 'Pending SSH configuration changed' }
        if ((Get-FileHash $backup -Algorithm SHA256).Hash -ne 'FB46B8F386771448755C9D220B49FC3AE6EF1447CCCBB568B0BFE766DA1E54FE') { throw 'Original SSH backup changed' }
        $expectedKeyLine = 'from="10.202.0.0/26",no-agent-forwarding,no-port-forwarding ' + $PublicKey
        if ((Get-Content $keys -Raw).Trim() -ne $expectedKeyLine) { throw 'Pending authorised public key differs' }
        if ((Get-Service sshd).Status.ToString() -ne 'Stopped') { throw 'Expected fail-closed service differs' }
        if ((Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP').Enabled.ToString() -ne 'False') { throw 'Original broad SSH rule is not disabled' }
        $null = Get-AccessEvidence
        try {
            Start-Service sshd
            $evidence = Get-AccessEvidence
            if ($evidence.service -ne 'Running') { throw 'SSH service not Running' }
            @{ status = 'complete'; adminUser = $admin; keyHash = $keyHash; atUtc = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content $marker -Encoding ASCII
            $evidence | ConvertTo-Json -Depth 5 -Compress
        } catch { Stop-Service sshd -ErrorAction SilentlyContinue; throw }
        exit 0
    }
    if ($previous.status -ne 'complete' -or $previous.keyHash -ne $keyHash -or $previous.adminUser -ne $admin) { throw 'Prior SSH setup differs or is incomplete. Inspect instead of retrying.' }
    Get-AccessEvidence | ConvertTo-Json -Depth 5 -Compress
    exit 0
}
if ($Operation -eq 'ResumeVerified') { throw 'Expected pending marker is absent' }

# A fresh image already has OpenSSH installed/running. Do not modify a customised
# service or an existing authorised-key file under the guise of initial setup.
if ((Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0').State.ToString() -ne 'Installed') { throw 'OpenSSH component absent. Installation requires a separately reviewed path.' }
if (-not (Test-Path $config) -or (Test-Path $keys) -or (Test-Path $backup) -or (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) { throw 'Unexpected existing SSH setup. Preserve it and inspect.' }
$original = Get-Content $config -Raw
$expectedExistingHash = 'FB46B8F386771448755C9D220B49FC3AE6EF1447CCCBB568B0BFE766DA1E54FE'
if ((Get-FileHash $config -Algorithm SHA256).Hash -ne $expectedExistingHash) { throw 'SSH configuration changed after read-only reconciliation' }
$active = @($original -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
$stock = @('AuthorizedKeysFile .ssh/authorized_keys', 'Subsystem sftp sftp-server.exe', 'Match Group administrators', 'AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys')
foreach ($line in $active) {
    $normalised = ($line -replace '\s+', ' ').Trim()
    # The independently hashed image configuration also has an AllowGroups gate.
    # Preserve it verbatim. The exact hash above prevents accepting arbitrary edits.
    if ($stock -notcontains $normalised -and $normalised -notmatch '^AllowGroups ') { throw 'Active non-default SSH configuration found. No changes applied.' }
}
$otherPort22Rules = @(Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow | Where-Object Name -ne 'OpenSSH-Server-In-TCP' | Where-Object { @($_ | Get-NetFirewallPortFilter | Select-Object -ExpandProperty LocalPort) -contains '22' })
if ($otherPort22Rules.Count) { throw 'Unowned explicit TCP22 allow rule exists. Inspect without modifying it.' }
$shell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$existingShell = Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue
if ($existingShell -and $existingShell.DefaultShell -ne $shell) { throw 'Unowned SSH default shell exists' }

@{ status = 'pending'; adminUser = $admin; keyHash = $keyHash; atUtc = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content $marker -Encoding ASCII
Copy-Item $config $backup -ErrorAction Stop
# Stop before changing authentication. RDP and the guest-agent recovery path remain.
Stop-Service sshd
try {
    $restrictions = @"
# LocalBox private administration. Owned by enable-smal-private-ssh.ps1.
Port 22
ListenAddress 10.200.16.4
AllowUsers $admin
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
AllowAgentForwarding no
AllowTcpForwarding no
GatewayPorts no
MaxAuthTries 3
LoginGraceTime 30
LogLevel VERBOSE

"@
    [IO.File]::WriteAllText($config, $restrictions + $original, [Text.Encoding]::ASCII)
    # Restrict the key to the same Bastion source as the Windows and Azure rules.
    [IO.File]::WriteAllText($keys, ('from="10.202.0.0/26",no-agent-forwarding,no-port-forwarding ' + $PublicKey + "`r`n"), [Text.Encoding]::ASCII)
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = [Security.Principal.SecurityIdentifier]::new($sid)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow'))
    }
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Set-Acl -Path $keys -AclObject $acl
    $null = & $sshd -t -f $config 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'sshd rejected configuration. Service remains stopped.' }
    $defaultRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if ($defaultRule) { $defaultRule | Disable-NetFirewallRule | Out-Null }
    New-NetFirewallRule -Name $ruleName -DisplayName 'LocalBox SSH from private Bastion only' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -RemoteAddress '10.202.0.0/26' -Program $sshd -Service sshd -Profile Any | Out-Null
    if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item 'HKLM:\SOFTWARE\OpenSSH' | Out-Null }
    New-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $shell -PropertyType String -Force | Out-Null
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
    $evidence = Get-AccessEvidence
    @{ status = 'complete'; adminUser = $admin; keyHash = $keyHash; atUtc = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content $marker -Encoding ASCII
    $evidence | ConvertTo-Json -Depth 5 -Compress
} catch {
    # Do not silently restore permissive/password access. Retain marker and backup.
    Stop-Service sshd -ErrorAction SilentlyContinue
    throw
}
