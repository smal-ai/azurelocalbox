# Durable read-only discovery with explicit phases and bounded HNS subprocess.
param([switch]$ResumeVerified)
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-inputs-20261028-02'
$statePath = Join-Path $root 'state.json'
$state = $null; $mounted = $null; $currentPath = $null
$mutex = [Threading.Mutex]::new($false, 'Global\LocalBox-GuestInputs-20261028-02')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit 3 }
function Save-Inspection {
    param([string]$Phase)
    $state.phase = $Phase
    $state.atUtc = (Get-Date).ToUniversalTime().ToString('o')
    $temporary = Join-Path $root 'state.json.tmp'
    [IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Depth 9), [Text.UTF8Encoding]::new($false))
    [IO.File]::Replace($temporary, $statePath, (Join-Path $root 'state.previous.json'))
}
function Get-BufferedInspectionHash {
    param([string]$Path)
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 1MB, [IO.FileOptions]::SequentialScan)
    $hash = [Security.Cryptography.SHA256]::Create()
    [byte[]]$buffer = New-Object byte[] (1MB)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $state.hashBytesRead = 0L
    try {
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $null = $hash.TransformBlock($buffer, 0, $count, $buffer, 0)
            $state.hashBytesRead += $count
            if ($timer.Elapsed.TotalSeconds -ge 15) { Save-Inspection $state.phase; $timer.Restart() }
        }
        $null = $hash.TransformFinalBlock([byte[]]@(), 0, 0)
        return [BitConverter]::ToString($hash.Hash).Replace('-', '')
    } finally { $hash.Dispose(); $stream.Dispose() }
}
try {
    if ($ResumeVerified) {
        $proof = Get-Content (Join-Path $root 'buffered-hash-recovery.json') -Raw | ConvertFrom-Json
        if ($proof.kind -ne 'read-only-hash-phase-restart' -or $proof.runId -ne 'guest-inputs-20261028-02' -or (Get-FileHash (Join-Path $root 'worker.before-buffered-hash.ps1')).Hash -cne '2BA7C92F8F3A67E9C11CD30A79DDA851A0EC0D477684FED3B61F14447A246C5C' -or -not (Test-Path (Join-Path $root 'execution.started'))) { throw 'Read-only hash recovery evidence differs' }
    }
    $markerName = if ($ResumeVerified) { 'buffered-hash-recovery.started' } else { 'execution.started' }
    $marker = [IO.File]::Open((Join-Path $root $markerName), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); $marker.Dispose()
    $initial = Get-Content $statePath -Raw | ConvertFrom-Json
    $state = [ordered]@{ runId = 'guest-inputs-20261028-02'; sourceCommit = $initial.sourceCommit; scope = 'approved-media-and-host-inspection-only'; status = 'running'; phase = 'identity-check'; atUtc = $null; errorType = $null; errorLine = $null; hashBytesRead = 0L; result = @{}; clusterBootstrapComplete = $false }
    if ($ResumeVerified) {
        if ($proof.sourceCommit -notmatch '^[a-f0-9]{40}$') { throw 'Recovery source evidence missing' }
        $state.sourceCommit = $proof.sourceCommit
        $state.previousSourceCommit = $initial.sourceCommit
        $state.resumedReadOnlyHash = $true
    }
    Save-Inspection 'identity-check'
    if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or (Get-FileHash (Join-Path $root 'manifest.json')).Hash -ne '__MANIFEST_SHA256__') { throw 'Unexpected host/manifest' }
    $m = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
    $request = [Net.HttpWebRequest]::Create('http://169.254.169.254/metadata/instance/compute/resourceId?api-version=2021-02-01&format=text')
    $request.Proxy = $null; $request.Headers['Metadata'] = 'true'; $request.Timeout = 5000
    $response = $request.GetResponse()
    try { $reader = [IO.StreamReader]::new($response.GetResponseStream()); try { $vmId = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() } } finally { $response.Close() }
    if ($vmId -ine $m.azureVmResourceId -or $m.networkOrGuestApply -ne $false -or $m.runId -ne $state.runId) { throw 'Inspection scope differs' }
    Save-Inspection 'hyperv-query'
    $state.result.virtualMachines = @(Get-VM | Select-Object Name, Id, State)
    $state.result.switches = @(Get-VMSwitch | Select-Object Name, Id, SwitchType)
    Save-Inspection 'nat-query'
    $state.result.nat = @(Get-NetNat | Select-Object Name, InternalIPInterfaceAddressPrefix, ExternalIPInterfaceAddressPrefix)
    Save-Inspection 'address-query'
    $state.result.ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin)
    $state.result.defaultRoutes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Select-Object InterfaceAlias, NextHop, RouteMetric)
    Save-Inspection 'volume-query'
    $state.result.volume = Get-Volume -DriveLetter V | Select-Object DriveLetter, Size, SizeRemaining, HealthStatus
    $state.result.defender = (Get-MpComputerStatus).RealTimeProtectionEnabled
    $state.result.hnsService = @(Get-Service -Name hns -ErrorAction SilentlyContinue | Select-Object Name, Status)
    Save-Inspection 'bounded-hns-query'
    # Single-quoted source prevents worker variables from leaking into the child.
    $command = '$ErrorActionPreference=''Stop'';try{if(Get-Command Get-HnsNetwork -ErrorAction SilentlyContinue){@{available=$true;networks=@(Get-HnsNetwork | Select-Object Name,Type,Id)}|ConvertTo-Json -Depth 5 -Compress}else{@{available=$false}|ConvertTo-Json -Compress};exit 0}catch{exit 1}'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $child = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList ('-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encoded) -RedirectStandardOutput (Join-Path $root 'hns-result.json') -RedirectStandardError (Join-Path $root 'hns-error.txt') -PassThru
    $state.result.hnsChildPid = $child.Id; Save-Inspection 'bounded-hns-query'
    if (-not $child.WaitForExit(20000)) {
        $child.Kill(); $null = $child.WaitForExit(5000)
        $state.result.hnsQuery = @{ status = 'timed-out'; onlyOwnedChildStopped = $true }
    } elseif ($child.ExitCode -ne 0) { $state.result.hnsQuery = @{ status = 'failed' } }
    else { $state.result.hnsQuery = @{ status = 'complete'; result = (Get-Content (Join-Path $root 'hns-result.json') -Raw | ConvertFrom-Json) } }
    $state.result.media = @()
    $media = @(
        @{ kind = 'azure-local'; path = 'C:\ProgramData\AzureLocalBox\Artifacts\2610\AzureLocal24H2.26100.32230.LCM.12.2610.0.3098.x64.en-us.iso'; length = 7491864576L; sha256 = '317330754A6DAC6F42C1BE40EB780E0959C6C3F7670B33D94556964CDCBC9E89' },
        @{ kind = 'evaluation-dc'; path = 'C:\ProgramData\AzureLocalBox\Bootstrap\eval-media-20261028-01\WindowsServer2025Evaluation.26100.32230.x64.en-us.iso'; length = 8152356864L; sha256 = '7B052573BA7894C9924E3E87BA732CCD354D18CB75A883EFA9B900EA125BFD51' }
    )
    foreach ($item in $media) {
        Save-Inspection ($item.kind + '-hash-check')
        if ((Get-Item -LiteralPath $item.path).Length -ne $item.length -or (Get-BufferedInspectionHash -Path $item.path) -cne $item.sha256) { throw 'Approved media content differs' }
        $currentPath = $item.path
        if ((Get-DiskImage -ImagePath $currentPath).Attached) { throw 'Pre-existing media attachment' }
        Save-Inspection ($item.kind + '-read-only-mount')
        $mounted = Mount-DiskImage -ImagePath $currentPath -Access ReadOnly -PassThru
        $volumes = @($mounted | Get-Volume)
        if ($volumes.Count -ne 1 -or -not $volumes[0].DriveLetter) { throw 'Unexpected ISO volume mapping' }
        $base = $volumes[0].DriveLetter + ':\'; $wim = Join-Path $base 'sources\install.wim'
        Save-Inspection ($item.kind + '-wim-metadata')
        $images = @(Get-WindowsImage -ImagePath $wim | ForEach-Object {
            $detail = Get-WindowsImage -ImagePath $wim -Index $_.ImageIndex
            @{ index = $detail.ImageIndex; name = $detail.ImageName; architecture = $detail.Architecture; version = $detail.Version.ToString(); edition = $detail.EditionId; installationType = $detail.InstallationType; sizeBytes = $detail.ImageSize }
        })
        Save-Inspection ($item.kind + '-signatures')
        $signatures = @('setup.exe', 'efi\boot\bootx64.efi') | ForEach-Object {
            $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $base $_)
            @{ path = $_; status = $signature.Status.ToString(); signer = $(if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }) }
        }
        $state.result.media += @{ kind = $item.kind; lengthBytes = $item.length; sha256 = $item.sha256; publisherHashAvailable = ($item.kind -eq 'azure-local'); images = $images; signatures = @($signatures) }
        Save-Inspection ($item.kind + '-dismount')
        Dismount-DiskImage -ImagePath $currentPath | Out-Null
        $mounted = $null; $currentPath = $null
    }
    $state.status = 'inspection-complete'; Save-Inspection 'media-inspected-and-dismounted'
} catch {
    if ($state) { $state.status = 'failed-inspect-before-resume'; $state.errorType = $_.Exception.GetType().Name; $state.errorLine = $_.InvocationInfo.ScriptLineNumber; try { Save-Inspection $state.phase } catch { } }
    exit 1
} finally {
    if ($mounted -and $currentPath) { Dismount-DiskImage -ImagePath $currentPath | Out-Null }
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
