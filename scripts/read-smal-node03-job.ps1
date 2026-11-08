# Read-only bounded progress. Never reads a secret, guest answer file or raw setup log.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected host' }
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\node03-20261029-01'
$task = Get-ScheduledTask -TaskName LocalBox-Node03-20261029-01 -ErrorAction Stop
$info = Get-ScheduledTaskInfo -TaskName $task.TaskName
function Read-Node03SharedJson([string]$path) {
    # Allow atomic File.Replace from the running worker/heartbeat while reading
    # this already-open stable snapshot. Do not lock their state files for delete.
    $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = [IO.StreamReader]::new($stream)
    try { $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
}
$state = Read-Node03SharedJson (Join-Path $root 'state.json')
$heartbeat = if (Test-Path (Join-Path $root 'heartbeat.json')) { Read-Node03SharedJson (Join-Path $root 'heartbeat.json') } else { $null }
@{ atUtc = [datetime]::UtcNow.ToString('o'); taskState = $task.State.ToString(); lastTaskResult = $info.LastTaskResult; heartbeat = $heartbeat; state = $state;
   workerSha256 = (Get-FileHash (Join-Path $root 'worker.ps1')).Hash; bundleSha256 = (Get-FileHash (Join-Path $root 'bundle.json')).Hash;
   actualTriggerCount = @($task.Triggers | Where-Object { $null -ne $_ }).Count; principal = $task.Principal.UserId; registrationInvokedByReader = $false } | ConvertTo-Json -Depth 13 -Compress
