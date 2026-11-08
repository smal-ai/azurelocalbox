# Public state and VM shape only. Never read or return secret-store content.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01'
$task = Get-ScheduledTask -TaskName 'LocalBox-GuestImages-20261028-01' -ErrorAction SilentlyContinue
if (-not (Test-Path $root)) { @{ directoryExists = $false; taskExists = [bool]$task } | ConvertTo-Json -Compress; exit 0 }
$state = Get-Content (Join-Path $root 'state.json') -Raw | ConvertFrom-Json
$info = if ($task) { Get-ScheduledTaskInfo -TaskName $task.TaskName } else { $null }
$heartbeat = if (Test-Path (Join-Path $root 'heartbeat.json')) { Get-Content (Join-Path $root 'heartbeat.json') -Raw | ConvertFrom-Json } else { $null }
@{ atUtc = (Get-Date).ToUniversalTime().ToString('o'); state = $state; heartbeat = $heartbeat; taskExists = [bool]$task; taskState = $(if ($task) { $task.State.ToString() } else { $null }); lastTaskResult = $info.LastTaskResult; virtualMachines = @(Get-VM | Select-Object Name, Id, State, Generation, MemoryStartup, ProcessorCount); volume = (Get-Volume -DriveLetter V | Select-Object Size, SizeRemaining, HealthStatus); clusterBootstrapComplete = $false } | ConvertTo-Json -Depth 10 -Compress
