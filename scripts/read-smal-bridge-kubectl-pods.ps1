# Isolated vendor client, one fixed raw GET invocation. No discovery, repair or credential retrieval.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine 'LocalBox-Client' -or $env:OS -cne 'Windows_NT') { throw 'Exact LocalBox-Client Windows host required' }
$end = [DateTimeOffset]::Parse('2026-11-10T11:00:00+02:00')
if ([DateTimeOffset]::UtcNow -ge $end) { throw 'Diagnostic window expired' }
$directory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'smal-bridge-kubectl-20261110-01'
$binary = Join-Path $directory 'kubectl.exe'; $config = Join-Path $directory 'customer-kubeconfig.json'
$allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
function Assert-PrivatePath([string]$Path, [bool]$Directory) {
    $item = Get-Item -LiteralPath $Path -Force; $acl = Get-Acl -LiteralPath $Path
    if ([bool]$item.PSIsContainer -ne $Directory -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Path type/reparse mismatch' }
    if ($allowed -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -or ($Directory -and -not $acl.AreAccessRulesProtected)) { throw 'Private owner/inheritance mismatch' }
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $allowed -notcontains $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value) { throw 'Private access too broad' }
    }
}
if (-not (Test-Path -LiteralPath $directory)) {
    if ([DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse('2026-11-10T10:45:00+02:00')) { throw 'Staging window expired' }
    [void][IO.Directory]::CreateDirectory($directory)
    $acl = New-Object Security.AccessControl.DirectorySecurity; $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
    foreach ($sid in $allowed) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $directory -AclObject $acl; Assert-PrivatePath $directory $true
    @{ status = 'private-staging-directory-created'; directory = $directory; binaryPath = $binary; configPath = $config; clientInvocations = 0 } | ConvertTo-Json -Compress
    return
}
$result = @{ status = 'not-invoked'; clientInvocations = 0; wireRequestCount = 'unknown'; processExited = $false }
$process = $null; $stdout = $null; $stderr = $null; $phase = 'staged-file-validation'
try {
    Assert-PrivatePath $directory $true; Assert-PrivatePath $binary $false; Assert-PrivatePath $config $false
    if ((Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant() -cne '1691938f7de0e931969f9968c3601cf32d6b0d573573afb4ce471f3d28f51984') { throw 'Binary hash mismatch' }
    if ((Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash.ToLowerInvariant() -cne 'c1a325ebbb9d87ea4d82dc8f1efb9d33cb06e3685ce964264b127bdd166b46c0') { throw 'Config hash mismatch' }
    if ($config.Contains('"')) { throw 'Invalid private path quoting' }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $binary; $info.WorkingDirectory = $directory; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.Arguments = '--kubeconfig "' + $config + '" --request-timeout=15s get --raw=/api/v1/namespaces/hybridaks-operator-system/pods'
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'KUBECONFIG', 'KUBERNETES_MASTER')) { $info.EnvironmentVariables.Remove($name) }
    $info.EnvironmentVariables['NO_PROXY'] = '*'; $info.EnvironmentVariables['no_proxy'] = '*'
    $stdoutPath = Join-Path $directory 'pods-stdout-private.json'; $stderrPath = Join-Path $directory 'pods-stderr-private.txt'
    $stdout = [IO.File]::Open($stdoutPath, 'CreateNew', 'Write', 'None'); $stderr = [IO.File]::Open($stderrPath, 'CreateNew', 'Write', 'None')
    $phase = 'one-shot-marker'
    $marker = [IO.File]::Open((Join-Path $directory 'client-invocation-once.marker'), 'CreateNew', 'Write', 'None'); $marker.Dispose()
    $phase = 'client-process'
    if ([DateTimeOffset]::UtcNow -ge $end) { throw 'No read time remains' }
    $process = New-Object Diagnostics.Process; $process.StartInfo = $info
    $watch = [Diagnostics.Stopwatch]::StartNew()
    if (-not $process.Start()) { throw 'Client did not start' }
    $result.clientInvocations = 1; $result.pid = $process.Id; $result.processStartedAtUtc = $process.StartTime.ToUniversalTime().ToString('o')
    $result | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $directory 'client-start.json') -Encoding UTF8
    $outBuffer = New-Object byte[] 4096; $errBuffer = New-Object byte[] 4096
    $outTask = $process.StandardOutput.BaseStream.ReadAsync($outBuffer, 0, $outBuffer.Length)
    $errTask = $process.StandardError.BaseStream.ReadAsync($errBuffer, 0, $errBuffer.Length)
    $outDone = $false; $errDone = $false; $total = 0
    while (-not $process.HasExited -or -not $outDone -or -not $errDone) {
        if ($watch.ElapsedMilliseconds -ge 30000 -or [DateTimeOffset]::UtcNow -ge $end) { $result.errorCategory = 'client-deadline'; throw 'Client deadline' }
        foreach ($side in @('out', 'err')) {
            $done = if ($side -eq 'out') { $outDone } else { $errDone }
            $task = if ($side -eq 'out') { $outTask } else { $errTask }
            if ($done -or -not $task.IsCompleted) { continue }
            $count = $task.GetAwaiter().GetResult()
            if ($count -eq 0) { if ($side -eq 'out') { $outDone = $true } else { $errDone = $true }; continue }
            $buffer = if ($side -eq 'out') { $outBuffer } else { $errBuffer }
            $file = if ($side -eq 'out') { $stdout } else { $stderr }
            $keep = [Math]::Min($count, 1048576 - $total); $file.Write($buffer, 0, $keep); $total += $keep
            if ($keep -lt $count) { $result.errorCategory = 'output-cap'; throw 'Combined output cap' }
            if ($side -eq 'out') { $outTask = $process.StandardOutput.BaseStream.ReadAsync($outBuffer, 0, $outBuffer.Length) }
            else { $errTask = $process.StandardError.BaseStream.ReadAsync($errBuffer, 0, $errBuffer.Length) }
        }
        Start-Sleep -Milliseconds 20
    }
    $phase = 'private-result-projection'; $stdout.Dispose(); $stderr.Dispose()
    if ($process.ExitCode -ne 0) {
        $result.errorCategory = 'kubectl-nonzero-exit'
        $text = [IO.File]::ReadAllText($stderrPath)
        if ($text -match '(?i)x509:|certificate signed by|certificate is valid for') { $result.errorCategory = 'tls-validation-failed' }
        elseif ($text -match '(?i)tls:|TLS handshake') { $result.errorCategory = 'tls-handshake-failed' }
        elseif ($text -match '(?i)Unauthorized|Forbidden') { $result.errorCategory = 'api-access-denied' }
        elseif ($text -match '(?i)connection refused|i/o timeout|no route to host') { $result.errorCategory = 'connection-failed' }
        $text = $null; throw 'Vendor client failed; raw stderr retained privately'
    }
    $pods = [IO.File]::ReadAllText($stdoutPath) | ConvertFrom-Json
    if ($pods.kind -cne 'PodList') { throw 'Unexpected pod response shape' }
    $result.pods = @($pods.items | ForEach-Object {
        @{ name = $_.metadata.name; phase = $_.status.phase
           conditions = @($_.status.conditions | Select-Object type, status, reason)
           containers = @($_.status.containerStatuses | ForEach-Object { @{ name = $_.name; ready = $_.ready; restartCount = $_.restartCount
               waitingReason = $_.state.waiting.reason; terminatedReason = $_.state.terminated.reason; exitCode = $_.state.terminated.exitCode
               lastTerminatedReason = $_.lastState.terminated.reason; lastExitCode = $_.lastState.terminated.exitCode } }) }
    })
    $result.status = 'management-pod-status-read'
} catch {
    $result.status = 'stopped-no-reinvocation'; $result.failurePhase = $phase; $result.sourceLine = [int]$_.InvocationInfo.ScriptLineNumber
    if (-not $result.errorCategory) { $result.errorCategory = 'local-wrapper-failure' }
} finally {
    if ($process -and $result.clientInvocations -eq 1) {
        try {
            if (-not $process.HasExited) { $process.Kill() }
            if ($process.WaitForExit(5000)) {
                $result.processExited = $true; $result.exitCode = $process.ExitCode; $result.processExitedAtUtc = $process.ExitTime.ToUniversalTime().ToString('o')
                $result.processDurationMilliseconds = [long]($process.ExitTime - $process.StartTime).TotalMilliseconds
            } else { $result.status = 'client-exit-uncertain-retain-credential' }
        } catch { $result.status = 'client-exit-uncertain-retain-credential' }
    }
    if ($stdout) { $stdout.Dispose() }; if ($stderr) { $stderr.Dispose() }
    if ($process) { $process.Dispose() }
    foreach ($name in @('pods-stdout-private.json', 'pods-stderr-private.txt')) {
        $path = Join-Path $directory $name
        if (Test-Path -LiteralPath $path) { $result[$name + 'Sha256'] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
}
# Parent removes only the exact hash-matched config after this exact client is known exited.
$result | ConvertTo-Json -Depth 9 -Compress
