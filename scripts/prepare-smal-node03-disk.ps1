__THREE_NODE_PRELUDE__
# Capture the Windows device set BEFORE the one exact Azure attachment.
if ((Test-Path $threeRoot) -or (Get-Volume -DriveLetter W -ErrorAction SilentlyContinue) -or (Get-VM -Name LB-NODE03 -ErrorAction SilentlyContinue)) { throw 'Three-node preparation already exists or name/drive conflicts' }
$v = Get-Volume -DriveLetter V; $c = Get-Volume -DriveLetter C
if ($v.HealthStatus.ToString() -ne 'Healthy' -or $v.SizeRemaining -lt 200GB -or (Get-VirtualDisk -FriendlyName LocalBoxData).UniqueId -cne 'D0CDB2F96D0E244E8B532E096F97FBBF') { throw 'Existing V storage differs' }
$disks = @(Get-Disk | ForEach-Object { @{ uniqueId = $_.UniqueId; number = $_.Number; size = $_.Size; isBoot = $_.IsBoot; isSystem = $_.IsSystem; style = $_.PartitionStyle.ToString() } })
$physical = @(Get-PhysicalDisk | ForEach-Object { @{ uniqueId = $_.UniqueId; size = $_.Size; canPool = $_.CanPool } })
if ($disks.Count -ne 2 -or $physical.Count -ne 9 -or @($physical | Where-Object canPool -EQ $true).Count -ne 0) { throw 'Unexpected host devices before attachment' }
$null = New-Item $threeRoot -ItemType Directory
Set-Acl $threeRoot (Get-Acl 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01')
[IO.File]::WriteAllBytes((Join-Path $threeRoot 'proposal.json'), $proposalBytes)
[IO.File]::WriteAllBytes((Join-Path $threeRoot 'approval.json'), $approvalBytes)
$record = @{ status = 'baseline-before-azure-lun8-attachment'; atUtc = [datetime]::UtcNow.ToString('o'); sourceCommit = $sourceCommit; azureDiskId = $context.diskId; azureDiskUniqueId = $context.azureDiskUniqueId; lun = 8; hostBootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o'); disks = $disks; physicalDisks = $physical; cVolumeId = $c.UniqueId; cSize = $c.Size; vVolumeId = $v.UniqueId; vSize = $v.Size; formattingPerformed = $false }
[IO.File]::WriteAllText((Join-Path $threeRoot 'disk-baseline.json'), ($record | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
$record | ConvertTo-Json -Depth 6 -Compress
