# Rendered only from committed source and the exact approved public manifest.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\storage-20261028-01'
$taskName = 'LocalBox-Storage-20261028-01'
if ($env:COMPUTERNAME -ne 'LocalBox-Client') { throw 'Unexpected target' }
if ((Test-Path $root) -or (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) { throw 'Storage job already exists. Inspect it, do not replay installation.' }
if ((Get-ExecutionPolicy) -in @('AllSigned', 'Restricted')) { throw 'Execution policy requires a separately approved signed-worker path' }
New-Item $root -ItemType Directory | Out-Null
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
}
$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
Set-Acl -Path $root -AclObject $acl
[IO.File]::WriteAllBytes((Join-Path $root 'manifest.json'), [Convert]::FromBase64String('__MANIFEST_BASE64__'))
[IO.File]::WriteAllBytes((Join-Path $root 'worker.ps1'), [Convert]::FromBase64String('__WORKER_BASE64__'))
if ((Get-FileHash (Join-Path $root 'manifest.json')).Hash -ne '__MANIFEST_SHA256__' -or (Get-FileHash (Join-Path $root 'worker.ps1')).Hash -ne '__WORKER_SHA256__') { throw 'Deployed worker/manifest hash mismatch' }
@{ schemaVersion = 1; runId = 'storage-20261028-01'; scope = 'storage-only'; status = 'queued'; phase = 'not-started'; sourceCommit = '__SOURCE_COMMIT__'; clusterBootstrapComplete = $false } | ConvertTo-Json | Set-Content (Join-Path $root 'state.json') -Encoding UTF8
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument ('-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $root 'worker.ps1') + '"')
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2) -StartWhenAvailable
$null = Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings
Start-ScheduledTask -TaskName $taskName
@{ runId = 'storage-20261028-01'; scope = 'storage-only'; taskName = $taskName; statePath = (Join-Path $root 'state.json'); sourceCommit = '__SOURCE_COMMIT__'; workerSha256 = '__WORKER_SHA256__'; manifestSha256 = '__MANIFEST_SHA256__'; startRequested = $true; clusterBootstrapComplete = $false; cronCreated = $false } | ConvertTo-Json -Compress
