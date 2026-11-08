# Exact recovery of the read-only, pre-mount hash phase. No media/network mutation.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-inputs-20261028-02'
$taskName = 'LocalBox-GuestInputs-20261028-02'
if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or (Test-Path (Join-Path $root 'buffered-hash-recovery.json'))) { throw 'Unexpected target or recovery already attempted' }
$state = Get-Content (Join-Path $root 'state.json') -Raw | ConvertFrom-Json
$task = Get-ScheduledTask -TaskName $taskName
if ($state.status -ne 'running' -or $state.phase -ne 'azure-local-hash-check' -or @($state.result.media).Count -ne 0 -or $task.State.ToString() -ne 'Running') { throw 'Read-only hash phase changed. Do not interrupt.' }
if ((Get-FileHash (Join-Path $root 'worker.ps1')).Hash -cne '2BA7C92F8F3A67E9C11CD30A79DDA851A0EC0D477684FED3B61F14447A246C5C' -or (Get-FileHash (Join-Path $root 'manifest.json')).Hash -cne '__MANIFEST_SHA256__' -or $task.Principal.UserId -notin @('SYSTEM', 'S-1-5-18') -or @($task.Triggers | Where-Object { $null -ne $_ }).Count -ne 0 -or $task.Actions.Count -ne 1 -or $task.Actions[0].Execute -ine 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -or $task.Actions[0].Arguments -cne ('-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $root 'worker.ps1') + '"')) { throw 'Original task or source identity differs' }
foreach ($path in @('C:\ProgramData\AzureLocalBox\Artifacts\2610\AzureLocal24H2.26100.32230.LCM.12.2610.0.3098.x64.en-us.iso', 'C:\ProgramData\AzureLocalBox\Bootstrap\eval-media-20261028-01\WindowsServer2025Evaluation.26100.32230.x64.en-us.iso')) { if ((Get-DiskImage -ImagePath $path).Attached) { throw 'Media attached; hash-only recovery not applicable' } }
if (Get-Process -Name dism,dismhost -ErrorAction SilentlyContinue) { throw 'Servicing process active. Do not interrupt.' }
[IO.File]::Copy((Join-Path $root 'worker.ps1'), (Join-Path $root 'worker.before-buffered-hash.ps1'), $false)
[IO.File]::Copy((Join-Path $root 'state.json'), (Join-Path $root 'state.before-buffered-hash.json'), $false)
$proof = @{ kind = 'read-only-hash-phase-restart'; runId = 'guest-inputs-20261028-02'; sourceCommit = '__SOURCE_COMMIT__'; originalPhase = $state.phase; originalMarkerRetained = $true; atUtc = (Get-Date).ToUniversalTime().ToString('o') }
$bytes = [Text.Encoding]::UTF8.GetBytes(($proof | ConvertTo-Json))
$file = [IO.File]::Open((Join-Path $root 'buffered-hash-recovery.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $file.Write($bytes, 0, $bytes.Length) } finally { $file.Dispose() }
# Stop exactly the inspected one-shot task, never services or unrelated processes.
Stop-ScheduledTask -TaskName $taskName
$deadline = [Diagnostics.Stopwatch]::StartNew()
while ((Get-ScheduledTask -TaskName $taskName).State.ToString() -eq 'Running') { if ($deadline.Elapsed.TotalSeconds -gt 15) { throw 'Task stop not reconciled; do not install/resume' }; Start-Sleep -Milliseconds 200 }
$after = Get-Content (Join-Path $root 'state.json') -Raw | ConvertFrom-Json
if ($after.phase -ne 'azure-local-hash-check' -or @($after.result.media).Count -ne 0) { throw 'Inspection advanced during stop; preserve and inspect' }
[IO.File]::WriteAllBytes((Join-Path $root 'worker.ps1'), [Convert]::FromBase64String('__WORKER_BASE64__'))
if ((Get-FileHash (Join-Path $root 'worker.ps1')).Hash -cne '__WORKER_SHA256__') { throw 'Buffered inspection worker integrity differs' }
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument ('-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $root 'worker.ps1') + '" -ResumeVerified')
$null = Set-ScheduledTask -TaskName $taskName -Action $action
Start-ScheduledTask -TaskName $taskName
@{ runId = 'guest-inputs-20261028-02'; sourceCommit = '__SOURCE_COMMIT__'; workerSha256 = '__WORKER_SHA256__'; recovery = 'read-only-hash-phase-restart'; originalMarkerAndSourceRetained = $true; startRequested = $true; networkOrGuestApplied = $false; clusterBootstrapComplete = $false } | ConvertTo-Json -Compress
