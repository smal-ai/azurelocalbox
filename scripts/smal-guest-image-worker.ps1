# Approved local guest image/VM creation only. VMs remain OFF for the next phase.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01'
$guestRoot = 'V:\AzureLocalBox\Guests\local-guests-20261028-01'
$statePath = Join-Path $root 'state.json'; $state = $null
$mountedPath = $null; $lease = $null; $heartbeatStarted = $false
$mutex = [Threading.Mutex]::new($false, 'Global\LocalBox-GuestImages-20261028-01')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit 3 }
function Save-GuestImageState {
    param([string]$Phase)
    $state.phase = $Phase; $state.atUtc = (Get-Date).ToUniversalTime().ToString('o')
    $temporary = Join-Path $root 'state.json.tmp'
    [IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Depth 7), [Text.UTF8Encoding]::new($false))
    [IO.File]::Replace($temporary, $statePath, (Join-Path $root 'state.previous.json'))
    $event = @{ runId = $state.runId; atUtc = $state.atUtc; phase = $state.phase; status = $state.status }
    [IO.File]::AppendAllText((Join-Path $root 'events.jsonl'), (($event | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}
try {
    $marker = [IO.File]::Open((Join-Path $root 'execution.started'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); $marker.Dispose()
    $initial = Get-Content $statePath -Raw | ConvertFrom-Json
    $state = [ordered]@{ runId = 'local-guests-20261028-01'; sourceCommit = $initial.sourceCommit; scope = 'approved-local-guest-images-and-offline-vms-only'; status = 'running'; phase = 'identity-check'; atUtc = $null; errorType = $null; errorLine = $null; images = @(); virtualMachines = @(); guardianCreated = $false; secretsCreated = $false; bootstrapCleanupAndRotationRequired = $true; clusterBootstrapComplete = $false }
    Save-GuestImageState 'identity-check'
    if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or (Get-FileHash (Join-Path $root 'manifest.json')).Hash -cne '__MANIFEST_SHA256__' -or (Get-FileHash (Join-Path $root 'bundle.json')).Hash -cne '__BUNDLE_SHA256__') { throw 'Host/source identity differs' }
    $m = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
    if ($m.runId -ne $state.runId -or $m.scope -ne $state.scope -or $m.newAzureResources -ne $false -or $m.bootGuestsInThisPhase -ne $false -or $m.maximumVirtualDiskBytes -ne 1696GB -or $m.minimumFreeBytes -ne 200GB) { throw 'Guest phase exceeds approved scope' }
    $request = [Net.HttpWebRequest]::Create('http://169.254.169.254/metadata/instance/compute/resourceId?api-version=2021-02-01&format=text')
    $request.Proxy = $null; $request.Headers['Metadata'] = 'true'; $request.Timeout = 5000
    $response = $request.GetResponse()
    try { $reader = [IO.StreamReader]::new($response.GetResponseStream()); try { $vmId = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() } } finally { $response.Close() }
    if ($vmId -ine $m.azureVmResourceId) { throw 'Azure VM identity differs' }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
public static class LocalBoxGuestImageHeartbeat {
    static Timer timer; static string path; static int pid; static int busy;
    public static void Start(string directory, int processId) {
        path = Path.Combine(directory, "heartbeat.json"); pid = processId;
        timer = new Timer(_ => {
            if (Interlocked.Exchange(ref busy, 1) != 0) return;
            try {
                string temporary = path + ".tmp";
                File.WriteAllText(temporary, "{\"processId\":" + pid + ",\"atUtc\":\"" + DateTime.UtcNow.ToString("o") + "\"}", new UTF8Encoding(false));
                if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
            } catch { } finally { Interlocked.Exchange(ref busy, 0); }
        }, null, 0, 15000);
    }
    public static void Stop() { if (timer != null) timer.Dispose(); }
}
'@
    [LocalBoxGuestImageHeartbeat]::Start($root, $PID); $heartbeatStarted = $true
    $inspection = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-inputs-20261028-02\state.json' -Raw | ConvertFrom-Json
    if ($inspection.status -ne 'inspection-complete' -or @($inspection.result.media).Count -ne 2) { throw 'Complete image inspection missing' }
    foreach ($media in $m.media) {
        $observed = @($inspection.result.media | Where-Object kind -EQ $media.kind)
        if ($observed.Count -ne 1 -or $observed[0].sha256 -cne $media.sha256 -or @($observed[0].signatures | Where-Object status -NE 'Valid').Count -ne 0) { throw 'Pinned media inspection/signatures differ' }
        $selected = @($observed[0].images | Where-Object index -EQ $media.index)
        if ($selected.Count -ne 1 -or $selected[0].edition -cne $media.edition -or $selected[0].version -cne $media.version -or $selected[0].architecture -ne 9 -or $selected[0].installationType -cne 'Server Core') { throw 'Selected OS image metadata differs' }
    }
    Save-GuestImageState 'live-prechecks'
    $storage = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\storage-20261028-01\state.json' -Raw | ConvertFrom-Json
    $volume = Get-Volume -DriveLetter V
    if ($storage.status -ne 'storage-complete' -or $volume.HealthStatus.ToString() -ne 'Healthy' -or $volume.FileSystem -ne 'NTFS' -or $volume.SizeRemaining -lt ($m.maximumVirtualDiskBytes + $m.minimumFreeBytes + 4GB)) { throw 'Approved storage capacity/health differs' }
    if (@(Get-VM).Count -ne 0 -or (Test-Path $guestRoot) -or (Get-HgsGuardian -Name 'LB-LocalGuardian' -ErrorAction SilentlyContinue)) { throw 'Existing VM/image/guardian conflicts with new phase' }
    $network = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\local-network-20261028-01\state.json' -Raw | ConvertFrom-Json
    if ($network.status -ne 'local-network-created' -or (Get-VMSwitch -Name LB-Fabric).Id.ToString() -cne $network.switchId -or @(Get-NetNat).Count -ne 1 -or (Get-NetNat -Name LB-NAT).InternalIPInterfaceAddressPrefix -cne '10.64.0.0/20' -or @(Get-NetIPAddress -IPAddress '10.200.16.4' -AddressFamily IPv4).Count -ne 1) { throw 'Approved live network differs' }
    if (-not (Get-MpComputerStatus).RealTimeProtectionEnabled) { throw 'Defender is not active' }
    Save-GuestImageState 'load-pinned-helper-bundle'
    $bundle = Get-Content (Join-Path $root 'bundle.json') -Raw | ConvertFrom-Json
    $expectedNames = @('smal-guest-secret-functions.ps1', 'smal-guest-image-functions.ps1', 'smal-guest-vm-functions.ps1')
    if ($bundle.schemaVersion -ne 1 -or @($bundle.files).Count -ne 3 -or @(Compare-Object $expectedNames @($bundle.files | ForEach-Object name)).Count -ne 0) { throw 'Unexpected helper bundle' }
    foreach ($item in $bundle.files) {
        $path = Join-Path $root $item.name
        $bytes = [Convert]::FromBase64String($item.base64)
        $file = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $file.Write($bytes, 0, $bytes.Length) } finally { $file.Dispose() }
        if ((Get-FileHash $path).Hash -cne $item.sha256) { throw 'Helper source integrity differs' }
        . $path
    }
    Save-GuestImageState 'create-protected-image-root'
    foreach ($parent in @('V:\AzureLocalBox', 'V:\AzureLocalBox\Guests')) {
        if (Test-Path $parent) { if ((Get-Item $parent).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Guest parent is a reparse point' } }
        else { $null = New-Item $parent -ItemType Directory }
    }
    $null = New-Item $guestRoot -ItemType Directory
    $acl = Get-Acl $root
    Set-Acl -Path $guestRoot -AclObject $acl
    $secretDirectory = Join-Path $root 'secrets'; $null = New-Item $secretDirectory -ItemType Directory
    Save-GuestImageState 'create-per-role-dpapi-secrets'
    foreach ($role in @('dc-bootstrap', 'dc-admin', 'directory-recovery', 'deployment-user', 'node01-bootstrap', 'node01-admin', 'node02-bootstrap', 'node02-admin')) {
        $value = New-LabGuestSecretText
        Write-LabGuestSecret -SecretDirectory $secretDirectory -Role $role -Value $value
        $value = $null
    }
    $state.secretsCreated = $true
    $roles = @{ 'LB-DC01' = 'dc-bootstrap'; 'LB-NODE01' = 'node01-bootstrap'; 'LB-NODE02' = 'node02-bootstrap' }
    foreach ($media in $m.media) {
        Save-GuestImageState ($media.kind + '-verify-before-apply')
        if ((Get-Item -LiteralPath $media.path).Length -ne $media.lengthBytes -or (Get-DiskImage -ImagePath $media.path).Attached) { throw 'Media file/attachment differs' }
        $lease = [IO.FileStream]::new($media.path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 1MB, [IO.FileOptions]::SequentialScan)
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $actualHash = [BitConverter]::ToString($hash.ComputeHash($lease)).Replace('-', '') } finally { $hash.Dispose() }
        if ($actualHash -cne $media.sha256) { throw 'Media checksum differs immediately before apply' }
        Save-GuestImageState ($media.kind + '-read-only-mount')
        $mounted = Mount-DiskImage -ImagePath $media.path -Access ReadOnly -PassThru; $mountedPath = $media.path
        $volumes = @($mounted | Get-Volume)
        if ($volumes.Count -ne 1 -or -not $volumes[0].DriveLetter) { throw 'Mounted ISO volume mapping differs' }
        $wim = $volumes[0].DriveLetter + ':\sources\install.wim'
        foreach ($name in $media.guests) {
            if (-not $roles.ContainsKey($name)) { throw 'Unapproved image guest' }
            $directory = Join-Path $guestRoot $name; $null = New-Item $directory -ItemType Directory
            $secure = Read-LabGuestSecureSecret -SecretDirectory $secretDirectory -Role $roles[$name]
            $pointer = [IntPtr]::Zero
            try {
                $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
                $clear = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
                $xml = New-LabGuestUnattendXml -ComputerName $name -BootstrapSecret $clear
                $image = New-LabGuestOsImage -VmName $name -OsDiskPath (Join-Path $directory 'OS.vhdx') -ImagePath $wim -ImageIndex $media.index -UnattendXml $xml -Checkpoint { param($phase) Save-GuestImageState $phase }
                $state.images += $image
            } finally {
                if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
                $secure.Dispose(); $clear = $null; $xml = $null
            }
            if ((Get-Volume -DriveLetter V).SizeRemaining -lt $m.minimumFreeBytes) { throw 'Guest storage free-space floor reached' }
        }
        Save-GuestImageState ($media.kind + '-dismount-iso')
        Dismount-DiskImage -ImagePath $mountedPath; $mountedPath = $null
        $lease.Dispose(); $lease = $null
    }
    Save-GuestImageState 'create-local-guardian'
    $null = New-HgsGuardian -Name 'LB-LocalGuardian' -GenerateCertificates
    $state.guardianCreated = $true
    foreach ($name in @('LB-DC01', 'LB-NODE01', 'LB-NODE02')) {
        $state.virtualMachines += New-LabGuestVm -VmName $name -OsDiskPath (Join-Path (Join-Path $guestRoot $name) 'OS.vhdx') -GuardianName 'LB-LocalGuardian' -Checkpoint { param($phase) Save-GuestImageState $phase }
    }
    if ($state.virtualMachines.Count -ne 3 -or @(Get-VM | Where-Object State -NE 'Off').Count -ne 0) { throw 'Guest creation result differs' }
    $state.status = 'guests-created-off'; Save-GuestImageState 'images-and-vms-created-bootstrap-cleanup-pending'
} catch {
    if ($state) { $state.status = 'failed-inspect-before-resume'; $state.errorType = $_.Exception.GetType().Name; $state.errorLine = $_.InvocationInfo.ScriptLineNumber; try { Save-GuestImageState $state.phase } catch { } }
    exit 1
} finally {
    if ($heartbeatStarted) { [LocalBoxGuestImageHeartbeat]::Stop() }
    if ($mountedPath) { Dismount-DiskImage -ImagePath $mountedPath | Out-Null }
    if ($lease) { $lease.Dispose() }
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
