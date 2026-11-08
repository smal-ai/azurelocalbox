# NODE01 getter/module metadata only. No MOC getter invocation or module load.
$ErrorActionPreference = 'Stop'
$plan = [pscustomobject]@{ guestIds = [pscustomobject]@{ 'LB-NODE01' = '3adff629-2f67-449b-ab32-8a8748c46f34' } }
$began = [datetime]::UtcNow.ToString('o')
$session = New-ComputeSession 'LB-NODE01'
try {
    $result = Invoke-Command -Session $session -ArgumentList ${function:Read-InitialQuery}.ToString(),${function:Read-InitialCommand}.ToString(),${function:Assert-InitialNode}.ToString() -ScriptBlock {
        param($query,$command,$assert)
        $ErrorActionPreference = 'Stop'
        Set-Item Function:Read-InitialQuery ([scriptblock]::Create($query)); Set-Item Function:Read-InitialCommand ([scriptblock]::Create($command)); Set-Item Function:Assert-InitialNode ([scriptblock]::Create($assert))
        Assert-InitialNode 'LB-NODE01'
        $queries = @()
        $pattern = '^Get-.*(Moc|AksHci|ArcHci).*(Network|Pool|Allocation|VirtualMachine|Vnic|Interface|Image|Status|Controller|Operation|Registered)'
        $sensitiveName = '(?i)password|credential|token|secret|certificate|kubeconfig|configuration'
        $queries += Read-InitialQuery 'alreadyLoadedGetterSignatures' { Get-Command -ListImported | Where-Object { $_.Name -match $pattern -and $_.Name -notmatch $sensitiveName } | Sort-Object Name | ForEach-Object { Read-InitialCommand $_ } }
        $queries += Read-InitialQuery 'alreadyLoadedVendorModules' { Get-Module | Where-Object Name -Match '(?i)Moc|AksHci|ArcHci' | Sort-Object Name,Version | ForEach-Object { @{ name = $_.Name; version = $_.Version.ToString(); path = $_.Path; sourceSha256 = $(if ($_.Path) { (Get-FileHash -LiteralPath $_.Path).Hash } else { $null }) } } }
        $queries += Read-InitialQuery 'installedVendorModuleMetadata' {
            Get-Module -ListAvailable -Name '*Moc*','AksHci*','ArcHci*' | Sort-Object Name,Version | ForEach-Object {
                @{ name = $_.Name; version = $_.Version.ToString(); path = $_.Path; sourceSha256 = (Get-FileHash -LiteralPath $_.Path).Hash
                    signatureStatus = (Get-AuthenticodeSignature -LiteralPath $_.Path).Status.ToString()
                    relevantExportedGetters = @($_.ExportedCommands.Keys | Where-Object { $_ -match $pattern -and $_ -notmatch $sensitiveName } | Sort-Object) }
            }
        }
        return @{ scope = 'LB-NODE01-installed-command-metadata-only'; queries = $queries; nativeAllocationTraversalPerformed = $false; imageOrControllerStateMeasured = $false }
    } -ErrorAction Stop
    @{ status = $(if (@($result.queries | Where-Object complete -EQ $false).Count) { 'partial-read-only' } else { 'complete' }); beganAtUtc = $began; finishedAtUtc = [datetime]::UtcNow.ToString('o'); mutationPerformed = $false; data = $result } | ConvertTo-Json -Depth 18 -Compress
} finally { Remove-PSSession -Session $session }
