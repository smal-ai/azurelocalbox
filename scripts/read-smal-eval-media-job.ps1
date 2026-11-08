# Read-only observation. Does not launch, resume or clean up the job.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\eval-media-20261028-01'
$task = Get-ScheduledTask -TaskName 'LocalBox-EvalMedia-20261028-01' -ErrorAction SilentlyContinue
if (-not (Test-Path $root)) { @{ directoryExists = $false; taskExists = [bool]$task; clusterBootstrapComplete = $false } | ConvertTo-Json -Compress; exit 0 }
$state = Get-Content (Join-Path $root 'state.json') -Raw | ConvertFrom-Json
$m = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
if ($m.fileName -cne 'WindowsServer2025Evaluation.26100.32230.x64.en-us.iso') { throw 'Unexpected media name' }
$final = Join-Path $root $m.fileName
$partial = Join-Path $root ($m.fileName + '.partial')
$info = if ($task) { Get-ScheduledTaskInfo -TaskName $task.TaskName } else { $null }
@{ atUtc = (Get-Date).ToUniversalTime().ToString('o'); state = $state; taskExists = [bool]$task; taskState = $(if ($task) { $task.State.ToString() } else { $null }); lastTaskResult = $info.LastTaskResult; finalBytes = $(if (Test-Path $final) { (Get-Item $final).Length } else { $null }); partialBytes = $(if (Test-Path $partial) { (Get-Item $partial).Length } else { $null }); manifestSha256 = (Get-FileHash (Join-Path $root 'manifest.json')).Hash; workerSha256 = (Get-FileHash (Join-Path $root 'worker.ps1')).Hash; startedMarkerExists = (Test-Path (Join-Path $root 'execution.started')); actualTriggerCount = @($task.Triggers | Where-Object { $null -ne $_ }).Count; clusterBootstrapComplete = $false } | ConvertTo-Json -Depth 6 -Compress
