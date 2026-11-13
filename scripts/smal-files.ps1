param(
    [ValidateSet('Inspect','PrepareImage','InspectNative','GuestAccess','GuestInspect','ConfigureGuest','RestartGuest')][string]$Action,
    [Parameter(Mandatory)][string]$PlatformBase64,
    [Parameter(Mandatory)][string]$FilesBase64,
    [string]$VmId,
    [string]$SecretsBase64,
    [string]$AccountSourceBase64,
    [string]$ShareSourceBase64
)
$ErrorActionPreference='Stop'
$platform=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PlatformBase64)) | ConvertFrom-Json
$files=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($FilesBase64)) | ConvertFrom-Json
if($env:COMPUTERNAME -cne $platform.hostName -or $files.name -cne 'smal-smb01' -or $files.address -cne '10.64.0.190') { throw 'Wrong file-service target' }
function Open-Node([string]$name) {
    $vm=Get-VM -Id $platform.guestIds.PSObject.Properties[$name].Value
    if($vm.Name -cne $name -or $vm.State.ToString() -cne 'Running') { throw 'Wrong HCI guest' }
    $helper=Join-Path $platform.guestHelperDirectory 'smal-guest-secret-functions.ps1'
    $bundle=Get-Content (Join-Path $platform.guestHelperDirectory 'bundle.json') -Raw | ConvertFrom-Json
    $entry=@($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
    if($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Guest helper differs' }
    . $helper
    $bindings=Get-Content (Join-Path $platform.credentialDirectory 'credential-bindings.json') -Raw | ConvertFrom-Json
    $binding=$bindings.nodes.PSObject.Properties[$name].Value
    if($binding.vmId -ine $vm.Id.ToString() -or $binding.role -cne 'cluster-node-admin' -or -not $binding.loginVerified) { throw 'Existing credential binding differs' }
    $secure=Read-LabGuestSecureSecret -SecretDirectory $binding.secretDirectory -Role $binding.role
    try { New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($name+'\ASBuiltInAdmin'),$secure)) }
    finally { $secure.Dispose() }
}
$node='LB-NODE03'
if($Action -in @('InspectNative','GuestAccess','GuestInspect','ConfigureGuest','RestartGuest')) {
    $matches=@(foreach($name in @('LB-NODE01','LB-NODE02','LB-NODE03')) {
        $check=Open-Node $name
        try {
            Invoke-Command -Session $check -ArgumentList $VmId -ScriptBlock {
                param($id)
                $vm=Get-VM -Id ([guid]$id) -ErrorAction SilentlyContinue
                if($vm) {
                    $settings=@(Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_VirtualSystemSettingData | Where-Object { $_.VirtualSystemIdentifier -eq $vm.Id.ToString() -and $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' })
                    @{node=$env:COMPUTERNAME;name=$vm.Name;id=$vm.Id.ToString();state=$vm.State.ToString();cpu=$vm.ProcessorCount;memoryBytes=$vm.MemoryStartup;biosGuid=@($settings | ForEach-Object BIOSGUID);heartbeat=$vm.Heartbeat.ToString();adapters=@($vm | Get-VMNetworkAdapter | Select-Object Name,IPAddresses);disks=@($vm | Get-VMHardDiskDrive | Select-Object Path,ControllerType,ControllerLocation)}
                }
            }
        } finally { Remove-PSSession $check }
    })
    if($Action -eq 'InspectNative') {
        @{action=$Action;vmId=$VmId;placements=$matches;observedAt=[datetime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 12 -Compress
        return
    }
    if($matches.Count -ne 1 -or $matches[0].name -notlike 'smal-smb01*' -or $matches[0].state -ne 'Running') { throw 'Expected the dedicated file VM running on one HCI node' }
    $node=$matches[0].node
}
$session=Open-Node $node
try {
    $result=Invoke-Command -Session $session -ArgumentList $Action,($files | ConvertTo-Json -Compress),$VmId,$SecretsBase64,$AccountSourceBase64,$ShareSourceBase64 -ScriptBlock {
        param($action,$configuration,$vmId,$secretsBase64,$accountSourceBase64,$shareSourceBase64)
        $ErrorActionPreference='Stop'
        $c=$configuration | ConvertFrom-Json
        if($action -in @('GuestAccess','GuestInspect','ConfigureGuest','RestartGuest')) {
            $vm=Get-VM -Id ([guid]$vmId)
            if($vm.Name -notlike 'smal-smb01*' -or $vm.State.ToString() -ne 'Running' -or $vm.ProcessorCount -ne 4 -or $vm.MemoryStartup -ne 8GB) { throw 'Dedicated file VM profile differs' }
            $secrets=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secretsBase64)) | ConvertFrom-Json
            if($secrets.admin.username -cne 'SMAL-SMB01\smalguestadmin') { throw 'Wrong dedicated guest administrator binding' }
            $credential=[pscredential]::new('smalguestadmin',(ConvertTo-SecureString $secrets.admin.password -AsPlainText -Force))
            if($action -eq 'GuestAccess') {
                $diagnostic=$null
                try {
                    $diagnostic=New-PSSession -VMId $vm.Id -Credential $credential
                    $basic=Invoke-Command -Session $diagnostic -ScriptBlock { @{name=$env:COMPUTERNAME;uuid=(Get-CimInstance Win32_ComputerSystemProduct).UUID;identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name} }
                    return @{stage='guest-access';guest=$basic;sessionState=$diagnostic.State.ToString()}
                } catch {
                    return @{stage='guest-access-failed';error=$_.Exception.Message;inner=$_.Exception.InnerException.Message;fullyQualifiedErrorId=$_.FullyQualifiedErrorId;category=$_.CategoryInfo.ToString();integration=@($vm | Get-VMIntegrationService | Select-Object Name,Enabled,PrimaryStatusDescription)}
                } finally { if($diagnostic) { Remove-PSSession $diagnostic } }
            }
            $guest=New-PSSession -VMId $vm.Id -Credential $credential
            try {
                $settings=@(Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_VirtualSystemSettingData | Where-Object { $_.VirtualSystemIdentifier -eq $vm.Id.ToString() -and $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' })
                if($settings.Count -ne 1 -or -not $settings[0].BIOSGUID) { throw 'Expected one realised file-VM BIOS identity' }
                $guestBlock={
                    param($action,$secrets,$accountSourceBase64,$shareSourceBase64,$expectedUuid,$workloadAddresses)
                    $ErrorActionPreference='Stop'
                    try {
                    $uuid=(Get-CimInstance Win32_ComputerSystemProduct).UUID
                    if($env:COMPUTERNAME -ine 'SMAL-SMB01' -or $uuid -ine $expectedUuid -or (Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) { throw 'Wrong dedicated guest UUID/name/domain role' }
                    if($action -eq 'GuestInspect') {
                        return @{name=$env:COMPUTERNAME;uuid=$uuid;disks=@(Get-Disk | Select-Object Number,UniqueId,Size,IsBoot,IsSystem,PartitionStyle);
                            volumes=@(Get-Volume | Select-Object DriveLetter,UniqueId,FileSystem,Size,SizeRemaining);
                            addresses=@(Get-NetIPAddress -AddressFamily IPv4 | Select-Object IPAddress,PrefixLength,InterfaceAlias);
                            accounts=@(Get-LocalUser | Select-Object Name,SID,Enabled,AccountExpires);
                            shares=@(Get-SmbShare | Select-Object Name,Path,EncryptData);
                            shareAccess=@(foreach($name in @('smal-evidence','smal-workflows')) { if(Get-SmbShare -Name $name -ErrorAction SilentlyContinue) { Get-SmbShareAccess -Name $name | Select-Object Name,AccountName,AccessRight,AccessControlType } });
                            administratorMembers=@(Get-LocalGroupMember -SID 'S-1-5-32-544' | Select-Object Name,SID);
                            quotas=@(if(Get-Command Get-FsrmQuota -ErrorAction SilentlyContinue) { foreach($path in @('E:\SMAL\smal-evidence','W:\SMAL\smal-workflows')) { Get-FsrmQuota -Path $path -ErrorAction SilentlyContinue | Select-Object Path,Size,SoftLimit } });
                            server=Get-SmbServerConfiguration | Select-Object EnableSMB1Protocol,EnableSMB2Protocol,EncryptData,RejectUnencryptedAccess;
                            bootTime=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime;
                            bitlocker=@(if(Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) { Get-BitLockerVolume | Select-Object MountPoint,ProtectionStatus,EncryptionPercentage,VolumeStatus });
                            features=@(Get-WindowsFeature BitLocker,FS-FileServer,FS-Resource-Manager | Select-Object Name,InstallState);
                            licenses=@(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" | Where-Object PartialProductKey | Select-Object Name,Description,LicenseStatus,GracePeriodRemaining)}
                    }
                    if($action -eq 'RestartGuest') {
                        if(-not(Test-Path 'C:\ProgramData\SMAL\FileService')) { throw 'Dedicated service bootstrap has not started' }
                        & shutdown.exe /r /t 15 /d p:2:4
                        if($LASTEXITCODE -ne 0) { throw 'Dedicated guest restart request failed' }
                        return @{stage='dedicated-guest-restart-scheduled';uuid=$uuid;previousBoot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime}
                    }
                    $root='C:\ProgramData\SMAL\FileService'
                    if(-not(Test-Path $root)) {
                        $null=New-Item $root -ItemType Directory -Force
                        $acl=[Security.AccessControl.DirectorySecurity]::new()
                        $acl.SetAccessRuleProtection($true,$false)
                        foreach($identity in @('NT AUTHORITY\SYSTEM','BUILTIN\Administrators')) {
                            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
                        }
                        Set-Acl $root $acl
                    }
                    $feature=Get-WindowsFeature BitLocker
                    if(-not $feature.Installed) {
                        $installed=Install-WindowsFeature BitLocker -IncludeAllSubFeature -IncludeManagementTools
                        return @{stage='bitlocker-feature-installed';restartNeeded=$installed.RestartNeeded.ToString();uuid=$uuid}
                    }
                    $diskPlans=@(@{size=32GB;letter='E';label='SMAL-Evidence'},@{size=8GB;letter='W';label='SMAL-Workflows'})
                    foreach($plan in $diskPlans) {
                        $disks=@(Get-Disk | Where-Object { $_.Size -eq $plan.size -and -not $_.IsBoot -and -not $_.IsSystem })
                        if($disks.Count -ne 1) { throw 'Exact unique primary data disk absent' }
                        $disk=$disks[0]
                        if($disk.PartitionStyle.ToString() -eq 'RAW') {
                            if(Get-Volume -DriveLetter $plan.letter -ErrorAction SilentlyContinue) { throw 'Drive letter already in use' }
                            $disk | Initialize-Disk -PartitionStyle GPT
                            $part=New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $plan.letter
                            $null=Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel $plan.label -Confirm:$false
                        } else {
                            $part=@(Get-Partition -DiskNumber $disk.Number | Where-Object DriveLetter -eq $plan.letter)
                            if($part.Count -ne 1 -or (Get-Volume -DriveLetter $plan.letter).FileSystemLabel -ne $plan.label) { throw 'Existing data volume identity differs, never format' }
                        }
                    }
                    foreach($mount in @('C:','E:','W:')) {
                        $bl=Get-BitLockerVolume -MountPoint $mount
                        if($bl.VolumeStatus.ToString() -eq 'FullyDecrypted') {
                            if($mount -eq 'C:') {
                                $tpm=Get-CimInstance -Namespace root/cimv2/Security/MicrosoftTpm -ClassName Win32_Tpm
                                if(-not $tpm -or -not $tpm.IsEnabled_InitialValue -or -not $tpm.IsActivated_InitialValue) { throw 'Dedicated guest TPM is not ready' }
                                if(-not $tpm.IsOwned_InitialValue) {
                                    $initialised=Initialize-Tpm
                                    if($initialised.RestartRequired) { return @{stage='tpm-initialised';restartNeeded='Yes';uuid=$uuid} }
                                    if($initialised.PhysicalPresenceRequired -or -not $initialised.TpmReady) { throw 'Guest TPM initialisation requires native physical-presence qualification' }
                                }
                                $protectors=@($bl.KeyProtector | Where-Object KeyProtectorType -eq 'Tpm')
                                if(-not $protectors.Count) {
                                    $native=& manage-bde.exe -protectors -add $mount -tpm 2>&1
                                    if($LASTEXITCODE -ne 0) { throw ('Native TPM protector failed: '+($native -join ' ')) }
                                }
                                $native=& manage-bde.exe -on $mount -usedspaceonly -skiphardwaretest -em xts_aes256 2>&1
                                if($LASTEXITCODE -ne 0) { throw ('Native OS encryption failed: '+($native -join ' ')) }
                                $null=Add-BitLockerKeyProtector -MountPoint $mount -RecoveryPasswordProtector
                            } else {
                                $null=Enable-BitLocker -MountPoint $mount -EncryptionMethod XtsAes256 -RecoveryPasswordProtector -UsedSpaceOnly
                                $null=Enable-BitLockerAutoUnlock -MountPoint $mount
                            }
                        }
                        $bl=Get-BitLockerVolume -MountPoint $mount
                        $recovery=@($bl.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword')
                        if($recovery.Count -ne 1) { throw 'Expected one dedicated volume recovery protector' }
                        $recovery | Export-Clixml -LiteralPath (Join-Path $root ($mount.Substring(0,1)+'-recovery.xml'))
                    }
                    $incomplete=@(Get-BitLockerVolume -MountPoint 'C:','E:','W:' | Where-Object { $_.ProtectionStatus.ToString() -ne 'On' -or $_.EncryptionPercentage -ne 100 })
                    $encryptionDeadline=[datetime]::UtcNow.AddMinutes(10)
                    while($incomplete.Count -and [datetime]::UtcNow -lt $encryptionDeadline) {
                        Start-Sleep -Seconds 10
                        $incomplete=@(Get-BitLockerVolume -MountPoint 'C:','E:','W:' | Where-Object { $_.ProtectionStatus.ToString() -ne 'On' -or $_.EncryptionPercentage -ne 100 })
                    }
                    if($incomplete.Count) { return @{stage='encrypting';uuid=$uuid;volumes=@($incomplete | Select-Object MountPoint,ProtectionStatus,EncryptionPercentage,VolumeStatus)} }
                    $accounts=@()
                    foreach($item in $secrets.accounts) {
                        $name=$item.username.Split('\')[-1]
                        if($name -notin @('smal_evidence_writer','smal_workflow_assets')) { throw 'Foreign account requested' }
                        $user=Get-LocalUser -Name $name -ErrorAction SilentlyContinue
                        $identityFile=Join-Path $root ($name+'-identity.json')
                        if($user) {
                            if(-not(Test-Path $identityFile)) { throw 'Existing unbound service account, reconcile before adoption' }
                            $identity=Get-Content $identityFile -Raw | ConvertFrom-Json
                            if($identity.sid -ne $user.SID.Value) { throw 'Service account SID differs' }
                        } else {
                            $request=@{Authority='DATA-target-credential-v2';Action='bootstrap';OperationId=('smb-account-'+[guid]::NewGuid().ToString('N'));
                                ExpiresAtUtc=[datetime]::UtcNow.AddMinutes(25).ToString('o');AccountExpiresAtUtc=$item.expiresAtUtc;GuestUuid=$uuid;Account=$name;Password=$item.password}
                            $input=Join-Path $root ($name+'-request.json')
                            $request | ConvertTo-Json | Set-Content $input
                            $accountScript=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($accountSourceBase64))
                            $identity=& ([scriptblock]::Create($accountScript)) -InputPath $input -Confirm:$false | ConvertFrom-Json
                            $identity | ConvertTo-Json -Depth 6 | Set-Content $identityFile
                        }
                        $accounts+=$identity
                    }
                    $shareNames=@('smal-evidence','smal-workflows')
                    $existing=@(Get-SmbShare | Where-Object Name -in $shareNames)
                    if($existing.Count -eq 0) {
                        $shareScript=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($shareSourceBase64))
                        $null=& ([scriptblock]::Create($shareScript)) -GuestUuid $uuid -EvidenceVolumeUniqueId (Get-Volume -DriveLetter E).UniqueId -WorkflowVolumeUniqueId (Get-Volume -DriveLetter W).UniqueId -OperationId ('smb-shares-'+[guid]::NewGuid().ToString('N')) -ExpiresAtUtc ([datetime]::UtcNow.AddMinutes(25).ToString('o')) -Confirm:$false
                    } elseif($existing.Count -ne 2) { throw 'Partial existing share operation. Inspect before resuming' }
                    if(-not(Get-NetFirewallRule -Name 'SMAL-SMB-Workload' -ErrorAction SilentlyContinue)) {
                        $null=New-NetFirewallRule -Name 'SMAL-SMB-Workload' -DisplayName 'SMAL SMB from AKS workload nodes' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -LocalAddress '10.64.0.190' -RemoteAddress $workloadAddresses -Profile Any
                    } else {
                        $null=Set-NetFirewallRule -Name 'SMAL-SMB-Workload' -RemoteAddress $workloadAddresses
                    }
                    return @{stage='configured';uuid=$uuid;accounts=$accounts;
                        shares=@(Get-SmbShare | Where-Object Name -in $shareNames | Select-Object Name,Path,EncryptData,CachingMode);
                        access=@(foreach($name in $shareNames) { Get-SmbShareAccess -Name $name | Select-Object Name,AccountName,AccessControlType,AccessRight });
                        bitlocker=@(Get-BitLockerVolume -MountPoint 'C:','E:','W:' | Select-Object MountPoint,ProtectionStatus,EncryptionPercentage,EncryptionMethod)}
                    } catch { throw ('FileGuestFailure:'+ $_.InvocationInfo.ScriptLineNumber+':'+$_.FullyQualifiedErrorId+':'+$_.Exception.Message) }
                }
                if($action -eq 'ConfigureGuest') {
                    # BitLocker uses COM APIs that require a local elevated process rather
                    # than the impersonated PowerShell Direct token. Execute this exact
                    # bounded guest configuration as SYSTEM on the dedicated guest only.
                    $guestResult=Invoke-Command -Session $guest -ArgumentList $guestBlock.ToString(),$secrets,$accountSourceBase64,$shareSourceBase64,$settings[0].BIOSGUID.Trim('{}'),$c.workloadAddresses -ScriptBlock {
                        param($source,$secrets,$accountSource,$shareSource,$uuid,$workloadAddresses)
                        $ErrorActionPreference='Stop'
                        if($env:COMPUTERNAME -ine 'SMAL-SMB01' -or (Get-CimInstance Win32_ComputerSystemProduct).UUID -ine $uuid) { throw 'Wrong dedicated guest task target' }
                        $id=[guid]::NewGuid().ToString('N')
                        $root='C:\ProgramData\SMAL\FileService\Tasks\'+$id
                        $null=New-Item $root -ItemType Directory -Force
                        $acl=[Security.AccessControl.DirectorySecurity]::new()
                        $acl.SetAccessRuleProtection($true,$false)
                        foreach($identity in @('NT AUTHORITY\SYSTEM','BUILTIN\Administrators')) {
                            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
                        }
                        Set-Acl $root $acl
                        $input=Join-Path $root 'input.json'
                        @{action='ConfigureGuest';secrets=@{accounts=$secrets.accounts};accountSourceBase64=$accountSource;shareSourceBase64=$shareSource;expectedUuid=$uuid;workloadAddresses=$workloadAddresses} | ConvertTo-Json -Depth 10 | Set-Content $input
                        $worker=Join-Path $root 'worker.ps1'
                        $workerSource=@'
param([string]$InputPath)
$ErrorActionPreference='Stop'
try {
    $input=Get-Content $InputPath -Raw | ConvertFrom-Json
    $arguments=@{}
    foreach($property in $input.PSObject.Properties) { $arguments[$property.Name]=$property.Value }
    $result=& {
'@ + $source + @'

    } @arguments
    $result | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $PSScriptRoot 'result.json')
} catch {
    @{error=$_.Exception.Message;fullyQualifiedErrorId=$_.FullyQualifiedErrorId;line=$_.InvocationInfo.ScriptLineNumber} | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot 'failure.json')
    exit 1
}
'@
                        [IO.File]::WriteAllText($worker,$workerSource,[Text.UTF8Encoding]::new($false))
                        $task='SMAL-FileService-'+$id
                        $taskAction=New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument ('-NoLogo -NoProfile -NonInteractive -File "'+$worker+'" -InputPath "'+$input+'"')
                        $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                        $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
                        $null=Register-ScheduledTask -TaskName $task -Action $taskAction -Principal $principal -Settings $settings
                        Start-ScheduledTask -TaskName $task
                        $deadline=[datetime]::UtcNow.AddMinutes(14)
                        while([datetime]::UtcNow -lt $deadline) {
                            if(Test-Path (Join-Path $root 'failure.json')) { $failure=Get-Content (Join-Path $root 'failure.json') -Raw | ConvertFrom-Json; throw ('Dedicated SYSTEM task '+$id+':'+$failure.error) }
                            if(Test-Path (Join-Path $root 'result.json')) { return (Get-Content (Join-Path $root 'result.json') -Raw | ConvertFrom-Json) }
                            Start-Sleep -Seconds 5
                        }
                        throw ('Dedicated SYSTEM task '+$id+' remains unresolved; inspect original task and files before resuming')
                    }
                } else {
                    $guestResult=Invoke-Command -Session $guest -ArgumentList $action,$secrets,$accountSourceBase64,$shareSourceBase64,$settings[0].BIOSGUID.Trim('{}'),$c.workloadAddresses -ScriptBlock $guestBlock
                }
                if($action -eq 'ConfigureGuest' -and $guestResult.stage -in @('encrypting','configured')) {
                    $recoveryDirectory='C:\ProgramData\SMAL\FileService\Recovery\'+$vm.Id.ToString()
                    if(-not(Test-Path $recoveryDirectory)) {
                        $null=New-Item $recoveryDirectory -ItemType Directory -Force
                        $acl=[Security.AccessControl.DirectorySecurity]::new()
                        $acl.SetAccessRuleProtection($true,$false)
                        foreach($identity in @('NT AUTHORITY\SYSTEM','BUILTIN\Administrators')) {
                            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
                        }
                        Set-Acl $recoveryDirectory $acl
                    }
                    foreach($letter in @('C','E','W')) {
                        Copy-Item -FromSession $guest -LiteralPath ('C:\ProgramData\SMAL\FileService\'+$letter+'-recovery.xml') -Destination (Join-Path $recoveryDirectory ($letter+'-recovery.xml')) -Force
                    }
                    $guestResult | Add-Member -NotePropertyName protectedRecoveryDirectory -NotePropertyValue $recoveryDirectory -Force
                }
                return $guestResult
            } finally { Remove-PSSession $guest }
        }
        if($env:COMPUTERNAME -cne 'LB-NODE03') { throw 'Wrong source-image HCI node' }
        if($action -eq 'Inspect') {
            Import-Module Moc
            $addresses=@(Get-VM | Get-VMNetworkAdapter | ForEach-Object IPAddresses)
            $probe=Test-Connection -ComputerName $c.address -Count 2 -Quiet
            return @{node=$env:COMPUTERNAME; address=$c.address; addressResponds=$probe; localVmAddresses=$addresses;
                sourceFiles=@(Get-ChildItem -LiteralPath $c.sourceDirectory -ErrorAction SilentlyContinue | Select-Object Name,Length,LastWriteTimeUtc);
                mocCommands=@(Get-Command -Module Moc '*Image*','*Network*' | Select-Object Name);
                sourceVolume=(Get-Volume -FilePath 'C:\ClusterStorage\UserStorage_3\' | Select-Object Size,SizeRemaining,HealthStatus)}
        }
        if($action -eq 'PrepareImage') {
            $root=$c.sourceDirectory
            $iso=Join-Path $root 'WindowsServer2025Evaluation.iso'
            $vhd=Join-Path $root 'WindowsServer2025Evaluation.vhdx'
            $ready=Join-Path $root 'image-ready.json'
            if(Test-Path $ready) { return (Get-Content $ready -Raw | ConvertFrom-Json) }
            if(Test-Path $vhd) { throw 'Existing incomplete source VHD. Inspect before continuing, never overwrite' }
            if(-not(Test-Path $root)) { $null=New-Item $root -ItemType Directory }
            if(-not(Test-Path $iso)) {
                & curl.exe --fail --location --silent --show-error --max-time 1200 --output $iso $c.evaluationMediaUrl
                if($LASTEXITCODE -ne 0) { throw 'Evaluation media download failed. Retain partial file for inspection' }
            }
            if((Get-Item $iso).Length -ne $c.evaluationMediaLength -or (Get-FileHash $iso).Hash -cne $c.evaluationMediaSha256) { throw 'Evaluation media length/hash differs' }
            if((Get-DiskImage -ImagePath $iso).Attached) { throw 'Pre-existing media attachment, do not adopt' }
            $mounted=$false; $attached=$false
            try {
                $media=Mount-DiskImage -ImagePath $iso -Access ReadOnly -PassThru
                $mounted=$true
                $volume=@($media | Get-Volume)
                if($volume.Count -ne 1 -or -not $volume[0].DriveLetter) { throw 'Wrong ISO volume' }
                $base=$volume[0].DriveLetter+':\'
                $sig=Get-AuthenticodeSignature (Join-Path $base 'setup.exe')
                if($sig.Status.ToString() -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'Microsoft setup signature invalid' }
                $wim=Join-Path $base 'sources\install.wim'
                $images=@(Get-WindowsImage -ImagePath $wim | Where-Object ImageName -eq 'Windows Server 2025 Datacenter Evaluation')
                if($images.Count -ne 1) { throw ('Expected single Datacenter Evaluation Core image; actual: '+((Get-WindowsImage -ImagePath $wim).ImageName -join ', ')) }
                $letters=@('W','X','Y','Z' | Where-Object { -not(Get-Volume -DriveLetter $_ -ErrorAction SilentlyContinue) -and -not(Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) })
                if($letters.Count -lt 2) { throw 'Two unused temporary volume letters required' }
                $diskImage=New-VHD -Path $vhd -SizeBytes 128GB -Dynamic
                $mount=Mount-VHD -Path $vhd -NoDriveLetter -Passthru
                $attached=$true
                $disks=@($mount | Get-Disk)
                if($disks.Count -ne 1 -or $disks[0].IsBoot -or $disks[0].IsSystem -or $disks[0].PartitionStyle.ToString() -ne 'RAW' -or $disks[0].Size -ne 128GB) { throw 'Not the newly created blank source disk' }
                $disk=$disks[0]
                $null=Initialize-Disk -Number $disk.Number -PartitionStyle GPT
                $efi=New-Partition -DiskNumber $disk.Number -Size 260MB -DriveLetter $letters[0] -GptType '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
                $null=Format-Volume -Partition $efi -FileSystem FAT32 -Confirm:$false
                $null=New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}'
                $os=New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $letters[1]
                $null=Format-Volume -Partition $os -FileSystem NTFS -NewFileSystemLabel 'SMAL-Source' -Confirm:$false
                $apply=$letters[1]+':\'
                $null=Expand-WindowsImage -ImagePath $wim -Index $images[0].ImageIndex -ApplyPath $apply -CheckIntegrity -Verify -LogPath (Join-Path $root 'apply-image.log')
                & "$env:SystemRoot\System32\bcdboot.exe" (Join-Path $apply 'Windows') /s ($letters[0]+':') /f UEFI 2>&1 | Out-Null
                if($LASTEXITCODE -ne 0) { throw 'Source UEFI boot creation failed' }
                Dismount-VHD $vhd
                $attached=$false
                $metadata=@{path=$vhd;virtualSizeBytes=$diskImage.Size;diskIdentifier=$diskImage.DiskIdentifier.ToString();
                    mediaSha256=$c.evaluationMediaSha256;imageName=$images[0].ImageName;imageIndex=$images[0].ImageIndex;
                    licensing='Windows Server 2025 Datacenter Evaluation; time-limited non-production lab';hyperVGeneration='V2'}
                $metadata | ConvertTo-Json | Set-Content $ready
                return $metadata
            } finally {
                if($attached) { Dismount-VHD $vhd }
                if($mounted) { Dismount-DiskImage -ImagePath $iso | Out-Null }
            }
        }
        throw 'Guest actions are not configured yet'
    }
    @{action=$Action;result=$result;observedAt=[datetime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 12 -Compress
} finally { Remove-PSSession $session }
