# Approved media download only. Never mount, execute, extract or boot this ISO.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\eval-media-20261028-01'
$mutex = [Threading.Mutex]::new($false, 'Global\LocalBox-EvalMedia-20261028-01')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit 3 }
$response = $null; $inputStream = $null; $outputStream = $null
$statePath = Join-Path $root 'state.json'
$state = $null
function Save-MediaState {
    $state.lastUpdatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $temporary = Join-Path $root 'state.json.tmp'
    [IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    [IO.File]::Replace($temporary, $statePath, (Join-Path $root 'state.previous.json'))
}
try {
    $marker = [IO.File]::Open((Join-Path $root 'execution.started'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $marker.Dispose()
    $initial = Get-Content $statePath -Raw | ConvertFrom-Json
    $state = [ordered]@{ runId = 'eval-media-20261028-01'; scope = 'evaluation-media-download-only'; sourceCommit = $initial.sourceCommit; status = 'running'; phase = 'identity-check'; bytesWritten = 0L; lastUpdatedAtUtc = $null; errorType = $null; measuredSha256 = $null; publisherSha256Available = $false; clusterBootstrapComplete = $false }
    Save-MediaState
    if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or (Get-FileHash (Join-Path $root 'manifest.json')).Hash -ne '__MANIFEST_SHA256__') { throw 'Host or manifest differs' }
    $m = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
    if ($m.runId -ne $state.runId -or $m.scope -ne $state.scope -or $m.publisherSha256 -or $m.mountOrExecutionApprovedByThisJob -ne $false -or $m.lengthBytes -ne 8152356864 -or $m.fileName -cne 'WindowsServer2025Evaluation.26100.32230.x64.en-us.iso') { throw 'Media scope differs' }
    $metadata = [Net.HttpWebRequest]::Create('http://169.254.169.254/metadata/instance/compute/resourceId?api-version=2021-02-01&format=text')
    $metadata.Proxy = $null; $metadata.Headers['Metadata'] = 'true'; $metadata.Timeout = 5000
    $metadataResponse = $metadata.GetResponse()
    try { $reader = [IO.StreamReader]::new($metadataResponse.GetResponseStream()); try { $vmId = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() } } finally { $metadataResponse.Close() }
    if ($vmId -ine $m.azureVmResourceId) { throw 'Azure VM identity differs' }
    $uri = [uri]$m.url
    if ($uri.Scheme -cne 'https' -or $uri.Host -cne 'software-static.download.prss.microsoft.com' -or $uri.Port -ne 443 -or $uri.Query -or $uri.UserInfo) { throw 'Unapproved media origin' }
    $volume = Get-Volume -DriveLetter C
    if ($volume.FileSystem -ne 'NTFS' -or $volume.HealthStatus.ToString() -ne 'Healthy' -or $volume.SizeRemaining -lt ($m.lengthBytes + 20GB)) { throw 'Insufficient healthy OS volume space' }
    if (-not (Get-MpComputerStatus).RealTimeProtectionEnabled) { throw 'Defender is not active' }
    # Keep ISO and partial file within the newly owned Administrator/SYSTEM directory.
    $partial = Join-Path $root ($m.fileName + '.partial')
    $final = Join-Path $root $m.fileName
    if ((Test-Path $partial) -or (Test-Path $final)) { throw 'Existing media must be inspected, never overwritten' }
    $state.phase = 'download-request'; Save-MediaState
    $request = [Net.HttpWebRequest]::Create($uri)
    $request.AllowAutoRedirect = $false
    $request.UseDefaultCredentials = $false
    $request.Headers['If-Match'] = $m.etag
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 60000
    $response = $request.GetResponse()
    if ([int]$response.StatusCode -ne 200 -or $response.ContentLength -ne $m.lengthBytes -or $response.Headers['ETag'] -cne $m.etag) { throw 'Pinned media response differs' }
    $state.phase = 'downloading'; Save-MediaState
    $inputStream = $response.GetResponseStream()
    $outputStream = [IO.File]::Open($partial, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    [byte[]]$buffer = New-Object byte[] (1MB)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        if (($state.bytesWritten + $count) -gt $m.lengthBytes) { throw 'Response exceeds pinned media size' }
        $outputStream.Write($buffer, 0, $count)
        $state.bytesWritten += $count
        if ($clock.Elapsed.TotalSeconds -ge 15) { Save-MediaState; $clock.Restart() }
    }
    $outputStream.Flush($true); $outputStream.Dispose(); $outputStream = $null
    if ($state.bytesWritten -ne $m.lengthBytes -or (Get-Item $partial).Length -ne $m.lengthBytes) { throw 'Truncated media preserved for inspection' }
    $state.phase = 'measuring-sha256'; Save-MediaState
    $state.measuredSha256 = (Get-FileHash $partial -Algorithm SHA256).Hash
    # This is measured provenance, not validation against an unavailable publisher hash.
    $state.phase = 'publishing-downloaded-media'; Save-MediaState
    [IO.File]::Move($partial, $final)
    $state.status = 'media-downloaded'; $state.phase = 'downloaded-unmounted-unexecuted'; Save-MediaState
} catch {
    if ($state) {
        $state.status = 'failed-inspect-before-resume'
        $state.errorType = $_.Exception.GetType().Name
        try { Save-MediaState } catch { }
    }
    exit 1
} finally {
    if ($outputStream) { $outputStream.Dispose() }
    if ($inputStream) { $inputStream.Dispose() }
    if ($response) { $response.Close() }
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
