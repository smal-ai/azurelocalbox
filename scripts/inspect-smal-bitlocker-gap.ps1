# Read-only encryption/recovery metadata. No recovery passwords or key material.
$ErrorActionPreference = 'Stop'; $phase = 'host-identity'
try {
    if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected host' }
    $targets = @(@{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34' }, @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' }, @{ name = 'LB-NODE03'; id = '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9' })
    $boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
    $bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
    $entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1'); $helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
    if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Secret helper differs' }
    . $helper
    $store = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'
    $bindings = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw | ConvertFrom-Json
    $nodes = @(foreach ($target in $targets) {
        $vm = Get-VM -Id $target.id; $binding = $bindings.nodes.PSObject.Properties[$target.name].Value
        if ($vm.Name -cne $target.name -or $vm.State.ToString() -ne 'Running' -or $binding.vmId -ine $target.id -or $binding.secretDirectory -cne $store -or $binding.role -cne 'cluster-node-admin' -or $binding.loginVerified -ne $true) { throw 'Exact guest/credential binding differs' }
        $phase = $target.name + '-credential-session'
        $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'; $session = $null
        try {
            $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($vm.Name + '\ASBuiltInAdmin'), $secure)) -ErrorAction Stop
            $phase = $target.name + '-read-only-encryption-diagnosis'
            Invoke-Command -Session $session -ArgumentList $target.name -ErrorAction Stop -ScriptBlock {
                param($ExpectedName)
                $ErrorActionPreference = 'Stop'
                if ($env:COMPUTERNAME -cne $ExpectedName) { throw 'Guest identity differs' }
                $admin = Get-LocalUser ASBuiltInAdmin
                if (-not $admin.SID.Value.EndsWith('-500') -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $admin.SID.Value) { throw 'Expected existing RID 500 identity differs' }
                $os = Get-BitLockerVolume -MountPoint 'C:'; $tpm = Get-Tpm; $computer = Get-CimInstance Win32_ComputerSystem
                $cmd = Get-Command Get-ASBitLocker -ErrorAction SilentlyContinue
                $agent = @{ available = [bool]$cmd; observationSucceeded = $false }
                if ($cmd) {
                    $agent.moduleName = $cmd.ModuleName; $agent.parameters = @($cmd.Parameters.Keys)
                    try {
                        $status = @(Get-ASBitLocker -VolumeType BootVolume -Local -ErrorAction Stop 3>$null 6>$null)
                        $agent.observationSucceeded = $true
                        $agent.records = @($status | ForEach-Object {
                            # Inspect only status field names/known scalar fields, never serialize the raw result.
                            @{ propertyNames = @($_.PSObject.Properties.Name | Where-Object { $_ -notmatch '(?i)secret|key|token|password' }); computerName = $_.ComputerName; volumeType = $_.VolumeType;
                               mountPoint = $_.MountPoint; encryptionStatus = [string]$_.EncryptionStatus; protectionStatus = [string]$_.ProtectionStatus; enabled = $_.Enabled }
                        })
                    } catch { $agent.errorType = $_.Exception.GetType().Name; $agent.errorCategory = [string]$_.CategoryInfo.Category }
                }
                $logs = @(Get-ChildItem 'C:\MASLogs\ASEncryptionLogs' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 4 | ForEach-Object {
                    $file = $_; $text = Get-Content $file.FullName -Tail 500 -ErrorAction Stop | Out-String
                    # Constant classifications only. Raw logs can contain recovery material.
                    @{ file = $file.Name; bytes = $file.Length; lastWriteUtc = $file.LastWriteTimeUtc.ToString('o');
                       mentionsVirtualMachine = [bool]($text -match '(?i)virtual machine|IsVirtualMachine|virtualized');
                       mentionsSkip = [bool]($text -match '(?i)skip'); mentionsBootVolume = [bool]($text -match '(?i)bootvolume|boot volume|OS volume');
                       mentionsError = [bool]($text -match '(?i)error|exception|failed') }
                })
                @{ name = $env:COMPUTERNAME; manufacturer = $computer.Manufacturer; model = $computer.Model;
                   bootVolume = @{ mountPoint = $os.MountPoint; protectionStatus = [string]$os.ProtectionStatus; volumeStatus = [string]$os.VolumeStatus; encryptionPercentage = $os.EncryptionPercentage; protectorCount = @($os.KeyProtector).Count; protectorTypes = @($os.KeyProtector | ForEach-Object { if ([string]$_.KeyProtectorType -eq 'RecoveryPassword') { 'RecoveryCode' } else { [string]$_.KeyProtectorType } }) };
                   tpm = @{ present = $tpm.TpmPresent; ready = $tpm.TpmReady; enabled = $tpm.TpmEnabled; activated = $tpm.TpmActivated };
                   bitLockerAgent = $agent; encryptionLogClassifications = $logs }
            }
        } finally { if ($session) { Remove-PSSession $session }; $secure.Dispose() }
    })
    $phase = 'dc-recovery-metadata'
    $dc = Get-VM -Id 'f94c71f1-6854-48b9-a9f1-8238c99366d0'
    if ($dc.Name -cne 'LB-DC01' -or $dc.State.ToString() -ne 'Running') { throw 'Exact DC differs' }
    $secure = Read-LabGuestSecureSecret -SecretDirectory 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01\secrets' -Role 'dc-admin'; $session = $null
    try {
        $session = New-PSSession -VMId $dc.Id -Credential ([pscredential]::new('LOCALBOX\Administrator', $secure)) -ErrorAction Stop
        $recovery = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            Import-Module ActiveDirectory
            # Request only non-secret object metadata. Never request recovery-password attributes.
            @(Get-ADObject -SearchBase 'OU=SMAL01,OU=AzureLocal,DC=ad,DC=localbox,DC=test' -LDAPFilter '(objectClass=msFVE-RecoveryInformation)' -Properties whenCreated | ForEach-Object {
                @{ objectGuid = $_.ObjectGUID.ToString(); distinguishedName = $_.DistinguishedName; createdUtc = $_.whenCreated.ToUniversalTime().ToString('o') }
            })
        }
    } finally { if ($session) { Remove-PSSession $session }; $secure.Dispose() }
    @{ atUtc = [datetime]::UtcNow.ToString('o'); observationStatus = 'complete-read-only'; nodes = $nodes; adRecoveryMetadata = @($recovery);
       rawLogsExported = $false; recoveryKeysExported = $false; mutationPerformed = $false; platformReadinessVerified = $false } | ConvertTo-Json -Depth 10 -Compress
} catch {
    @{ observationStatus = 'failed-safe-diagnostic'; phase = $phase; errorType = $_.Exception.GetType().Name; sourceLine = $_.InvocationInfo.ScriptLineNumber;
       recoveryKeysExported = $false; mutationPerformed = $false; platformReadinessVerified = $false } | ConvertTo-Json -Compress
}
