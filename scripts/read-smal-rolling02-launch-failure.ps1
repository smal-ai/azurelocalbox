$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'LocalBox-Client'){throw 'Wrong outer host'}
$end=[DateTimeOffset]::Parse('2026-11-10T18:00:00+02:00')
if([DateTimeOffset]::UtcNow -ge $end){throw 'Launch inspection window closed'}
$root='C:\ProgramData\AzureLocalBox\FoundationProfile-20261110-02'
$path=Join-Path $root 'worker-drain-LB-NODE02.ps1'
$expected='fd02e48b96d93b2631687808e92642d6a4d5ec44a0e2f2e8fc6e685ef95f4998'
function Digest-LaunchBytes([byte[]]$b){$h=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($h.ComputeHash($b)).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
$present=Test-Path -LiteralPath $root
$safe=$present -and (Get-Item -LiteralPath $root).PSIsContainer -and -not ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint)
function Read-LaunchJson($name){
 $r=@{name=$name;present=$false}
 if(-not $safe){return $r}
 try{
  if([DateTimeOffset]::UtcNow -ge $end){throw 'Read end reached'}
  $p=Join-Path $root $name;if(-not(Test-Path -LiteralPath $p -PathType Leaf)){return $r}
  $r.present=$true;$f=Get-Item -LiteralPath $p;$r.bytes=$f.Length
  if($f.Length -gt 65536 -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'JSON bound/path refused'}
  $s=[IO.File]::OpenRead($p)
  try{if($s.Length -gt 65536){throw 'JSON grew beyond bound'};$b=New-Object byte[] ([int]$s.Length);if($s.Read($b,0,$b.Length) -ne $b.Length){throw 'Short JSON read'}}finally{$s.Dispose()}
  $r.sha256=Digest-LaunchBytes $b;$v=[Text.Encoding]::UTF8.GetString($b)|ConvertFrom-Json;$m=@{}
  foreach($k in 'operationId,planSha256,sourceCommit,active,stage,key,phase,pid,processStartedUtc,sourceSha256,sequence,rpcInvoked,rpcReturned,outcome,postReadSucceeded,errorType,errorLine,atUtc,independentProofSha256'.Split(',')){
   $p=$v.PSObject.Properties[$k];if($null -eq $p){continue};$x=$p.Value
   if($null -eq $x -or $x -is [bool] -or $x -is [int] -or $x -is [long]){$m[$k]=$x}
   elseif($x -is [string] -and $x -cmatch '^[A-Za-z0-9_.:+-]{0,256}$' -and $x -notmatch 'eyJ|(?i:password|access_token|refresh_token|client_secret|authorization)'){$m[$k]=$x}
   else{$m[$k]='withheld-unsafe-or-nonscalar'}
  };$r.fields=$m;$r.status='read'
 }catch{$r.status='failed-read-only';$r.errorType=$_.Exception.GetType().FullName}
 $r
}
$files=@('operation.json','request-drain-LB-NODE02.json','worker-drain-LB-NODE02.state.json','launch-drain-LB-NODE02-returned.json','worker-drain-LB-NODE02-event-1.json','worker-drain-LB-NODE02-event-2.json','worker-drain-LB-NODE02-event-3.json','worker-drain-LB-NODE02-event-4.json','resume-invocation-drain-LB-NODE02-01.json','resume-returned-drain-LB-NODE02-01.json','drain-proof-LB-NODE02.json'|ForEach-Object {Read-LaunchJson $_})
$worker=@{present=$false;expectedSha256=$expected}
try{
 if($safe -and (Test-Path -LiteralPath $path -PathType Leaf)){
  $worker.present=$true;$f=Get-Item -LiteralPath $path;$worker.bytes=$f.Length
  if($f.Length -gt 1048576 -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Worker bound/path refused'}
  $worker.sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();$worker.matchesExpected=$worker.sha256 -ceq $expected
  $t=$null;$e=$null;$null=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)
  $worker.parseErrorCount=$e.Count;$worker.parseErrors=@($e|Select-Object -First 32|ForEach-Object {@{errorId=$_.ErrorId;line=$_.Extent.StartLineNumber}})
 }
}catch{$worker.errorType=$_.Exception.GetType().FullName}
$node=$null;try{$v=Get-VM -Id '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' -ErrorAction Stop;$node=@{id=$v.Id.ToString();nameMatches=$v.Name -ceq 'LB-NODE02';state=$v.State.ToString();cpu=$v.ProcessorCount;memory=$v.MemoryStartup}}catch{$node=@{errorType=$_.Exception.GetType().FullName}}
$shell=@{};try{$a=Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH';$shell.defaultShell=$a.DefaultShell;$shell.commandOption=$a.DefaultShellCommandOption}catch{$shell.errorType=$_.Exception.GetType().FullName}
$policy=@(Get-ExecutionPolicy -List|ForEach-Object {@{scope=$_.Scope.ToString();policy=$_.ExecutionPolicy.ToString()}})
$scan=@{complete=$false};$rows=@()
try{
 if([DateTimeOffset]::UtcNow -ge $end){throw 'Read end reached'}
  $all=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='sshd.exe' OR ProcessId=10264 OR ProcessId=3448" -OperationTimeoutSec 5 -ErrorAction Stop)
  $scan.count=$all.Count;$scan.unreadablePowerShellCommandLines=@($all|Where-Object {$_.Name -ieq 'powershell.exe' -and -not $_.CommandLine}).Count;$scan.complete=$all.Count -le 128 -and $scan.unreadablePowerShellCommandLines -eq 0;$all=@($all|Select-Object -First 128)
  $wanted=@(10264,3448,$PID)+@($files|Where-Object name -EQ 'request-drain-LB-NODE02.json'|ForEach-Object {$_.fields.pid})
 $wanted+=@($all|Where-Object {$_.CommandLine -match ('(?i)(?:^|\s)-File\s+"?'+[regex]::Escape($path)+'"?\s*$')}|ForEach-Object {$_.ProcessId})
 for($i=0;$i -lt 5;$i++){$wanted+=@($all|Where-Object {$_.ProcessId -in $wanted}|ForEach-Object {$_.ParentProcessId});$wanted=@($wanted|Select-Object -Unique)}
 foreach($p in @($all|Where-Object {$_.ProcessId -in $wanted})){$rows+=@{pid=$p.ProcessId;parentPid=$p.ParentProcessId;name=$p.Name;startUtc=$p.CreationDate.ToUniversalTime().ToString('o');commandLineAvailable=($null -ne $p.CommandLine);commandLineSha256=$(if($p.CommandLine){Digest-LaunchBytes ([Text.Encoding]::UTF8.GetBytes($p.CommandLine))})}}
}catch{$scan.complete=$false;$scan.errorType=$_.Exception.GetType().FullName}
@{status='read-only-launch-inspection';atUtc=[datetime]::UtcNow.ToString('o');readerPid=$PID;rootPresent=$present;rootPathSafe=$safe;files=$files;workerFile=$worker;node02=$node;defaultShell=$shell;executionPolicies=$policy;languageMode=$ExecutionContext.SessionState.LanguageMode.ToString();processScan=$scan;relevantProcesses=@($rows);mutationPerformed=$false;effectSettled=$false;readEndReached=([DateTimeOffset]::UtcNow -ge $end)}|ConvertTo-Json -Depth 10 -Compress
