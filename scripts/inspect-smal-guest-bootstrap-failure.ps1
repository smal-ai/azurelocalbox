# Read-only exact failed phase inspection. Credentials remain inside this host.
$ErrorActionPreference = 'Stop'
$bootRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$imageRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01'
$task = Get-ScheduledTask -TaskName 'LocalBox-GuestBootstrap-20261028-01'
$state = Get-Content (Join-Path $bootRoot 'state.json') -Raw | ConvertFrom-Json
if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or $task.State.ToString() -ne 'Ready' -or $state.status -ne 'failed-inspect-before-resume' -or $state.phase -ne 'LB-DC01-configure-exact-guest-network' -or (Get-ScheduledTaskInfo -TaskName $task.TaskName).LastTaskResult -ne 1) { throw 'Exact failed phase differs' }
$bundle = Get-Content (Join-Path $imageRoot 'bundle.json') -Raw | ConvertFrom-Json
$secretFile = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
$path = Join-Path $imageRoot 'smal-guest-secret-functions.ps1'
if ($secretFile.Count -ne 1 -or (Get-FileHash $path).Hash -cne $secretFile[0].sha256) { throw 'Secret helper integrity differs' }
. $path
$vm = Get-VM -Id 'f94c71f1-6854-48b9-a9f1-8238c99366d0'
if ($vm.Name -cne 'LB-DC01' -or $vm.State.ToString() -ne 'Running') { throw 'Exact DC VM identity differs' }
$adapters = @(Get-VMNetworkAdapter -VM $vm | Select-Object Name, MacAddress)
$secure = Read-LabGuestSecureSecret -SecretDirectory (Join-Path $imageRoot 'secrets') -Role 'dc-bootstrap'
$credential = [pscredential]::new('LB-DC01\Administrator', $secure)
$session = $null
try {
    $session = New-PSSession -VMId $vm.Id -Credential $credential -ErrorAction Stop
    $result = Invoke-Command -Session $session -ArgumentList 'LB-DC01', '10.64.0.10', $adapters -ErrorAction Stop -ScriptBlock {
        param($ExpectedName, $Address, $Mapping)
        $ErrorActionPreference = 'Stop'
        $protection = $null; $protectionErrorType = $null
        try { $protection = Get-MpComputerStatus -ErrorAction Stop } catch { $protectionErrorType = $_.Exception.GetType().Name }
        $profiles = @(Get-NetFirewallProfile)
        $required = if ($ExpectedName -eq 'LB-DC01') { @('MGMT1') } else { @('MGMT1', 'MGMT2', 'STORAGEA', 'STORAGEB') }
        $differenceCount = $null; $differenceErrorType = $null
        try { $differenceCount = @(Compare-Object $required @($Mapping | ForEach-Object Name)).Count } catch { $differenceErrorType = $_.Exception.GetType().Name }
        @{ computer = $env:COMPUTERNAME; expectedNameArgument = $ExpectedName; addressArgument = $Address; mappingType = $(if ($Mapping) { $Mapping.GetType().FullName } else { $null }); mappingCount = @($Mapping).Count; mappingNames = @($Mapping | ForEach-Object Name); requiredType = $required.GetType().FullName; requiredCount = $required.Count; profileDifferenceCount = $differenceCount; profileDifferenceErrorType = $differenceErrorType; protectionErrorType = $protectionErrorType; protection = ($protection | Select-Object RealTimeProtectionEnabled, AMServiceEnabled, AntivirusEnabled, AMProductVersion); firewallProfiles = @($profiles | Select-Object Name, Enabled); profilesRejectedByOriginalGuard = @($profiles | Where-Object Enabled -NE $true).Count; adapters = @(Get-NetAdapter -Physical | Select-Object Name, InterfaceIndex, MacAddress, HardwareInterface, Status); ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState); defaults = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object InterfaceIndex, NextHop); domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole; adServiceExists = [bool](Get-Service -Name NTDS -ErrorAction SilentlyContinue); setup = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState; clusterBootstrapComplete = $false }
    }
    @{ atUtc = (Get-Date).ToUniversalTime().ToString('o'); vmId = $vm.Id.ToString(); hostAdapters = $adapters; guest = $result; mutationPerformed = $false; credentialValueExported = $false } | ConvertTo-Json -Depth 7 -Compress
} finally {
    if ($session) { Remove-PSSession -Session $session }
    $secure.Dispose()
}
