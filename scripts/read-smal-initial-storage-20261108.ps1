# Fixed NODE01 native volume/VD associations. No storage resize or reservation write.
$ErrorActionPreference = 'Stop'
$plan = [pscustomobject]@{ guestIds = [pscustomobject]@{ 'LB-NODE01' = '3adff629-2f67-449b-ab32-8a8748c46f34' } }
$began = [datetime]::UtcNow.ToString('o')
$session = New-ComputeSession 'LB-NODE01'
try {
    $result = Invoke-Command -Session $session -ArgumentList ${function:Read-InitialField}.ToString(),${function:Select-InitialFields}.ToString(),${function:Read-InitialQuery}.ToString(),${function:Read-InitialCommand}.ToString(),${function:Assert-InitialNode}.ToString() -ScriptBlock {
        param($field,$select,$query,$command,$assert)
        $ErrorActionPreference = 'Stop'
        Set-Item Function:Read-InitialField ([scriptblock]::Create($field)); Set-Item Function:Select-InitialFields ([scriptblock]::Create($select))
        Set-Item Function:Read-InitialQuery ([scriptblock]::Create($query)); Set-Item Function:Read-InitialCommand ([scriptblock]::Create($command)); Set-Item Function:Assert-InitialNode ([scriptblock]::Create($assert))
        Assert-InitialNode 'LB-NODE01'
        $queries = @()
        $queries += Read-InitialQuery 'osBuild' { Get-CimInstance Win32_OperatingSystem | ForEach-Object { Select-InitialFields $_ @('Version','BuildNumber','LastBootUpTime') } }
        $virtualDisks = @{ rows = @() }
        $queries += Read-InitialQuery 'virtualDisks' { Get-VirtualDisk | ForEach-Object { $virtualDisks.rows += $_; @{ id = $_.UniqueId; name = $_.FriendlyName; sizeBytes = $_.Size; footprintOnPoolBytes = $_.FootprintOnPool; provisioningType = $_.ProvisioningType.ToString(); resiliency = $_.ResiliencySettingName; copies = $_.NumberOfDataCopies; health = $_.HealthStatus.ToString() } } }
        $queries += Read-InitialQuery 'csvNativePartitions' { Get-ClusterSharedVolume -Cluster smal-localbox01 | ForEach-Object { $csv = $_; foreach ($info in $_.SharedVolumeInfo) { @{ csvId = $csv.Id.ToString(); csvName = $csv.Name; state = $csv.State.ToString(); ownerNode = $csv.OwnerNode.Name; path = $info.FriendlyVolumeName; partition = Select-InitialFields $info.Partition @('Name','Size','FreeSpace','FileSystem','PartitionNumber') } } } }
        $names = @('Get-Disk','Get-Partition','Get-Volume','Get-StorageTier','Resize-VirtualDisk','Resize-Partition')
        $commands = @{}
        $queries += Read-InitialQuery 'installedStorageInterfaces' { foreach ($name in $names) { $cmd = Get-Command -Name $name -ErrorAction SilentlyContinue; $commands[$name] = $cmd; if ($cmd) { Read-InitialCommand $cmd } } }
        $queries += Read-InitialQuery 'virtualDiskNativeVolumeAssociations' {
            if (-not $commands['Get-Disk'] -or -not $commands['Get-Partition'] -or -not $commands['Get-Volume'] -or -not $commands['Get-Disk'].Parameters.ContainsKey('VirtualDisk') -or -not $commands['Get-Partition'].Parameters.ContainsKey('DiskNumber') -or -not $commands['Get-Volume'].Parameters.ContainsKey('Partition')) { throw 'Verified native association parameters are unavailable' }
            foreach ($vd in $virtualDisks.rows) {
                foreach ($disk in @(Get-Disk -VirtualDisk $vd -ErrorAction Stop)) {
                    foreach ($partition in @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)) {
                        foreach ($volume in @(Get-Volume -Partition $partition -ErrorAction Stop)) {
                            @{ virtualDiskId = $vd.UniqueId; virtualDiskName = $vd.FriendlyName; diskUniqueId = $disk.UniqueId; diskNumber = $disk.Number
                                partition = Select-InitialFields $partition @('Guid','PartitionNumber','Size','AccessPaths')
                                volume = Select-InitialFields $volume @('UniqueId','Path','ObjectId','FileSystemLabel','FileSystemType','Size','SizeRemaining','HealthStatus') }
                        }
                    }
                }
            }
        }
        $queries += Read-InitialQuery 'storageTierAssociations' {
            if (-not $commands['Get-StorageTier'] -or -not $commands['Get-StorageTier'].Parameters.ContainsKey('VirtualDisk')) { throw 'Verified tier association interface is unavailable' }
            foreach ($vd in $virtualDisks.rows) { Get-StorageTier -VirtualDisk $vd -ErrorAction Stop | ForEach-Object { @{ virtualDiskId = $vd.UniqueId; tier = Select-InitialFields $_ @('UniqueId','FriendlyName','Size','FootprintOnPool','MediaType','ResiliencySettingName','NumberOfDataCopies') } } }
        }
        return @{ scope = 'LB-NODE01/smal-localbox01'; queries = $queries }
    } -ErrorAction Stop
    @{ status = $(if (@($result.queries | Where-Object complete -EQ $false).Count) { 'partial-read-only' } else { 'complete' }); beganAtUtc = $began; finishedAtUtc = [datetime]::UtcNow.ToString('o'); mutationPerformed = $false; data = $result } | ConvertTo-Json -Depth 22 -Compress
} finally { Remove-PSSession -Session $session }
