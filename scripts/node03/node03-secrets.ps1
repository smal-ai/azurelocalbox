# Library only. Loading this file neither generates nor persists a secret.
# Call only within the approved SYSTEM worker and its protected owned directory.
function New-LabGuestSecretText {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%+=_-'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        do {
            $characters = [Collections.Generic.List[char]]::new()
            [byte[]]$sample = New-Object byte[] 1
            while ($characters.Count -lt 40) {
                # Rejection sampling avoids modulo bias.
                $rng.GetBytes($sample)
                $limit = 256 - (256 % $alphabet.Length)
                if ($sample[0] -lt $limit) { $characters.Add($alphabet[$sample[0] % $alphabet.Length]) }
            }
            $text = -join $characters
        } while ($text -cnotmatch '[A-Z]' -or $text -cnotmatch '[a-z]' -or $text -notmatch '[0-9]' -or $text -notmatch '[!@#%+=_\-]')
        return $text
    } finally { $rng.Dispose() }
}

function Write-LabGuestSecret {
    param([string]$SecretDirectory, [string]$Role, [string]$Value)
    Add-Type -AssemblyName System.Security
    if ($Role -notmatch '^[a-z][a-z0-9-]{1,39}$' -or $Value.Length -lt 40) { throw 'Invalid guest secret role or value length' }
    # Caller creates and validates the owned Administrator/SYSTEM-only directory.
    $path = Join-Path $SecretDirectory ($Role + '.dpapi')
    [byte[]]$clear = [Text.Encoding]::UTF8.GetBytes($Value)
    [byte[]]$encrypted = $null
    try {
        $encrypted = [Security.Cryptography.ProtectedData]::Protect($clear, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        $file = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $file.Write($encrypted, 0, $encrypted.Length); $file.Flush($true) } finally { $file.Dispose() }
    } finally {
        [Array]::Clear($clear, 0, $clear.Length)
        if ($encrypted) { [Array]::Clear($encrypted, 0, $encrypted.Length) }
    }
    # No output. In particular, never return the clear or encrypted credential.
}

function Read-LabGuestSecureSecret {
    param([string]$SecretDirectory, [string]$Role)
    Add-Type -AssemblyName System.Security
    if ($Role -notmatch '^[a-z][a-z0-9-]{1,39}$') { throw 'Invalid guest secret role' }
    [byte[]]$encrypted = [IO.File]::ReadAllBytes((Join-Path $SecretDirectory ($Role + '.dpapi')))
    [byte[]]$clear = $null
    $secure = [Security.SecureString]::new()
    try {
        $clear = [Security.Cryptography.ProtectedData]::Unprotect($encrypted, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        # Generated secrets use only ASCII. Avoid creating a further clear string.
        foreach ($byte in $clear) { $secure.AppendChar([char]$byte) }
        $secure.MakeReadOnly()
        return $secure
    } catch { $secure.Dispose(); throw }
    finally {
        [Array]::Clear($encrypted, 0, $encrypted.Length)
        if ($clear) { [Array]::Clear($clear, 0, $clear.Length) }
    }
}

function New-LabGuestUnattendXml {
    param([string]$ComputerName, [string]$BootstrapSecret)
    if ($ComputerName -cne 'LB-NODE03' -or $BootstrapSecret.Length -lt 40) { throw 'Unapproved guest identity or secret length' }
    $escaped = [Security.SecurityElement]::Escape($BootstrapSecret)
    # PlainText=true is deliberate, explicitly approved and confined to the new
    # protected guest image. No autologon or first-logon code. Cleanup/rotation
    # must pass before any registration. Base64 would not encrypt this value.
    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <!-- AzureLocalBox node03-20261029-01 $ComputerName -->
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$ComputerName</ComputerName>
      <TimeZone>South Africa Standard Time</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserAccounts><AdministratorPassword><Value>$escaped</Value><PlainText>true</PlainText></AdministratorPassword></UserAccounts>
      <OOBE><HideEULAPage>true</HideEULAPage><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE></OOBE>
    </component>
  </settings>
</unattend>
"@
}
