# Fixed read-only guest preflight. Run Command executes as SYSTEM, not a guest login.
# No installation, disk writes, credentials, policy changes or bootstrap invocation.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('System', 'Network')]
    [string]$Section
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$result = [ordered]@{
    section = $Section
    atUtc = (Get-Date).ToUniversalTime().ToString('o')
    computer = $env:COMPUTERNAME
    authenticatedGuestLogin = $false
}

if ($Section -eq 'System') {
    $os = Get-CimInstance Win32_OperatingSystem
    $system = Get-CimInstance Win32_ComputerSystem
    $result.os = @{ version = $os.Version; build = $os.BuildNumber; lastBootUtc = $os.LastBootUpTime.ToUniversalTime().ToString('o') }
    $result.capacity = @{ logicalCpu = $system.NumberOfLogicalProcessors; memoryGiB = [math]::Round($system.TotalPhysicalMemory / 1GB); hypervisorPresent = $system.HypervisorPresent }
    $result.cpu = @(Get-CimInstance Win32_Processor | Select-Object -Property VMMonitorModeExtensions, VirtualizationFirmwareEnabled, SecondLevelAddressTranslationExtensions)
    $result.features = @(Get-WindowsFeature -Name Hyper-V, Hyper-V-PowerShell, Containers | ForEach-Object { @{ name = $_.Name; state = $_.InstallState.ToString() } })
    $result.disks = @(Get-Disk | Sort-Object Number | ForEach-Object { @{ number = $_.Number; gib = [math]::Round($_.Size / 1GB); style = $_.PartitionStyle.ToString(); boot = $_.IsBoot; system = $_.IsSystem; offline = $_.IsOffline; readOnly = $_.IsReadOnly } })
    $result.volumes = @(Get-Volume | Where-Object DriveLetter | ForEach-Object { @{ letter = $_.DriveLetter.ToString(); fs = $_.FileSystem; sizeGiB = [math]::Round($_.Size / 1GB); freeGiB = [math]::Round($_.SizeRemaining / 1GB) } })
    $result.dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object ServerAddresses | ForEach-Object { @{ interface = $_.InterfaceAlias; servers = @($_.ServerAddresses) } })
    $result.pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    $result.localBoxPathExists = Test-Path 'C:\LocalBox'
    try {
        $mp = Get-MpComputerStatus
        $result.defender = @{ antivirusEnabled = $mp.AntivirusEnabled; realTimeProtection = $mp.RealTimeProtectionEnabled }
    } catch { $result.defender = @{ errorType = $_.Exception.GetType().Name } }
    $result.winrmRunning = (Get-Service WinRM).Status.ToString() -eq 'Running'
    $sshCapability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    $sshService = Get-Service sshd -ErrorAction SilentlyContinue
    $result.ssh = @{ capability = $sshCapability.State.ToString(); service = $(if ($sshService) { $sshService.Status.ToString() } else { 'absent' }); configExists = (Test-Path 'C:\ProgramData\ssh\sshd_config'); adminKeysExist = (Test-Path 'C:\ProgramData\ssh\administrators_authorized_keys') }
    # Read only. Do not enable WinRM or configure TrustedHosts/CredSSP.
    try { $result.trustedHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value } catch { $result.trustedHosts = 'unavailable' }
} else {
    # HEAD only, no redirect following, no credentials and normal OS TLS validation.
    # GitHub release hosts are tested because the legacy PowerShell installer needs
    # them, but they are absent from Entlz's exact HTTPS list. Do not widen policy.
    $urls = @(
        'https://login.microsoftonline.com/c6e67968-af25-4557-ab8b-06b693048d3b/v2.0/.well-known/openid-configuration',
        'https://management.azure.com/',
        'https://www.powershellgallery.com/api/v2/',
        'https://raw.githubusercontent.com/Azure/arc_jumpstart/main/README.md',
        'https://jumpstartprodsg.blob.core.windows.net/jslocal/localbox/prod/AzLocal2604.sha256',
        'https://jumpstartprodsg.blob.core.windows.net/hcibox23h2/WinServerApril2024.sha256',
        'https://github.com/PowerShell/PowerShell/releases',
        'https://release-assets.githubusercontent.com/'
    )
    $result.web = @(foreach ($url in $urls) {
        $uri = [uri]$url
        $row = [ordered]@{ host = $uri.DnsSafeHost; dns = $false; http = $null; tlsHttpResponse = $false }
        try {
            $addresses = @(Resolve-DnsName -Name $uri.DnsSafeHost -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object IPAddress | Select-Object -ExpandProperty IPAddress)
            $row.dns = $addresses.Count -gt 0
            $request = [System.Net.HttpWebRequest]::Create($uri)
            $request.Method = 'HEAD'
            $request.AllowAutoRedirect = $false
            $request.UseDefaultCredentials = $false
            $request.Timeout = 10000
            $request.ReadWriteTimeout = 10000
            $response = $null
            try { $response = $request.GetResponse() }
            catch [System.Net.WebException] {
                if ($_.Exception.Response) { $response = $_.Exception.Response }
                else { $row.error = $_.Exception.Status.ToString() }
            }
            if ($response) {
                try {
                    $row.http = [int]$response.StatusCode
                    $row.tlsHttpResponse = $true
                    if ($row.http -ge 300 -and $row.http -lt 400) {
                        $location = $response.Headers['Location']
                        if ($location) { $row.redirectHost = ([uri]::new($uri, $location)).DnsSafeHost }
                    }
                } finally { $response.Close() }
            }
        } catch { $row.error = $_.Exception.GetType().Name }
        [pscustomobject]$row
    })
    try {
        $result.centralDns = @(Resolve-DnsName -Name login.microsoftonline.com -Server 10.204.0.4 -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object IPAddress).Count -gt 0
    } catch { $result.centralDns = $false }
    $udp = $null
    try {
        $udp = [System.Net.Sockets.UdpClient]::new()
        $udp.Client.ReceiveTimeout = 8000
        $udp.Connect('time.windows.com', 123)
        [byte[]]$packet = New-Object byte[] 48
        $packet[0] = 0x23 # NTPv4 client, no clock adjustment.
        $stamp = [uint64]([datetime]::UtcNow - [datetime]'1900-01-01').TotalSeconds
        for ($i = 0; $i -lt 4; $i++) { $packet[40 + $i] = [byte](($stamp -shr (24 - 8 * $i)) -band 255) }
        $null = $udp.Send($packet, $packet.Length)
        $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $reply = $udp.Receive([ref]$remote)
        $originMatches = $reply.Length -ge 48
        if ($originMatches) {
            for ($i = 0; $i -lt 8; $i++) { if ($reply[24 + $i] -ne $packet[40 + $i]) { $originMatches = $false } }
        }
        $result.ntp = @{ response = ($originMatches -and (($reply[0] -band 7) -eq 4) -and (($reply[0] -shr 6) -ne 3) -and $reply[1] -ge 1 -and $reply[1] -le 15); remoteIp = $remote.Address.ToString(); clockAdjusted = $false }
    } catch { $result.ntp = @{ response = $false; errorType = $_.Exception.GetType().Name; clockAdjusted = $false } }
    finally { if ($udp) { $udp.Dispose() } }
    $result.limitations = 'HEAD/DNS/NTP only. No WebSocket, image pull, nested traffic, TLS inspection audit or platform readiness claim.'
}

$json = $result | ConvertTo-Json -Depth 7 -Compress
if ($json.Length -gt 3800) { throw 'Preflight output exceeds Run Command evidence budget' }
Write-Output $json
