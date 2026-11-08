# Initial local bootstrap prerequisite only. No cluster/module/image/network/disk work.
# No automatic reboot. Run through the verified, key-only private Bastion SSH path.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:COMPUTERNAME -ne 'LocalBox-Client') { throw 'Unexpected target' }
if (-not (Get-NetIPAddress -IPAddress 10.200.16.4 -AddressFamily IPv4 -ErrorAction SilentlyContinue)) { throw 'Expected private host IP absent' }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Elevated existing administrator required' }
$cpu = @(Get-CimInstance Win32_Processor)
if (@($cpu | Where-Object { -not $_.VMMonitorModeExtensions -or -not $_.VirtualizationFirmwareEnabled -or -not $_.SecondLevelAddressTranslationExtensions }).Count) { throw 'Nested virtualisation prerequisite absent' }
$defenderBefore = Get-MpComputerStatus
if (-not $defenderBefore.RealTimeProtectionEnabled) { throw 'Expected Defender protection is not active' }
$feature = Get-WindowsFeature -Name Hyper-V
$marker = 'C:\ProgramData\AzureLocalBox\host-hyperv-prerequisite.json'
$applied = $false
$restartNeeded = 'Unknown'
if ($feature.InstallState.ToString() -ne 'Installed') {
    if ($feature.InstallState.ToString() -ne 'Available') { throw 'Hyper-V payload is not available locally' }
    if (Test-Path $marker) { throw 'Prior Hyper-V operation exists. Inspect rather than repeat.' }
    if (-not (Test-Path 'C:\ProgramData\AzureLocalBox')) { New-Item 'C:\ProgramData\AzureLocalBox' -ItemType Directory | Out-Null }
    @{ status = 'pending'; atUtc = (Get-Date).ToUniversalTime().ToString('o'); rebootAuthorised = $false } | ConvertTo-Json | Set-Content $marker -Encoding ASCII
    $installation = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart:$false -ErrorAction Stop
    if (-not $installation.Success) { throw 'Hyper-V prerequisite installation failed. Inspect marker and servicing state.' }
    $restartNeeded = $installation.RestartNeeded.ToString()
    $applied = $true
    @{ status = 'complete'; restartNeeded = $restartNeeded; atUtc = (Get-Date).ToUniversalTime().ToString('o'); rebootPerformed = $false } | ConvertTo-Json | Set-Content $marker -Encoding ASCII
}
$defenderAfter = Get-MpComputerStatus
[ordered]@{
    computer = $env:COMPUTERNAME
    atUtc = (Get-Date).ToUniversalTime().ToString('o')
    roleInstallApplied = $applied
    hyperV = (Get-WindowsFeature -Name Hyper-V).InstallState.ToString()
    hyperVPowerShell = (Get-WindowsFeature -Name Hyper-V-PowerShell).InstallState.ToString()
    restartNeeded = $restartNeeded
    rebootPerformed = $false
    lastBootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    defenderRealTimeProtection = $defenderAfter.RealTimeProtectionEnabled
    manualDefenderExclusionsAdded = $false
    nestedNetworkConfigured = $false
    disksFormatted = $false
    azureLocalDeployed = $false
} | ConvertTo-Json -Compress
