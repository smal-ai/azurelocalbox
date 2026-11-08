# Library only. PowerShell Direct over the immediate host, never network remoting.
function Wait-LabGuestSession {
    param([guid]$VmId, [string]$ExpectedName, [pscredential]$Credential, [string]$PreviousBootUtc)
    if ($ExpectedName -notin @('LB-DC01', 'LB-NODE01', 'LB-NODE02') -or -not $Credential) { throw 'Unapproved guest session target' }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 1800) {
        $session = $null; $ready = $null
        try {
            $session = New-PSSession -VMId $VmId -Credential $Credential -ErrorAction Stop
            $ready = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                $setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
                $image = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'
                @{ computer = $env:COMPUTERNAME; imageState = $image.ImageState; setupInProgress = $setup.SystemSetupInProgress; bootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') }
            }
        } catch {
            if ($_.CategoryInfo.Category.ToString() -in @('AuthenticationError', 'SecurityError') -or $_.FullyQualifiedErrorId -match 'InvalidCredential|AccessDenied|LogonFailure') {
                if ($session) { Remove-PSSession -Session $session }
                throw 'Guest authentication failed. Inspect before another attempt to avoid account lockout.'
            }
        }
        if ($ready) {
            if ($ready.computer -cne $ExpectedName) { Remove-PSSession -Session $session; throw 'Guest computer identity differs' }
            if ($ready.imageState -eq 'IMAGE_STATE_COMPLETE' -and $ready.setupInProgress -eq 0 -and (-not $PreviousBootUtc -or $ready.bootUtc -cne $PreviousBootUtc)) { return $session }
        }
        if ($session) { Remove-PSSession -Session $session }
        Start-Sleep -Seconds 10
    }
    throw 'Guest setup/session deadline reached. Inspect rather than restarting installation.'
}

