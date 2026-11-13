# LocalBox-Client metadata only. No PSDirect/MOC, credential retrieval or Kubernetes API call.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine 'LocalBox-Client' -or $env:OS -cne 'Windows_NT') { throw 'Exact LocalBox-Client Windows host required' }

function Get-TextDigest([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PathProjection([string]$Path) {
    $row = @{ path = $Path; exists = $false }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $row }
        $item = Get-Item -LiteralPath $Path -Force
        $row.exists = $true
        $row.reparsePoint = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
        $row.type = $(if ($item.PSIsContainer) { 'directory' } else { 'file' })
        $row.sizeBytes = $(if (-not $item.PSIsContainer) { [long]$item.Length } else { $null })
        if ($row.reparsePoint) { $row.status = 'refused-reparse-point'; return $row }
        $row.owner = (Get-Acl -LiteralPath $Path).Owner
        $row.status = 'metadata-only'
    } catch { $row.status = 'metadata-error'; $row.errorType = $_.Exception.GetType().Name }
    return $row
}

function Get-ApplicationProjection([string]$Name) {
    $row = @{ name = $Name; available = $false }
    try {
        # Application-only lookup cannot discover or autoload provider cmdlets.
        $commands = @(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
        if ($commands.Count -eq 0) { return $row }
        $command = $commands[0]; $path = $command.Source
        $item = Get-Item -LiteralPath $path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Application reparse point refused' }
        $row.available = $true; $row.path = $path; $row.commandType = 'Application'
        $row.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $version = $item.VersionInfo.ProductVersion
        $row.fileVersion = $(if ($version -match '^[0-9][0-9A-Za-z.+_-]{0,80}$') { $version } else { $null })
        $row.status = 'application-metadata-only'
        if ($Name -ceq 'kubectl' -and $row.sha256 -ceq '815c3c39984d1f7347486ad58b8e33e61ee87bc8ad79e0dbc9793e22200614fb') {
            $row.qualifiedVersion = 'v1.33.1'; $row.versionBasis = 'published-windows-amd64-artifact-sha256'
        }
    } catch { $row.status = 'application-metadata-error'; $row.errorType = $_.Exception.GetType().Name }
    return $row
}

function Invoke-LocalRead([string]$Application, [string]$Arguments) {
    if ($Application.Contains('"')) { throw 'Invalid application path' }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    if ([IO.Path]::GetExtension($Application) -in @('.cmd', '.bat')) {
        $info.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $info.Arguments = '/d /s /c ""' + $Application + '" ' + $Arguments + '"'
    } else { $info.FileName = $Application; $info.Arguments = $Arguments }
    $info.EnvironmentVariables['AZURE_EXTENSION_USE_DYNAMIC_INSTALL'] = 'no'
    $info.EnvironmentVariables['AZURE_CORE_COLLECT_TELEMETRY'] = 'no'
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Local metadata process did not start' }
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Local metadata process timed out' }
        $text = $stdout.GetAwaiter().GetResult(); $discard = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $text.Length -gt 1048576) { throw 'Local metadata read failed or exceeded cap' }
        return $text
    } finally { $process.Dispose() }
}

function Convert-ConfigProjection($Clusters, $Contexts, [string]$Current) {
    $result = @{ currentContextNameSha256 = Get-TextDigest $Current; clusters = @(); contexts = @(); credentialValuesReturned = $false; referencedFilesRead = $false }
    foreach ($entry in @($Clusters)) {
        if ($null -eq $entry) { continue }
        $cluster = $entry.cluster; $server = [string]$cluster.server
        $ca = $cluster.'certificate-authority-data'; $caHash = $null; $caStatus = 'absent'
        if ($ca) {
            try {
                $bytes = [Convert]::FromBase64String([string]$ca)
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $caHash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant(); $caStatus = 'inline-public-ca-hashed' }
                finally { $sha.Dispose(); $bytes = $null }
            } catch { $caStatus = 'invalid-inline-ca-data' }
        } elseif ($cluster.'certificate-authority') { $caStatus = 'reference-not-read' }
        $result.clusters += @{ nameSha256 = Get-TextDigest ([string]$entry.name); serverSha256 = Get-TextDigest $server
            serverIsHttps = $server.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)
            inlineCaSha256 = $caHash; caStatus = $caStatus; caReferenceSha256 = Get-TextDigest ([string]$cluster.'certificate-authority')
            insecureSkipTlsVerify = [bool]$cluster.'insecure-skip-tls-verify' }
    }
    foreach ($entry in @($Contexts)) {
        if ($null -eq $entry) { continue }
        $result.contexts += @{ nameSha256 = Get-TextDigest ([string]$entry.name); clusterNameSha256 = Get-TextDigest ([string]$entry.context.cluster)
            current = ([string]$entry.name -ceq $Current) }
    }
    return $result
}

