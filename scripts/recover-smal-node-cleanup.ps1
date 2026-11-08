# Exact node-1 cleanup continuation. Preserve DC, existing VM/network and proofs.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$imageRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01'
$taskName = 'LocalBox-GuestBootstrap-20261028-01'
if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or (Test-Path (Join-Path $root 'node-cleanup-recovery-01.json'))) { throw 'Target differs or node cleanup recovery already attempted' }
$task = Get-ScheduledTask -TaskName $taskName; $info = Get-ScheduledTaskInfo -TaskName $taskName
$state = Get-Content (Join-Path $root 'state.json') -Raw | ConvertFrom-Json
if ($task.State.ToString() -ne 'Ready' -or $info.LastTaskResult -ne 1 -or $state.status -ne 'failed-inspect-before-resume' -or $state.phase -ne 'LB-NODE01-clean-owned-answer-files-and-rotate' -or $state.errorCode -ne 'IOException' -or $state.domain.dnsRoot -ne 'ad.localbox.test' -or $state.newCredentialLoginVerified.'LB-DC01' -ne $true -or $state.cleanup.'LB-DC01'.setupLogsNeedReview -or $state.cleanup.'LB-NODE01' -or $state.newCredentialLoginVerified.'LB-NODE01' -or -not $state.connectivity.'LB-NODE01'.transportChecksPassed -or -not $state.natEvidence.'LB-NODE01'.observedSourceTranslation) { throw 'Exact cleanup-only checkpoint or retained DC/node proofs differ' }
if ($task.Principal.UserId -notin @('SYSTEM', 'S-1-5-18') -or @($task.Triggers | Where-Object { $null -ne $_ }).Count -ne 0 -or $task.Actions.Count -ne 1 -or $task.Actions[0].Execute -ine 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -or $task.Actions[0].Arguments -cne ('-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $root 'worker.ps1') + '" -ResumeVerified')) { throw 'Expected existing task action/ownership differs' }
if ((Get-FileHash (Join-Path $root 'worker.ps1')).Hash -cne '462DED0CD6F44CEF5D2882200FDF374F57CCA1FB60D8528AD59D7D3AEC3A6983' -or (Get-FileHash (Join-Path $root 'bundle.json')).Hash -cne 'F8D2115030F01BCCB2A6E8C224612D91864E8684B69AB82BFAB9195FBF1F2E8E' -or (Get-FileHash (Join-Path $root 'manifest.json')).Hash -cne '__MANIFEST_SHA256__' -or -not (Test-Path (Join-Path $root 'execution.started')) -or -not (Test-Path (Join-Path $root 'network-recovery-01.started'))) { throw 'Pinned node cleanup source/markers differ' }
$old = Get-Content (Join-Path $root 'bundle.json') -Raw | ConvertFrom-Json
foreach ($file in $old.files) { if ($file.name -notin @('smal-guest-direct-functions.ps1', 'smal-guest-secret-functions.ps1') -or (Get-FileHash (Join-Path $root $file.name)).Hash -cne $file.sha256) { throw 'Original helper source differs' } }
. (Join-Path $root 'smal-guest-secret-functions.ps1')
$node = Get-VM -Id '3adff629-2f67-449b-ab32-8a8748c46f34'
$second = Get-VM -Id '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3'
$dc = Get-VM -Id 'f94c71f1-6854-48b9-a9f1-8238c99366d0'
if ($node.Name -cne 'LB-NODE01' -or $node.State.ToString() -ne 'Running' -or $second.Name -cne 'LB-NODE02' -or $second.State.ToString() -ne 'Off' -or $dc.Name -cne 'LB-DC01' -or $dc.State.ToString() -ne 'Running') { throw 'Expected existing VM identities/states differ' }
$secure = Read-LabGuestSecureSecret -SecretDirectory (Join-Path $imageRoot 'secrets') -Role 'node01-bootstrap'; $session = $null
try {
    $session = New-PSSession -VMId $node.Id -Credential ([pscredential]::new('LB-NODE01\Administrator', $secure)) -ErrorAction Stop
    $verified = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -cne 'LB-NODE01' -or (Get-CimInstance Win32_ComputerSystem).DomainRole -ne 2 -or (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState -ne 'IMAGE_STATE_COMPLETE' -or (Get-Service vmms).Status.ToString() -ne 'Running') { throw 'Node setup/domain/Hyper-V state differs' }
        $address = @(Get-NetIPAddress -IPAddress '10.64.0.11' -AddressFamily IPv4)
        if ($address.Count -ne 1 -or $address[0].InterfaceAlias -cne 'MGMT1' -or $address[0].PrefixLength -ne 24 -or @((Get-DnsClientServerAddress -InterfaceIndex $address[0].InterfaceIndex -AddressFamily IPv4).ServerAddresses).Count -ne 1 -or (Get-DnsClientServerAddress -InterfaceIndex $address[0].InterfaceIndex -AddressFamily IPv4).ServerAddresses[0] -cne '10.64.0.10') { throw 'Approved existing node management network differs' }
        if (-not (Get-MpComputerStatus).RealTimeProtectionEnabled -or @(Get-NetFirewallProfile | Where-Object Enabled -NE $true).Count -ne 0) { throw 'Node protection differs' }
        return $true
    }
    if ($verified -ne $true) { throw 'Existing node/bootstrap-login proof missing' }
} finally { if ($session) { Remove-PSSession -Session $session }; $secure.Dispose() }
foreach ($entry in @(@{ source = 'state.json'; backup = 'state.before-node-cleanup-recovery.json' }, @{ source = 'worker.ps1'; backup = 'worker.before-node-cleanup-recovery.ps1' }, @{ source = 'bundle.json'; backup = 'bundle.before-node-cleanup-recovery.json' })) { [IO.File]::Copy((Join-Path $root $entry.source), (Join-Path $root $entry.backup), $false) }
foreach ($item in $old.files) { [IO.File]::Copy((Join-Path $root $item.name), (Join-Path $root ($item.name + '.before-node-cleanup-recovery')), $false) }
$proof = @{ kind = 'verified-node01-cleanup-before-node02'; runId = 'guest-bootstrap-20261028-01'; sourceCommit = '__SOURCE_COMMIT__'; atUtc = (Get-Date).ToUniversalTime().ToString('o'); originalMarkersRetained = $true; dcAndNode01ConfigurationRetained = $true; node01OriginalCredentialLoginVerified = $true; node02RemainsOff = $true }
$bytes = [Text.Encoding]::UTF8.GetBytes(($proof | ConvertTo-Json))
$stream = [IO.File]::Open((Join-Path $root 'node-cleanup-recovery-01.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
[IO.File]::WriteAllBytes((Join-Path $root 'bundle.json'), [Convert]::FromBase64String('__BUNDLE_BASE64__'))
[IO.File]::WriteAllBytes((Join-Path $root 'worker.ps1'), [Convert]::FromBase64String('__WORKER_BASE64__'))
if ((Get-FileHash (Join-Path $root 'bundle.json')).Hash -cne '__BUNDLE_SHA256__' -or (Get-FileHash (Join-Path $root 'worker.ps1')).Hash -cne '__WORKER_SHA256__') { throw 'Node cleanup recovery package integrity differs' }
$bundle = Get-Content (Join-Path $root 'bundle.json') -Raw | ConvertFrom-Json
if (@($bundle.files).Count -ne 2) { throw 'Recovery helper count differs' }
foreach ($item in $bundle.files) {
    if ($item.name -notin @('smal-guest-direct-functions.ps1', 'smal-guest-secret-functions.ps1')) { throw 'Unexpected recovery helper name' }
    [IO.File]::WriteAllBytes((Join-Path $root $item.name), [Convert]::FromBase64String($item.base64))
    if ((Get-FileHash (Join-Path $root $item.name)).Hash -cne $item.sha256) { throw 'Recovery helper integrity differs' }
}
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument ('-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $root 'worker.ps1') + '" -ResumeNodeCleanup')
$null = Set-ScheduledTask -TaskName $taskName -Action $action
Start-ScheduledTask -TaskName $taskName
@{ runId = 'guest-bootstrap-20261028-01'; recovery = 'verified-node01-cleanup-before-node02'; sourceCommit = '__SOURCE_COMMIT__'; workerSha256 = '__WORKER_SHA256__'; bundleSha256 = '__BUNDLE_SHA256__'; startRequested = $true; originalMarkersAndStateRetained = $true; dcOrNode01ConfigurationRepeated = $false; azureRegistrationIncluded = $false; clusterBootstrapComplete = $false } | ConvertTo-Json -Compress
