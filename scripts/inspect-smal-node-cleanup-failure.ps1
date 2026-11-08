# Exact node-1 read-only cleanup/clock inspection. Never return file contents.
$ErrorActionPreference = 'Stop'
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$imageRoot = 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01'
$state = Get-Content (Join-Path $root 'state.json') -Raw | ConvertFrom-Json
if ($env:COMPUTERNAME -ne 'LocalBox-Client' -or $state.phase -ne 'LB-NODE01-clean-owned-answer-files-and-rotate' -or $state.status -ne 'failed-inspect-before-resume' -or (Get-ScheduledTask -TaskName 'LocalBox-GuestBootstrap-20261028-01').State.ToString() -ne 'Ready') { throw 'Exact node cleanup failure differs' }
$bundle = Get-Content (Join-Path $root 'bundle.json') -Raw | ConvertFrom-Json
$file = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
$helper = Join-Path $root 'smal-guest-secret-functions.ps1'
if ($file.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $file[0].sha256) { throw 'Secret helper integrity differs' }
. $helper
$vm = Get-VM -Id '3adff629-2f67-449b-ab32-8a8748c46f34'
if ($vm.Name -cne 'LB-NODE01' -or $vm.State.ToString() -ne 'Running') { throw 'Exact running node differs' }
$secure = Read-LabGuestSecureSecret -SecretDirectory (Join-Path $imageRoot 'secrets') -Role 'node01-bootstrap'
$session = $null
try {
    $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new('LB-NODE01\Administrator', $secure)) -ErrorAction Stop
    $guest = Invoke-Command -Session $session -ArgumentList $secure -ErrorAction Stop -ScriptBlock {
        param($OldValue)
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -cne 'LB-NODE01') { throw 'Node identity differs' }
        $files = @()
        foreach ($directory in @('C:\Windows\Panther', 'C:\Windows\System32\Sysprep')) { if (Test-Path $directory) { $files += @(Get-ChildItem -LiteralPath $directory -Recurse -File | Where-Object { $_.Name -like '*unattend*.xml' -or $_.Extension -eq '.log' }) } }
        $rows = @(); $pointer = [IntPtr]::Zero
        try {
            $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($OldValue); $old = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
            foreach ($item in $files) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected setup reparse point' }
                $row = @{ path = $item.FullName; bytes = $item.Length; normalReadSucceeded = $false; normalErrorType = $null; normalErrorHResult = $null; sharedReadSucceeded = $false; sharedErrorType = $null; oldValuePresent = $null; ownedMarkerPresent = $null }
                try { $null = [IO.File]::ReadAllText($item.FullName); $row.normalReadSucceeded = $true } catch { $errorValue = $_.Exception; if ($errorValue.InnerException) { $errorValue = $errorValue.InnerException }; $row.normalErrorType = $errorValue.GetType().Name; $row.normalErrorHResult = $errorValue.HResult.ToString('X8') }
                $stream = $null; $reader = $null
                try {
                    if ($item.Length -gt 128MB) { throw 'Setup file exceeds diagnostic cap' }
                    $stream = [IO.FileStream]::new($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                    $reader = [IO.StreamReader]::new($stream); $text = $reader.ReadToEnd()
                    $row.sharedReadSucceeded = $true; $row.oldValuePresent = $text.Contains($old); $row.ownedMarkerPresent = $text.Contains('AzureLocalBox local-guests-20261028-01')
                } catch { $row.sharedErrorType = $_.Exception.GetType().Name }
                finally { if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }; $text = $null }
                $rows += $row
            }
        } finally { if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }; $old = $null }
        $user = Get-LocalUser -Name Administrator
        @{ computer = $env:COMPUTERNAME; utcNow = [datetime]::UtcNow.ToString('o'); localNow = (Get-Date).ToString('o'); timeZone = (Get-TimeZone).Id; timeService = (Get-Service w32time).Status.ToString(); timeSource = ((& w32tm.exe /query /source 2>$null) -join ' ').Trim(); localAdminChangedAtUtc = $user.PasswordLastSet.ToUniversalTime().ToString('o'); setupFiles = $rows; domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole; vmmsRunning = (Get-Service vmms).Status.ToString() -eq 'Running'; mutationPerformed = $false }
    }
    @{ hostUtc = [datetime]::UtcNow.ToString('o'); guest = $guest; originalBootstrapLoginVerified = $true; credentialValueExported = $false; mutationPerformed = $false } | ConvertTo-Json -Depth 7 -Compress
} finally { if ($session) { Remove-PSSession -Session $session }; $secure.Dispose() }