function Set-LabGuestNetwork {
    param([System.Management.Automation.Runspaces.PSSession]$Session, [string]$VmName, [object[]]$Adapters)
    $addresses = @{ 'LB-DC01' = '10.64.0.10'; 'LB-NODE01' = '10.64.0.11'; 'LB-NODE02' = '10.64.0.12' }
    if (-not $addresses.ContainsKey($VmName)) { throw 'Unapproved guest network target' }
    return Invoke-Command -Session $Session -ArgumentList $VmName, $addresses[$VmName], $Adapters -ErrorAction Stop -ScriptBlock {
        param($ExpectedName, $Address, $Mapping)
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -cne $ExpectedName) { throw 'Guest identity/protection differs' }
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $protected = $false
            try { $protected = (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled -and @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object Enabled -NE $true).Count -eq 0 } catch { }
            if ($protected) { break }
            if ($wait.Elapsed.TotalSeconds -gt 180) { throw 'Guest identity/protection differs' }
            Start-Sleep -Seconds 3
        }
        $required = if ($ExpectedName -eq 'LB-DC01') { @('MGMT1') } else { @('MGMT1', 'MGMT2', 'STORAGEA', 'STORAGEB') }
        if (@($Mapping).Count -ne $required.Count -or @(Compare-Object $required @($Mapping | ForEach-Object Name)).Count -ne 0) { throw 'Guest adapter profile differs' }
        $macs = @($Mapping | ForEach-Object { $_.MacAddress.Replace('-', '').Replace(':', '').ToUpperInvariant() })
        if (@($macs | Select-Object -Unique).Count -ne $required.Count -or @($macs | Where-Object { $_ -notmatch '^[0-9A-F]{12}$' -or $_ -eq '000000000000' }).Count -ne 0) { throw 'Host MAC mapping missing or ambiguous' }
        foreach ($expected in $Mapping) {
            $mac = $expected.MacAddress.Replace('-', '').Replace(':', '').ToUpperInvariant()
            $match = @(Get-NetAdapter -Physical | Where-Object { $_.MacAddress.Replace('-', '').Replace(':', '').ToUpperInvariant() -ceq $mac })
            if ($match.Count -ne 1) { throw 'Guest adapter MAC identity differs' }
            $adapter = $match[0]
            if ($adapter.Name -cne $expected.Name) {
                if (Get-NetAdapter -Name $expected.Name -ErrorAction SilentlyContinue) { throw 'Guest adapter rename conflicts' }
                Rename-NetAdapter -InputObject $adapter -NewName $expected.Name
            }
            Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled
            if ($expected.Name -ne 'MGMT1') {
                Set-DnsClient -InterfaceIndex $adapter.ifIndex -RegisterThisConnectionsAddress $false
                if (@(Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Unexpected non-management gateway' }
                if (@(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -NotLike '169.254.*').Count -gt 0) { throw 'Non-management address needs the reviewed ATC plan' }
            }
        }
        $management = Get-NetAdapter -Name MGMT1
        $existing = @(Get-NetIPAddress -InterfaceIndex $management.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' })
        if ($existing.Count -gt 0 -and ($existing.Count -ne 1 -or $existing[0].IPAddress -cne $Address -or $existing[0].PrefixLength -ne 24)) { throw 'Guest management IP already conflicts' }
        if ($existing.Count -eq 0) { $null = New-NetIPAddress -InterfaceIndex $management.ifIndex -IPAddress $Address -PrefixLength 24 -DefaultGateway '10.64.0.1' }
        Set-DnsClientServerAddress -InterfaceIndex $management.ifIndex -ServerAddresses '10.64.0.10'
        return @{ computer = $env:COMPUTERNAME; managementIp = $Address; gateway = '10.64.0.1'; dns = '10.64.0.10'; guestFirewallEnabled = $true; defenderEnabled = $true; adapterCount = $required.Count }
    }
}

function Install-LabDomainForest {
    param([System.Management.Automation.Runspaces.PSSession]$Session, [Security.SecureString]$RecoverySecret)
    return Invoke-Command -Session $Session -ArgumentList $RecoverySecret -ErrorAction Stop -ScriptBlock {
        param($RecoveryValue)
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -cne 'LB-DC01' -or (Get-CimInstance Win32_ComputerSystem).DomainRole -ne 2) { throw 'New forest target differs' }
        $null = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
        Import-Module ADDSDeployment
        $command = Get-Command Install-ADDSForest
        foreach ($parameter in @('ForestMode', 'DomainMode')) {
            if ('WinThreshold' -notin $command.Parameters[$parameter].ParameterType.GetEnumNames()) { throw 'Selected AD functional level unavailable' }
        }
        $null = Install-ADDSForest -DomainName 'ad.localbox.test' -DomainNetbiosName 'LOCALBOX' -ForestMode WinThreshold -DomainMode WinThreshold -InstallDns -SafeModeAdministratorPassword $RecoveryValue -NoRebootOnCompletion:$true -Force:$true
        return @{ forestInstallationReturned = $true; guestRebootRequired = $true; bootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') }
    }
}

function Complete-LabGuestBootstrapSecret {
    param([System.Management.Automation.Runspaces.PSSession]$Session, [string]$VmName, [Security.SecureString]$BootstrapSecret, [Security.SecureString]$FinalSecret)
    if ($VmName -notin @('LB-DC01', 'LB-NODE01', 'LB-NODE02')) { throw 'Unapproved cleanup target' }
    return Invoke-Command -Session $Session -ArgumentList $VmName, $BootstrapSecret, $FinalSecret -ErrorAction Stop -ScriptBlock {
        param($ExpectedName, $OldValue, $NewValue)
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -cne $ExpectedName) { throw 'Guest cleanup identity differs' }
        $pointer = [IntPtr]::Zero
        $removed = 0; $logsNeedReview = $false; $answersNeedReview = $false; $unreadableLogs = 0; $unreadableAnswers = 0
        function Read-SharedSetupText {
            param([string]$Path)
            $stream = $null; $reader = $null
            try {
                $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                if ($stream.Length -gt 128MB) { throw 'Setup file exceeds inspection cap' }
                $reader = [IO.StreamReader]::new($stream)
                return $reader.ReadToEnd()
            } finally { if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() } }
        }
        try {
            $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($OldValue)
            $oldText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
            $files = @()
            foreach ($directory in @('C:\Windows\Panther', 'C:\Windows\System32\Sysprep')) {
                if (-not (Test-Path -LiteralPath $directory)) { continue }
                if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Guest setup path is a reparse point' }
                $files += @(Get-ChildItem -LiteralPath $directory -Filter '*unattend*.xml' -Recurse -File)
            }
            if (Test-Path -LiteralPath 'C:\Unattend.xml') { $files += Get-Item -LiteralPath 'C:\Unattend.xml' }
            foreach ($file in $files) {
                if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Guest answer file is a reparse point' }
                try { $text = Read-SharedSetupText $file.FullName } catch { $answersNeedReview = $true; $unreadableAnswers++; continue }
                # Delete only files attributable to our own run or bootstrap value.
                if ($text.Contains('AzureLocalBox local-guests-20261028-01') -or $text.Contains($oldText)) {
                    try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop } catch { $answersNeedReview = $true }
                    if (Test-Path -LiteralPath $file.FullName) { $answersNeedReview = $true } else { $removed++ }
                }
            }
            # Inspect setup logs without deleting or rewriting their history. Even
            # after rotation, a match blocks a clean bootstrap/registration claim.
            foreach ($file in @(Get-ChildItem -LiteralPath 'C:\Windows\Panther' -Filter '*.log' -Recurse -File -ErrorAction SilentlyContinue)) {
                if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Guest setup log is a reparse point' }
                try { if ((Read-SharedSetupText $file.FullName).Contains($oldText)) { $logsNeedReview = $true } }
                catch { $logsNeedReview = $true; $unreadableLogs++ }
            }
            if ($ExpectedName -eq 'LB-DC01') {
                Import-Module ActiveDirectory
                $domain = Get-ADDomain -Identity 'ad.localbox.test'
                Set-ADAccountPassword -Identity ($domain.DomainSID.ToString() + '-500') -Reset -NewPassword $NewValue
            } else { Set-LocalUser -Name Administrator -Password $NewValue }
            return @{ computer = $env:COMPUTERNAME; ownedAnswerFilesRemoved = $removed; credentialRotationRequested = $true; setupLogsNeedReview = $logsNeedReview; answerFileCleanupNeedsReview = $answersNeedReview; unreadableSetupLogs = $unreadableLogs; unreadableAnswerCandidates = $unreadableAnswers; secureErasureClaimed = $false }
        } finally {
            if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
            $oldText = $null; $text = $null
        }
    }
}

