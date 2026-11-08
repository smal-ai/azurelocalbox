# Read-only reconciliation of the rejected setup. Never reads a private key.
$ErrorActionPreference = 'Stop'
$dir = 'C:\ProgramData\ssh'
$config = Join-Path $dir 'sshd_config'
$rows = @(foreach ($line in (Get-Content $config)) {
    $normalised = ($line.Trim() -replace '\s+', ' ')
    if (-not $normalised -or $normalised.StartsWith('#')) { continue }
    $parts = $normalised -split ' ', 2
    $safe = $normalised -match '^(PasswordAuthentication|PubkeyAuthentication|AllowTcpForwarding|AllowAgentForwarding) (yes|no)$' -or
        $normalised -match '^Port [0-9]+$' -or
        $normalised -match '^AuthorizedKeysFile (\.ssh/authorized_keys|__PROGRAMDATA__/ssh/administrators_authorized_keys)$' -or
        $normalised -match '^Match Group administrators$' -or
        $normalised -match '^Subsystem sftp ([a-zA-Z]:[\\/][a-zA-Z0-9\\/._-]+|sftp-server.exe)$' -or
        $normalised -match '^AllowUsers [a-zA-Z0-9_-]+$'
    @{ directive = $parts[0]; value = $(if ($safe) { $normalised } else { 'custom-value-redacted' }) }
})
$rule = Get-NetFirewallRule -Name 'LocalBox-SSH-From-Private-Bastion' -ErrorAction SilentlyContinue
$firewall = if ($rule) { @{ enabled = $rule.Enabled.ToString(); action = $rule.Action.ToString(); remoteAddress = @($rule | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty RemoteAddress); localPort = @($rule | Get-NetFirewallPortFilter | Select-Object -ExpandProperty LocalPort) } } else { $null }
$markerStatus = if (Test-Path (Join-Path $dir 'localbox-private-ssh.json')) { (Get-Content (Join-Path $dir 'localbox-private-ssh.json') -Raw | ConvertFrom-Json).status } else { 'absent' }
[ordered]@{
    computer = $env:COMPUTERNAME
    atUtc = (Get-Date).ToUniversalTime().ToString('o')
    configSha256 = (Get-FileHash $config -Algorithm SHA256).Hash
    activeConfiguration = $rows
    setupMarkerExists = Test-Path (Join-Path $dir 'localbox-private-ssh.json')
    backupExists = Test-Path (Join-Path $dir 'sshd_config.before-localbox-private-ssh')
    adminKeysExist = Test-Path (Join-Path $dir 'administrators_authorized_keys')
    service = (Get-Service sshd).Status.ToString()
    firewall = $firewall
    markerStatus = $markerStatus
    defaultSshAllowRuleEnabled = @((Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) | Select-Object -ExpandProperty Enabled | ForEach-Object ToString)
    servicePath = (Get-CimInstance Win32_Service -Filter "Name='sshd'").PathName
    listeners = @(Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, OwningProcess)
    firewallProgram = @($rule | Get-NetFirewallApplicationFilter | Select-Object -ExpandProperty Program)
    firewallService = @($rule | Get-NetFirewallServiceFilter | Select-Object -ExpandProperty Service)
    firewallProfiles = $rule.Profile.ToString()
    profileDefaults = @(Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction)
    recentSshEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'OpenSSH/Operational'; StartTime = (Get-Date).AddMinutes(-20) } -MaxEvents 10 -ErrorAction SilentlyContinue | ForEach-Object {
        $category = if ($_.Message -match 'Accepted publickey') { 'accepted-publickey' } elseif ($_.Message -match 'Failed publickey') { 'failed-publickey' } elseif ($_.Message -match 'listening on') { 'listening' } elseif ($_.Message -match 'Connection') { 'connection-event' } else { 'other' }
        @{ atUtc = $_.TimeCreated.ToUniversalTime().ToString('o'); id = $_.Id; category = $category }
    })
    readOnly = $true
} | ConvertTo-Json -Depth 5 -Compress
