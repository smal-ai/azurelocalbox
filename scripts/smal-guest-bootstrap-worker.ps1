# Local-only guest boot/domain/bootstrap cleanup. No Azure resource or grant calls.
param([switch]$ResumeVerified, [switch]$ResumeNodeCleanup)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$imageRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01'
$secretDirectory = Join-Path $imageRoot 'secrets'
$statePath = Join-Path $root 'state.json'; $state = $null; $session = $null; $heartbeatStarted = $false
$credentials = [Collections.Generic.List[pscredential]]::new()
$mutex = [Threading.Mutex]::new($false, 'Global\LocalBox-GuestBootstrap-20261028-01')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit 3 }
function Save-BootstrapState {
    param([string]$Phase)
    $state.phase = $Phase; $state.atUtc = (Get-Date).ToUniversalTime().ToString('o')
    $temporary = Join-Path $root 'state.json.tmp'
    [IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Depth 9), [Text.UTF8Encoding]::new($false))
    [IO.File]::Replace($temporary, $statePath, (Join-Path $root 'state.previous.json'))
    $event = @{ runId = $state.runId; atUtc = $state.atUtc; phase = $state.phase; status = $state.status }
    [IO.File]::AppendAllText((Join-Path $root 'events.jsonl'), (($event | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}
function New-StoredGuestCredential {
    param([string]$User, [string]$Role)
    $credential = [pscredential]::new($User, (Read-LabGuestSecureSecret -SecretDirectory $secretDirectory -Role $Role))
    $credentials.Add($credential)
    return $credential
}
function Start-ExactGuest {
    param([string]$Name)
    $entry = @($images.virtualMachines | Where-Object vmName -CEQ $Name)
    if ($entry.Count -ne 1) { throw 'Exact guest image record missing' }
    $vm = Get-VM -Id ([guid]$entry[0].vmId)
    if ($vm.Name -cne $Name -or $vm.State.ToString() -ne 'Off' -or $vm.Generation -ne 2 -or -not (Get-VMSecurity -VM $vm).TpmEnabled -or (Get-VMFirmware -VM $vm).SecureBoot.ToString() -ne 'On') { throw 'Guest VM identity/state/security differs. Do not start.' }
    if ((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB -lt ($vm.MemoryStartup + 16GB)) { throw 'Insufficient host memory admission' }
    Save-BootstrapState ($Name + '-start-approved-guest')
    Start-VM -VM $vm
    return $vm
}
function Save-NestedNatEvidence {
    param([string]$Name, [string]$Ip)
    $captured = $false; $sessions = @()
    try { $sessions = @(Get-NetNatSession -ErrorAction Stop | Where-Object InternalSourceAddress -EQ $Ip | Select-Object Protocol, InternalSourceAddress, InternalSourcePort, ExternalSourceAddress, ExternalSourcePort, InternalDestinationAddress, InternalDestinationPort, ExternalDestinationAddress, ExternalDestinationPort); $captured = $true } catch { }
    $state.natEvidence[$Name] = @{ atUtc = (Get-Date).ToUniversalTime().ToString('o'); sessions = $sessions; captureSucceeded = $captured; expectedOuterSource = '10.200.16.4'; observedSourceTranslation = ($captured -and $sessions.Count -gt 0 -and @($sessions | Where-Object ExternalSourceAddress -NE '10.200.16.4').Count -eq 0) }
}
function ConvertTo-MutableBootstrapValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) { $result = @{}; foreach ($key in $Value.Keys) { $result[$key] = ConvertTo-MutableBootstrapValue $Value[$key] }; return $result }
    if ($Value -is [pscustomobject]) { $result = @{}; foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = ConvertTo-MutableBootstrapValue $property.Value }; return $result }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) { $array = @(foreach ($item in $Value) { ConvertTo-MutableBootstrapValue $item }); return ,$array }
    return $Value
}
try {
    if ($ResumeVerified -and $ResumeNodeCleanup) { throw 'Only one exact recovery mode is allowed' }
    if ($ResumeVerified) {
        $proof = Get-Content (Join-Path $root 'network-recovery-01.json') -Raw | ConvertFrom-Json
        if ($proof.kind -ne 'verified-dc-before-network-before-directory' -or $proof.runId -ne 'guest-bootstrap-20261028-01' -or (Get-FileHash (Join-Path $root 'worker.before-network-recovery.ps1')).Hash -cne '880F2068D876507DDD0E9FC76C8D1905EAFA49A8F1CD542C42E095C4391B7E79' -or -not (Test-Path (Join-Path $root 'execution.started'))) { throw 'Exact DC-only recovery evidence differs' }
    }
    if ($ResumeNodeCleanup) {
        $proof = Get-Content (Join-Path $root 'node-cleanup-recovery-01.json') -Raw | ConvertFrom-Json
        if ($proof.kind -ne 'verified-node01-cleanup-before-node02' -or $proof.runId -ne 'guest-bootstrap-20261028-01' -or (Get-FileHash (Join-Path $root 'worker.before-node-cleanup-recovery.ps1')).Hash -cne '462DED0CD6F44CEF5D2882200FDF374F57CCA1FB60D8528AD59D7D3AEC3A6983' -or -not (Test-Path (Join-Path $root 'execution.started')) -or -not (Test-Path (Join-Path $root 'network-recovery-01.started'))) { throw 'Exact node cleanup recovery evidence differs' }
    }
    $markerName = if ($ResumeVerified) { 'network-recovery-01.started' } elseif ($ResumeNodeCleanup) { 'node-cleanup-recovery-01.started' } else { 'execution.started' }
    $marker = [IO.File]::Open((Join-Path $root $markerName), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); $marker.Dispose()
    $initial = Get-Content $statePath -Raw | ConvertFrom-Json
    $state = [ordered]@{ runId = 'guest-bootstrap-20261028-01'; sourceCommit = $initial.sourceCommit; scope = 'approved-local-guest-boot-domain-and-secret-cleanup-only'; status = 'running'; phase = 'identity-check'; atUtc = $null; errorType = $null; errorLine = $null; guestConfiguration = @{}; cleanup = @{}; newCredentialLoginVerified = @{}; connectivity = @{}; natEvidence = @{}; domain = $null; guestUpdateAssessmentPerformed = $false; evaluationActivationVerified = $false; nodeDomainJoinPerformed = $false; azureRegistrationPerformed = $false; clusterBootstrapComplete = $false }
    $state.errorCode = $null
    $state.clockEvidence = @{}
    if ($ResumeNodeCleanup) {
        $state = ConvertTo-MutableBootstrapValue $initial
        $state.status = 'running'; $state.phase = 'identity-check'; $state.errorType = $null; $state.errorLine = $null; $state.errorCode = $null
        if (-not $state.ContainsKey('clockEvidence')) { $state.clockEvidence = @{} }
        $state.resumedNode01Cleanup = $true
    }
    if ($ResumeVerified -or $ResumeNodeCleanup) {
        if ($proof.sourceCommit -notmatch '^[a-f0-9]{40}$') { throw 'Recovery source evidence missing' }
        $state.previousSourceCommit = $initial.sourceCommit; $state.sourceCommit = $proof.sourceCommit; $state.resumedDcNetworkPhase = $true
    }
    Save-BootstrapState 'identity-check'
    if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or (Get-FileHash (Join-Path $root 'manifest.json')).Hash -cne '__MANIFEST_SHA256__' -or (Get-FileHash (Join-Path $root 'bundle.json')).Hash -cne '__BUNDLE_SHA256__') { throw 'Host/source identity differs' }
    $m = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
    if ($m.runId -ne $state.runId -or $m.scope -ne $state.scope -or $m.registerAzureResources -ne $false -or $m.joinNodesToDomain -ne $false -or $m.deployAksOrWorkloads -ne $false -or $m.domain -cne 'ad.localbox.test' -or $m.netbios -cne 'LOCALBOX' -or $m.dcForwarder -cne '10.204.0.4') { throw 'Bootstrap scope differs' }
    $request = [Net.HttpWebRequest]::Create('http://169.254.169.254/metadata/instance/compute/resourceId?api-version=2021-02-01&format=text')
    $request.Proxy = $null; $request.Headers['Metadata'] = 'true'; $request.Timeout = 5000
    $response = $request.GetResponse()
    try { $reader = [IO.StreamReader]::new($response.GetResponseStream()); try { $vmId = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() } } finally { $response.Close() }
    if ($vmId -ine '/subscriptions/8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea/resourceGroups/rg-localbox-nodes-san-1/providers/Microsoft.Compute/virtualMachines/LocalBox-Client') { throw 'Azure VM identity differs' }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
