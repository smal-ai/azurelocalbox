# Read existing -02 state only. No directory/client/module/getter/lifecycle invocation.
$ErrorActionPreference='Stop';$session=$null;$secure=$null;$phase='host-binding'
try {
    if ($env:COMPUTERNAME -cne 'LocalBox-Client') {throw 'Unexpected host'}
    $vm=Get-VM -Id '3adff629-2f67-449b-ab32-8a8748c46f34'
    if ($vm.Name -cne 'LB-NODE01' -or [string]$vm.State -cne 'Running') {throw 'Exact running NODE01 required'}
    $boot='C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
    $bundle=Get-Content (Join-Path $boot 'bundle.json') -Raw|ConvertFrom-Json
    $entry=@($bundle.files|Where-Object name -CEQ 'smal-guest-secret-functions.ps1');$helper=Join-Path $boot 'smal-guest-secret-functions.ps1'
    if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) {throw 'Existing protected helper differs'}
    . $helper
    $store='C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'
    $bindings=Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw|ConvertFrom-Json
    $binding=$bindings.nodes.'LB-NODE01'
    if ($binding.vmId -ine $vm.Id.ToString() -or $binding.role -cne 'cluster-node-admin' -or $binding.secretDirectory -cne $store -or $binding.loginVerified -ne $true) {throw 'Existing NODE01 binding differs'}
    $secure=Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'
    $session=New-PSSession -VMId $vm.Id -Credential ([pscredential]::new('LB-NODE01\ASBuiltInAdmin',$secure)) -ErrorAction Stop
    $phase='existing-state-read'
    $result=Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference='Stop'
        $root='C:\ProgramData\AzureLocalBox\MocRead-20261109-02'
        $expectedSource='079b5ceea3d9fe8261484447ad2e472303feba79c2dd4e2e686f89d7bcf529cf'
        $expectedStart=[DateTimeOffset]::Parse('2026-11-09T19:51:17.6309347Z')
        $output=@{status='inspecting';root=$root;expectedPid=6824;expectedStartUtc='2026-11-09T19:51:17.6309347Z';expectedClientSourceSha256=$expectedSource;
            files=@{};currentOriginalProcessState='not-inspected';lineageVerified=$false;wrapperExitCode=$null;exitCodeMeaning='unknown-not-success';businessSuccessAccepted=$false;writesPerformed=$false}
        function Read-BoundedExisting([string]$Path,[int]$Maximum) {
            $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt $Maximum) {throw 'Existing state file invalid or outside read bound'}
            $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            try {
                $bytes=[byte[]]::new($Maximum+1);$count=0
                while($count -lt $bytes.Length){$n=$stream.Read($bytes,$count,$bytes.Length-$count);if($n -eq 0){break};$count+=$n}
                if ($count -gt $Maximum) {throw 'Existing state exceeded read bound'}
                $value=[byte[]]::new($count);[Array]::Copy($bytes,$value,$count);return ,$value
            } finally {$stream.Dispose()}
        }
        function Hash-ExistingBytes([byte[]]$Bytes) {
            $h=[Security.Cryptography.SHA256]::Create()
            try{[BitConverter]::ToString($h.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}
        }
        try {
            if ($env:COMPUTERNAME -cne 'LB-NODE01' -or -not [Security.Principal.WindowsIdentity]::GetCurrent().User.Value.EndsWith('-500')) {throw 'Expected NODE01/RID500 context'}
            $directory=[IO.DirectoryInfo]::new($root)
            while($null -ne $directory){$directory.Refresh();if($directory.Exists -and ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Existing state ancestor redirected'};$directory=$directory.Parent}
            $output.rootExists=Test-Path -LiteralPath $root
            try {
                $live=Get-Process -Id 6824 -ErrorAction Stop
                $start=$live.StartTime.ToUniversalTime().ToString('o')
                $same=$live.ProcessName -ieq 'powershell' -and ([DateTimeOffset]::Parse($start)).UtcDateTime.Ticks -eq $expectedStart.UtcDateTime.Ticks
                $output.currentOriginalProcessState=if($same){'running-original'}else{'pid-reused-not-original'}
                $output.currentProcess=@{pid=$live.Id;startUtc=$start;matchesOriginal=$same}
            } catch {
                $output.currentOriginalProcessState=if([string]$_.CategoryInfo.Category -ceq 'ObjectNotFound'){'not-present'}else{'unknown-process-access'}
                $output.processReadErrorCategory=[string]$_.CategoryInfo.Category
            }
            foreach($name in @('client-read.ps1','process.json','result.json')) {
                $path=Join-Path $root $name;$exists=Test-Path -LiteralPath $path
                $output.files[$name]=@{exists=$exists}
                if ($exists) {$item=Get-Item -LiteralPath $path -Force;$output.files[$name].bytes=$item.Length;$output.files[$name].lastWriteUtc=$item.LastWriteTimeUtc.ToString('o')}
            }
            if (-not $output.files['client-read.ps1'].exists -or -not $output.files['process.json'].exists) {$output.status='missing-original-lineage';return $output}
            $source=Read-BoundedExisting (Join-Path $root 'client-read.ps1') 1048576
            $sourceHash=Hash-ExistingBytes $source;$output.files['client-read.ps1'].sha256=$sourceHash
            $recordBytes=Read-BoundedExisting (Join-Path $root 'process.json') 65536
            $output.files['process.json'].sha256=Hash-ExistingBytes $recordBytes
            $record=[Text.Encoding]::UTF8.GetString($recordBytes)|ConvertFrom-Json
            if ($sourceHash -cne $expectedSource -or $record.sourceSha256 -cne $expectedSource -or $record.pid -ne 6824 -or ([DateTimeOffset]$record.processStartedUtc).UtcDateTime.Ticks -ne $expectedStart.UtcDateTime.Ticks) {$output.status='original-lineage-mismatch';return $output}
            $output.lineageVerified=$true
            $output.originalRecordedState=if($record.status -cin @('running','exited','uncertain-client-still-running-do-not-retry')){$record.status}else{'unrecognised'}
            if ($record.exitCode -is [int] -or $record.exitCode -is [long]) {$output.wrapperExitCode=$record.exitCode;$output.exitCodeMeaning='original-reported-code-not-business-proof'}
            if (-not $output.files['result.json'].exists) {$output.status='existing-safe-result-absent';return $output}
            $bytes=Read-BoundedExisting (Join-Path $root 'result.json') 1048576
            $output.files['result.json'].sha256=Hash-ExistingBytes $bytes
            $text=[Text.Encoding]::UTF8.GetString($bytes)
            if ($text -match '-----BEGIN|\beyJ[A-Za-z0-9_-]{15,}\.|(?i:password|access_token|refresh_token)') {$output.status='existing-result-refused-sensitive-pattern';return $output}
            $safe=$text|ConvertFrom-Json
            if ($safe.status -cnotin @('complete','failed','scope-incomplete-stop')) {$output.status='existing-result-status-unrecognised';return $output}
            $output.status='existing-safe-result-read';$output.safeResult=$safe;$output.reportedBusinessStatus=$safe.status
            $output.resultSource='existing-result-file-no-client-replay'
            $output
        } catch {
            $output.status='failed-existing-state-read';$output.errorType=$_.Exception.GetType().FullName;$output.errorCategory=[string]$_.CategoryInfo.Category;$output.sourceLine=[int]$_.InvocationInfo.ScriptLineNumber
            $output
        }
    }
    @{node='LB-NODE01';vmId=$vm.Id.ToString();atUtc=[DateTime]::UtcNow.ToString('o');result=$result}|ConvertTo-Json -Depth 24 -Compress
} catch {
    @{status='failed';phase=$phase;errorType=$_.Exception.GetType().FullName;errorCategory=[string]$_.CategoryInfo.Category;writesPerformed=$false}|ConvertTo-Json -Compress
} finally {
    if($session){Remove-PSSession $session}
    if($secure){$secure.Dispose()}
}
