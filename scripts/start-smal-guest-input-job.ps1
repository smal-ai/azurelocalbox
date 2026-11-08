# Durable inspection only. No recurring trigger and no automatic restart.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-inputs-20261028-02'
$taskName = 'LocalBox-GuestInputs-20261028-02'
if ($env:COMPUTERNAME -ne 'LocalBox-Client') { throw 'Unexpected target' }
if ((Test-Path $root) -or (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) { throw 'Inspection already exists. Read rather than replay.' }
if ((Get-ExecutionPolicy) -in @('AllSigned', 'Restricted')) { throw 'Execution policy requires a separately approved signed-worker path' }
$null = New-Item $root -ItemType Directory
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
}
$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
Set-Acl -Path $root -AclObject $acl
[IO.File]::WriteAllBytes((Join-Path $root 'manifest.json'), [Convert]::FromBase64String('__MANIFEST_BASE64__'))
[IO.File]::WriteAllBytes((Join-Path $root 'worker.ps1'), [Convert]::FromBase64String('__WORKER_BASE64__'))
if ((Get-FileHash (Join-Path $root 'manifest.json')).Hash -ne '__MANIFEST_SHA256__' -or (Get-FileHash (Join-Path $root 'worker.ps1')).Hash -ne '__WORKER_SHA256__') { throw 'Inspection integrity differs' }
@{ runId = 'guest-inputs-20261028-02'; sourceCommit = '__SOURCE_COMMIT__'; scope = 'approved-media-and-host-inspection-only'; status = 'queued'; phase = 'not-started'; clusterBootstrapComplete = $false } | ConvertTo-Json | Set-Content (Join-Path $root 'state.json') -Encoding UTF8
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument ('-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $root 'worker.ps1') + '"')
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
$null = Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings
Start-ScheduledTask -TaskName $taskName
@{ runId = 'guest-inputs-20261028-02'; sourceCommit = '__SOURCE_COMMIT__'; startRequested = $true; workerSha256 = '__WORKER_SHA256__'; manifestSha256 = '__MANIFEST_SHA256__'; networkOrGuestApplied = $false; clusterBootstrapComplete = $false } | ConvertTo-Json -Compress