public static class LocalBoxGuestBootstrapHeartbeat {
    static Timer timer; static string path; static int pid; static int busy;
    public static void Start(string directory, int processId) {
        path = Path.Combine(directory, "heartbeat.json"); pid = processId;
        timer = new Timer(_ => {
            if (Interlocked.Exchange(ref busy, 1) != 0) return;
            try {
                string temporary = path + ".tmp";
                File.WriteAllText(temporary, "{\"processId\":" + pid + ",\"atUtc\":\"" + DateTime.UtcNow.ToString("o") + "\"}", new UTF8Encoding(false));
                if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
            } catch { } finally { Interlocked.Exchange(ref busy, 0); }
        }, null, 0, 15000);
    }
    public static void Stop() { if (timer != null) timer.Dispose(); }
}
'@
    [LocalBoxGuestBootstrapHeartbeat]::Start($root, $PID); $heartbeatStarted = $true
    Save-BootstrapState 'waiting-for-exact-image-job'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $images = Get-Content (Join-Path $imageRoot 'state.json') -Raw | ConvertFrom-Json
        $imageTask = Get-ScheduledTask -TaskName 'LocalBox-GuestImages-20261028-01'
        $imageInfo = Get-ScheduledTaskInfo -TaskName $imageTask.TaskName
        if ($images.sourceCommit -cne $m.imageSourceCommit -or (Get-FileHash (Join-Path $imageRoot 'worker.ps1')).Hash -cne $m.imageWorkerSha256) { throw 'Exact image dependency source differs' }
        if ($images.status -like 'failed*' -or ($imageTask.State.ToString() -ne 'Running' -and $imageInfo.LastTaskResult -ne 0)) { throw 'Image dependency failed or stopped. No guest boot.' }
        if ($images.status -eq 'guests-created-off' -and $imageTask.State.ToString() -ne 'Running' -and $imageInfo.LastTaskResult -eq 0) { break }
        if ($timer.Elapsed.TotalHours -gt 6) { throw 'Image dependency deadline reached. No replay.' }
        Start-Sleep -Seconds 15
    }
    if (@($images.virtualMachines).Count -ne 3 -or @(Get-VM).Count -ne 3 -or -not $images.secretsCreated) { throw 'Three approved guest records required' }
    Save-BootstrapState 'load-pinned-bootstrap-helpers'
    $bundle = Get-Content (Join-Path $root 'bundle.json') -Raw | ConvertFrom-Json
    $expectedNames = @('smal-guest-secret-functions.ps1', 'smal-guest-direct-functions.ps1')
    if ($bundle.schemaVersion -ne 1 -or @($bundle.files).Count -ne 2 -or @(Compare-Object $expectedNames @($bundle.files | ForEach-Object name)).Count -ne 0) { throw 'Unexpected bootstrap helper bundle' }
    foreach ($item in $bundle.files) {
        $path = Join-Path $root $item.name; $bytes = [Convert]::FromBase64String($item.base64)
        if (-not $ResumeVerified -and -not $ResumeNodeCleanup) {
            $file = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $file.Write($bytes, 0, $bytes.Length) } finally { $file.Dispose() }
        }
        if ((Get-FileHash $path).Hash -cne $item.sha256) { throw 'Bootstrap helper integrity differs' }
        . $path
    }
    if (-not $ResumeNodeCleanup) {
    if ($ResumeVerified) {
        $dc = Get-VM -Id 'f94c71f1-6854-48b9-a9f1-8238c99366d0'
        if ($dc.Name -cne 'LB-DC01' -or $dc.State.ToString() -ne 'Running') { throw 'Exact running DC recovery target differs' }
        Save-BootstrapState 'resume-existing-dc-no-repeat-boot'
    } else { $dc = Start-ExactGuest 'LB-DC01' }
    $dcCredential = New-StoredGuestCredential -User 'LB-DC01\Administrator' -Role 'dc-bootstrap'
    Save-BootstrapState 'LB-DC01-wait-for-setup-and-direct-session'
    $session = Wait-LabGuestSession -VmId $dc.Id -ExpectedName 'LB-DC01' -Credential $dcCredential
    Save-BootstrapState 'LB-DC01-configure-exact-guest-network'
    $state.guestConfiguration['LB-DC01'] = Set-LabGuestNetwork -Session $session -VmName 'LB-DC01' -Adapters @(Get-VMNetworkAdapter -VM $dc | Select-Object Name, MacAddress)
    Save-BootstrapState 'LB-DC01-create-approved-forest'
    $recovery = Read-LabGuestSecureSecret -SecretDirectory $secretDirectory -Role 'directory-recovery'
    try { $forest = Install-LabDomainForest -Session $session -RecoverySecret $recovery } finally { $recovery.Dispose() }
    Save-BootstrapState 'LB-DC01-required-domain-reboot'
    try { Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock { Restart-Computer -Force } } catch { }
    Remove-PSSession -Session $session; $session = $null
    $dcDomainCredential = New-StoredGuestCredential -User 'LOCALBOX\Administrator' -Role 'dc-bootstrap'
    Save-BootstrapState 'LB-DC01-verify-new-domain-boot'
    $session = Wait-LabGuestSession -VmId $dc.Id -ExpectedName 'LB-DC01' -Credential $dcDomainCredential -PreviousBootUtc $forest.bootUtc
    Save-BootstrapState 'LB-DC01-configure-domain-dns-forwarder'
    $state.domain = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        Import-Module ActiveDirectory
        $wait = [Diagnostics.Stopwatch]::StartNew(); $domain = $null; $forest = $null
        while (-not $domain -or -not $forest) {
            try { $domain = Get-ADDomain -Identity 'ad.localbox.test' -ErrorAction Stop; $forest = Get-ADForest -Identity 'ad.localbox.test' -ErrorAction Stop } catch { $domain = $null; $forest = $null }
            if ($domain -and $forest) { break }
            if ($wait.Elapsed.TotalSeconds -gt 600) { throw 'New lab directory services did not become ready' }
            Start-Sleep -Seconds 5
        }
        if ($env:COMPUTERNAME -cne 'LB-DC01' -or $domain.DNSRoot -cne 'ad.localbox.test' -or $domain.NetBIOSName -cne 'LOCALBOX') { throw 'Created directory identity differs' }
        $null = Set-DnsServerForwarder -IPAddress '10.204.0.4' -UseRootHint $false -PassThru
        # Configure only this new lab forest's PDC time source, not the outer host.
        & w32tm.exe /config '/manualpeerlist:time.windows.com,0x8' /syncfromflags:manual /reliable:yes /update | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Lab DC time-source configuration failed' }
        @{ dnsRoot = $domain.DNSRoot; netbios = $domain.NetBIOSName; domainMode = $domain.DomainMode.ToString(); forestMode = $forest.ForestMode.ToString(); dnsForwarders = @((Get-DnsServerForwarder).IPAddress | ForEach-Object { $_.ToString() }); configuredTimePeer = 'time.windows.com'; timeSynchronisationProvenByConfiguration = $false; defenderEnabled = (Get-MpComputerStatus).RealTimeProtectionEnabled; guestFirewallEnabled = @(Get-NetFirewallProfile | Where-Object Enabled -NE $true).Count -eq 0 }
    }
    Save-BootstrapState 'LB-DC01-verify-nested-connectivity'
    $state.connectivity['LB-DC01'] = Test-LabGuestConnectivity -Session $session
    Save-NestedNatEvidence -Name 'LB-DC01' -Ip '10.64.0.10'
    Save-BootstrapState 'LB-DC01-clean-owned-answer-files-and-rotate'
    $final = Read-LabGuestSecureSecret -SecretDirectory $secretDirectory -Role 'dc-admin'
    try { $state.cleanup['LB-DC01'] = Complete-LabGuestBootstrapSecret -Session $session -VmName 'LB-DC01' -BootstrapSecret $dcDomainCredential.Password -FinalSecret $final } finally { $final.Dispose() }
    Remove-PSSession -Session $session; $session = $null
    $dcFinalCredential = New-StoredGuestCredential -User 'LOCALBOX\Administrator' -Role 'dc-admin'
    $session = Wait-LabGuestSession -VmId $dc.Id -ExpectedName 'LB-DC01' -Credential $dcFinalCredential
    $state.newCredentialLoginVerified['LB-DC01'] = $true
    Remove-PSSession -Session $session; $session = $null
    }
    foreach ($row in @(@{ name = 'LB-NODE01'; prefix = 'node01'; ip = '10.64.0.11' }, @{ name = 'LB-NODE02'; prefix = 'node02'; ip = '10.64.0.12' })) {
        $resumeThisNode = $ResumeNodeCleanup -and $row.name -eq 'LB-NODE01'
        if ($resumeThisNode) {
            $node = Get-VM -Id '3adff629-2f67-449b-ab32-8a8748c46f34'
            if ($node.Name -cne 'LB-NODE01' -or $node.State.ToString() -ne 'Running') { throw 'Exact running node cleanup target differs' }
            Save-BootstrapState 'resume-existing-node01-no-repeat-boot-or-network'
        } else { $node = Start-ExactGuest $row.name }
        $credential = New-StoredGuestCredential -User ($row.name + '\Administrator') -Role ($row.prefix + '-bootstrap')
        Save-BootstrapState ($row.name + '-wait-for-setup-and-direct-session')
        $session = Wait-LabGuestSession -VmId $node.Id -ExpectedName $row.name -Credential $credential
        if (-not $resumeThisNode) {
        Save-BootstrapState ($row.name + '-configure-exact-guest-network')
        $state.guestConfiguration[$row.name] = Set-LabGuestNetwork -Session $session -VmName $row.name -Adapters @(Get-VMNetworkAdapter -VM $node | Select-Object Name, MacAddress)
        Save-BootstrapState ($row.name + '-verify-or-install-nested-hyperv')
        $role = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $feature = Get-WindowsFeature -Name Hyper-V
            $restart = $false
            if (-not $feature.Installed -or -not (Get-Command Get-VMHost -ErrorAction SilentlyContinue)) { $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools; if (-not $result.Success) { throw 'Guest Hyper-V installation failed' }; $restart = $result.RestartNeeded.ToString() -eq 'Yes' }
            @{ rebootRequired = $restart; bootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') }
        }
        if ($role.rebootRequired) {
            Save-BootstrapState ($row.name + '-required-hyperv-reboot')
            try { Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock { Restart-Computer -Force } } catch { }
            Remove-PSSession -Session $session; $session = $null
            $session = Wait-LabGuestSession -VmId $node.Id -ExpectedName $row.name -Credential $credential -PreviousBootUtc $role.bootUtc
        }
        $state.guestConfiguration[$row.name].nestedHyperv = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            $wait = [Diagnostics.Stopwatch]::StartNew()
            while ((Get-Service vmms).Status.ToString() -ne 'Running') { if ($wait.Elapsed.TotalSeconds -gt 300) { throw 'Nested Hyper-V service did not become ready' }; Start-Sleep -Seconds 2 }
            $hostInfo = Get-VMHost
            @{ vmmsRunning = $true; logicalProcessors = $hostInfo.LogicalProcessorCount; guestReportedCores = [int](Get-CimInstance Win32_Processor | Measure-Object NumberOfCores -Sum).Sum; memoryBytes = $hostInfo.MemoryCapacity; defenderEnabled = (Get-MpComputerStatus).RealTimeProtectionEnabled; guestFirewallEnabled = @(Get-NetFirewallProfile | Where-Object Enabled -NE $true).Count -eq 0 }
        }
        }
        Save-BootstrapState ($row.name + '-verify-clock-without-manual-adjustment')
        $state.clockEvidence[$row.name] = Get-LabGuestClockEvidence -Session $session
        Save-BootstrapState ($row.name + '-verify-nested-connectivity')
        $state.connectivity[$row.name] = Test-LabGuestConnectivity -Session $session
        Save-NestedNatEvidence -Name $row.name -Ip $row.ip
        Save-BootstrapState ($row.name + '-clean-owned-answer-files-and-rotate')
        $final = Read-LabGuestSecureSecret -SecretDirectory $secretDirectory -Role ($row.prefix + '-admin')
        try { $state.cleanup[$row.name] = Complete-LabGuestBootstrapSecret -Session $session -VmName $row.name -BootstrapSecret $credential.Password -FinalSecret $final } finally { $final.Dispose() }
        Remove-PSSession -Session $session; $session = $null
        $newCredential = New-StoredGuestCredential -User ($row.name + '\Administrator') -Role ($row.prefix + '-admin')
        $session = Wait-LabGuestSession -VmId $node.Id -ExpectedName $row.name -Credential $newCredential
        $state.newCredentialLoginVerified[$row.name] = $true
        Remove-PSSession -Session $session; $session = $null
    }
    $passed = $state.domain.defenderEnabled -and $state.domain.guestFirewallEnabled
    foreach ($name in @('LB-DC01', 'LB-NODE01', 'LB-NODE02')) {
        if (-not $state.newCredentialLoginVerified[$name] -or $state.cleanup[$name].setupLogsNeedReview -or $state.cleanup[$name].answerFileCleanupNeedsReview -or -not $state.connectivity[$name].transportChecksPassed -or -not $state.natEvidence[$name].observedSourceTranslation) { $passed = $false }
    }
    foreach ($name in @('LB-NODE01', 'LB-NODE02')) {
        $health = $state.guestConfiguration[$name].nestedHyperv
        if (-not $health.vmmsRunning -or -not $health.defenderEnabled -or -not $health.guestFirewallEnabled -or $health.logicalProcessors -ne 12 -or $health.memoryBytes -lt 90GB -or -not $state.clockEvidence[$name].selectedClockChecksPassed) { $passed = $false }
    }
    $state.status = if ($passed) { 'local-bootstrap-configured-and-checked' } else { 'local-bootstrap-configured-checks-pending' }
    Save-BootstrapState 'local-only-bootstrap-finished-no-azure-registration'
} catch {
    if ($state) {
        $state.status = 'failed-inspect-before-resume'; $state.errorType = $_.Exception.GetType().Name; $state.errorLine = $_.InvocationInfo.ScriptLineNumber
        $state.errorCode = 'unclassified'
        if ($_.FullyQualifiedErrorId -match '^(?<code>[A-Za-z][A-Za-z0-9_.-]{0,100})(?:,|$)') { $state.errorCode = $matches.code }
        foreach ($code in @('Guest identity/protection differs', 'Guest adapter profile differs', 'Host MAC mapping missing or ambiguous', 'Guest adapter MAC identity differs', 'Guest adapter rename conflicts', 'Guest management IP already conflicts', 'Unexpected non-management gateway', 'Non-management address needs the reviewed ATC plan')) { if ($_.Exception.Message.Contains($code)) { $state.errorCode = $code } }
        try { Save-BootstrapState $state.phase } catch { }
    }
    exit 1
} finally {
    if ($session) { Remove-PSSession -Session $session }
    foreach ($credential in $credentials) { $credential.Password.Dispose() }
    if ($heartbeatStarted) { [LocalBoxGuestBootstrapHeartbeat]::Stop() }
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
