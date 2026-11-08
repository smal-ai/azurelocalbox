# One exact NODE01 diagnostic attempt through the existing protected credential path.
# No alternate principal, restart, configuration change or retry. Read callback owns lifetime.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Wrong outer host' }
$plan = [pscustomobject]@{ guestIds = [pscustomobject]@{ 'LB-NODE01' = '3adff629-2f67-449b-ab32-8a8748c46f34' } }
$result = @{ status = 'pending'; beganAtUtc = [datetime]::UtcNow.ToString('o'); scope = 'LB-NODE01-exact-PSDirect-diagnostic'
    vmId = '3adff629-2f67-449b-ab32-8a8748c46f34'; stage = 'preflight'; authenticationAttempts = $null; sessionCreationRequests = 0
    selectedUser = 'LB-NODE01\ASBuiltInAdmin'; mutationPerformed = $false; alternateIdentityAttempted = $false; data = $null; error = $null }
try {
    if ([datetime]::UtcNow.AddSeconds(90) -ge [datetime]::Parse('2026-11-08T22:00:00Z').ToUniversalTime()) { throw 'Diagnostic cutoff reached' }
    $result.stage = 'create-session'; $result.sessionCreationRequests = 1
    $result.data = New-ComputeSession -name 'LB-NODE01' -Read {
        param($session)
        $result.stage = 'guest-read'; $result.authenticationAttempts = 1
        Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $admin = Get-LocalUser -Name ASBuiltInAdmin
            if ($env:COMPUTERNAME -cne 'LB-NODE01' -or -not $admin.Enabled -or -not $admin.SID.Value.EndsWith('-500') -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $admin.SID.Value) { throw 'Exact node/RID500 differs' }
            $computer = Get-CimInstance Win32_ComputerSystem; $os = Get-CimInstance Win32_OperatingSystem
            @{ name = $env:COMPUTERNAME; capturedAtUtc = [datetime]::UtcNow.ToString('o'); logicalProcessors = (Get-VMHost).LogicalProcessorCount
                memoryBytes = $computer.TotalPhysicalMemory; domain = $computer.Domain; partOfDomain = $computer.PartOfDomain
                osVersion = $os.Version; buildNumber = $os.BuildNumber
                vmSessionService = @(Get-CimInstance Win32_Service -Filter "Name='vmicvmsession'" | ForEach-Object {
                    @{ name = $_.Name; state = $_.State; startMode = $_.StartMode; exitCode = $_.ExitCode; serviceSpecificExitCode = $_.ServiceSpecificExitCode }
                }); mutationPerformed = $false }
        }
    }
    $result.status = 'complete-canonical-guest-read'; $result.stage = 'session-closed-credential-disposed'
} catch {
    $chain = @(); $exception = $_.Exception
    for ($i = 0; $null -ne $exception -and $i -lt 4; $i++) {
        $chain += @{ type = $exception.GetType().FullName; hresultHex = ('0x{0:X8}' -f ($exception.HResult -band 0xFFFFFFFFL)) }
        $exception = $exception.InnerException
    }
    $result.status = 'failed-diagnostic-no-automatic-retry'
    $identifierBytes = [Text.Encoding]::UTF8.GetBytes([string]$_.FullyQualifiedErrorId)
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $result.error = @{ typesAndHresults = $chain; category = $_.CategoryInfo.Category.ToString(); reason = $_.CategoryInfo.Reason
            fullyQualifiedErrorIdSha256 = [BitConverter]::ToString($hash.ComputeHash($identifierBytes)).Replace('-', '').ToLowerInvariant()
            fullyQualifiedErrorIdByteLength = $identifierBytes.Length; sourceLine = $_.InvocationInfo.ScriptLineNumber
            rawMessageOrStackExported = $false }
    } finally { $hash.Dispose(); [Array]::Clear($identifierBytes, 0, $identifierBytes.Length) }
}
$result.finishedAtUtc = [datetime]::UtcNow.ToString('o')
$result | ConvertTo-Json -Depth 14 -Compress