function Test-LabGuestConnectivity {
    param([System.Management.Automation.Runspaces.PSSession]$Session)
    return Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -notin @('LB-DC01', 'LB-NODE01', 'LB-NODE02')) { throw 'Unapproved connectivity target' }
        $result = @{ computer = $env:COMPUTERNAME; atUtc = (Get-Date).ToUniversalTime().ToString('o'); domainSrv = $false; privateDnsNormal = $false; privateDnsTcp = $false; publicHeadStatus = $null; privateHeadStatus = $null; ntpResponse = $false; clockAdjustedByProbe = $false; authenticatedPrivateDataAccessTested = $false }
        try { $result.domainSrv = @(Resolve-DnsName -Name '_ldap._tcp.dc._msdcs.ad.localbox.test' -Type SRV -Server '10.64.0.10' -DnsOnly -QuickTimeout -ErrorAction Stop).Count -gt 0 } catch { }
        try { $result.privateDnsNormal = @('10.200.17.4') -contains (Resolve-DnsName -Name 'kv-smal-san-1.vault.azure.net' -Type A -Server '10.64.0.10' -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object IPAddress | Select-Object -First 1 -ExpandProperty IPAddress) } catch { }
        try { $result.privateDnsTcp = @('10.200.17.4') -contains (Resolve-DnsName -Name 'kv-smal-san-1.vault.azure.net' -Type A -Server '10.64.0.10' -DnsOnly -TcpOnly -QuickTimeout -ErrorAction Stop | Where-Object IPAddress | Select-Object -First 1 -ExpandProperty IPAddress) } catch { }
        foreach ($probe in @(@{ uri = 'https://login.microsoftonline.com/organizations/v2.0/.well-known/openid-configuration'; key = 'publicHeadStatus' }, @{ uri = 'https://kv-smal-san-1.vault.azure.net/'; key = 'privateHeadStatus' })) {
            $request = [Net.HttpWebRequest]::Create($probe.uri)
            $request.Method = 'HEAD'; $request.AllowAutoRedirect = $false; $request.UseDefaultCredentials = $false; $request.Timeout = 20000
            try { $response = $request.GetResponse(); try { $result[$probe.key] = [int]$response.StatusCode } finally { $response.Close() } }
            catch [Net.WebException] { if ($_.Exception.Response) { $result[$probe.key] = [int]$_.Exception.Response.StatusCode; $_.Exception.Response.Close() } }
        }
        $udp = $null
        try {
            $udp = [Net.Sockets.UdpClient]::new(); $udp.Client.ReceiveTimeout = 8000; $udp.Connect('time.windows.com', 123)
            [byte[]]$packet = New-Object byte[] 48; $packet[0] = 0x23
            $stamp = [uint64]([datetime]::UtcNow - [datetime]'1900-01-01').TotalSeconds
            for ($i = 0; $i -lt 4; $i++) { $packet[40 + $i] = [byte](($stamp -shr (24 - 8 * $i)) -band 255) }
            $null = $udp.Send($packet, $packet.Length)
            $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0); $reply = $udp.Receive([ref]$remote)
            $matches = $reply.Length -ge 48
            if ($matches) { for ($i = 0; $i -lt 8; $i++) { if ($reply[24 + $i] -ne $packet[40 + $i]) { $matches = $false } } }
            $result.ntpResponse = $matches -and (($reply[0] -band 7) -eq 4) -and (($reply[0] -shr 6) -ne 3) -and $reply[1] -ge 1 -and $reply[1] -le 15
        } catch { } finally { if ($udp) { $udp.Dispose() } }
        $result.transportChecksPassed = $result.domainSrv -and $result.privateDnsNormal -and $result.privateDnsTcp -and $result.publicHeadStatus -eq 200 -and $null -ne $result.privateHeadStatus -and $result.ntpResponse
        return $result
    }
}

