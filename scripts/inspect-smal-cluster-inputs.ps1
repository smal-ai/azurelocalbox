# Read-only final hardware/storage/AD inspection. No formatting or domain join.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected host' }
$boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
$entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
$helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Secret helper differs' }
. $helper
$store = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'
$bindings = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw | ConvertFrom-Json
$nodes = @(foreach ($target in @(@{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34' }, @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' })) {
    $vm = Get-VM -Id $target.id
    $binding = $bindings.nodes.PSObject.Properties[$target.name].Value
    if ($vm.Name -cne $target.name -or $vm.State.ToString() -ne 'Running' -or $binding.vmId -ine $target.id -or $binding.role -cne 'cluster-node-admin' -or $binding.secretDirectory -cne $store -or $binding.loginVerified -ne $true) { throw 'Exact running node/binding differs' }
    $backing = @(Get-VMHardDiskDrive -VM $vm | ForEach-Object {
        $vhd = Get-VHD -Path $_.Path
        @{ path = $_.Path; controllerType = $_.ControllerType.ToString(); controllerNumber = $_.ControllerNumber; lun = $_.ControllerLocation; size = $vhd.Size; diskId = $vhd.DiskIdentifier.ToString(); parentPath = $vhd.ParentPath }
    })
    $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'; $session = $null
    try {
        $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($vm.Name + '\Administrator'), $secure)) -ErrorAction Stop
        $guest = Invoke-Command -Session $session -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $drives = @(Get-CimInstance Win32_DiskDrive)
            $os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
            @{ name = $env:COMPUTERNAME; domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole;
               build = ($os.CurrentBuild + '.' + $os.UBR); bootstrap = [string](Get-ArcBootstrapStatus).Response.Status;
               disks = @(Get-Disk | ForEach-Object { $disk = $_; $drive = @($drives | Where-Object Index -EQ $disk.Number); if ($drive.Count -ne 1) { throw 'Ambiguous guest disk mapping' }; @{ number = $disk.Number; uniqueId = $disk.UniqueId; size = $disk.Size; partitionStyle = $disk.PartitionStyle.ToString(); isBoot = $disk.IsBoot; isSystem = $disk.IsSystem; scsiPort = $drive[0].SCSIPort; scsiTarget = $drive[0].SCSITargetId; lun = $drive[0].SCSILogicalUnit } });
               adapters = @(Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress);
               ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress, PrefixLength);
               nonPrimordialPoolCount = @(Get-StoragePool | Where-Object IsPrimordial -EQ $false).Count;
               defenderEnabled = (Get-MpComputerStatus).RealTimeProtectionEnabled }
        }
        @{ name = $vm.Name; vmId = $vm.Id.ToString(); backing = $backing; guest = $guest }
    } finally { if ($session) { Remove-PSSession $session }; $secure.Dispose() }
})
$dc = Get-VM -Id 'f94c71f1-6854-48b9-a9f1-8238c99366d0'
if ($dc.Name -cne 'LB-DC01' -or $dc.State.ToString() -ne 'Running') { throw 'Exact DC differs' }
$secure = Read-LabGuestSecureSecret -SecretDirectory 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01\secrets' -Role 'dc-admin'; $session = $null
try {
    $session = New-PSSession -VMId $dc.Id -Credential ([pscredential]::new('LOCALBOX\Administrator', $secure)) -ErrorAction Stop
    $ad = Invoke-Command -Session $session -ScriptBlock {
        Import-Module ActiveDirectory; Import-Module GroupPolicy
        $ou = 'OU=SMAL01,OU=AzureLocal,DC=ad,DC=localbox,DC=test'
        $user = Get-ADUser lboxdeploy -Properties PasswordNeverExpires,PasswordExpired,msDS-UserPasswordExpiryTimeComputed,MemberOf
        @{ domain = (Get-ADDomain).DNSRoot; ou = (Get-ADOrganizationalUnit -Identity $ou).DistinguishedName; inheritanceBlocked = (Get-GPInheritance -Target $ou).GpoInheritanceBlocked;
           lcm = @{ user = $user.SamAccountName; enabled = $user.Enabled; dn = $user.DistinguishedName; expired = $user.PasswordExpired; neverExpires = $user.PasswordNeverExpires; groupCount = @($user.MemberOf).Count; expiryFileTime = [string]$user.'msDS-UserPasswordExpiryTimeComputed' } }
    }
} finally { if ($session) { Remove-PSSession $session }; $secure.Dispose() }
@{ atUtc = [datetime]::UtcNow.ToString('o'); nodes = $nodes; ad = $ad; mutationPerformed = $false } | ConvertTo-Json -Depth 10 -Compress
