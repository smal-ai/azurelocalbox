$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'LocalBox-Client'){throw 'Wrong outer host'}
$end=[DateTimeOffset]::Parse('2026-11-10T16:15:00+02:00')
if([DateTimeOffset]::UtcNow -ge $end){throw 'Original-state read window closed'}
$root='C:\ProgramData\AzureLocalBox\FoundationProfile-20261109-01'
$worker=Join-Path $root 'worker-drain-LB-NODE02.ps1'
$expected='a1b4eba99686959e22e55ab58f9b3e1392fe0623c42112db1c1ccb1c5e9b8361'
$loaders=@{'6d24649d56f4a8ac32504c7b250b9b44d14effef3b60a39e29a1abbdd8f2970c'='dispatch-loader';'e292d7963935b6c395cad896bcb75e225a7d2739270b21f4bec2a4ac14be0cc6'='observe-loader'}
function Get-OriginalStateDigest([byte[]]$bytes){$h=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($h.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
$present=Test-Path -LiteralPath $root
$safe=$present -and (Get-Item -LiteralPath $root).PSIsContainer -and -not ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint)
function J([string]$name){
 $r=@{name=$name;present=$false}
 if(-not $safe){if($present){$r.status='root-path-refused'};return $r}
 if([DateTimeOffset]::UtcNow -ge $end){$r.status='read-end-reached';return $r}
 $path=Join-Path $root $name
 try{
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $r}
  $r.present=$true;$f=Get-Item -LiteralPath $path;$r.bytes=$f.Length
  if($f.Length -gt 65536 -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)){$r.status='bound-or-path-refused';return $r}
  $s=[IO.File]::OpenRead($path)
  try{if($s.Length -gt 65536){throw 'JSON file grew beyond bound'};$b=New-Object byte[] ([int]$s.Length);if($s.Read($b,0,$b.Length) -ne $b.Length){throw 'Short JSON read'}}finally{$s.Dispose()}
  $r.sha256=Get-OriginalStateDigest $b
  $v=[Text.Encoding]::UTF8.GetString($b)|ConvertFrom-Json;$m=@{}
  foreach($k in 'operationId,planSha256,sourceCommit,active,stage,key,phase,pid,processStartedUtc,sourceSha256,sequence,rpcInvoked,rpcReturned,outcome,postReadSucceeded,errorType,errorLine,atUtc,independentProofSha256'.Split(',')){
   $p=$v.PSObject.Properties[$k];if($null -eq $p){continue};$x=$p.Value
   if($null -eq $x -or $x -is [bool] -or $x -is [int] -or $x -is [long]){$m[$k]=$x}
   elseif($x -is [string] -and $x -cmatch '^[A-Za-z0-9_.:+-]{0,256}$' -and $x -notmatch 'eyJ|(?i:password|access_token|refresh_token|client_secret|authorization)'){$m[$k]=$x}
   else{$m[$k]='withheld-nonscalar-or-unsafe'}
  }
  $r.fields=$m;$r.status='read'
 }catch{$r.status='failed-read-only';$r.errorType=$_.Exception.GetType().FullName}
 $r
}
$files=@('operation.json','request-drain-LB-NODE02.json','worker-drain-LB-NODE02.state.json'|ForEach-Object {J $_})
$w=@{present=$false;expectedSha256=$expected}
try{if([DateTimeOffset]::UtcNow -ge $end){throw 'Read end reached'};if($safe -and (Test-Path -LiteralPath $worker -PathType Leaf)){$w.present=$true;$f=Get-Item -LiteralPath $worker;if($f.Length -gt 1048576 -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Worker hash bound/path refused'};$w.sha256=(Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash.ToLowerInvariant();$w.matchesExpected=$w.sha256 -ceq $expected}}catch{$w.errorType=$_.Exception.GetType().FullName}
$vm=$null
try{if([DateTimeOffset]::UtcNow -ge $end){throw 'Read end reached'};$v=Get-VM -Id '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' -ErrorAction Stop;$vm=@{id=$v.Id.ToString();nameMatches=$v.Name -ceq 'LB-NODE02';state=$v.State.ToString();cpu=$v.ProcessorCount;memory=$v.MemoryStartup}}catch{$vm=@{errorType=$_.Exception.GetType().FullName}}
$ps=@();$scan=@{complete=$false}
try{
 if([DateTimeOffset]::UtcNow -ge $end){throw 'Read end reached'}
 $all=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -OperationTimeoutSec 5 -ErrorAction Stop);$scan.count=$all.Count;$scan.complete=$all.Count -le 128;$scan.unreadableCommandLines=0
 foreach($p in @($all|Select-Object -First 128)){
  $line=$p.CommandLine;if(-not $line){$scan.unreadableCommandLines++;continue};$kind=$null
  if($line -match '(?i)(?:^|\s)-EncodedCommand\s+"?([A-Za-z0-9+/=]+)"?\s*$'){$key=Get-OriginalStateDigest ([Text.Encoding]::UTF8.GetBytes($Matches[1]));$kind=$loaders[$key]}
  if($line -match ('(?i)(?:^|\s)-File\s+"?'+[regex]::Escape($worker)+'"?\s*$')){$kind='worker'}
  if($kind){$ps+=@{kind=$kind;pid=$p.ProcessId;startUtc=$p.CreationDate.ToUniversalTime().ToString('o');commandLineSha256=(Get-OriginalStateDigest ([Text.Encoding]::UTF8.GetBytes($line)))}}
 }
}catch{$scan.complete=$false;$scan.errorType=$_.Exception.GetType().FullName}
@{status='read-only-original-state';atUtc=[datetime]::UtcNow.ToString('o');readEndReached=([DateTimeOffset]::UtcNow -ge $end);mutationPerformed=$false;effectSettled=$false;readerPid=$PID;rootPresent=$present;rootPathSafe=$safe;files=$files;workerFile=$w;node02=$vm;processScan=$scan;matchedProcesses=@($ps)}|ConvertTo-Json -Depth 10 -Compress
