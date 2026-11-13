# Explicit NODE01 vendor-client runtime read. Never called by the metadata observer.
$ErrorActionPreference='Stop'
$phase='host-binding';$session=$null;$secure=$null
try {
    if ($env:COMPUTERNAME -cne 'LocalBox-Client') {throw 'Unexpected outer host'}
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
    $phase='protected-session'
    $session=New-PSSession -VMId $vm.Id -Credential ([pscredential]::new('LB-NODE01\ASBuiltInAdmin',$secure)) -ErrorAction Stop
    $phase='vendor-client-read'
    $runtime={
        $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
        $phase='guest-identity';$privateRoot=$null;$privateReady=$false;$calls=@();$pins=@();$readBudget=@{count=0}
        $vhdRequests=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        $containerRoots=@('C:\ClusterStorage\UserStorage_1','C:\ClusterStorage\Infrastructure_1\Shares\SU1_Infrastructure_1\MocArb\WorkingDirectory\ImageStore')
        $readEnd=[DateTimeOffset]::Parse('2026-11-10T11:45:00+02:00')
        function Digest([byte[]]$Bytes) {
            $h=[Security.Cryptography.SHA256]::Create()
            try {[BitConverter]::ToString($h.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()} finally {$h.Dispose()}
        }
        function SafeValue($Value) {
            if ($null -eq $Value) {return @{status='not-reported'}}
            if ($Value -is [bool] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]) {return @{status='reported';value=$Value;type=$Value.GetType().FullName}}
            if ($Value -isnot [string] -and $Value -isnot [guid] -and $Value -isnot [enum]) {return @{status='unsupported-shape';type=$Value.GetType().FullName}}
            $text=[string]$Value
            if ($text.Length -gt 1024 -or $text -match '-----BEGIN|\beyJ[A-Za-z0-9_-]{15,}\.|\b(?:ssh-rsa|ssh-ed25519|ecdsa-sha2-[A-Za-z0-9-]+)\s|#cloud-config|[\r\n]|(?i:password|access_token|refresh_token|client_secret|authorization|connectionstring)|://|\?') {return @{status='withheld';sha256=(Digest ([Text.Encoding]::UTF8.GetBytes($text)))}}
            @{status='reported';value=$text;type=$Value.GetType().FullName}
        }
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
        function Shape($Item,[int]$Depth=0) {
            if ($null -eq $Item) {return @{clrType='null';kind='null'}}
            $shape=@{clrType=(SafeValue $Item.GetType().FullName);valuesExported=$false}
            if ($Item -is [string] -or $Item -is [ValueType]) {$shape.kind='scalar';return $shape}
            if ($Item -is [Collections.IDictionary]) {
                $shape.kind='dictionary';$shape.memberCount=$Item.Count
                $shape.members=@($Item.Keys|Select-Object -First 64|ForEach-Object {
                    $key=$_;$value=$Item[$key]
                    @{name=(SafeValue $key);clrType=$(if($null -eq $value){'null'}else{SafeValue $value.GetType().FullName})}
                })
                $shape.complete=$Item.Count -le 64
            } elseif ($Item -is [Collections.IList]) {
                $shape.kind='collection';$shape.count=$Item.Count;$shape.complete=$Item.Count -le 64 -and $Depth -lt 2
                if ($Depth -lt 2) {$shape.items=@($Item|Select-Object -First 64|ForEach-Object {Shape $_ ($Depth+1)})}
            } else {
                $shape.kind='object';$properties=@($Item.PSObject.Properties);$shape.memberCount=$properties.Count
                $shape.members=@($properties|Select-Object -First 64|ForEach-Object {@{name=(SafeValue $_.Name);declaredType=(SafeValue $_.TypeNameOfValue)}})
                $shape.complete=$properties.Count -le 64
            }
            # Inspect only recognised collection members, never arbitrary private property values.
            if ($Depth -lt 2 -and $shape.kind -cin @('dictionary','object')) {
                $shape.collections=@(foreach($name in @('value','locations','galleryImages','containers','groups')) {
                    $member=Member $Item $name
                    if ($member.present) {@{name=$name;shape=(Shape $member.value ($Depth+1))}}
                })
                $shape.structures=@(foreach($name in @('properties','virtualmachineproperties','networkinterfaceproperties','virtualnetworkproperties','status','tags')) {
                    $member=Member $Item $name
                    if ($member.present) {@{name=$name;shape=(Shape $member.value ($Depth+1))}}
                })
            }
            $shape
        }
        function AdmitVhdPath([string]$Path) {
            if ($Path -notmatch '^[Cc]:\\' -or $Path -match '[*?\[\]]' -or $Path.Substring(2).Contains(':') -or $Path -notmatch '(?i)\.vhdx?$') {return $null}
            try {$full=[IO.Path]::GetFullPath($Path)} catch {return $null}
            if (@($containerRoots|Where-Object {$full.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase)}).Count -ne 1) {return $null}
            $full
        }
        function Detail($Value,[int]$Depth=0,$Budget=@{nodes=0}) {
            $Budget.nodes++
            if ($Depth -gt 6 -or $Budget.nodes -gt 256) {return @{status='detail-bound-reached'}}
            if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) {return (SafeValue $Value)}
            if ($Value -is [Collections.IList]) {return @{status='bounded-array';count=$Value.Count;complete=($Value.Count -le 32);items=@($Value|Select-Object -First 32|ForEach-Object {Detail $_ ($Depth+1) $Budget})}}
            $fields=@{}
            $scalarNames='name,id,location,group,containername,containerId,storageContainerId,parentId,ownerId,vmId,virtualMachineId,vhdId,diskId,nicId,networkInterfaceId,virtualNetworkId,networkId,subnetId,imageId,imageName,version,imageVersion,osType,osSku,architecture,state,code,errorCode,provisioningState,healthState,powerState,cpu,cpus,cpuCount,vcpus,processorCount,virtualProcessorCount,memory,memoryBytes,memoryMB,memoryInMB,memorySizeMB,memorySizeInMB,size,sizeBytes,sizeInMB,sizeInGB,virtualSize,virtualSizeBytes,maximumBytes,occupiedBytes,diskSizeBytes,diskSizeGB,totalSize,usedSize,freeSize,totalBytes,usedBytes,freeBytes,path,imagePath,vhdPath,diskPath,parentPath,filePath,ipAddress,ipAddresses,privateIPAddress,macAddress,address,addressPrefix,addressPrefixes,start,end,startAddress,endAddress,startIP,endIP,rangeStart,rangeEnd,gateway,dnsServers,prefixLength,vlanId,subnetMask,allocated,allocatedAddress,allocatedAddresses,usedAddresses,capacity'.Split(',')
            foreach($name in $scalarNames) {
                $member=Member $Value $name;if(-not $member.present){continue}
                $leaf=$member.value
                if ($leaf -is [Collections.IList]) {$fields[$name]=@{status='bounded-scalars';count=$leaf.Count;complete=($leaf.Count -le 32);items=@($leaf|Select-Object -First 32|ForEach-Object {SafeValue $_})}} else {$fields[$name]=SafeValue $leaf}
            }
            foreach($name in 'properties,virtualmachineproperties,networkinterfaceproperties,virtualnetworkproperties,tags,statuses,status,info,provisioning,provisioningStatus,health,healthStatus,powerStatus,operation,error,hardwareProfile,storageProfile,networkProfile,osDisk,dataDisks,networkInterfaces,ipConfigurations,subnets,subnet,addressSpace,ranges,addressRanges,allocation,attachments,vm,vhd,nic,parent,owner,disks,image,network,virtualMachine'.Split(',')) {
                $member=Member $Value $name
                if($member.present -and $name -ceq 'tags'){
                    $tagFields=@{}
                    foreach($key in @('imageId','imagePath','imageSizeBytes','imageSizeInMB','vhdPath','diskId','virtualSizeBytes','sizeBytes','containerId','vmId','virtualMachineId','hyperVVmId','instanceId')){
                        $tag=Member $member.value $key;if($tag.present){$tagFields[$key]=SafeValue $tag.value}
                    }
                    $fields.tags=@{status='management-tags-only';shape=(Shape $member.value);fields=$tagFields};continue
                }
                if($member.present){$fields[$name]=Detail $member.value ($Depth+1) $Budget}
            }
            @{status='allowlisted-management-only';fields=$fields;recognisedFieldCount=$fields.Count;unitsNotInferred=$true}
        }
        function ReadReturnedVhds {
            return ,@(foreach($path in $vhdRequests.Keys) {
                if([DateTimeOffset]::UtcNow -ge $readEnd){@{status='read-end-reached';remainingPathsNotRead=$true};break}
                try {
                    $directory=[IO.FileInfo]::new($path).Directory
                    while($null -ne $directory){
                        $directory.Refresh()
                        if(-not $directory.Exists -or (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $directory.FullName -inotmatch '^C:\\ClusterStorage\\(?:UserStorage_1|Infrastructure_1)$')){throw 'VHD ancestor missing or redirected outside exact CSV mount points'}
                        $directory=$directory.Parent
                    }
                    $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
                    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'VHD file redirected or invalid'}
                    $disk=Get-VHD -Path $path -ErrorAction Stop
                    if($null -eq $disk.Size -or $null -eq $disk.FileSize){throw 'VHD numeric size fields not reported'}
                    @{status='read';path=(SafeValue $path);observedIn=$vhdRequests[$path];id=[string]$disk.DiskIdentifier;maximumBytes=[long]$disk.Size;occupiedFileBytes=[long]$disk.FileSize;vhdType=[string]$disk.VhdType;parentPath=(SafeValue $disk.ParentPath);capacityAdmitted=$false}
                } catch {@{status='unavailable';path=(SafeValue $path);observedIn=$vhdRequests[$path];errorType=$_.Exception.GetType().FullName;errorCategory=[string]$_.CategoryInfo.Category}}
            })
        }
        function RetainTypedJson([string]$Name,$Data) {
            $path=Join-Path $privateRoot ($Name+'-typed.json');$created=$false
            try {
                # Windows PowerShell may silently stringify over-depth values. Reject
                # unsupported/deep trees before conversion, independently of warnings.
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
        function ReadContainerFiles {
            $queue=[Collections.Generic.Queue[object]]::new();$entries=[Collections.Generic.List[object]]::new();$issues=@();$bound=$false;$depthBound=$false;$vhdLimit=$false
            foreach($root in $containerRoots){$queue.Enqueue(@{path=$root;depth=0})}
            while($queue.Count -and $entries.Count -lt 128){
                if([DateTimeOffset]::UtcNow -ge $readEnd){$issues+=@{status='read-end-reached'};break}
                $next=$queue.Dequeue();$iterator=$null
                try {
                    $directory=[IO.DirectoryInfo]::new($next.path);$ancestor=$directory
                    while($null -ne $ancestor){$ancestor.Refresh();if(-not $ancestor.Exists -or (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $ancestor.FullName -inotmatch '^C:\\ClusterStorage\\(?:UserStorage_1|Infrastructure_1)$')){throw 'Enumeration ancestor invalid'};$ancestor=$ancestor.Parent}
                    $iterator=$directory.EnumerateFileSystemInfos().GetEnumerator()
                    while($entries.Count -lt 128 -and $iterator.MoveNext()){
                        if([DateTimeOffset]::UtcNow -ge $readEnd){$issues+=@{status='read-end-reached'};break}
                        $item=$iterator.Current;$isDirectory=[bool]($item.Attributes -band [IO.FileAttributes]::Directory);$redirected=[bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint);$depth=$next.depth+1
                        $row=@{path=(SafeValue $item.FullName);depth=$depth;directory=$isDirectory;reparsePoint=$redirected;lastWriteUtc=$item.LastWriteTimeUtc.ToString('o')}
                        if(-not $isDirectory -and -not $redirected){$row.fileBytes=$item.Length}
                        $entries.Add($row)
                        if($redirected){continue}
                        if($isDirectory){if($depth -lt 3){$queue.Enqueue(@{path=$item.FullName;depth=$depth})}else{$depthBound=$true};continue}
                        if($item.Extension -in @('.vhd','.vhdx')){
                            $path=AdmitVhdPath $item.FullName
                            if($path -and -not $vhdRequests.ContainsKey($path)){if($vhdRequests.Count -lt 16){$vhdRequests.Add($path,@('enumerated-filesystem-path-only'))}else{$vhdLimit=$true}}
                        }
                    }
                    if($entries.Count -ge 128){$bound=$true}
                } catch {$issues+=@{path=(SafeValue $next.path);status='metadata-unavailable';errorType=$_.Exception.GetType().FullName}}
                finally {if($null -ne $iterator -and $iterator -is [IDisposable]){$iterator.Dispose()}}
            }
            @{status='bounded-filesystem-metadata-only';entries=$entries.ToArray();entryCount=$entries.Count;entryBoundReached=$bound;depthBoundReached=$depthBound;vhdBoundReached=$vhdLimit;directoriesNotVisited=$queue.Count;issues=$issues;imageOwnership='not-established-by-filenames-or-container-membership';fileContentsRead=$false}
        }
        function ProjectItem($Item) {
            # Fixed management fields only. Missing fields are not absence/zero evidence.
            $paths=@('id','name','type','location','group','state','provisioningState','path','imagePath','containerName','containerId','storageContainerId','version','imageVersion','kubernetesVersion','osType','osSku','architecture','size','sizeBytes','sizeInMB','sizeInGB','virtualSize','virtualSizeBytes','diskSizeBytes','diskSizeGB','properties.id','properties.name','properties.path','properties.imagePath','properties.provisioningState','properties.size','properties.sizeBytes','properties.sizeInMB','properties.sizeInGB','properties.virtualSizeBytes','properties.containerId','status.state','status.provisioningState','storageProfile.osDiskImage.sizeInMB','version.properties.storageProfile.osDiskImage.sizeInMB')
            $fields=@{};$missing=@()
            foreach($path in $paths) {
                $value=$Item;$present=$true
                foreach($part in $path.Split('.')) {
                    $member=Member $value $part
                    if (-not $member.present) {$present=$false;break}
                    $value=$member.value
                }
                if ($present) {$fields[$path]=SafeValue $value} else {$missing+= $path}
            }
            $unreported=@($fields.Values|Where-Object {$_.status -cne 'reported'}).Count
            @{fields=$fields;detail=(Detail $Item);missingFields=$missing;withheldOrUnsupportedFieldCount=$unreported;allRequestedFieldsReported=($missing.Count -eq 0 -and $unreported -eq 0);imageOrCapacityAdmitted=$false}
        }
        function SaveCapture([string]$Name,$records,$failure) {
            if ($null -eq $failure) {$failure=@($records|Where-Object {$_ -is [Management.Automation.ErrorRecord]})|Select-Object -First 1}
            $text=($records|Out-String -Width 4096)
            if ($null -ne $failure) {$text+=[Environment]::NewLine+$failure.ToString()}
            $bytes=[Text.Encoding]::UTF8.GetBytes($text)
            $log=Join-Path $privateRoot ($Name+'.txt')
            # Node-local protected diagnostic only. Never return raw vendor streams.
            $file=[IO.File]::Open($log,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            try {$file.Write($bytes,0,[Math]::Min($bytes.Length,1048576))} finally {$file.Dispose()}
            $diagnostic=@{path=$log;fullStreamSha256=(Digest $bytes);bytes=$bytes.Length;retainedBytes=[Math]::Min($bytes.Length,1048576);truncated=($bytes.Length -gt 1048576)}
            if ($null -ne $failure) {
                $original=[Text.Encoding]::UTF8.GetBytes($failure.ToString());$originalPath=Join-Path $privateRoot ($Name+'-original-failure.txt')
                $s=[IO.File]::Open($originalPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
                try{$s.Write($original,0,[Math]::Min($original.Length,1048576))}finally{$s.Dispose()}
                return @{status='failed';phase=$Name;errorType=(SafeValue $failure.Exception.GetType().FullName);errorCategory=[string]$failure.CategoryInfo.Category;diagnostic=$diagnostic;originalFailure=@{path=$originalPath;sha256=(Digest $original);bytes=$original.Length;truncated=($original.Length -gt 1048576)}}
            }
            $data=@($records|Where-Object {$_ -isnot [Management.Automation.InformationRecord] -and $_ -isnot [Management.Automation.WarningRecord] -and $_ -isnot [Management.Automation.VerboseRecord] -and $_ -isnot [Management.Automation.DebugRecord] -and $_ -isnot [Management.Automation.ErrorRecord]})
            @{status='complete';phase=$Name;data=$data;diagnostic=$diagnostic}
        }
        function ClientCall([string]$Name,[scriptblock]$Read) {
            if ($readBudget.count -ge 7 -or [DateTimeOffset]::UtcNow -ge $readEnd) {throw 'Seven-call or read-end bound reached'}
            $readBudget.count++
            $records=[Collections.Generic.List[object]]::new();$failure=$null
            try {& $Read *>&1|ForEach-Object {$records.Add($_)}} catch {$failure=$_}
            SaveCapture $Name $records $failure
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
        try {
            if ($env:COMPUTERNAME -cne 'LB-NODE01') {throw 'Unexpected guest'}
            $admin=Get-LocalUser -Name ASBuiltInAdmin
            if (-not $admin.Enabled -or -not $admin.SID.Value.EndsWith('-500') -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $admin.SID.Value) {throw 'Existing RID500 identity differs'}
            $phase='pins-before-import'
            $base='C:\Program Files\WindowsPowerShell\Modules\'
            $expected=@(
                @('Moc\1.2.161\Moc.psd1','b4c171acdf6bdaf86a6751396e27b52714af2d1410505d1f3412103cf5435c3f','AB172913A2960A224809EE8A0C371CD47A079B72'),
                @('Moc\1.2.161\Moc.psm1','b9dbda4ab8c0ce6c77d8fa219a153983114afc859f5bb10689f6f3cf71025b7f','AB172913A2960A224809EE8A0C371CD47A079B72'),
                @('Moc\1.2.161\Common.psm1','1c4ce70357820cb4c2d95f6ac9a51fa3e9067f9130714b6f77aeaa46cd97babb','AB172913A2960A224809EE8A0C371CD47A079B72'),
                @('DownloadSdk\1.1.149\DownloadSdk.psd1','167b5fef982f9cfb191ab208f0fa67263ed2c29ea9541d3ef369a763f2c12c39','AB172913A2960A224809EE8A0C371CD47A079B72'),
                @('DownloadSdk\1.1.149\DownloadSdk.psm1','b14eb2061006cdd47069772bd6ff1919dbf6425814c73de4e90d14153097cdbc','AB172913A2960A224809EE8A0C371CD47A079B72'),
                @('TraceProvider\1.0.156\TraceProvider.psd1','4e12356f2d70a3edd58fb40865ceb6308d90a78c10693e40c8914946502c984d','1D77A9B9E8FE2075D9AD15123257FB90DB0DA4A1'),
                @('TraceProvider\1.0.156\TraceProvider.psm1','11d66b33526c7be33f6a50f658e917546d7d2439bd9d9279fc35b374fd0d0b80','AB172913A2960A224809EE8A0C371CD47A079B72'))
            foreach($pin in $expected) {
                $path=$base+$pin[0];$directory=[IO.FileInfo]::new($path).Directory
                $ancestors=@();while($null -ne $directory){$ancestors=@($directory)+$ancestors;$directory=$directory.Parent}
                foreach($ancestor in $ancestors){$ancestor.Refresh();if(-not $ancestor.Exists -or ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Redirected public module ancestor'}}
                $info=[IO.FileInfo]::new($path);if(-not $info.Exists -or $info.Length -gt 2097152 -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Public module file outside bound'}
                if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $pin[1]) {throw 'Observed public module hash differs'}
                $signature=Get-AuthenticodeSignature -FilePath $path
                if ([string]$signature.Status -cne 'Valid' -or $signature.SignerCertificate.Thumbprint -ine $pin[2]) {throw 'Observed public signer differs'}
                $pins+=@{path=$path;sha256=$pin[1];signature='Valid';signerThumbprint=$pin[2]}
            }
            if (@(Get-Module -Name Moc).Count) {throw 'Unexpected pre-imported Moc module'}
            $privateRoot='C:\ProgramData\AzureLocalBox\MocRead-20261110-04'
            if (-not (Test-Path -LiteralPath $privateRoot) -or $PSCommandPath -ine (Join-Path $privateRoot 'client-read.ps1')) {throw 'Expected protected fixed client process required'}
            $begin=[IO.File]::Open((Join-Path $privateRoot 'client-began'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);$begin.Dispose()
            $privateReady=$true
            $phase='import'
            # Import in this remote script scope, not a short-lived capture-function scope.
            $records=[Collections.Generic.List[object]]::new();$failure=$null
            try {Import-Module -Name 'C:\Program Files\WindowsPowerShell\Modules\Moc\1.2.161\Moc.psd1' -Scope Local -PassThru -ErrorAction Stop *>&1|ForEach-Object {$records.Add($_)}} catch {$failure=$_}
            $call=SaveCapture 'import' $records $failure
            $calls+=@{phase=$phase;status=$call.status;diagnostic=$call.diagnostic}
            if ($call.status -cne 'complete') {return @{status='failed';failure=$call;pins=$pins;calls=$calls}}
            $loaded=@(Get-Module -Name Moc)
            if ($loaded.Count -ne 1 -or [string]$loaded[0].Version -cne '1.2.161' -or [string]$loaded[0].Guid -ine 'f6cfb7b2-99e9-47f7-8000-7390756ee89b') {throw 'Imported Moc identity differs'}
            $location='MocLocation';$groups=@('management','Default_Group')
            $requests=@();foreach($group in $groups){$requests+=@(@{kind='nics';envelope='networkInterfaces';group=$group},@{kind='vnets';envelope='virtualNetworks';group=$group})}
            $requests+=@(
                @{kind='gallery';envelope='galleryImages';name='appliance-0.1.41.10527-v1.33.5';id='17e1deded2021a00'},
                @{kind='gallery';envelope='galleryImages';name='linux-cblmariner-0.12.15.10811';id='17d4332062ff03a3'},
                @{kind='vm';envelope='virtualMachines';group='management';name='32c9b21328b3df180e0d814a8afe5134fa140c2909569-control-plane-0';id='19c1d77215d4b74'})
            $incomplete=$false;$index=0
            $vmJoin=@{status='not-established';mocVmId='19c1d77215d4b74';hyperVVmIdFromPriorObservation='4c6ca5cc-8c9a-499b-8ffe-c029bbfd3522';evidence=@();namesAreNotIdentityProof=$true}
            foreach($request in $requests) {
                $phase=$request.kind;$scope=$location+'/'+$request.group+'/'+$phase+'/'+$request.name
                $captureName='detail-'+$index+'-'+$phase;$index++
                $call=switch($phase){
                    'nics' {ClientCall $captureName {Get-MocNetworkInterface -group $request.group -ErrorAction Stop}}
                    'vnets' {ClientCall $captureName {Get-MocVirtualNetwork -group $request.group -ErrorAction Stop}}
                    'gallery' {ClientCall $captureName {Get-MocGalleryImage -name $request.name -location $location -timeoutSeconds 20 -ErrorAction Stop}}
                    'vm' {ClientCall $captureName {Get-MocVirtualMachine -name $request.name -group $request.group -timeoutSeconds 20 -ErrorAction Stop}}
                }
                $entry=@{phase=$phase;location=$location;group=$request.group;requestedName=$request.name;status=$call.status;diagnostic=$call.diagnostic}
                $calls+=,$entry
                if($call.status -cne 'complete'){$entry.failure=$call;$incomplete=$true;continue}
                if($phase -cin @('gallery','vm')){
                    $entry.rawTypedCapture=RetainTypedJson $captureName $call.data
                    if($entry.rawTypedCapture.status -cne 'retained-private-JSON'){$incomplete=$true}
                }
                $entry.pipelineShapes=@($call.data|Select-Object -First 64|ForEach-Object {Shape $_})
                try {$items=Items $call $request.envelope} catch {$entry.status='unsupported-shape';$incomplete=$true;continue}
                if($request.id -and ($items.Count -ne 1 -or (Member $items[0] 'id').value -cne $request.id -or (Member $items[0] 'name').value -cne $request.name)){$entry.status='named-identity-mismatch';$incomplete=$true;continue}
                if(@($items|Where-Object {
                    $returnedLocation=Member $_ 'location';$returnedGroup=Member $_ 'group'
                    ($returnedLocation.present -and $returnedLocation.value -cne $location) -or ($request.group -and $returnedGroup.present -and $returnedGroup.value -cne $request.group)
                }).Count){$entry.status='returned-scope-mismatch';$incomplete=$true;continue}
                $entry.count=$items.Count;$entry.items=@($items|ForEach-Object {ProjectItem $_})
                if($phase -ceq 'vm'){
                    foreach($path in @('virtualmachineproperties.id','virtualmachineproperties.vmId','virtualmachineproperties.virtualMachineId','virtualmachineproperties.hyperVVmId','virtualmachineproperties.instanceId','tags.vmId','tags.virtualMachineId','tags.hyperVVmId','tags.instanceId')){
                        $value=$items[0];foreach($part in $path.Split('.')){$value=(Member $value $part).value}
                        $guid=[guid]::Empty
                        if($value -is [string] -and [guid]::TryParse($value,[ref]$guid) -and $guid -eq [guid]$vmJoin.hyperVVmIdFromPriorObservation){$vmJoin.status='explicit-returned-identity-match';$vmJoin.evidence+=@{field=$path;returnedId=$value}}
                    }
                }
            }
            $filesystem=ReadContainerFiles
            $vhdMetadata=ReadReturnedVhds
            $incomplete=$incomplete -or $filesystem.entryBoundReached -or $filesystem.depthBoundReached -or $filesystem.vhdBoundReached -or $filesystem.issues.Count -gt 0 -or @($vhdMetadata|Where-Object {$_.status -cne 'read'}).Count -gt 0
            @{status=$(if($incomplete){'scope-incomplete-stop'}else{'complete'});atUtc=[DateTime]::UtcNow.ToString('o');location=$location;groups=$groups;getterCalls=$readBudget.count;filesystem=$filesystem;vhdMetadata=$vhdMetadata;MocToHyperVIdentityJoin=$vmJoin;imageFileOwnership='not-established-by-file-or-image-name';deploymentLocationSelected=$false;pins=$pins;calls=$calls;
              runtimePermissionUsed='existing-client-auth-cache-log-environment-and-idempotent-read-retry';resourceWritesRequested=$false;
              imageAllocationOrCapacityAdmitted=$false;rawStreamsExported=$false}
        } catch {
            $failure=@{phase=$phase;errorType=(SafeValue $_.Exception.GetType().FullName);errorCategory=[string]$_.CategoryInfo.Category;sourceLine=[int]$_.InvocationInfo.ScriptLineNumber}
            if ($privateReady -and (Test-Path -LiteralPath $privateRoot)) {
                $bytes=[Text.Encoding]::UTF8.GetBytes($_.ToString());$file=Join-Path $privateRoot 'original-failure.txt'
                $s=[IO.File]::Open($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
                try{$s.Write($bytes,0,[Math]::Min($bytes.Length,1048576))}finally{$s.Dispose()}
                $failure.privateOriginal=$file;$failure.sha256=Digest $bytes
            }
            @{status='failed';failure=$failure;pins=$pins;calls=$calls;rawStreamsExported=$false}
        }
    }
    # One fixed child, not a general dispatcher: catches vendor Out-Default/console output.
    $clientSource="function Invoke-FixedMocRead {`n"+$runtime.ToString()+"`n}`n"+
        '$safe=Invoke-FixedMocRead;[IO.File]::WriteAllText(''C:\ProgramData\AzureLocalBox\MocRead-20261110-04\result.json'',($safe|ConvertTo-Json -Depth 24 -Compress),[Text.UTF8Encoding]::new($false))'
    $result=Invoke-Command -Session $session -ArgumentList $clientSource -ErrorAction Stop -ScriptBlock {
        param([string]$ClientSource)
        $ErrorActionPreference='Stop'
        if ($env:COMPUTERNAME -cne 'LB-NODE01' -or -not [Security.Principal.WindowsIdentity]::GetCurrent().User.Value.EndsWith('-500')) {throw 'Expected NODE01/RID500 client context'}
        function Read-OriginalMocState([string]$Root) {
            try {
                $scriptPath=Join-Path $Root 'client-read.ps1'
                $parent=Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($Root)) -Force -ErrorAction Stop
                if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Original operation parent redirected'}
                $exists=Test-Path -LiteralPath $Root -ErrorAction Stop;$entries=@();$files=@{}
                if ($exists) {
                    $directory=Get-Item -LiteralPath $Root -Force -ErrorAction Stop
                    if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Original operation root is not a plain directory'}
                    $entries=@(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop)
                }
                $record=$null;$resultStatus='not-reported'
                foreach($name in @('client-read.ps1','process.json','result.json')) {
                    $path=Join-Path $Root $name;$item=@($entries|Where-Object Name -CEQ $name)
                    $files[$name]=@{exists=($item.Count -eq 1)}
                    if (-not $item.Count) {continue}
                    if ($item.Count -ne 1 -or $item[0].PSIsContainer -or ($item[0].Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Original state entry redirected or invalid'}
                    $files[$name].bytes=$item[0].Length;$files[$name].lastWriteUtc=$item[0].LastWriteTimeUtc.ToString('o')
                    if ($name -ceq 'process.json') {
                        if ($item[0].Length -gt 65536) {throw 'Original process record exceeds bound'}
                        $value=Get-Content -LiteralPath $path -Raw -ErrorAction Stop|ConvertFrom-Json
                        $record=@{status='unrecognised';pid=$null;sourceSha256=$null}
                        if ($value.status -cin @('running','exited','uncertain-client-still-running-do-not-retry')) {$record.status=$value.status}
                        if (($value.pid -is [int] -or $value.pid -is [long]) -and $value.pid -gt 0 -and $value.pid -le [int]::MaxValue) {$record.pid=$value.pid}
                        if ($value.sourceSha256 -is [string] -and $value.sourceSha256 -cmatch '^[a-f0-9]{64}$') {$record.sourceSha256=$value.sourceSha256}
                    }
                    if ($name -ceq 'result.json') {
                        if ($item[0].Length -gt 1048576) {throw 'Original safe result exceeds bound'}
                        $value=Get-Content -LiteralPath $path -Raw -ErrorAction Stop|ConvertFrom-Json
                        if ($value.status -cin @('complete','failed','scope-incomplete-stop')) {$resultStatus=$value.status}
                    }
                }
                $processes=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop)
                $unknown=@($processes|Where-Object {[string]::IsNullOrWhiteSpace($_.CommandLine)}).Count
                $matches=@($processes|Where-Object {$_.CommandLine -is [string] -and $_.CommandLine.IndexOf($scriptPath,[StringComparison]::OrdinalIgnoreCase) -ge 0}|ForEach-Object {
                    @{pid=$_.ProcessId;creationUtc=$(if($_.CreationDate -is [datetime]){$_.CreationDate.ToUniversalTime().ToString('o')}else{'not-reported'});matchesOriginalScript=$true}
                })
                # Published -01 writes the script before starting the process and never deletes it.
                # A returned/dead process alone is deliberately not independent settlement.
                $unstarted=$entries.Count -eq 0 -and $matches.Count -eq 0 -and $unknown -eq 0
                @{readComplete=$true;observedAtUtc=[DateTime]::UtcNow.ToString('o');root=$Root;rootExists=$exists;entryCount=$entries.Count;files=$files;processRecord=$record;safeResultStatus=$resultStatus;
                  matchingProcesses=$matches;unreadablePowerShellCommandLineCount=$unknown;provedPrelaunchUnstarted=$unstarted;independentlySettled=$false;
                  requiresIndependentSettlement=(-not $unstarted);rawCommandLinesExported=$false}
            } catch { @{readComplete=$false;root=$Root;provedPrelaunchUnstarted=$false;independentlySettled=$false;requiresIndependentSettlement=$true;errorType=$_.Exception.GetType().FullName;errorCategory=[string]$_.CategoryInfo.Category} }
        }
        function New-ProtectedMocDirectory([string]$Root) {
            if (Test-Path -LiteralPath $Root) {throw 'Fresh diagnostic root already exists; no replay'}
            $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
            if (-not $sid.Value.EndsWith('-500')) {throw 'Current RID500 identity required'}
            $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false)
            foreach($principal in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
                $rule=[Security.AccessControl.FileSystemAccessRule]::new($principal,[Security.AccessControl.FileSystemRights]::FullControl,
                    ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
                $acl.AddAccessRule($rule)
            }
            $null=New-Item $Root -ItemType Directory -ErrorAction Stop
            Set-Acl -LiteralPath $Root -AclObject $acl -ErrorAction Stop
            if (-not (Get-Acl -LiteralPath $Root).AreAccessRulesProtected) {throw 'Node-local diagnostic DACL is not protected'}
        }
        $original=Read-OriginalMocState 'C:\ProgramData\AzureLocalBox\MocRead-20261109-01'
        if ($original.readComplete -ne $true -or $original.provedPrelaunchUnstarted -ne $true) {return @{status='blocked-original-reconciliation-required';original=$original;retryAllowed=$false}}
        $previousRoot='C:\ProgramData\AzureLocalBox\MocRead-20261109-02'
        $previous=Read-OriginalMocState $previousRoot
        $previousRecord=Get-Content -LiteralPath (Join-Path $previousRoot 'process.json') -Raw|ConvertFrom-Json
        if ($previous.readComplete -ne $true -or $previous.matchingProcesses.Count -ne 0 -or $previous.unreadablePowerShellCommandLineCount -ne 0 -or
            $previousRecord.pid -ne 6824 -or $previousRecord.sourceSha256 -cne '079b5ceea3d9fe8261484447ad2e472303feba79c2dd4e2e686f89d7bcf529cf' -or ([DateTimeOffset]$previousRecord.processStartedUtc).UtcDateTime.Ticks -ne ([DateTimeOffset]::Parse('2026-11-09T19:51:17.6309347Z')).UtcDateTime.Ticks -or
            (Get-FileHash -LiteralPath (Join-Path $previousRoot 'client-read.ps1')).Hash -ine '079b5ceea3d9fe8261484447ad2e472303feba79c2dd4e2e686f89d7bcf529cf' -or
            (Get-FileHash -LiteralPath (Join-Path $previousRoot 'result.json')).Hash -ine 'f2c667d72b6028d19a7728a6d70a43ed31b955cc0ab6fe62af2bda51e037dfd8' -or $previous.safeResultStatus -cne 'scope-incomplete-stop') {
            return @{status='blocked-previous-result-lineage-or-process';original=$original;previous=$previous;retryAllowed=$false}
        }
        $completedRoot='C:\ProgramData\AzureLocalBox\MocRead-20261110-03'
        $completed=Read-OriginalMocState $completedRoot
        $completedRecord=Get-Content -LiteralPath (Join-Path $completedRoot 'process.json') -Raw|ConvertFrom-Json
        if ($completed.readComplete -ne $true -or $completed.matchingProcesses.Count -ne 0 -or $completed.unreadablePowerShellCommandLineCount -ne 0 -or
            $completedRecord.pid -ne 14596 -or $completedRecord.status -cne 'exited' -or ($completedRecord.exitCode -isnot [int] -and $completedRecord.exitCode -isnot [long]) -or $completedRecord.exitCode -ne 0 -or
            $completedRecord.sourceSha256 -cne '9df1b9cb0cb355dcc29a59f41bdf900f2bd42e9a1499c2f7c21e949b566d2e97' -or
            ([DateTimeOffset]$completedRecord.processStartedUtc).UtcDateTime.Ticks -ne ([DateTimeOffset]::Parse('2026-11-10T09:02:59.0631610Z')).UtcDateTime.Ticks -or
            (Get-FileHash -LiteralPath (Join-Path $completedRoot 'client-read.ps1')).Hash -ine '9df1b9cb0cb355dcc29a59f41bdf900f2bd42e9a1499c2f7c21e949b566d2e97' -or
            (Get-FileHash -LiteralPath (Join-Path $completedRoot 'result.json')).Hash -ine '4eb3b9586fcc0f811c17072e96d2aa7f219fff8d0327e7dfd10dabd8632cfeba' -or $completed.safeResultStatus -cne 'scope-incomplete-stop') {
            return @{status='blocked-completed-read-lineage-or-process';original=$original;previous=$previous;completed=$completed;retryAllowed=$false}
        }
        $remaining=[int][Math]::Floor(([DateTimeOffset]::Parse('2026-11-10T11:45:00+02:00')-[DateTimeOffset]::UtcNow).TotalSeconds)
        if($remaining -le 0){return @{status='blocked-read-end-passed';completed=$completed;retryAllowed=$false}}
        $root='C:\ProgramData\AzureLocalBox\MocRead-20261110-04'
        if (Test-Path -LiteralPath $root) {return @{status='blocked-new-root-already-exists';original=$original;previous=$previous;retryAllowed=$false}}
        New-ProtectedMocDirectory $root
        $script=Join-Path $root 'client-read.ps1';[IO.File]::WriteAllText($script,$ClientSource,[Text.UTF8Encoding]::new($false))
        $sourceSha=(Get-FileHash -LiteralPath $script -Algorithm SHA256).Hash.ToLowerInvariant()
        $process=Start-Process -FilePath powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',$script) -RedirectStandardOutput (Join-Path $root 'client.stdout') -RedirectStandardError (Join-Path $root 'client.stderr') -PassThru
        $handle=$process.Handle # Retain the native process handle before waiting for exit.
        $record=@{status='running';pid=$process.Id;processStartedUtc=$process.StartTime.ToUniversalTime().ToString('o');sourceSha256=$sourceSha;retryAllowed=$false;privateRoot=$root;original=$original;completed=$completed}
        [IO.File]::WriteAllText((Join-Path $root 'process.json'),($record|ConvertTo-Json -Compress))
        $waitMilliseconds=[Math]::Max(0,[int](([DateTimeOffset]::Parse('2026-11-10T11:45:00+02:00')-[DateTimeOffset]::UtcNow).TotalMilliseconds))
        if (-not $process.WaitForExit([Math]::Min(360000,$waitMilliseconds))) {
            $record.status='uncertain-client-still-running-do-not-retry'
            [IO.File]::WriteAllText((Join-Path $root 'process.json'),($record|ConvertTo-Json -Compress));return $record
        }
        $process.Refresh();$record.status='exited';$record.exitCode=$process.ExitCode
        [IO.File]::WriteAllText((Join-Path $root 'process.json'),($record|ConvertTo-Json -Compress))
        $path=Join-Path $root 'result.json'
        if (-not (Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -gt 1048576) {return @{status='failed-private-client-result-unavailable';original=$original;previous=$previous;process=$record;rawStreamsExported=$false}}
        $safe=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
        if ($safe.status -cnotin @('complete','failed','scope-incomplete-stop')) {throw 'Unrecognised safe result status'}
        @{status='client-result';original=$original;previous=$previous;process=$record;result=$safe;resultSha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant();clientSourceSha256=$sourceSha;exitCodeMeaning='reported-if-available-not-business-proof';rawStreamsExported=$false}
    }
    @{node='LB-NODE01';vmId=$vm.Id.ToString();result=$result;atUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 28 -Compress
} catch {
    @{status='failed';phase=$phase;errorType=$_.Exception.GetType().FullName;errorCategory=[string]$_.CategoryInfo.Category;rawStreamsExported=$false}|ConvertTo-Json -Compress
} finally {
    if ($session) {Remove-PSSession $session}
    if ($secure) {$secure.Dispose()}
}
