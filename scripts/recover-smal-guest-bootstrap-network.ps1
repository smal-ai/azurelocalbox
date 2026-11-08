# Resume only the inspected DC-before-network/before-directory checkpoint.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$imageRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01'
$taskName = 'LocalBox-GuestBootstrap-20261028-01'
if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or (Test-Path (Join-Path $root 'network-recovery-01.json'))) { throw 'Target differs or network recovery already attempted' }
$task = Get-ScheduledTask -TaskName $taskName; $info = Get-ScheduledTaskInfo -TaskName $taskName
$state = Get-Content (Join-Path $root 'state.json') -Raw | ConvertFrom-Json
if ($task.State.ToString() -ne 'Ready' -or $info.LastTaskResult -ne 1 -or $state.status -ne 'failed-inspect-before-resume' -or $state.phase -ne 'LB-DC01-configure-exact-guest-network' -or $state.domain -or @($state.cleanup.PSObject.Properties).Count -ne 0 -or @($state.newCredentialLoginVerified.PSObject.Properties).Count -ne 0) { throw 'Original pre-directory failure no longer matches' }
if ($task.Principal.UserId -notin @('SYSTEM', 'S-1-5-18') -or @($task.Triggers | Where-Object { $null -ne $_ }).Count -ne 0 -or $task.Actions.Count -ne 1 -or $task.Actions[0].Execute -ine 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -or $task.Actions[0].Arguments -cne ('-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $root 'worker.ps1') + '"')) { throw 'Original task ownership/action differs' }
if ((Get-FileHash (Join-Path $root 'worker.ps1')).Hash -cne '880F2068D876507DDD0E9FC76C8D1905EAFA49A8F1CD542C42E095C4391B7E79' -or (Get-FileHash (Join-Path $root 'bundle.json')).Hash -cne '28ACF061603CF458AB89557BDFB3F1DC1554C345DBD3C86CAF495329A2115F06' -or (Get-FileHash (Join-Path $root 'manifest.json')).Hash -cne '__MANIFEST_SHA256__' -or -not (Test-Path (Join-Path $root 'execution.started'))) { throw 'Original source/marker differs' }
$old = Get-Content (Join-Path $root 'bundle.json') -Raw | ConvertFrom-Json
foreach ($file in $old.files) { if ($file.name -notin @('smal-guest-direct-functions.ps1', 'smal-guest-secret-functions.ps1') -or (Get-FileHash (Join-Path $root $file.name)).Hash -cne $file.sha256) { throw 'Original helper source differs' } }
. (Join-Path $root 'smal-guest-secret-functions.ps1')
$dc = Get-VM -Id 'f94c71f1-6854-48b9-a9f1-8238c99366d0'
$nodes = @('3adff629-2f67-449b-ab32-8a8748c46f34', '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' | ForEach-Object { Get-VM -Id $_ })
if ($dc.Name -cne 'LB-DC01' -or $dc.State.ToString() -ne 'Running' -or $nodes.Count -ne 2 -or @($nodes | Where-Object { $_.State.ToString() -ne 'Off' }).Count -ne 0) { throw 'Expected existing DC/node states differ' }
$secure = Read-LabGuestSecureSecret -SecretDirectory (Join-Path $imageRoot 'secrets') -Role 'dc-bootstrap'
$session = $null
try {
    $session = New-PSSession -VMId $dc.Id -Credential ([pscredential]::new('LB-DC01\Administrator', $secure)) -ErrorAction Stop
    $verified = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -cne 'LB-DC01' -or (Get-CimInstance Win32_ComputerSystem).DomainRole -ne 2 -or (Get-Service NTDS -ErrorAction SilentlyContinue) -or (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState -ne 'IMAGE_STATE_COMPLETE') { throw 'Directory/setup state differs from inspected pre-directory checkpoint' }
        $adapters = @(Get-NetAdapter -Physical)
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' })
        if ($adapters.Count -ne 1 -or $adapters[0].Name -cne 'Ethernet' -or $adapters[0].MacAddress.Replace('-', '') -cne '00155D100401' -or $ips.Count -ne 0 -or @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count -ne 0) { throw 'Network effects exist or adapter identity changed' }
        if (-not (Get-MpComputerStatus).RealTimeProtectionEnabled -or @(Get-NetFirewallProfile | Where-Object Enabled -NE $true).Count -ne 0) { throw 'Guest protection is not ready' }
        return $true
    }
    if ($verified -ne $true) { throw 'Guest pre-directory/no-network-effects proof missing' }
} finally { if ($session) { Remove-PSSession -Session $session }; $secure.Dispose() }
foreach ($name in @('state.json', 'worker.ps1', 'bundle.json')) { [IO.File]::Copy((Join-Path $root $name), (Join-Path $root ($name.Replace('.json', '').Replace('.ps1', '') + '.before-network-recovery.' + $(if ($name.EndsWith('.ps1')) { 'ps1' } else { 'json' }))), $false) }
foreach ($item in $old.files) { [IO.File]::Copy((Join-Path $root $item.name), (Join-Path $root ($item.name + '.before-network-recovery')), $false) }
$proof = @{ kind = 'verified-dc-before-network-before-directory'; runId = 'guest-bootstrap-20261028-01'; sourceCommit = '__SOURCE_COMMIT__'; atUtc = (Get-Date).ToUniversalTime().ToString('o'); originalMarkerRetained = $true; dcGuestBootstrapLoginVerified = $true; nodesRemainOff = $true }
$bytes = [Text.Encoding]::UTF8.GetBytes(($proof | ConvertTo-Json))
$stream = [IO.File]::Open((Join-Path $root 'network-recovery-01.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
[IO.File]::WriteAllBytes((Join-Path $root 'bundle.json'), [Convert]::FromBase64String('__BUNDLE_BASE64__'))
[IO.File]::WriteAllBytes((Join-Path $root 'worker.ps1'), [Convert]::FromBase64String('__WORKER_BASE64__'))
if ((Get-FileHash (Join-Path $root 'bundle.json')).Hash -cne '__BUNDLE_SHA256__' -or (Get-FileHash (Join-Path $root 'worker.ps1')).Hash -cne '__WORKER_SHA256__') { throw 'Recovery package integrity differs' }
$bundle = Get-Content (Join-Path $root 'bundle.json') -Raw | ConvertFrom-Json
if (@($bundle.files).Count -ne 2) { throw 'Recovery helper count differs' }
foreach ($item in $bundle.files) {
    if ($item.name -notin @('smal-guest-direct-functions.ps1', 'smal-guest-secret-functions.ps1')) { throw 'Unexpected recovery helper name' }
    [IO.File]::WriteAllBytes((Join-Path $root $item.name), [Convert]::FromBase64String($item.base64))
    if ((Get-FileHash (Join-Path $root $item.name)).Hash -cne $item.sha256) { throw 'Recovery helper integrity differs' }
}
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument ('-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $root 'worker.ps1') + '" -ResumeVerified')
$null = Set-ScheduledTask -TaskName $taskName -Action $action
Start-ScheduledTask -TaskName $taskName
@{ runId = 'guest-bootstrap-20261028-01'; recovery = 'verified-dc-before-network-before-directory'; sourceCommit = '__SOURCE_COMMIT__'; workerSha256 = '__WORKER_SHA256__'; bundleSha256 = '__BUNDLE_SHA256__'; startRequested = $true; originalMarkerAndSourceRetained = $true; imageOrVmCreationRepeated = $false; azureRegistrationIncluded = $false; clusterBootstrapComplete = $false } | ConvertTo-Json -Compress
