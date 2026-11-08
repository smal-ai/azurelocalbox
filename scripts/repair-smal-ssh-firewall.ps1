# Reconcile only the service filter on our own rule. Source, port and program stay.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ne 'LocalBox-Client') { throw 'Unexpected target' }
$config = 'C:\ProgramData\ssh\sshd_config'
if ((Get-FileHash $config -Algorithm SHA256).Hash -ne '52ADEA08D10405087D4DC9091710C399328AE598C594B4CB70245B03D8FA44B4') { throw 'SSH configuration changed' }
if ((Get-Content 'C:\ProgramData\ssh\localbox-private-ssh.json' -Raw | ConvertFrom-Json).status -ne 'complete') { throw 'SSH setup not complete' }
$rule = Get-NetFirewallRule -Name 'LocalBox-SSH-From-Private-Bastion'
$address = @($rule | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty RemoteAddress)
$port = @($rule | Get-NetFirewallPortFilter | Select-Object -ExpandProperty LocalPort)
$program = @($rule | Get-NetFirewallApplicationFilter | Select-Object -ExpandProperty Program)
$service = @($rule | Get-NetFirewallServiceFilter | Select-Object -ExpandProperty Service)
if ($address.Count -ne 1 -or $address[0] -ne '10.202.0.0/255.255.255.192' -or $port.Count -ne 1 -or $port[0] -ne '22' -or $program.Count -ne 1 -or $program[0] -ne 'C:\Windows\System32\OpenSSH\sshd.exe' -or $service.Count -ne 1 -or $service[0] -ne 'sshd') { throw 'Owned firewall rule differs from inspected state' }
$sidInfo = @(& sc.exe qsidtype sshd)
if ($LASTEXITCODE -ne 0 -or -not ($sidInfo -match 'SERVICE_SID_TYPE:\s+NONE')) { throw 'Service SID is not the expected NONE. Inspect without changing filters.' }
# An sshd process without a service SID cannot satisfy our extra service filter.
# Program + exact port + Bastion source remain required. Do not enable the broad rule.
$rule | Get-NetFirewallServiceFilter | Set-NetFirewallServiceFilter -Service Any | Out-Null
$after = @($rule | Get-NetFirewallServiceFilter | Select-Object -ExpandProperty Service)
if ($after.Count -ne 1 -or $after[0] -ne 'Any') { throw 'Service filter repair not verified' }
[ordered]@{
    computer = $env:COMPUTERNAME
    atUtc = (Get-Date).ToUniversalTime().ToString('o')
    serviceSidNone = $true
    serviceFilterBefore = 'sshd'
    serviceFilterAfter = $after[0]
    remoteAddress = $address[0]
    localPort = $port[0]
    program = $program[0]
    defaultSshAllowRuleEnabled = (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP').Enabled.ToString()
    configSha256 = (Get-FileHash $config -Algorithm SHA256).Hash
} | ConvertTo-Json -Compress
