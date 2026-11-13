$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'LocalBox-Client'){throw 'Wrong outer host'}
$root='C:\ProgramData\AzureLocalBox\FoundationProfile-20261109-01'
$worker=Join-Path $root 'worker-drain-LB-NODE02.ps1'
$expiry=[DateTimeOffset]::Parse('2026-11-10T15:20:00+02:00')
$end=[DateTimeOffset]::Parse('2026-11-10T17:00:00+02:00')
$pins=@{
8776=@('2026-11-10T13:00:42.5791210Z','d3adac3f72b0a183f032ed5c3df8366b797307849d47e62b7035cacfa1d39934')
11816=@('2026-11-10T13:00:43.6199680Z','31925c1e029e90125647f72e3155bc122c919c46087874fdf2da736e2462a88f')
4832=@('2026-11-10T13:05:42.8873720Z','217ac5afc96706b8262e3e3c4cf043e7fef7d3e84b19525bba96a0a4be86b935')
11044=@('2026-11-10T13:05:43.8813780Z','07267ac2f4db983fd58b5ab7e3cd835e156929969222dd3eb6a3304e7a5b6644')
}
function Hash-CleanupLine([string]$s){$h=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function Window {if([DateTimeOffset]::UtcNow -lt $expiry -or [DateTimeOffset]::UtcNow -ge $end){throw 'Cleanup window or original expiry guard failed'}}
function Node {
 Window
 if(Test-Path -LiteralPath $root){throw 'Original operation root exists; no termination permitted'}
 $v=Get-VM -Id '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' -ErrorAction Stop
 if($v.Name -cne 'LB-NODE02' -or $v.State.ToString() -cne 'Running' -or $v.ProcessorCount -ne 8 -or $v.MemoryStartup -ne 64GB){throw 'NODE02 changed; no termination permitted'}
 @{id=$v.Id.ToString();state=$v.State.ToString();cpu=$v.ProcessorCount;memory=$v.MemoryStartup}
}
function Scan {
 Window
 $all=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -OperationTimeoutSec 5 -ErrorAction Stop)
 if($all.Count -gt 128 -or @($all|Where-Object {-not $_.CommandLine}).Count){throw 'Incomplete process scan; no termination permitted'}
 if(@($all|Where-Object {$_.CommandLine -match ('(?i)(?:^|\s)-File\s+"?'+[regex]::Escape($worker)+'"?\s*$')}).Count){throw 'Original worker process exists; no termination permitted'}
 return ,$all
}
function Match($p){
 $id=[int]$p.ProcessId;$pin=$pins[$id]
 if($null -eq $pin -or $p.Name -ine 'powershell.exe' -or $p.CreationDate.ToUniversalTime().ToString('o') -cne $pin[0] -or (Hash-CleanupLine $p.CommandLine) -cne $pin[1]){throw 'Original PID/start/command hash differs; no termination permitted'}
}
$handles=@{};$stopped=@();$before=@();$result=@{status='refused';transportCleanupOnly=$true;nodeMutation=$false;effectSettled=$false;originalPlanSha256='a778a5867740c0ea7de46f84f0cd4099eea27f4ba945364284ccb583a2d32b3a'};$stage='preconditions'
try{
 $result.nodeBefore=Node;$all=Scan
 foreach($id in $pins.Keys){
  $p=@($all|Where-Object ProcessId -EQ $id)
  if($p.Count -gt 1){throw 'Duplicate process identity'}
  if(-not $p.Count){continue}
  Match $p[0]
  $g=Get-Process -Id $id -ErrorAction Stop;$null=$g.Handle
  if($g.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ') -cne $p[0].CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')){throw 'Process handle start identity differs'}
  $handles[$id]=$g;$before+=@{pid=$id;startUtc=$pins[$id][0];commandLineSha256=$pins[$id][1]}
 }
 # All four identity slots and both host/VM guards are validated before any kill.
 $null=Node;$fresh=Scan
 foreach($id in $handles.Keys){$p=@($fresh|Where-Object ProcessId -EQ $id);if($p.Count -ne 1){throw 'Target changed before cleanup'};Match $p[0]}
 $stage='targeted-stop'
 foreach($id in @($handles.Keys|Sort-Object {$pins[$_][0]} -Descending)){
  Window
  if(-not $handles[$id].HasExited){Stop-Process -InputObject $handles[$id] -Force -ErrorAction Stop;$null=$handles[$id].WaitForExit(5000)}
  $stopped+=$id
 }
 $stage='readback';$result.nodeAfter=Node;$after=Scan
 $remaining=@($after|Where-Object {$pins.ContainsKey([int]$_.ProcessId)}|ForEach-Object {[int]$_.ProcessId})
 $result.remainingPinnedPids=$remaining;$result.rootAbsent=-not(Test-Path -LiteralPath $root);$result.status=if($remaining.Count){'incomplete-no-retry'}else{'exact-loaders-absent-node-unchanged'}
}catch{$result.errorType=$_.Exception.GetType().FullName;$result.failedStage=$stage;if($stopped.Count){$result.status='partial-no-retry'}}
finally{foreach($g in $handles.Values){$g.Dispose()}}
$result.matchedBefore=$before;$result.stoppedOrAlreadyExitedPids=$stopped;$result.atUtc=[datetime]::UtcNow.ToString('o');$result.originalApprovalExpired=([DateTimeOffset]::UtcNow -ge $expiry)
$result|ConvertTo-Json -Depth 8 -Compress