$result = @{ hostName = $env:COMPUTERNAME; atUtc = [datetime]::UtcNow.ToString('o'); status = 'inspected'
    effects = $false; credentialsFetched = $false; kubernetesApiAccessed = $false; execPluginsInvoked = $false
    kubeconfigEnvironmentPresent = [bool]$env:KUBECONFIG; recordedApplianceDirectories = @() }
$kubectl = Get-ApplicationProjection 'kubectl'; $az = Get-ApplicationProjection 'az'
$result.applications = @($kubectl, $az)
$result.arcappliance = @{ status = 'az-unavailable' }
if ($az.available -and $az.path -and $az.status -ceq 'application-metadata-only') {
    try {
        $versionInfo = Invoke-LocalRead $az.path 'version --only-show-errors --output json' | ConvertFrom-Json
        $version = [string]$versionInfo.'azure-cli'
        if ($version -match '^[0-9][0-9A-Za-z.+_-]{0,80}$') { $az.cliVersion = $version }
        $metadata = Invoke-LocalRead $az.path 'extension show --name arcappliance --only-show-errors --output json' | ConvertFrom-Json
        $extensionVersion = [string]$metadata.version
        if ($extensionVersion -notmatch '^[0-9][0-9A-Za-z.+_-]{0,80}$') { throw 'Invalid extension version metadata' }
        $result.arcappliance = @{ status = 'installed'; name = 'arcappliance'; version = $extensionVersion; path = $metadata.path }
    } catch { $result.arcappliance = @{ status = 'not-established'; errorType = $_.Exception.GetType().Name } }
}
# Only named paths. No directory enumeration, profile search or environment-path following.
$result.applianceDirectory = Get-PathProjection 'C:\ProgramData\kva\.ssh'
$result.kubeconfigs = @()
foreach ($path in @((Join-Path $HOME '.kube\config'), 'C:\LocalBox\kubeconfig')) {
    $row = Get-PathProjection $path
    if ($row.exists -and $row.type -eq 'file' -and -not $row.reparsePoint -and $row.status -eq 'metadata-only') {
        # Inspected upstream v1.33.1 config/view.go uses GetStartingConfig, never
        # REST ClientConfig or exec authentication. No flatten means no key/CA-file reads.
        # Windows amd64 release SHA256 is pinned. Other clients are inventoried only.
        if ($row.sizeBytes -gt 262144) { $row.readerStatus = 'config-exceeds-read-cap' }
        elseif ($kubectl.sha256 -cne '815c3c39984d1f7347486ad58b8e33e61ee87bc8ad79e0dbc9793e22200614fb') { $row.readerStatus = 'existing-client-hash-needs-review' }
        else {
            try {
                if ($path.Contains('"')) { throw 'Invalid fixed candidate path' }
                $prefix = 'config view --kubeconfig "' + $path + '" --merge=false --raw=true --flatten=false --output=jsonpath-as-json='
                # Select before stdout: never output users, token, password, client-key
                # data, auth-provider or exec-plugin configuration, even into the pipe.
                $clusters = Invoke-LocalRead $kubectl.path ($prefix + '{.clusters}') | ConvertFrom-Json
                $contexts = Invoke-LocalRead $kubectl.path ($prefix + '{.contexts}') | ConvertFrom-Json
                $current = Invoke-LocalRead $kubectl.path ($prefix + '{.current-context}') | ConvertFrom-Json
                $row.identities = Convert-ConfigProjection $clusters $contexts ([string]$current)
                $row.readerStatus = 'local-config-projected-not-api-or-bridge-trust-acceptance'
            } catch { $row.readerStatus = 'local-config-read-error'; $row.errorType = $_.Exception.GetType().Name }
        }
    }
    $result.kubeconfigs += $row
}
$result | ConvertTo-Json -Depth 9 -Compress
