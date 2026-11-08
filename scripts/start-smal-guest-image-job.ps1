# Install a bounded approved local image/VM job. No boot, registration or cloud cost.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01'
$taskName = 'LocalBox-GuestImages-20261028-01'
if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or (Test-Path $root) -or (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) { throw 'Target differs or guest image attempt already exists. Inspect, never replay.' }
if ((Get-ExecutionPolicy) -in @('AllSigned', 'Restricted')) { throw 'Separately approved signing path required' }
$null = New-Item $root -ItemType Directory
$acl = [Security.AccessControl.DirectorySecurity]::new(); $acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) { $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')) }
$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')); Set-Acl -Path $root -AclObject $acl
[IO.File]::WriteAllBytes((Join-Path $root 'manifest.json'), [Convert]::FromBase64String('__MANIFEST_BASE64__'))
[IO.File]::WriteAllBytes((Join-Path $root 'worker.ps1'), [Convert]::FromBase64String('__WORKER_BASE64__'))
[IO.File]::WriteAllBytes((Join-Path $root 'bundle.json'), [Convert]::FromBase64String('__BUNDLE_BASE64__'))
if ((Get-FileHash (Join-Path $root 'manifest.json')).Hash -cne '__MANIFEST_SHA256__' -or (Get-FileHash (Join-Path $root 'worker.ps1')).Hash -cne '__WORKER_SHA256__' -or (Get-FileHash (Join-Path $root 'bundle.json')).Hash -cne '__BUNDLE_SHA256__') { throw 'Guest job source integrity differs' }
@{ runId = 'local-guests-20261028-01'; sourceCommit = '__SOURCE_COMMIT__'; scope = 'approved-local-guest-images-and-offline-vms-only'; status = 'queued'; phase = 'not-started'; clusterBootstrapComplete = $false } | ConvertTo-Json | Set-Content (Join-Path $root 'state.json') -Encoding UTF8
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument ('-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $root 'worker.ps1') + '"')
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6)
$null = Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings
Start-ScheduledTask -TaskName $taskName
@{ runId = 'local-guests-20261028-01'; sourceCommit = '__SOURCE_COMMIT__'; startRequested = $true; workerSha256 = '__WORKER_SHA256__'; manifestSha256 = '__MANIFEST_SHA256__'; bundleSha256 = '__BUNDLE_SHA256__'; bootGuestsInThisPhase = $false; clusterBootstrapComplete = $false } | ConvertTo-Json -Compress
