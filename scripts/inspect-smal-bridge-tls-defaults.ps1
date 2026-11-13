# Local process/.NET defaults only. No connection or configuration changes.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine 'LocalBox-Client' -or $env:OS -cne 'Windows_NT') { throw 'Exact LocalBox-Client Windows host required' }
$result = @{ powerShellVersion = $PSVersionTable.PSVersion.ToString(); clrVersion = [Environment]::Version.ToString()
    process64Bit = [Environment]::Is64BitProcess; os64Bit = [Environment]::Is64BitOperatingSystem
    securityProtocolName = [Net.ServicePointManager]::SecurityProtocol.ToString(); securityProtocolValue = [int][Net.ServicePointManager]::SecurityProtocol }
foreach ($view in @('Registry64', 'Registry32')) {
    $base = $null; $framework = $null; $full = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::$view)
        $framework = $base.OpenSubKey('SOFTWARE\Microsoft\.NETFramework\v4.0.30319', $false)
        $full = $base.OpenSubKey('SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', $false)
        $result[$view + 'FrameworkKeyPresent'] = $null -ne $framework; $result[$view + 'FullKeyPresent'] = $null -ne $full
        foreach ($name in @('Release', 'SchUseStrongCrypto', 'SystemDefaultTlsVersions')) {
            $key = if ($name -eq 'Release') { $full } else { $framework }
            $value = if ($null -ne $key) { $key.GetValue($name, $null) } else { $null }
            $result[$view + $name] = if ($value -is [int]) { $value } elseif ($null -eq $value) { 'absent' } else { 'unexpected-type' }
        }
    } finally {
        if ($full) { $full.Dispose() }; if ($framework) { $framework.Dispose() }; if ($base) { $base.Dispose() }
    }
}
$result | ConvertTo-Json -Compress
