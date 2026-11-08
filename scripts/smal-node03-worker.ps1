# One approved new NODE3 only. No Arc authentication or cluster deployment here.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\node03-20261029-01'
$threeRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\three-node-20261029-01'
$guestRoot = 'W:\AzureLocalBox\Guests\three-node-20261029-01\LB-NODE03'
$statePath = Join-Path $root 'state.json'
$state = @{ sourceCommit = '__SOURCE_COMMIT__'; status = 'running'; phase = 'identity-check'; atUtc = $null; vm = $null; cleanup = $null; commonCredentialLoginVerified = $false; azureRegistrationPerformed = $false; clusterDeploymentPerformed = $false }
$session = $null; $bootstrap = $null; $common = $null; $lease = $null; $mounted = $false; $heartbeat = $false
$mutex = [Threading.Mutex]::new($false, 'Global\LocalBox-Node03-20261029-01')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit 3 }
function Save-Node03([string]$phase) {
    $state.phase = $phase; $state.atUtc = [datetime]::UtcNow.ToString('o')
    $temporary = $statePath + '.tmp'
    [IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    [IO.File]::Replace($temporary, $statePath, (Join-Path $root 'state.previous.json'))
    [IO.File]::AppendAllText((Join-Path $root 'events.jsonl'), ((@{ atUtc = $state.atUtc; phase = $phase; status = $state.status } | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}
try {
    $marker = [IO.File]::Open((Join-Path $root 'execution.started'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); $marker.Dispose()
    if ($env:COMPUTERNAME -cne 'LocalBox-Client' -or (Get-FileHash (Join-Path $root 'approval.json')).Hash -cne '__NODE03_APPROVAL_SHA256__' -or (Get-FileHash (Join-Path $root 'bundle.json')).Hash -cne '__NODE03_BUNDLE_SHA256__') { throw 'NODE3 host/source/approval differs' }
    $consent = Get-Content (Join-Path $root 'approval.json') -Raw | ConvertFrom-Json
    if ($consent.approved -ne $true -or $consent.node03ImageTemporaryAnswerFileCleanupAndSharedClusterCredentialApproved -ne $true) { throw 'NODE3 apply approval missing' }
    $resize = Get-Content (Join-Path $threeRoot 'existing-node-resize.json') -Raw | ConvertFrom-Json
    $diskProof = Get-Content (Join-Path $threeRoot 'new-disk-format.json') -Raw | ConvertFrom-Json
    if ($resize.status -cne 'complete-existing-nodes-64gib-8vcpu-and-one-vhd-relocated' -or $diskProof.status -cne 'complete-new-lun8-only-formatted-w' -or (Get-Volume -DriveLetter W).UniqueId -cne $diskProof.volumeId -or (Get-Volume -DriveLetter W).SizeRemaining -lt 1088GB -or (Get-Volume -DriveLetter V).SizeRemaining -lt 200GB -or (Test-Path $guestRoot) -or (Get-VM -Name LB-NODE03 -ErrorAction SilentlyContinue) -or @(Get-VM).Count -ne 3) { throw 'Existing preparation/capacity or NODE3 identity differs' }
    foreach ($row in @(@{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34' }, @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' })) {
        $existing = Get-VM -Id $row.id
        if ($existing.Name -cne $row.name -or $existing.MemoryStartup -ne 64GB -or $existing.ProcessorCount -ne 8 -or $existing.State.ToString() -ne 'Running') { throw 'Existing resized guest differs' }
    }
    $bundle = Get-Content (Join-Path $root 'bundle.json') -Raw | ConvertFrom-Json
    $names = @('node03-secrets.ps1','node03-image.ps1','node03-vm.ps1','node03-direct.ps1')
    if (@($bundle.files).Count -ne 4 -or @(Compare-Object $names @($bundle.files.name)).Count -ne 0) { throw 'Exact helper set differs' }
    foreach ($item in $bundle.files) {
        $path = Join-Path $root $item.name; $bytes = [Convert]::FromBase64String($item.base64)
        if ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-','') -cne $item.sha256) { throw 'Helper source hash differs' }
        [IO.File]::WriteAllBytes($path, $bytes); . $path
    }
    Add-Type -TypeDefinition @'
using System; using System.IO; using System.Text; using System.Threading;
public static class LocalBoxNode03Heartbeat {
    static Timer timer; static string path; static int busy;
    public static void Start(string directory) { path=Path.Combine(directory,"heartbeat.json"); timer=new Timer(_=>{if(Interlocked.Exchange(ref busy,1)!=0)return;try{string t=path+".tmp";File.WriteAllText(t,"{\"atUtc\":\""+DateTime.UtcNow.ToString("o")+"\"}",new UTF8Encoding(false));if(File.Exists(path))File.Replace(t,path,null);else File.Move(t,path);}catch{}finally{Interlocked.Exchange(ref busy,0);}},null,0,15000); }
    public static void Stop() {if(timer!=null)timer.Dispose();}
}
'@
    [LocalBoxNode03Heartbeat]::Start($root); $heartbeat = $true
    Save-Node03 'protect-new-owned-node03-directory-and-secrets'
    $null = New-Item $guestRoot -ItemType Directory -Force; Set-Acl $guestRoot (Get-Acl $root)
    $store = Join-Path $root 'secrets'; $null = New-Item $store -ItemType Directory
    $value = New-LabGuestSecretText; Write-LabGuestSecret -SecretDirectory $store -Role 'node03-bootstrap' -Value $value; $value = $null
    $bootstrap = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'node03-bootstrap'
    $iso = 'C:\ProgramData\AzureLocalBox\Artifacts\2610\AzureLocal24H2.26100.32230.LCM.12.2610.0.3098.x64.en-us.iso'
    Save-Node03 'verify-pinned-iso-before-read-only-mount'
    if ((Get-Item $iso).Length -ne 7491864576 -or (Get-DiskImage -ImagePath $iso).Attached) { throw 'Pinned HCI media length/attachment differs' }
    $lease = [IO.FileStream]::new($iso, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { if ([BitConverter]::ToString($hash.ComputeHash($lease)).Replace('-','') -cne '317330754A6DAC6F42C1BE40EB780E0959C6C3F7670B33D94556964CDCBC9E89') { throw 'Publisher-verified HCI ISO hash differs' } } finally { $hash.Dispose() }
    $image = Mount-DiskImage -ImagePath $iso -Access ReadOnly -PassThru; $mounted = $true
    $volumes = @($image | Get-Volume)
    if ($volumes.Count -ne 1 -or -not $volumes[0].DriveLetter) { throw 'Mounted image volume ambiguous' }
    $wim = $volumes[0].DriveLetter + ':\sources\install.wim'
    $metadata = Get-WindowsImage -ImagePath $wim -Index 1
    if ($metadata.EditionId -cne 'ServerAzureStackHCICor' -or $metadata.Version.ToString() -cne '10.0.26100.33650') { throw 'Selected HCI edition/build differs' }
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($bootstrap)
    try { $clear = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer); $xml = New-LabGuestUnattendXml -ComputerName LB-NODE03 -BootstrapSecret $clear; $state.image = New-LabGuestOsImage -VmName LB-NODE03 -OsDiskPath (Join-Path $guestRoot 'OS.vhdx') -ImagePath $wim -ImageIndex 1 -UnattendXml $xml -Checkpoint { param($phase) Save-Node03 $phase } }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); $clear = $null; $xml = $null }
    Dismount-DiskImage -ImagePath $iso; $mounted = $false; $lease.Dispose(); $lease = $null
    Save-Node03 'create-new-node03-only-preserve-existing-guardian'
    $state.vm = New-LabGuestVm -VmName LB-NODE03 -OsDiskPath (Join-Path $guestRoot 'OS.vhdx') -GuardianName LB-LocalGuardian -Checkpoint { param($phase) Save-Node03 $phase }
    Save-Node03 'returned-node03-id-bound-before-boot'
    $vm = Get-VM -Id ([guid]$state.vm.vmId)
    if ($vm.Name -cne 'LB-NODE03' -or $vm.State.ToString() -ne 'Off' -or (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB -lt 80GB) { throw 'New guest identity/state or RAM admission differs' }
    Start-VM -VM $vm
    $credential = [pscredential]::new('LB-NODE03\Administrator', $bootstrap)
    Save-Node03 'wait-for-node03-setup-and-map-approved-adapters'
    $session = Wait-LabGuestSession -VmId $vm.Id -ExpectedName LB-NODE03 -Credential $credential
    $state.network = Set-LabGuestNetwork -Session $session -VmName LB-NODE03 -Adapters @(Get-VMNetworkAdapter -VM $vm | Select-Object Name,MacAddress)
    Save-Node03 'verify-or-install-nested-hyperv-only-in-node03'
    $role = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference = 'Stop'; if ($env:COMPUTERNAME -cne 'LB-NODE03' -or (Get-CimInstance Win32_ComputerSystem).DomainRole -ne 2) { throw 'New standalone node differs' }
        $restart = $false
        if (-not (Get-WindowsFeature Hyper-V).Installed -or -not (Get-Command Get-VMHost -ErrorAction SilentlyContinue)) { $feature = Install-WindowsFeature Hyper-V -IncludeManagementTools; if (-not $feature.Success) { throw 'Nested Hyper-V installation failed' }; $restart = $feature.RestartNeeded.ToString() -eq 'Yes' }
        @{ rebootRequired = $restart; bootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') }
    }
    if ($role.rebootRequired) {
        Save-Node03 'required-node03-feature-reboot'
        try { Invoke-Command -Session $session -ScriptBlock { Restart-Computer -Force } -ErrorAction Stop } catch { }
        Remove-PSSession $session; $session = $null
        $session = Wait-LabGuestSession -VmId $vm.Id -ExpectedName LB-NODE03 -Credential $credential -PreviousBootUtc $role.bootUtc
    }
    Save-Node03 'observe-clock-connectivity-and-protection'
    $state.clock = Get-LabGuestClockEvidence -Session $session
    $state.connectivity = Test-LabGuestConnectivity -Session $session
    $state.nested = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock { $h = Get-VMHost; @{ vmmsRunning = ((Get-Service vmms).Status.ToString() -eq 'Running'); logicalProcessors = $h.LogicalProcessorCount; memoryBytes = $h.MemoryCapacity; defenderEnabled = (Get-MpComputerStatus).RealTimeProtectionEnabled; firewallEnabled = @(Get-NetFirewallProfile | Where-Object Enabled -NE $true).Count -eq 0 } }
    Save-Node03 'clean-owned-answer-files-and-rotate-to-cluster-only-credential'
    $common = Read-LabGuestSecureSecret -SecretDirectory 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets' -Role 'cluster-node-admin'
    $state.cleanup = Complete-LabGuestBootstrapSecret -Session $session -VmName LB-NODE03 -BootstrapSecret $bootstrap -FinalSecret $common
    Remove-PSSession $session; $session = $null
    $session = Wait-LabGuestSession -VmId $vm.Id -ExpectedName LB-NODE03 -Credential ([pscredential]::new('LB-NODE03\Administrator', $common))
    $state.commonCredentialLoginVerified = $true
    $state.guestDisks = @(Invoke-Command -Session $session -ScriptBlock { Get-Disk | ForEach-Object { @{ uniqueId = $_.UniqueId; size = $_.Size; style = $_.PartitionStyle.ToString(); isBoot = $_.IsBoot; isSystem = $_.IsSystem } } } -ErrorAction Stop)
    $state.hostDisks = @(Get-VMHardDiskDrive -VM $vm | ForEach-Object { $vhd = Get-VHD -Path $_.Path; @{ path = $_.Path; lun = $_.ControllerLocation; diskId = $vhd.DiskIdentifier.ToString(); size = $vhd.Size } })
    Remove-PSSession $session; $session = $null
    if ($state.cleanup.setupLogsNeedReview -or $state.cleanup.answerFileCleanupNeedsReview -or -not $state.clock.selectedClockChecksPassed -or -not $state.connectivity.transportChecksPassed -or -not $state.nested.vmmsRunning -or $state.nested.logicalProcessors -ne 8 -or $state.nested.memoryBytes -lt 60GB -or -not $state.nested.defenderEnabled -or -not $state.nested.firewallEnabled -or $state.guestDisks.Count -ne 5 -or @($state.guestDisks | Where-Object { -not $_.isBoot -and -not $_.isSystem -and $_.style -eq 'RAW' -and $_.size -eq 170GB }).Count -ne 4) { throw 'NODE3 local acceptance or credential cleanup incomplete' }
    Save-Node03 'publish-only-verified-public-node03-credential-binding'
    $bindingPath = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json'
    $bindings = Get-Content $bindingPath -Raw | ConvertFrom-Json
    if ($bindings.runId -cne 'cluster-prereqs-20261028-01' -or $bindings.nodes.PSObject.Properties['LB-NODE03']) { throw 'Credential binding identity exists or differs' }
    $bindings.nodes | Add-Member -NotePropertyName 'LB-NODE03' -NotePropertyValue @{ vmId = $vm.Id.ToString(); secretDirectory = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'; role = 'cluster-node-admin'; loginVerified = $true }
    [IO.File]::WriteAllText(($bindingPath + '.node03.tmp'), ($bindings | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    [IO.File]::Replace(($bindingPath + '.node03.tmp'), $bindingPath, ($bindingPath + '.before-node03-20261029.json'))
    if ((Get-Volume -DriveLetter V).SizeRemaining -lt 200GB -or (Get-Volume -DriveLetter W).SizeRemaining -lt 200GB) { throw 'Volume free-space floor reached' }
    $state.status = 'complete-node03-local-bootstrap-cleanup-and-common-login'; Save-Node03 'ready-for-human-arc-authentication-not-registered'
} catch { $state.status = 'failed-or-uncertain-inspect-before-resume'; $state.errorType = $_.Exception.GetType().Name; $state.errorLine = $_.InvocationInfo.ScriptLineNumber; try { Save-Node03 $state.phase } catch { }; exit 1 }
finally { if ($session) { Remove-PSSession $session }; if ($bootstrap) { $bootstrap.Dispose() }; if ($common) { $common.Dispose() }; if ($mounted) { Dismount-DiskImage -ImagePath $iso | Out-Null }; if ($lease) { $lease.Dispose() }; if ($heartbeat) { [LocalBoxNode03Heartbeat]::Stop() }; $mutex.ReleaseMutex(); $mutex.Dispose() }
