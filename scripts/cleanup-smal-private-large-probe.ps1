$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'LocalBox-Client'){throw 'Wrong outer host'}
$end=[DateTimeOffset]::Parse('2026-11-10T18:00:00+02:00')
$argumentSha='e0cdd35e3a2d6e3c9d5b9ab53e62f324dadd21f96064aea1a1fb115136ab38aa'
$loaderSha='68ff0896778796218c395d820be3bc38ef220fcc0eb5e336b9479f5ee42c5512'
function Hash-ProbeCLI([string]$s){$h=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function Window {if([DateTimeOffset]::UtcNow -ge $end){throw 'Inert probe cleanup window closed'}}
function Is-Probe($p){
 if($p.Name -ine 'powershell.exe' -or -not $p.CommandLine){return $false}
 $matches=[regex]::Matches($p.CommandLine,"\[Convert\]::FromBase64String\(\s*'{1,2}([A-Za-z0-9+/=]+)'{1,2}\s*\)",[Text.RegularExpressions.RegexOptions]::IgnoreCase)
 foreach($m in $matches){
  $token=$m.Groups[1].Value
  if((Hash-ProbeCLI $token) -ceq $argumentSha){
   try{$text=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($token));if((Hash-ProbeCLI $text) -ceq $loaderSha){return $true}}catch{}
  }
 }
 $false
}
function Scan {
 Window
 $all=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -OperationTimeoutSec 5 -ErrorAction Stop)
 if($all.Count -gt 128 -or @($all|Where-Object {-not $_.CommandLine}).Count){throw 'Incomplete process scan'}
 $found=@($all|Where-Object {Is-Probe $_});if($found.Count -gt 2){throw 'More than two inert-probe loader matches'}
 return ,$found
}
$held=@{};$before=@();$stopped=@();$r=@{status='refused';inertSourceSha256='c136334e9e289f5fe644a8fbd3b44dacab9c7dac81a3d1f08c13b050cac5acc2';guestMutation=$false;effectSettled=$false};$stage='identity-guards'
try{
 $first=Scan
 foreach($p in $first){
  $id=[int]$p.ProcessId;$g=Get-Process -Id $id -ErrorAction Stop;$null=$g.Handle
  if($g.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ') -cne $p.CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ')){throw 'Native handle/start differs'}
  $held[$id]=$g;$before+=@{pid=$id;startUtc=$p.CreationDate.ToUniversalTime().ToString('o');commandLineSha256=(Hash-ProbeCLI $p.CommandLine)}
 }
 $fresh=Scan;if($fresh.Count -ne $before.Count){throw 'Probe identity set changed'}
 foreach($pin in $before){$p=@($fresh|Where-Object ProcessId -EQ $pin.pid);if($p.Count -ne 1 -or $p[0].CreationDate.ToUniversalTime().ToString('o') -cne $pin.startUtc -or (Hash-ProbeCLI $p[0].CommandLine) -cne $pin.commandLineSha256){throw 'Probe PID/start/full command hash changed'}}
 $stage='targeted-stop'
 foreach($pin in @($before|Sort-Object startUtc -Descending)){
  Window;$g=$held[$pin.pid]
  if(-not $g.HasExited){Stop-Process -InputObject $g -Force -ErrorAction Stop;$null=$g.WaitForExit(5000)}
  $stopped+=$pin.pid
 }
 $stage='readback';$after=Scan
 $r.remaining=@($after|ForEach-Object {@{pid=$_.ProcessId;startUtc=$_.CreationDate.ToUniversalTime().ToString('o');commandLineSha256=(Hash-ProbeCLI $_.CommandLine)}})
 $r.status=if($after.Count){'incomplete-no-retry'}else{'exact-inert-loaders-absent'}
}catch{$r.errorType=$_.Exception.GetType().FullName;$r.failedStage=$stage;if($stopped.Count){$r.status='partial-no-retry'}}
finally{foreach($g in $held.Values){$g.Dispose()}}
$r.matchedBefore=$before;$r.stoppedOrAlreadyExitedPids=$stopped;$r.atUtc=[datetime]::UtcNow.ToString('o');$r|ConvertTo-Json -Depth 8 -Compress
