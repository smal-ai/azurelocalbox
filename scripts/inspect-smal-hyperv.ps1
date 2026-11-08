# Read-only before/after reboot inspection over pinned-key private Bastion SSH.
$ErrorActionPreference = 'Stop'
try {
if ($env:COMPUTERNAME -ne 'LocalBox-Client') { throw 'Unexpected target' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$os = Get-CimInstance Win32_OperatingSystem
$vmms = Get-Service vmms -ErrorAction SilentlyContinue
$result = [ordered]@{
    computer = $env:COMPUTERNAME
    atUtc = (Get-Date).ToUniversalTime().ToString('o')
    lastBootUtc = $os.LastBootUpTime.ToUniversalTime().ToString('o')
    user = $identity.Name
    administrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    sshConnection = $env:SSH_CONNECTION
    hyperV = (Get-WindowsFeature -Name Hyper-V).InstallState.ToString()
    hyperVPowerShell = (Get-WindowsFeature -Name Hyper-V-PowerShell).InstallState.ToString()
    vmms = $(if ($vmms) { $vmms.Status.ToString() } else { 'absent-before-reboot' })
    sshd = (Get-Service sshd).Status.ToString()
    defenderRealTimeProtection = (Get-MpComputerStatus).RealTimeProtectionEnabled
    pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}
try {
    $hostInfo = Get-VMHost
    $result.hyperVHostQuerySucceeded = $true
    $result.hyperVHost = @{ logicalProcessors = $hostInfo.LogicalProcessorCount; memoryGiB = [math]::Round($hostInfo.MemoryCapacity / 1GB) }
    $result.nestedVmCount = @(Get-VM).Count
    $result.virtualSwitchCount = @(Get-VMSwitch).Count
    $result.netNatCount = @(Get-NetNat).Count
    $management = @(Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_VirtualSystemManagementService)
    $result.hyperVManagementServiceCount = $management.Count
    $result.hyperVManagementHealth = @($management | Select-Object -ExpandProperty HealthState)
} catch {
    $result.hyperVHostQuerySucceeded = $false
    $result.hyperVQueryErrorType = $_.Exception.GetType().Name
}
$result.dataDisks = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem } | ForEach-Object { @{ number = $_.Number; sizeGiB = [math]::Round($_.Size / 1GB); style = $_.PartitionStyle.ToString() } })
$result.dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object ServerAddresses | ForEach-Object { @{ interface = $_.InterfaceAlias; servers = @($_.ServerAddresses) } })
$result.platformDeploymentAttempted = $false
$result.nestedVmBootTestPerformed = $false
$result.inspectionSucceeded = $true
$result | ConvertTo-Json -Depth 6 -Compress
} catch {
    @{ computer = $env:COMPUTERNAME; inspectionSucceeded = $false; errorId = $_.FullyQualifiedErrorId; errorType = $_.Exception.GetType().Name } | ConvertTo-Json -Compress
}
