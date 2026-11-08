# Approved credential delivery only: encrypt two existing dedicated credentials to
# a one-use operator RSA public key. No clear credential/token is output or saved.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected host' }
$approvalPath = 'C:\ProgramData\AzureLocalBox\Bootstrap\arc-console-20261028-01\approval.json'
if ((Get-FileHash $approvalPath).Hash -cne '__APPROVAL_SHA256__') { throw 'Exact approval differs' }
$approval = Get-Content $approvalPath -Raw | ConvertFrom-Json
if ($approval.approved -ne $true -or $approval.westEuropeNewOwnedRgAndListedPlatformResourcesApproved -ne $true) { throw 'Platform approval missing' }
$boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
$entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
$helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Secret helper differs' }
. $helper
$rsa = [Security.Cryptography.RSACng]::new()
$parameters = [Security.Cryptography.RSAParameters]::new()
$parameters.Modulus = [Convert]::FromBase64String('__RSA_MODULUS__')
$parameters.Exponent = [Convert]::FromBase64String('AQAB')
$rsa.ImportParameters($parameters)
if ($rsa.KeySize -ne 4096) { throw 'Expected RSA4096' }
$node = $null; $lcm = $null; $clear = $null
try {
    $node = Read-LabGuestSecureSecret -SecretDirectory 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets' -Role 'cluster-node-admin'
    $lcm = Read-LabGuestSecureSecret -SecretDirectory 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01\secrets' -Role 'deployment-user'
    # Base64 username:secret is the pinned Microsoft template's credential format,
    # NOT encryption. It remains in memory until sealed with RSA-OAEP-SHA256.
    $values = @{}
    foreach ($item in @(@{ key = 'local'; user = 'Administrator'; secure = $node }, @{ key = 'domain'; user = 'LOCALBOX\lboxdeploy'; secure = $lcm })) {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($item.secure)
        try { $text = $item.user + ':' + [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer); $bytes = [Text.Encoding]::UTF8.GetBytes($text); $values[$item.key] = [Convert]::ToBase64String($bytes) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }; $text = $null }
    }
    $clear = [Text.Encoding]::UTF8.GetBytes((@{ nonce = '__ENVELOPE_NONCE__'; values = $values } | ConvertTo-Json -Compress))
    if ($clear.Length -gt 446) { throw 'Credential envelope exceeds RSA4096 OAEP-SHA256 limit' }
    $cipher = $rsa.Encrypt($clear, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    @{ scheme = 'RSA4096-OAEP-SHA256'; nonce = '__ENVELOPE_NONCE__'; ciphertext = [Convert]::ToBase64String($cipher); clearValuesExported = $false } | ConvertTo-Json -Compress
} finally { if ($clear) { [Array]::Clear($clear, 0, $clear.Length) }; if ($node) { $node.Dispose() }; if ($lcm) { $lcm.Dispose() }; $values = $null; $rsa.Dispose() }
