__CAPACITY_PRELUDE__
# Read-only admission proof for the exact first-file GUID-encoding interruption.
Assert-CapacityHost
$old = @(Read-CapacityOriginalVhds); $cluster = @(Read-CapacityClusterBaseline)
$failed = Get-Content (Join-Path $capacityRoot 'vhds.json') -Raw | ConvertFrom-Json
$format = Get-Content (Join-Path $capacityRoot 'format.json') -Raw | ConvertFrom-Json
$first = 'X:\AzureLocalBox\CapacityExpansion-20261030-01\LB-NODE01\S2D-5.vhdx'
if ($failed.status -cne 'failed-or-uncertain-inspect-do-not-repeat' -or $failed.errorType -cne 'RuntimeException' -or $failed.errorLine -ne 106 -or $failed.disks.Count -ne 0 -or $failed.pendingPath -cne $first -or $failed.planSha256 -cne $approval.planSha256 -or $format.azureDiskUniqueId -ine $context.azureDiskUniqueId) { throw 'Not the exact retained first-file binding failure' }
$files = @(Get-ChildItem 'X:\AzureLocalBox\CapacityExpansion-20261030-01' -File -Recurse)
if ($files.Count -ne 1 -or $files[0].FullName -cne $first) { throw 'Unexpected additional file; no automatic continuation' }
$vhd = Get-VHD -Path $first
if ($vhd.Attached -or $vhd.ParentPath -or $vhd.Size -ne 170GB -or $vhd.VhdType.ToString() -cne 'Dynamic' -or $vhd.FileSize -gt 32MB) { throw 'First owned VHD is not the expected unused small dynamic file' }
$prototype = @($old | Where-Object { $_.name -ceq 'LB-NODE01' -and $_.lun -eq 1 })[0]
if ($vhd.LogicalSectorSize -ne $prototype.logicalSectorSize -or $vhd.PhysicalSectorSize -ne $prototype.physicalSectorSize -or $vhd.BlockSize -ne $prototype.blockSize) { throw 'Owned new VHD geometry differs' }
@{ status = 'verified-one-owned-unattached-first-vhd-and-unchanged-cluster'; atUtc = [datetime]::UtcNow.ToString('o'); planSha256 = $approval.planSha256;
   azureDiskUniqueId = $context.azureDiskUniqueId; originalVhdCount = $old.Count; originalPoolDeviceCount = $cluster[0].members.Count;
   firstVhd = @{ path = $vhd.Path; vhdId = $vhd.DiskIdentifier.ToString(); sizeBytes = $vhd.Size; fileSize = $vhd.FileSize; sha256 = (Get-FileHash $first).Hash;
                 blockSize = $vhd.BlockSize; logicalSectorSize = $vhd.LogicalSectorSize; physicalSectorSize = $vhd.PhysicalSectorSize; attached = $vhd.Attached };
   mutationPerformed = $false } | ConvertTo-Json -Depth 7 -Compress
