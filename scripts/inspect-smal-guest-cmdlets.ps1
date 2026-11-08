# Read-only installed API inventory. No module download or host feature change.
$ErrorActionPreference = 'Stop'
$names = @('New-VHD', 'Mount-VHD', 'Dismount-VHD', 'Get-Disk', 'Initialize-Disk', 'New-Partition', 'Format-Volume', 'Expand-WindowsImage', 'New-VM', 'Set-VM', 'Set-VMMemory', 'Set-VMProcessor', 'Set-VMFirmware', 'Get-HgsGuardian', 'New-HgsGuardian', 'New-HgsKeyProtector', 'Set-VMKeyProtector', 'Enable-VMTPM', 'Rename-VMNetworkAdapter', 'Connect-VMNetworkAdapter', 'Add-VMNetworkAdapter', 'Set-VMNetworkAdapter', 'Set-VMNetworkAdapterVlan', 'Disable-VMIntegrationService', 'Get-VMSecurity', 'New-PSSession', 'Invoke-Command')
$items = @($names | ForEach-Object {
    $name = $_
    $command = Get-Command -Name $name -ErrorAction SilentlyContinue
    $safeNames = if ($command) { @($command.Parameters.Keys | Where-Object { $_ -notmatch '(?i:password|access_token|refresh_token)' } | Sort-Object) } else { @() }
    @{ name = $name; available = [bool]$command; parameters = @($safeNames); omittedParameterCount = $(if ($command) { @($command.Parameters.Keys).Count - @($safeNames).Count } else { 0 }); module = $command.ModuleName; version = $(if ($command.Module) { $command.Module.Version.ToString() } else { $null }) }
})
@{ atUtc = (Get-Date).ToUniversalTime().ToString('o'); commands = $items; clusterBootstrapComplete = $false } | ConvertTo-Json -Depth 5 -Compress
