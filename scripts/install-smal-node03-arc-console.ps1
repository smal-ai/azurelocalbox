__THREE_NODE_PRELUDE__
# Deliver a pinned console only after successful local NODE3 cleanup/login.
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\arc-node03-console-20261029-01'
$job = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\node03-20261029-01\state.json' -Raw | ConvertFrom-Json
if ($job.status -cne 'complete-node03-local-bootstrap-cleanup-and-common-login' -or $job.vm.vmId -ine '__NODE03_VM_ID__' -or $job.commonCredentialLoginVerified -ne $true -or $job.cleanup.setupLogsNeedReview -or $job.cleanup.answerFileCleanupNeedsReview -or (Test-Path $root)) { throw 'Exact completed NODE3 proof missing or console already installed' }
$null = New-Item $root -ItemType Directory; Set-Acl $root (Get-Acl $threeRoot)
[IO.File]::WriteAllBytes((Join-Path $root 'Register-Node03.ps1'), [Convert]::FromBase64String('__NODE03_CONSOLE_BASE64__'))
[IO.File]::WriteAllBytes((Join-Path $root 'approval.json'), $approvalBytes)
if ((Get-FileHash (Join-Path $root 'Register-Node03.ps1')).Hash -cne '__NODE03_CONSOLE_SHA256__') { throw 'Installed NODE3 console source hash differs' }
$state = @{ status = 'installed-not-invoked'; sourceCommit = $sourceCommit; vmId = '__NODE03_VM_ID__'; scriptPath = (Join-Path $root 'Register-Node03.ps1'); scriptSha256 = '__NODE03_CONSOLE_SHA256__'; humanDeviceAuthenticationRequired = $true; registrationPerformed = $false; consoleOutputCaptured = $false }
[IO.File]::WriteAllText((Join-Path $root 'package.json'), ($state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$state | ConvertTo-Json -Compress
