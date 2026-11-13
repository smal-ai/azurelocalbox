# Existing location capture only. No import, getter, client or diagnostic write.
$ErrorActionPreference='Stop';$session=$null;$secure=$null
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
    $result=Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference='Stop'
        if ($env:COMPUTERNAME -cne 'LB-NODE01' -or -not [Security.Principal.WindowsIdentity]::GetCurrent().User.Value.EndsWith('-500')) {throw 'Expected NODE01/RID500 context'}
        $path='C:\ProgramData\AzureLocalBox\MocRead-20261109-02\locations.txt'
        $directory=[IO.FileInfo]::new($path).Directory
        while($null -ne $directory){$directory.Refresh();if(-not $directory.Exists -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Capture ancestor invalid'};$directory=$directory.Parent}
        $item=Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -ne 316) {throw 'Exact existing capture required'}
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {$bytes=[byte[]]::new(317);$count=0;while($count -lt 317){$n=$stream.Read($bytes,$count,317-$count);if($n -eq 0){break};$count+=$n};if($count -ne 316){throw 'Capture size changed'}} finally {$stream.Dispose()}
        $h=[Security.Cryptography.SHA256]::Create()
        try {$hash=[BitConverter]::ToString($h.ComputeHash($bytes,0,316)).Replace('-','').ToLowerInvariant()} finally {$h.Dispose()}
        if ($hash -cne '4c4772338f2895be1ae788176187c3f24b4d80b666f0b88b0eea09da84e1c825') {throw 'Exact capture hash differs'}
        $text=[Text.Encoding]::UTF8.GetString($bytes,0,316)
        # Out-String retained display text, not the original CLR object. Never claim otherwise.
        # Export only fixed recognised labels and strictly bounded management-name candidates.
        $keys=@('value','locations','name','id','type','location','group','state','provisioningState')
        $labels=@($keys|Where-Object {$text -match ('(?im)(?:^|[;{\s])'+[regex]::Escape($_)+'\s*(?:[:=]|\s)')}|ForEach-Object {@{key=$_;type='rendered-text-original-type-not-retained'}})
        $names=@([regex]::Matches($text,'(?im)(?:^|[;{\s])name\s*[:=]\s*["'']?(?<name>[A-Za-z0-9][A-Za-z0-9._-]{0,127})(?=["'';},\s]|$)')|ForEach-Object {$_.Groups['name'].Value}|Where-Object {$_ -notmatch '(?i:password|access_token|refresh_token|^eyJ)'}|Select-Object -Unique)
        @{status='existing-location-capture-projected';path=$path;bytes=316;sha256=$hash;labels=$labels;managementNameCandidates=$names;
          originalClrType='not-retained-by-Out-String';namesAreNotLocationAdmission=$true;rawTextExported=$false;writesPerformed=$false}
    }
    @{node='LB-NODE01';vmId=$vm.Id.ToString();result=$result}|ConvertTo-Json -Depth 8 -Compress
} catch {
    @{status='failed-capture-read';errorType=$_.Exception.GetType().FullName;errorCategory=[string]$_.CategoryInfo.Category;rawTextExported=$false}|ConvertTo-Json -Compress
} finally {
    if($session){Remove-PSSession $session}
    if($secure){$secure.Dispose()}
}
