# Only the existing LCM credential, unqualified username, one-use public-key envelope.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected host' }
$approvalPath = 'C:\ProgramData\AzureLocalBox\Bootstrap\three-node-20261029-01\approval.json'
if ((Get-FileHash $approvalPath).Hash -cne '__THREE_NODE_APPROVAL_SHA256__') { throw 'Exact three-node approval differs' }
$approval = Get-Content $approvalPath -Raw | ConvertFrom-Json
if ($approval.approved -ne $true -or $approval.threeNodeNoWitnessDeploymentApprovedSubjectToExactIdsAndEffectChecks -ne $true) { throw 'Approved credential/deployment scope missing' }
$boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
$entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1'); $helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Secret helper differs' }
. $helper
$rsa = [Security.Cryptography.RSACng]::new(); $p = [Security.Cryptography.RSAParameters]::new()
$p.Modulus = [Convert]::FromBase64String('__RSA_MODULUS__'); $p.Exponent = [Convert]::FromBase64String('AQAB'); $rsa.ImportParameters($p)
if ($rsa.KeySize -ne 4096) { throw 'Expected RSA4096' }
$lcm = $null; $clear = $null; $pointer = [IntPtr]::Zero
try {
    $lcm = Read-LabGuestSecureSecret -SecretDirectory 'C:\ProgramData\AzureLocalBox\Bootstrap\local-guests-20261028-01\secrets' -Role 'deployment-user'
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($lcm)
    $text = 'lboxdeploy:' + [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $value = [Convert]::ToBase64String($bytes)
    $clear = [Text.Encoding]::UTF8.GetBytes((@{ nonce = '__ENVELOPE_NONCE__'; values = @{ domain = $value } } | ConvertTo-Json -Compress))
    if ($clear.Length -gt 446) { throw 'Envelope exceeds RSA4096 OAEP limit' }
    $sealed = $rsa.Encrypt($clear,[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    @{ scheme = 'RSA4096-OAEP-SHA256'; nonce = '__ENVELOPE_NONCE__'; ciphertext = [Convert]::ToBase64String($sealed); clearValuesExported = $false } | ConvertTo-Json -Compress
} finally { if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }; if ($clear) { [Array]::Clear($clear,0,$clear.Length) }; if ($bytes) { [Array]::Clear($bytes,0,$bytes.Length) }; if ($lcm) { $lcm.Dispose() }; $text = $null; $value = $null; $rsa.Dispose() }
