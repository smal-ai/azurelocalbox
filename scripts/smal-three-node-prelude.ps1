# Public context and exact proposal/approval validation. This prelude mutates nothing.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected outer host' }
$contextBytes = [Convert]::FromBase64String('__THREE_NODE_CONTEXT_BASE64__')
if ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($contextBytes)).Replace('-','') -cne '__THREE_NODE_CONTEXT_SHA256__') { throw 'Three-node public context hash differs' }
$context = [Text.Encoding]::UTF8.GetString($contextBytes) | ConvertFrom-Json
$proposalBytes = [Convert]::FromBase64String($context.proposalBase64)
$approvalBytes = [Convert]::FromBase64String($context.approvalBase64)
$approval = [Text.Encoding]::UTF8.GetString($approvalBytes) | ConvertFrom-Json
$proposal = [Text.Encoding]::UTF8.GetString($proposalBytes) | ConvertFrom-Json
if ($approval.approved -ne $true -or $approval.onlyNewDiskFormatAndExactSingleBlankVhdMoveApproved -ne $true -or [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($proposalBytes)).Replace('-','').ToLowerInvariant() -cne $approval.proposalJsonSha256) { throw 'Exact three-node approval missing' }
if ($context.diskId -ine '/subscriptions/8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea/resourceGroups/rg-localbox-nodes-san-1/providers/Microsoft.Compute/disks/LocalBox-Client-Node03-SSD-20261029' -or $context.lun -ne 8 -or $proposal.newDisk.sizeGiB -ne 2048 -or $proposal.newDisk.sku -cne 'Premium_LRS' -or $proposal.newDisk.joinExistingPool -ne $false) { throw 'Approved disk effect differs' }
$null = [guid]::Parse($context.azureDiskUniqueId)
$threeRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\three-node-20261029-01'
$sourceCommit = '__SOURCE_COMMIT__'
