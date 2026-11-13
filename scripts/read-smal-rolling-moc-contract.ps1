$ErrorActionPreference='Stop'
$ComputeCapacityLibraryOnly=$true
$entry=$null
if($env:COMPUTERNAME -cne 'LocalBox-Client'){throw 'Wrong outer host'}
$deadline=[DateTimeOffset]::Parse('2026-11-10T15:00:00+02:00')
if([DateTimeOffset]::UtcNow -ge $deadline){throw 'Fixed MOC qualifier window closed'}
$plan=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('eyJndWVzdElkcyI6eyJMQi1EQzAxIjoiZjk0YzcxZjEtNjg1NC00OGI5LWE5ZjEtODIzOGM5OTM2NmQwIiwiTEItTk9ERTAxIjoiM2FkZmY2MjktMmY2Ny00NDliLWFiMzItOGE4NzQ4YzQ2ZjM0IiwiTEItTk9ERTAyIjoiMTJhNDRlMGMtY2MwOC00YzRjLWE4MTItZmEwYjU2ZWZkYmMzIiwiTEItTk9ERTAzIjoiNWI2ZWJhMTUtZmE4Mi00ZTEyLTllNDUtNWZmYmNkNDhjOGE5In0sInRyYW5zaXRpb25Db250cmFjdCI6eyJkZXZpY2VPd25lcnMiOnt9fX0='))|ConvertFrom-Json)
function Assert-Compute([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function New-ComputeSession([string]$name) {
    $id = $plan.guestIds.PSObject.Properties[$name].Value
    $vm = Get-VM -Id $id
    Assert-Compute ($vm.Name -ceq $name -and $vm.State.ToString() -ceq 'Running') 'Exact Running node required'
    $boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
    $bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
    $entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
    $helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
    Assert-Compute ($entry.Count -eq 1 -and (Get-FileHash $helper).Hash -ceq $entry[0].sha256) 'Existing secret helper differs'
    . $helper
    $store = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'
    $bindings = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw | ConvertFrom-Json
    $binding = $bindings.nodes.PSObject.Properties[$name].Value
    Assert-Compute ($binding.vmId -ieq $id -and $binding.role -ceq 'cluster-node-admin' -and $binding.secretDirectory -ceq $store -and $binding.loginVerified -eq $true) 'Existing credential binding differs'
    $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'
    try {
        # Exactly one authentication attempt. No old account-name fallback.
        return New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($name + '\ASBuiltInAdmin'), $secure)) -ErrorAction Stop
    } finally { $secure.Dispose() }
}

