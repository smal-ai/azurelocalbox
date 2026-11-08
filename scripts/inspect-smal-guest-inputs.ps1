# Read-only host inspection and temporary read-only ISO mounts, now approved.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ne 'LocalBox-Client') { throw 'Unexpected target' }
$media = @(
    @{ kind = 'azure-local'; path = 'C:\ProgramData\AzureLocalBox\Artifacts\2610\AzureLocal24H2.26100.32230.LCM.12.2610.0.3098.x64.en-us.iso'; length = 7491864576L; sha256 = '317330754A6DAC6F42C1BE40EB780E0959C6C3F7670B33D94556964CDCBC9E89' },
    @{ kind = 'evaluation-dc'; path = 'C:\ProgramData\AzureLocalBox\Bootstrap\eval-media-20261028-01\WindowsServer2025Evaluation.26100.32230.x64.en-us.iso'; length = 8152356864L; sha256 = '7B052573BA7894C9924E3E87BA732CCD354D18CB75A883EFA9B900EA125BFD51' }
)
$result = @{ atUtc = (Get-Date).ToUniversalTime().ToString('o'); computer = $env:COMPUTERNAME; virtualMachines = @(Get-VM | Select-Object Name, Id, State); switches = @(Get-VMSwitch | Select-Object Name, Id, SwitchType); nat = @(Get-NetNat | Select-Object Name, InternalIPInterfaceAddressPrefix, ExternalIPInterfaceAddressPrefix); ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin); defaultRoutes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Select-Object InterfaceAlias, NextHop, RouteMetric); volume = (Get-Volume -DriveLetter V | Select-Object DriveLetter, Size, SizeRemaining, HealthStatus); defender = (Get-MpComputerStatus).RealTimeProtectionEnabled; media = @(); clusterBootstrapComplete = $false }
if (Get-Command Get-HnsNetwork -ErrorAction SilentlyContinue) { $result.hnsNetworks = @(Get-HnsNetwork | Select-Object Name, Type, Id) } else { $result.hnsCmdletAvailable = $false }
foreach ($item in $media) {
    $file = Get-Item -LiteralPath $item.path
    if ($file.Length -ne $item.length -or (Get-FileHash -LiteralPath $item.path).Hash -cne $item.sha256) { throw 'Approved media content differs' }
    $existing = Get-DiskImage -ImagePath $item.path
    if ($existing.Attached) { throw 'Media already attached; inspect ownership before proceeding' }
    $mounted = $null
    try {
        $mounted = Mount-DiskImage -ImagePath $item.path -Access ReadOnly -PassThru
        $volumes = @($mounted | Get-Volume)
        if ($volumes.Count -ne 1 -or -not $volumes[0].DriveLetter) { throw 'Unexpected ISO volume mapping' }
        $base = $volumes[0].DriveLetter + ':\'
        $wim = Join-Path $base 'sources\install.wim'
        if (-not (Test-Path -LiteralPath $wim)) { throw 'Expected install.wim absent' }
        $images = @(Get-WindowsImage -ImagePath $wim | ForEach-Object {
            $detail = Get-WindowsImage -ImagePath $wim -Index $_.ImageIndex
            @{ index = $detail.ImageIndex; name = $detail.ImageName; architecture = $detail.Architecture; version = $detail.Version.ToString(); edition = $detail.EditionId; installationType = $detail.InstallationType; sizeBytes = $detail.ImageSize }
        })
        $signatures = @('setup.exe', 'efi\boot\bootx64.efi') | ForEach-Object {
            $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $base $_)
            @{ path = $_; status = $signature.Status.ToString(); signer = $(if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }) }
        }
        $result.media += @{ kind = $item.kind; lengthBytes = $file.Length; sha256 = $item.sha256; publisherHashAvailable = ($item.kind -eq 'azure-local'); images = $images; signatures = @($signatures) }
    } finally { if ($mounted) { Dismount-DiskImage -ImagePath $item.path | Out-Null } }
}
$result | ConvertTo-Json -Depth 7 -Compress
