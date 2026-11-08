# Expand only C: into its existing approved 1 TiB boot disk. No disk formatting,
# recovery-partition deletion, data-disk initialisation, disk resize or new Azure cost.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ne 'LocalBox-Client') { throw 'Unexpected target' }
if (-not (Get-NetIPAddress -IPAddress 10.200.16.4 -AddressFamily IPv4 -ErrorAction SilentlyContinue)) { throw 'Expected private address absent' }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Existing administrator required' }
$partition = Get-Partition -DriveLetter C
$disk = Get-Disk -Number $partition.DiskNumber
$volume = Get-Volume -DriveLetter C
if (-not $disk.IsBoot -or $disk.Size -ne 1TB -or $disk.PartitionStyle.ToString() -ne 'GPT' -or $volume.FileSystem -ne 'NTFS' -or $volume.HealthStatus.ToString() -ne 'Healthy') { throw 'C: is not the expected healthy NTFS volume on the existing 1 TiB GPT boot disk' }
$dataBefore = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem } | Sort-Object Number | ForEach-Object { @{ number = $_.Number; style = $_.PartitionStyle.ToString(); size = $_.Size } }) | ConvertTo-Json -Compress
$supported = Get-PartitionSupportedSize -DriveLetter C
if ($supported.SizeMax -lt 900GB -or $supported.SizeMax -gt $disk.Size) { throw 'Contiguous expansion unavailable. Do not remove partitions or change disk layout.' }
$marker = 'C:\ProgramData\AzureLocalBox\os-volume-expansion.json'
$before = $partition.Size
$applied = $false
if ($supported.SizeMax -gt ($partition.Size + 1MB)) {
    if (Test-Path $marker) { throw 'Prior expansion exists. Inspect rather than repeat.' }
    $pending = @{ status = 'pending'; beforeBytes = $before; targetBytes = $supported.SizeMax; atUtc = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json
    $stream = [IO.File]::Open($marker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $bytes = [Text.Encoding]::ASCII.GetBytes($pending); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    Resize-Partition -DriveLetter C -Size $supported.SizeMax -ErrorAction Stop
    $applied = $true
}
$after = Get-Partition -DriveLetter C
if ([math]::Abs($after.Size - $supported.SizeMax) -gt 1MB) { throw 'Expansion verification differs. Inspect marker and partition.' }
$dataAfter = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem } | Sort-Object Number | ForEach-Object { @{ number = $_.Number; style = $_.PartitionStyle.ToString(); size = $_.Size } }) | ConvertTo-Json -Compress
if ($dataBefore -ne $dataAfter) { throw 'Data disk inventory changed during inspection. Stop.' }
if ($applied) { @{ status = 'complete'; beforeBytes = $before; afterBytes = $after.Size; atUtc = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content $marker -Encoding ASCII }
[ordered]@{
    computer = $env:COMPUTERNAME
    atUtc = (Get-Date).ToUniversalTime().ToString('o')
    expansionApplied = $applied
    bootDiskGiB = [math]::Round($disk.Size / 1GB)
    beforePartitionGiB = [math]::Round($before / 1GB, 2)
    afterPartitionGiB = [math]::Round($after.Size / 1GB, 2)
    freeGiB = [math]::Round((Get-Volume -DriveLetter C).SizeRemaining / 1GB, 2)
    dataDiskInventoryUnchanged = $true
    defenderRealTimeProtection = (Get-MpComputerStatus).RealTimeProtectionEnabled
    rebootPerformed = $false
    newAzureDiskAllocation = $false
    nestedVmCreated = $false
} | ConvertTo-Json -Compress
