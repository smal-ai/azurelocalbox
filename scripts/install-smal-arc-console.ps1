# Install reviewed human-console entry point only. Does NOT register a node.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\arc-console-20261028-01'
if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or (Test-Path $root)) { throw 'Target differs or console package exists. Inspect rather than reinstall.' }
$null = New-Item $root -ItemType Directory
Set-Acl -Path $root -AclObject (Get-Acl 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01')
[IO.File]::WriteAllBytes((Join-Path $root 'Register-LocalBoxNode.ps1'), [Convert]::FromBase64String('__CONSOLE_BASE64__'))
[IO.File]::WriteAllBytes((Join-Path $root 'approval.json'), [Convert]::FromBase64String('__APPROVAL_BASE64__'))
if ((Get-FileHash (Join-Path $root 'Register-LocalBoxNode.ps1')).Hash -cne '__CONSOLE_SHA256__' -or (Get-FileHash (Join-Path $root 'approval.json')).Hash -cne '__APPROVAL_SHA256__') { throw 'Installed console/approval hash differs' }
$state = @{ sourceCommit = '__SOURCE_COMMIT__'; scriptSha256 = '__CONSOLE_SHA256__'; approvalSha256 = '__APPROVAL_SHA256__'; scriptPath = (Join-Path $root 'Register-LocalBoxNode.ps1'); status = 'installed-not-invoked'; humanDeviceAuthenticationRequired = $true; registrationPerformed = $false; consoleOutputCaptured = $false }
[IO.File]::WriteAllText((Join-Path $root 'package.json'), ($state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$state | ConvertTo-Json -Compress
