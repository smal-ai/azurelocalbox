__THREE_NODE_PRELUDE__
# Reconcile a transport interruption without formatting or changing any device.
$baseline = Get-Content (Join-Path $threeRoot 'disk-baseline.json') -Raw | ConvertFrom-Json
if ($baseline.azureDiskId -ine $context.diskId -or $baseline.azureDiskUniqueId -ine $context.azureDiskUniqueId) { throw 'Baseline identity differs' }
$disks = @(Get-Disk | ForEach-Object { @{ uniqueId = $_.UniqueId; number = $_.Number; size = $_.Size; isBoot = $_.IsBoot; isSystem = $_.IsSystem; style = $_.PartitionStyle.ToString(); offline = $_.IsOffline; readOnly = $_.IsReadOnly } })
$new = @($disks | Where-Object { $_.uniqueId -notin @($baseline.disks.uniqueId) })
@{ atUtc = [datetime]::UtcNow.ToString('o'); currentBootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o'); baselineBootUtc = $baseline.hostBootUtc;
   formatMarkerExists = (Test-Path (Join-Path $threeRoot 'new-disk-format.started')); formatStateExists = (Test-Path (Join-Path $threeRoot 'new-disk-format.json'));
   wExists = [bool](Get-Volume -DriveLetter W -ErrorAction SilentlyContinue); disks = $disks; newDevices = $new;
   physical = @(Get-PhysicalDisk | ForEach-Object { @{ uniqueId = $_.UniqueId; size = $_.Size; canPool = $_.CanPool } }); mutationPerformed = $false } | ConvertTo-Json -Depth 6 -Compress
