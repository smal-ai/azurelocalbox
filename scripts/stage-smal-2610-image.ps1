# Owner-approved download/checksum stage only. Never mount, install or boot the ISO.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$uri = 'https://azurestackreleases.download.prss.microsoft.com/dbazure/AzureLocal/Hci24H2/ComposedImage/Deploy/12.2610.0.3098/AzureLocal24H2.26100.32230.LCM.12.2610.0.3098.x64.en-us.iso'
$expectedHash = '317330754A6DAC6F42C1BE40EB780E0959C6C3F7670B33D94556964CDCBC9E89'
$expectedBytes = [long]7491864576
$expectedEtag = '"0xFC8DB909792CCF30973111607E1F86D3CFB3ED60AC1E9879D6614872E59150EC"'
$directory = 'C:\ProgramData\AzureLocalBox\Artifacts\2610'
$iso = Join-Path $directory 'AzureLocal24H2.26100.32230.LCM.12.2610.0.3098.x64.en-us.iso'
$partial = $iso + '.partial'
$marker = Join-Path $directory 'staging.json'
$downloaded = $false
if ($env:COMPUTERNAME -ne 'LocalBox-Client') { throw 'Unexpected target' }
if (-not (Get-NetIPAddress -IPAddress 10.200.16.4 -AddressFamily IPv4 -ErrorAction SilentlyContinue)) { throw 'Expected private host IP absent' }
if ((Get-MpComputerStatus).RealTimeProtectionEnabled -ne $true) { throw 'Expected Defender protection absent' }
$dataBefore = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem } | Sort-Object Number | ForEach-Object { @{ number = $_.Number; style = $_.PartitionStyle.ToString(); size = $_.Size } }) | ConvertTo-Json -Compress

if (Test-Path $marker) {
    $previous = Get-Content $marker -Raw | ConvertFrom-Json
    if ($previous.status -ne 'complete' -or -not (Test-Path $iso) -or (Test-Path $partial)) { throw 'Previous image operation is incomplete. Inspect instead of retrying.' }
} else {
    if ((Test-Path $directory) -or (Test-Path $iso) -or (Test-Path $partial)) { throw 'Unowned image staging path exists. Preserve it and inspect.' }
    if ((Get-Volume -DriveLetter C).SizeRemaining -lt ($expectedBytes + 20GB)) { throw 'Insufficient free OS volume space' }
    New-Item -ItemType Directory -Path $directory | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = [Security.Principal.SecurityIdentifier]::new($sid)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Set-Acl -Path $directory -AclObject $acl
    @{ status = 'pending'; uri = $uri; expectedHash = $expectedHash; expectedBytes = $expectedBytes; atUtc = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content $marker -Encoding ASCII
    $response = $null
    $inputStream = $null
    $outputStream = $null
    $written = [long]0
    try {
        $request = [Net.HttpWebRequest]::Create($uri)
        $request.Method = 'GET'
        $request.AllowAutoRedirect = $false
        $request.UseDefaultCredentials = $false
        $request.Headers['If-Match'] = $expectedEtag
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 120000
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200 -or $response.ContentLength -ne $expectedBytes -or $response.Headers['ETag'] -ne $expectedEtag) { throw 'Image metadata changed from the reviewed pin' }
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($partial, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        [byte[]]$buffer = New-Object byte[] 1048576
        while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($timer.Elapsed.TotalSeconds -gt 1200 -or ($written + $count) -gt $expectedBytes) { throw 'Image transfer exceeded the reviewed time/byte budget' }
            $outputStream.Write($buffer, 0, $count)
            $written += $count
        }
        $outputStream.Dispose(); $outputStream = $null
        if ($written -ne $expectedBytes -or (Get-FileHash $partial -Algorithm SHA256).Hash -ne $expectedHash) { throw 'Downloaded ISO length/checksum differs from publisher metadata' }
        # Same-directory move only after verification, never overwrite a final file.
        [IO.File]::Move($partial, $iso)
        @{ status = 'complete'; uri = $uri; sha256 = $expectedHash; bytes = $written; atUtc = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content $marker -Encoding ASCII
        $downloaded = $true
    } catch {
        @{ status = 'failed-inspect-before-retry'; receivedBytes = $written; errorType = $_.Exception.GetType().Name; atUtc = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content $marker -Encoding ASCII
        throw
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Close() }
    }
}
$file = Get-Item $iso
$actualHash = (Get-FileHash $iso -Algorithm SHA256).Hash
if ($file.Length -ne $expectedBytes -or $actualHash -ne $expectedHash) { throw 'Staged ISO no longer matches publisher pin' }
$dataAfter = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem } | Sort-Object Number | ForEach-Object { @{ number = $_.Number; style = $_.PartitionStyle.ToString(); size = $_.Size } }) | ConvertTo-Json -Compress
if ($dataBefore -ne $dataAfter) { throw 'Data disk inventory changed. Stop.' }
[ordered]@{
    computer = $env:COMPUTERNAME
    atUtc = (Get-Date).ToUniversalTime().ToString('o')
    stagingStatus = 'complete-sha256-verified'
    downloadedThisOperation = $downloaded
    solutionVersion = '12.2610.1004.41'
    composedImageVersion = '12.2610.0.3098'
    iso = $iso
    bytes = $file.Length
    sha256 = $actualHash
    dataDiskInventoryUnchanged = $true
    mountedOrExecuted = $false
    nestedVmCreated = $false
    platformRegistrationPerformed = $false
} | ConvertTo-Json -Compress
