$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'LocalBox-Client'){throw 'Wrong outer host'}
$root='C:\ProgramData\AzureLocalBox\FoundationProfile-20261110-02'
$path=Join-Path $root 'worker-drain-LB-NODE02.ps1'
$marker=Join-Path $root 'resume-invocation-drain-LB-NODE02-01.json'
$returned=Join-Path $root 'resume-returned-drain-LB-NODE02-01.json'
$deadline=[DateTimeOffset]::Parse('2026-11-10T20:00:00+02:00')
$workerSha='fd02e48b96d93b2631687808e92642d6a4d5ec44a0e2f2e8fc6e685ef95f4998'
$planSha='c6b4dfdfb3e1170129c8d578d3a87794d9ec41142275ed69c5decc2fb6006d53'
$pins=@{
'operation.json'='a24e4946070b235be182a4e65767eef662902a30b9abde6431f2d6ffd5387ea5'
'request-drain-LB-NODE02.json'='b988fb7f3f08a00c6e3d404ae9573721c750a7abd019bf8af6c061f93d776848'
'launch-drain-LB-NODE02-returned.json'='014b724cd0db73b1754f32281f58174a4a1f205afcbf259728f2aa7c471aff89'
}
function New-ResumeJson($file,$value){
 $b=[Text.Encoding]::UTF8.GetBytes(($value|ConvertTo-Json -Depth 12 -Compress))
 $s=[IO.File]::Open($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 try{$s.Write($b,0,$b.Length);$s.Flush($true)}finally{$s.Dispose()}
}
function Assert-ResumeFacts([bool]$owned=$false){
 if([DateTimeOffset]::UtcNow -ge $deadline){throw 'Original approval expired'}
 $r=Get-Item -LiteralPath $root
 if(-not $r.PSIsContainer -or ($r.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Original root path differs'}
 if(-not $owned -and (@(Get-ChildItem -LiteralPath $root -Filter 'resume-invocation-drain-LB-NODE02-*.json' -File|Select-Object -First 1).Count -or (Test-Path -LiteralPath $returned))){throw 'Prior resumption marker exists; no replay'}
 foreach($name in $pins.Keys){
  $p=Join-Path $root $name;$f=Get-Item -LiteralPath $p
  if($f.Length -gt 65536 -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pins[$name]){throw 'Original metadata identity differs'}
 }
 foreach($name in @('worker-drain-LB-NODE02.state.json','drain-proof-LB-NODE02.json')){if(Test-Path -LiteralPath (Join-Path $root $name)){throw 'Worker evidence exists'}}
 if(@(Get-ChildItem $root -Filter 'worker-drain-LB-NODE02-event-*.json' -File|Select-Object -First 1).Count){throw 'Worker event exists'}
 $f=Get-Item -LiteralPath $path
 if($f.Length -gt 1048576 -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $workerSha){throw 'Original worker source differs'}
 $t=$null;$e=$null;$null=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e);if($e.Count){throw 'Original worker parse failed'}
 $all=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR ProcessId=10264 OR ProcessId=10804" -OperationTimeoutSec 5 -ErrorAction Stop)
 if($all.Count -gt 128 -or @($all|Where-Object {$_.Name -ieq 'powershell.exe' -and -not $_.CommandLine}).Count){throw 'Incomplete process scan'}
 if(@($all|Where-Object {$_.ProcessId -in @(10264,10804) -or $_.CommandLine -match ('(?i)(?:^|\s)-File\s+"?'+[regex]::Escape($path)+'"?(?:\s|$)')}).Count){throw 'Original PID or exact worker process exists; no resume'}
 $v=Get-VM -Id '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' -ErrorAction Stop
 if($v.Name -cne 'LB-NODE02' -or $v.State.ToString() -cne 'Running' -or $v.ProcessorCount -ne 8 -or $v.MemoryStartup -ne 64GB){throw 'NODE02 profile/state changed'}
}
$r=@{status='refused';originalPlanSha256=$planSha;workerSha256=$workerSha;key='drain-LB-NODE02';sameOriginalWorker=$true;effectSettled=$false;retryAllowed=$false};$created=$false;$invoked=$false;$phase='guards';$errors=@();$streamCount=0
try{
 Assert-ResumeFacts
 New-ResumeJson $marker @{operationId='smal-foundation-profile-20261110-02';key='drain-LB-NODE02';planSha256=$planSha;workerSha256=$workerSha;pid=$PID;atUtc=[datetime]::UtcNow.ToString('o');basisReceiptSha256='94ce49973030226032cc3780722e0d7fc55ce0ca624239badcde42e2638ef8cf';authority='parent-reconciled-ended-before-preflight-RPC'}
 $created=$true;Assert-ResumeFacts $true
 if([DateTimeOffset]::UtcNow -ge $deadline){throw 'Original approval expired'}
 $phase='same-worker-invocation';$invoked=$true
 & $path *>&1|ForEach-Object {$streamCount++;if($_ -is [Management.Automation.ErrorRecord]){$errors+=@{errorType=$_.Exception.GetType().FullName}}}
 $r.status='worker-call-returned-await-original-observation'
}catch{$r.errorType=$_.Exception.GetType().FullName;$r.failedPhase=$phase;if($created){$r.status='resumption-held-no-retry'}}
$r.markerCreated=$created;$r.workerInvoked=$invoked;$r.streamRecordsSuppressed=$streamCount;$r.errorTypes=@($errors|Select-Object -First 8);$r.atUtc=[datetime]::UtcNow.ToString('o')
if($created){
 try{
  $state=Join-Path $root 'worker-drain-LB-NODE02.state.json'
  if(Test-Path -LiteralPath $state){
   if((Get-Item -LiteralPath $state).Length -gt 65536){throw 'Worker state exceeds bound'}
   $v=Get-Content -LiteralPath $state -Raw|ConvertFrom-Json;$m=@{}
   foreach($k in 'operationId,planSha256,sourceCommit,stage,key,phase,pid,processStartedUtc,sourceSha256,sequence,rpcInvoked,rpcReturned,outcome,postReadSucceeded,errorType,errorLine,atUtc'.Split(',')){
    $p=$v.PSObject.Properties[$k];if($null -eq $p){continue};$x=$p.Value
    if($null -eq $x -or $x -is [bool] -or $x -is [int] -or $x -is [long]){$m[$k]=$x}
    elseif($x -is [string] -and $x -cmatch '^[A-Za-z0-9_.:+-]{0,256}$' -and $x -notmatch 'eyJ|(?i:password|access_token|refresh_token|client_secret|authorization)'){$m[$k]=$x}
   };$r.workerState=$m;$r.workerStateSha256=(Get-FileHash -LiteralPath $state -Algorithm SHA256).Hash.ToLowerInvariant()
  }else{$r.workerStateAbsent=$true}
 }catch{$r.stateReadErrorType=$_.Exception.GetType().FullName}
 try{New-ResumeJson $returned $r}catch{$r.returnRecordErrorType=$_.Exception.GetType().FullName}
}
$r|ConvertTo-Json -Depth 12 -Compress
