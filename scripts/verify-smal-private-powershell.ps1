# Read-only proof of authenticated PowerShell execution over SSH, not Run Command.
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
[ordered]@{
    atUtc = (Get-Date).ToUniversalTime().ToString('o')
    computer = $env:COMPUTERNAME
    user = $identity.Name
    administrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    powershell = $PSVersionTable.PSVersion.ToString()
    sshConnection = $env:SSH_CONNECTION
    bootstrapApplied = $false
} | ConvertTo-Json -Compress
