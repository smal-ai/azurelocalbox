# Read-only Arc diagnosis. Never read bootstrap.json, tokens or process arguments.
# Return structured allowlisted log facts only, never raw log/error messages.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected outer host' }
$root = 'C:\ProgramData\AzureLocalBox\Bootstrap'
$boot = Join-Path $root 'guest-bootstrap-20261028-01'
$bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
$entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
$helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Secret helper differs' }
. $helper
$store = Join-Path $root 'cluster-prereqs-20261028-01\secrets'
$bindings = Get-Content (Join-Path $root 'cluster-prereqs-20261028-01\credential-bindings.json') -Raw | ConvertFrom-Json
$targets = @(
    @{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34' },
    @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' }
)
$results = @(foreach ($target in $targets) {
    $vm = Get-VM -Id $target.id
    if ($vm.Name -cne $target.name -or $vm.State.ToString() -ne 'Running') { throw 'Exact running node differs' }
    $binding = $bindings.nodes.PSObject.Properties[$target.name].Value
    if ($binding.vmId -ine $target.id -or $binding.role -cne 'cluster-node-admin' -or $binding.secretDirectory -cne $store -or $binding.loginVerified -ne $true) { throw 'Node credential binding differs' }
    $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'
    $session = $null
    try {
        $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($target.name + '\Administrator'), $secure)) -ErrorAction Stop
        Invoke-Command -Session $session -ArgumentList $target.name -ErrorAction Stop -ScriptBlock {
            param($ExpectedName)
            $ErrorActionPreference = 'Stop'
            if ($env:COMPUTERNAME -cne $ExpectedName) { throw 'Guest identity differs' }
            function Select-BootstrapStatus($item) {
                # Do not export Message, StackTrace or ErrorMessage. They may echo auth input.
                @{ name = [string]$item.Name; status = [string]$item.Status; startTime = [string]$item.StartTime; endTime = [string]$item.EndTime;
                   exceptionTypes = @($item.Errors | Where-Object { $_ } | ForEach-Object { [string]$_.ExceptionType });
                   children = @($item.DetailedResponse | Where-Object { $_ } | ForEach-Object { Select-BootstrapStatus $_ }) }
            }
            $os = Get-CimInstance Win32_OperatingSystem
            $result = @{ name = $env:COMPUTERNAME; atUtc = [datetime]::UtcNow.ToString('o'); lastBootUtc = $os.LastBootUpTime.ToUniversalTime().ToString('o'); bootstrap = $null; agentLog = $null;
                         services = @(Get-CimInstance Win32_Service -Filter "Name='himds' OR Name='GCArcService' OR Name='ExtensionService'" | ForEach-Object {
                             $delayed = (Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $_.Name) -Name DelayedAutoStart -ErrorAction SilentlyContinue).DelayedAutoStart
                             @{ name = $_.Name; status = $_.State; startMode = $_.StartMode; delayedAutoStart = $delayed; exitCode = $_.ExitCode; serviceSpecificExitCode = $_.ServiceSpecificExitCode; processId = $_.ProcessId }
                         }) }
            if (Get-Command Get-ArcBootstrapStatus -ErrorAction SilentlyContinue) {
                try { $status = Get-ArcBootstrapStatus; $result.bootstrap = Select-BootstrapStatus $status.Response }
                catch { $result.bootstrapReadErrorType = $_.Exception.GetType().Name }
            }
            $path = Join-Path $env:ProgramData 'AzureConnectedMachineAgent\Log\azcmagent.log'
            if (Test-Path -LiteralPath $path) {
                $file = Get-Item -LiteralPath $path
                $lines = @(Get-Content -LiteralPath $path -Tail 3000)
                $facts = @(foreach ($line in $lines) {
                    $codes = @([regex]::Matches($line, '\bAZCM[0-9]{4}\b') | ForEach-Object Value | Sort-Object -Unique)
                    $known = @('AuthorizationFailed','LinkedAuthorizationFailed','RequestDisallowedByPolicy','ResourceGroupNotFound','SubscriptionNotFound','NoRegisteredProviderFound','MissingSubscriptionRegistration','InvalidAuthenticationToken','ExpiredAuthenticationToken','AuthenticationFailed','InvalidResourceLocation','ResourceAlreadyExists','Conflict','Forbidden','TooManyRequests','BadRequest','InvalidResourceType')
                    $armCodes = @($known | Where-Object { $line -match ('\b' + $_ + '\b') })
                    $denied = $line -match '(?i:does not have authorization|not authorized to perform|authorization permission mismatch)'
                    if ($codes.Count -or $armCodes.Count -or $denied) {
                        $stamp = [regex]::Match($line, '\d{4}-\d{2}-\d{2}[T ][0-9:.]+(?:Z|[+-]\d{2}:\d{2})?').Value
                        $actions = @([regex]::Matches($line, 'Microsoft\.[A-Za-z]+/[A-Za-z]+(?:/[A-Za-z]+){0,3}') | ForEach-Object Value | Sort-Object -Unique)
                        @{ time = $stamp; agentCodes = $codes; armCodes = $armCodes; authorizationDenied = $denied; actions = $actions }
                    }
                })
                $result.agentLog = @{ path = $path; modifiedUtc = $file.LastWriteTimeUtc.ToString('o'); scannedTailLines = $lines.Count; facts = @($facts | Select-Object -Last 30); rawLinesExported = $false }
            }
            $result
        }
    } finally { if ($session) { Remove-PSSession -Session $session }; $secure.Dispose() }
})
@{ atUtc = [datetime]::UtcNow.ToString('o'); nodes = $results; mutationPerformed = $false; authenticationOutputCaptured = $false } | ConvertTo-Json -Depth 14 -Compress