# Exact GET-only installed-command/membership qualification. No command bodies exported.
$ProfileMocRead = {
    param([string]$expectedNode, [bool]$metadataOnly = $false, $identityBinding = $null, [bool]$readMembership = $true)
    $ErrorActionPreference = 'Stop'
    if ($expectedNode -cnotin @('LB-NODE01','LB-NODE02','LB-NODE03') -or $env:COMPUTERNAME -cne $expectedNode) { throw 'Exact MOC observer node differs' }
    $admin = Get-LocalUser -Name ASBuiltInAdmin
    if (-not $admin.Enabled -or -not $admin.SID.Value.EndsWith('-500') -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $admin.SID.Value) { throw 'MOC observer RID 500 differs' }
    function Hash-ProfileMoc([string]$text) {
        $hash = [Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '').ToLowerInvariant() } finally { $hash.Dispose() }
    }
    function Digest([byte[]]$bytes) {
        $hash=[Security.Cryptography.SHA256]::Create()
        try { [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
    }
    function SafeValue($Value) {
        if ($null -eq $Value) { return @{status='reported';value=$null;type='null'} }
        if ($Value -is [string] -or $Value -is [ValueType]) {
            $text=[string]$Value
            if ($text.Length -le 1024 -and $text -notmatch '-----BEGIN|\beyJ[A-Za-z0-9_-]{15,}\.|[\r\n]|(?i:password|access_token|refresh_token|client_secret|authorization|connectionstring)|://|\?') { return @{status='reported';value=$Value;type=$Value.GetType().FullName} }
        }
        @{status='withheld';type=$Value.GetType().FullName}
    }
    # These collection rules retain the previously qualified Foundation Items logic.
    function Member($Item,[string]$Name) {
        if ($null -eq $Item) {return @{present=$false;value=$null}}
        if ($Item -is [Collections.IDictionary]) {
            $keys=@($Item.Keys|Where-Object {$_ -is [string] -and $_ -ieq $Name})
            if ($keys.Count -gt 1) {throw 'Ambiguous vendor dictionary keys'}
            if ($keys.Count -eq 1) {return @{present=$true;value=$Item[$keys[0]]}}
        } else {
            $property=$Item.PSObject.Properties[$Name]
            if ($null -ne $property) {return @{present=$true;value=$property.Value}}
        }
        @{present=$false;value=$null}
    }
    function OuterItems($Value) {
        $flat=[Collections.Generic.List[object]]::new();$limit=@{visited=0}
        function AddOuter($Value,[int]$Depth) {
            $limit.visited++;if ($limit.visited -gt 256) {throw 'Outer collection traversal bound exceeded'}
            if ($Value -is [Collections.IList] -and $Value -isnot [Collections.IDictionary]) {
                if ($Depth -ge 4 -or $Value.Count -gt 64) {throw 'Outer collection depth/count exceeded'}
                foreach($entry in $Value) {AddOuter $entry ($Depth+1)}
            } else {
                if ($flat.Count -ge 64) {throw 'Normalised item count exceeded'}
                $flat.Add($Value)
            }
        }
        AddOuter $Value 0
        return ,$flat.ToArray()
    }
    function Items($Call,[string]$Envelope) {
        $data=OuterItems $Call.data
        for($depth=0;$depth -lt 3 -and $data.Count -eq 1;$depth++) {
            $members=@(@('value',$Envelope)|Select-Object -Unique|ForEach-Object {Member $data[0] $_}|Where-Object {$_.present})
            if ($members.Count -gt 1) {throw 'Ambiguous vendor collection envelope'}
            if ($members.Count -eq 0) {break}
            $collection=$members[0].value
            if ($null -eq $collection -or $collection -is [Collections.IDictionary] -or $collection -isnot [Collections.IList]) {throw 'Vendor envelope is not an explicit array/list'}
            $data=OuterItems $collection
        }
        if ($data.Count -gt 64 -or @($data|Where-Object {$null -eq $_ -or $_ -is [string] -or $_ -is [ValueType]}).Count) {throw 'Unsupported or oversized vendor result shape'}
        if ($data.Count -eq 1 -and ((Member $data[0] 'value').present -or (Member $data[0] $Envelope).present)) {throw 'Vendor envelope depth exceeded'}
        return ,$data
    }
    function RetainTypedJson([string]$Name,$Data) {
        $path=Join-Path $privateRoot ($Name+'-typed.json');$created=$false
        try {
            $jsonBudget=@{nodes=0}
            function TestJsonTree($Value,[int]$Depth=0) {
                $jsonBudget.nodes++;if($Depth -gt 22 -or $jsonBudget.nodes -gt 65536){return $false}
                if($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]){return $true}
                if($Value -is [Collections.IDictionary]){foreach($key in $Value.Keys){if($key -isnot [string] -or -not (TestJsonTree $Value[$key] ($Depth+1))){return $false}}}
                elseif($Value -is [Collections.IList]){foreach($item in $Value){if(-not (TestJsonTree $item ($Depth+1))){return $false}}}
                elseif($Value -is [pscustomobject]){foreach($property in $Value.PSObject.Properties){if($property.MemberType -ne 'NoteProperty' -or -not (TestJsonTree $property.Value ($Depth+1))){return $false}}}
                else{return $false}
                $true
            }
            if(-not (TestJsonTree $Data)){return @{status='capture-incomplete';reason='unsupported-or-over-bound-JSON-tree';fileCreated=$false;rawValuesExported=$false}}
            $warnings=@();$json=ConvertTo-Json -InputObject $Data -Depth 24 -Compress -WarningVariable warnings -WarningAction SilentlyContinue
            if($warnings.Count){return @{status='capture-incomplete';reason='serializer-depth-warning';fileCreated=$false;rawValuesExported=$false}}
            $bytes=[Text.Encoding]::UTF8.GetBytes($json)
            if($bytes.Length -gt 1048576){return @{status='capture-incomplete';reason='one-MiB-cap-exceeded';bytes=$bytes.Length;fileCreated=$false;rawValuesExported=$false}}
            $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);$created=$true
            try{$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
            @{status='retained-private-JSON';path=$path;bytes=$bytes.Length;sha256=(Digest $bytes);complete=$true;rawValuesExported=$false}
        } catch {@{status='capture-incomplete';reason='serialization-or-create-only-write-failed';fileCreated=$created;existingFileNeverOverwritten=$true;errorType=$_.Exception.GetType().FullName;rawValuesExported=$false}}
    }
    function Project-ProfileMocRecord($record) {
        $fields=[Collections.Generic.List[object]]::new();$shape=[Collections.Generic.List[object]]::new();$budget=@{visited=0;complete=$true}
        function Walk-ProfileMoc($value,[string[]]$path,[int]$depth) {
            $budget.visited++;if($budget.visited -gt 256 -or $depth -gt 3){$budget.complete=$false;return}
            $names=if($value -is [Collections.IDictionary]){@($value.Keys)}else{@($value.PSObject.Properties.Name)}
            if($names.Count -gt 64){$budget.complete=$false;return}
            foreach($key in $names){
                if($key -isnot [string]){$budget.complete=$false;continue}
                $safeName=SafeValue $key
                if($safeName.status -cne 'reported'){$shape.Add(@{path=@($path);nameStatus='withheld'});continue}
                $child=if($value -is [Collections.IDictionary]){$value[$key]}else{$value.PSObject.Properties[$key].Value}
                $next=@($path)+$key
                $type=if($null -eq $child){'null'}else{$child.GetType().FullName};$safeType=SafeValue $type
                $shape.Add(@{path=@($next);clrType=$(if($safeType.status -ceq 'reported'){$safeType.value}else{'withheld-type'})})
                if($key -iin @('name','nodeName','computerName','hostName','id','nodeId','machineId','location','type')){$fields.Add(@{path=@($next);scalar=(SafeValue $child)})}
                if($key -iin @('properties','info','node','machine') -and $null -ne $child -and $child -isnot [string] -and $child -isnot [ValueType] -and $child -isnot [Collections.IList]){Walk-ProfileMoc $child $next ($depth+1)}
            }
        }
        Walk-ProfileMoc $record @() 0
        $type=SafeValue $record.GetType().FullName
        @{clrType=$(if($type.status -ceq 'reported'){$type.value}else{'withheld-type'});fields=@($fields.ToArray());shape=@($shape.ToArray());complete=$budget.complete}
    }
    function Resolve-ProfileMocMembers($records,$binding) {
        if($null -eq $binding -or $binding.semantics -cne 'WindowsComputerName' -or $binding.location -cne 'MocLocation' -or @($binding.fieldPath).Count -lt 1 -or @($binding.fieldPath).Count -gt 3 -or $binding.evidenceSha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'Membership identity field/Windows semantics require explicit evidence-bound review'}
        $names=@();$native=@()
        foreach($record in $records){
            $matches=@($record.fields|Where-Object { (@($_.path)-join '|') -ceq (@($binding.fieldPath)-join '|') })
            if($matches.Count -ne 1 -or $matches[0].scalar.status -cne 'reported' -or $matches[0].scalar.type -cne 'System.String'){throw 'Actual reviewed identity field is not one reported string'}
            $value=$matches[0].scalar.value
            $known=@('LB-NODE01','LB-NODE02','LB-NODE03')|Where-Object {[StringComparer]::OrdinalIgnoreCase.Equals($_,$value)}
            if(@($known).Count -ne 1){throw 'Unknown native identity; no FQDN/GUID translation permitted'}
            $names+=@($known)[0];$native+=@{nativeName=$value;canonicalWindowsName=@($known)[0]}
        }
        if(@($names|Select-Object -Unique).Count -ne $names.Count){throw 'Duplicate actual membership identity'}
        @{members=@($names|Sort-Object);nativeNames=@($native)}
    }
    $commands = [ordered]@{}
    $issues = @()
    foreach ($name in @('Get-MocNode','Remove-MocPhysicalNode','New-MocPhysicalNode')) {
        $found = @(Get-Command -Name $name -All -ErrorAction SilentlyContinue)
        if ($found.Count -ne 1) {
            if (-not $metadataOnly) { throw 'Unique installed module-backed MOC command required' }
            $issues += ($name + ': unique installed command missing')
            $commands[$name] = @{ name = $name; matches = @($found | ForEach-Object { @{ name = $_.Name; commandType = $_.CommandType.ToString(); moduleName = $_.ModuleName } }) }
            continue
        }
        $command = $found[0]
        if ($command.Name -cne $name -or $command.CommandType.ToString() -cnotin @('Function','Cmdlet') -or -not $command.ModuleName -or -not $command.Module.Path) { $issues += ($name + ': module-backed function/cmdlet required') }
        $sets = @($command.ParameterSets | Sort-Object Name | ForEach-Object {
            [ordered]@{ name = $_.Name; isDefault = $_.IsDefault; parameters = @($_.Parameters | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; type = $_.ParameterType.FullName; mandatory = $_.IsMandatory } }) }
        })
        $valid = @($sets | Where-Object {
            if ($name -ceq 'Get-MocNode') { @($_.parameters|Where-Object {$_.name -ieq 'location' -and $_.type -ceq 'System.String'}).Count -eq 1 -and @($_.parameters|Where-Object {$_.name -ieq 'timeoutSeconds' -and $_.type -ceq 'System.Int32'}).Count -eq 1 -and @($_.parameters|Where-Object {$_.mandatory -and $_.name -ine 'location'}).Count -eq 0 }
            else { @($_.parameters | Where-Object { $_.name -ieq 'NodeName' -and $_.type -cin @('System.String','System.String[]') }).Count -eq 1 -and @($_.parameters | Where-Object { $_.mandatory -and $_.name -ine 'NodeName' }).Count -eq 0 }
        })
        if ($valid.Count -eq 0 -or ($valid.Count -gt 1 -and @($valid | Where-Object isDefault -EQ $true).Count -ne 1)) { $issues += ($name + ': observed location/timeout or nodeName binding unsupported or ambiguous') }
        $descriptor = [ordered]@{ name = $name; commandType = $command.CommandType.ToString(); moduleName = $command.ModuleName; moduleVersion = $(if ($command.Module) { $command.Module.Version.ToString() } else { $null }); moduleGuid = $(if ($command.Module) { $command.Module.Guid.ToString() } else { $null }); modulePath = $command.Module.Path; moduleSha256 = $(if ($command.Module.Path) { (Get-FileHash -LiteralPath $command.Module.Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } else { $null }); definitionSha256 = Hash-ProfileMoc $command.Definition; parameterSets = $sets }
        $descriptor.contractSha256 = Hash-ProfileMoc ($descriptor | ConvertTo-Json -Depth 20 -Compress)
        if($descriptor.moduleName -cne 'Moc' -or $descriptor.moduleVersion -cne '1.2.161' -or $descriptor.moduleSha256 -cne 'b9dbda4ab8c0ce6c77d8fa219a153983114afc859f5bb10689f6f3cf71025b7f'){$issues+=($name+': actual observed Moc 1.2.161 module pin differs')}
        $commands[$name] = $descriptor
    }
    if ($issues.Count -gt 0) {
        if (-not $metadataOnly) { throw 'Installed MOC module/signature/required-parameter qualification failed' }
        return [ordered]@{ qualified = $false; observerNode = $expectedNode; commands = $commands; qualificationIssues = @($issues); members = $null; membershipObserved = $false; atUtc = [datetime]::UtcNow.ToString('o') }
    }
    if(-not $readMembership){return [ordered]@{qualified=$false;bindingsQualified=$true;observerNode=$expectedNode;commands=$commands;members=$null;membershipObserved=$false;membershipDataRead=$false;atUtc=[datetime]::UtcNow.ToString('o')}}
    $getter = @(Get-Command -Name Get-MocNode -All -ErrorAction Stop)
    if ($getter.Count -ne 1) { throw 'MOC getter changed during qualification' }
    $stream=[Collections.Generic.List[object]]::new();$failure=$null
    try { & $getter[0] -location 'MocLocation' -timeoutSeconds 20 *>&1|ForEach-Object {$stream.Add($_)} } catch {$failure=$_}
    $data=@($stream.ToArray()|Where-Object {$_ -isnot [Management.Automation.InformationRecord] -and $_ -isnot [Management.Automation.WarningRecord] -and $_ -isnot [Management.Automation.VerboseRecord] -and $_ -isnot [Management.Automation.DebugRecord] -and $_ -isnot [Management.Automation.ErrorRecord]})
    if(@($stream.ToArray()|Where-Object {$_ -is [Management.Automation.ErrorRecord]}).Count){$failure='getter-error-record'}
    $read=[ordered]@{qualified=$false;bindingsQualified=$true;observerNode=$expectedNode;commands=$commands;location='MocLocation';getter='Get-MocNode';getterArguments=@{location='MocLocation';timeoutSeconds=20};members=$null;membershipObserved=$false;membershipDataRead=($null -eq $failure);projectionComplete=$false;records=@();nativeNames=@();atUtc=[datetime]::UtcNow.ToString('o')}
    $read.returnShape=@{pipelineRecordCount=$stream.Count;dataItemCount=$data.Count;typeSampleComplete=($stream.Count -le 64 -and $data.Count -le 64);pipelineTypes=@(for($i=0;$i -lt [Math]::Min($stream.Count,64);$i++){if($null -eq $stream[$i]){'null'}else{SafeValue $stream[$i].GetType().FullName}});dataTypes=@(for($i=0;$i -lt [Math]::Min($data.Count,64);$i++){if($null -eq $data[$i]){'null'}else{SafeValue $data[$i].GetType().FullName}})}
    # Private diagnostic data only, not an operation root or history bypass. Never
    # overwrite existing evidence or expose raw vendor data on the output stream.
    try {
        $privateRoot='C:\ProgramData\AzureLocalBox\MocMembershipRead-20261110-01'
        $protectedAcl=Get-Acl 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01'
        if(-not (Test-Path -LiteralPath $privateRoot)){$null=New-Item $privateRoot -ItemType Directory;Set-Acl $privateRoot $protectedAcl}
        if(((Get-Item -LiteralPath $privateRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-Acl $privateRoot).Sddl -cne $protectedAcl.Sddl){throw 'Private MOC diagnostic directory ACL/path differs'}
        $captureName='membership-'+[guid]::NewGuid().ToString('N')
        $read.rawTypedCapture=RetainTypedJson $captureName $data
        $text=($stream.ToArray()|Out-String -Width 4096);if($null -ne $failure){$text+=[Environment]::NewLine+[string]$failure}
        $bytes=[Text.Encoding]::UTF8.GetBytes($text);$path=Join-Path $privateRoot ($captureName+'-stream.txt')
        $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try{$file.Write($bytes,0,[Math]::Min($bytes.Length,1048576))}finally{$file.Dispose()}
        $read.privateStreamCapture=@{path=$path;fullStreamSha256=(Digest $bytes);bytes=$bytes.Length;retainedBytes=[Math]::Min($bytes.Length,1048576);truncated=($bytes.Length -gt 1048576);rawValuesExported=$false}
    } catch {
        $read.privateCaptureErrorType=$_.Exception.GetType().FullName
        if($null -eq $read.rawTypedCapture){$read.rawTypedCapture=@{status='capture-incomplete';errorType=$_.Exception.GetType().FullName;rawValuesExported=$false}}
    }
    if($null -ne $failure){$read.qualificationIssues=@('Supported getter failed; raw values withheld');return $read}
    try {
        $items=Items @{data=$data} 'nodes'
        $read.records=@($items|ForEach-Object {Project-ProfileMocRecord $_})
        $read.projectionComplete=@($read.records|Where-Object complete -NE $true).Count -eq 0
        if(-not $read.projectionComplete){throw 'Bounded membership projection incomplete'}
        $resolved=Resolve-ProfileMocMembers $read.records $identityBinding
        $read.members=@($resolved.members);$read.nativeNames=@($resolved.nativeNames);$read.membershipObserved=$true;$read.qualified=$true
    } catch {$read.qualificationIssues=@($_.Exception.Message)}
    return $read
}
function Read-ProfileMoc([string]$node, [bool]$metadataOnly = $false, [bool]$readMembership = $true) {
    $mocSession = New-ComputeSession $node
    try { return Invoke-Command -Session $mocSession -ArgumentList $node, $metadataOnly, $plan.mocContract.membershipIdentity, $readMembership -ScriptBlock $ProfileMocRead -ErrorAction Stop } finally { Remove-PSSession $mocSession }
}
function Assert-ProfileMocMembership($read, [string[]]$expected, $contract) {
    Assert-Compute ($read.qualified -eq $true -and $read.observerNode -cin @('LB-NODE01','LB-NODE02','LB-NODE03')) 'Qualified exact MOC observer required'
    $binding = Get-ComputeField (Get-ComputeField $contract 'nodes') $read.observerNode
    Assert-Compute ($null -ne $binding) 'Pinned installed MOC observer contract missing'
    Assert-ComputeEqual $read.commands (Get-ComputeField $binding 'commands') 'Installed MOC module/signature/required-parameter contract differs'
    Assert-ComputeEqual @($read.members | Sort-Object) @($expected | Sort-Object) 'Actual MOC membership differs from exact stage'
}


$nodes=[ordered]@{}
foreach($node in @('LB-NODE02','LB-NODE03','LB-NODE01')) {
    if([DateTimeOffset]::UtcNow -ge $deadline){throw 'Fixed MOC qualifier window closed'}
    $nodes[$node]=Read-ProfileMoc $node $true ($node -ceq 'LB-NODE02')
}
if([DateTimeOffset]::UtcNow -ge $deadline){throw 'Fixed MOC qualifier window closed after reads'}
@{status='complete';mutationPerformed=$false;atUtc=[datetime]::UtcNow.ToString('o');commonSourceSha256='0e58f64f888c897a48b1d4f28bd6faec22346e9d8f1c36e4c92da29f0a2b6b86';nodes=$nodes}|ConvertTo-Json -Depth 30 -Compress
