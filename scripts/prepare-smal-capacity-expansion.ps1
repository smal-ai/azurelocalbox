__CAPACITY_PRELUDE__
# Record the device set before the one approved new Azure attachment.
if ((Test-Path $capacityRoot) -or (Get-Volume -DriveLetter X -ErrorAction SilentlyContinue)) { throw 'Capacity preparation or drive X already exists; inspect, never overwrite' }
Assert-CapacityHost
$vhds = @(Read-CapacityOriginalVhds); $cluster = @(Read-CapacityClusterBaseline)
$disks = @(Get-Disk | ForEach-Object { @{ uniqueId = $_.UniqueId; number = $_.Number; size = $_.Size; isBoot = $_.IsBoot; isSystem = $_.IsSystem; style = $_.PartitionStyle.ToString() } })
$physical = @(Get-PhysicalDisk | ForEach-Object { @{ uniqueId = $_.UniqueId; size = $_.Size; canPool = $_.CanPool } })
if ($disks.Count -ne 3 -or $physical.Count -ne 10 -or @($physical | Where-Object canPool -EQ $true).Count -ne 0) { throw 'Unexpected outer devices before attachment' }
$volumes = @(Get-Volume | Where-Object DriveLetter -In @('C','V','W') | ForEach-Object { @{ letter = [string]$_.DriveLetter; uniqueId = $_.UniqueId; size = $_.Size } })
$null = New-Item $capacityRoot -ItemType Directory
Set-Acl $capacityRoot (Get-Acl 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01')
[IO.File]::WriteAllBytes((Join-Path $capacityRoot 'plan.json'),$planBytes)
[IO.File]::WriteAllBytes((Join-Path $capacityRoot 'approval.json'),$approvalBytes)
$record = @{ status = 'complete-pre-attachment-baseline'; sourceCommit = $sourceCommit; planSha256 = $approval.planSha256; azureDiskId = $plan.newDisk.id;
            hostBootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o'); disks = $disks; physicalDisks = $physical; volumes = $volumes; originalVhds = $vhds; cluster = $cluster; storageMutationPerformed = $false }
Save-CapacityState (Join-Path $capacityRoot 'baseline.json') $record
$record | ConvertTo-Json -Depth 14 -Compress