function Get-LabGuestClockEvidence {
    param([System.Management.Automation.Runspaces.PSSession]$Session)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $before = [datetime]::UtcNow
        $guest = Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
            @{ utcNow = [datetime]::UtcNow.ToString('o'); timeServiceRunning = (Get-Service w32time).Status.ToString() -eq 'Running'; timeSource = ((& w32tm.exe /query /source 2>$null) -join ' ').Trim() }
        }
        $after = [datetime]::UtcNow
        $guestUtc = [datetime]::Parse($guest.utcNow, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $middle = $before.AddTicks([long](($after - $before).Ticks / 2))
        $offset = ($guestUtc - $middle).TotalSeconds
        $ready = $guest.timeServiceRunning -and $guest.timeSource -like '*time.windows.com*' -and [math]::Abs($offset) -le 60
        $result = @{ hostUtc = $middle.ToString('o'); guestUtc = $guest.utcNow; observedOffsetSeconds = $offset; allowedOffsetSeconds = 60; timeServiceRunning = $guest.timeServiceRunning; timeSource = $guest.timeSource; selectedClockChecksPassed = [bool]$ready; clockManuallyAdjusted = $false }
        if ($ready -or $timer.Elapsed.TotalSeconds -gt 600) { return $result }
        Start-Sleep -Seconds 5
    }
}
