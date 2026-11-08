__THREE_NODE_PRELUDE__
# Deliver and start one durable SYSTEM task. No recurrence or reboot trigger.
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\node03-20261029-01'
$taskName = 'LocalBox-Node03-20261029-01'
if ($approval.node03ImageTemporaryAnswerFileCleanupAndSharedClusterCredentialApproved -ne $true -or (Test-Path $root) -or (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) -or (Get-VM -Name LB-NODE03 -ErrorAction SilentlyContinue)) { throw 'New node approval missing or job/VM identity already exists' }
$resize = Get-Content (Join-Path $threeRoot 'existing-node-resize.json') -Raw | ConvertFrom-Json
if ($resize.status -cne 'complete-existing-nodes-64gib-8vcpu-and-one-vhd-relocated') { throw 'Existing-node phase is incomplete' }
$null = New-Item $root -ItemType Directory; Set-Acl $root (Get-Acl $threeRoot)
[IO.File]::WriteAllBytes((Join-Path $root 'approval.json'), $approvalBytes)
[IO.File]::WriteAllBytes((Join-Path $root 'proposal.json'), $proposalBytes)
[IO.File]::WriteAllBytes((Join-Path $root 'bundle.json'), [Convert]::FromBase64String('__NODE03_BUNDLE_BASE64__'))
[IO.File]::WriteAllBytes((Join-Path $root 'worker.ps1'), [Convert]::FromBase64String('__NODE03_WORKER_BASE64__'))
if ((Get-FileHash (Join-Path $root 'bundle.json')).Hash -cne '__NODE03_BUNDLE_SHA256__' -or (Get-FileHash (Join-Path $root 'worker.ps1')).Hash -cne '__NODE03_WORKER_SHA256__') { throw 'Installed NODE3 worker/bundle hash differs' }
[IO.File]::WriteAllText((Join-Path $root 'state.json'), ((@{ status = 'installed-not-yet-run'; sourceCommit = $sourceCommit; workerSha256 = '__NODE03_WORKER_SHA256__'; bundleSha256 = '__NODE03_BUNDLE_SHA256__' }) | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument ('-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $root 'worker.ps1') + '"')
$principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances IgnoreNew
$null = Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings
Start-ScheduledTask -TaskName $taskName
@{ status = 'one-shot-node03-job-started'; sourceCommit = $sourceCommit; taskName = $taskName; workerSha256 = '__NODE03_WORKER_SHA256__'; bundleSha256 = '__NODE03_BUNDLE_SHA256__'; recurringTriggerCreated = $false; registrationInvoked = $false } | ConvertTo-Json -Compress
