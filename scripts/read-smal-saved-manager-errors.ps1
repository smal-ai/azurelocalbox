# Exact saved software-error lines only. No client, network or credential access.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine 'LocalBox-Client' -or $env:OS -cne 'Windows_NT') { throw 'Exact LocalBox-Client Windows host required' }
if ([DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse('2026-11-10T11:30:00+02:00')) { throw 'Saved-error read window expired' }
$directory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'smal-bridge-kubectl-20261110-01'
$path = Join-Path $directory 'manager-log-stdout-private.txt'
$allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
$selected = @('569836a7286d1ad6f74fa7a50aff52ea54b913430a768c3cdc7d73afb02cf7e6', '0d12c9e44f38f7b89f3548e9531ae897210bf3b27f49e065c21dfcb650ad07fe')
function Get-Digest([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-SafeManagementText([string]$Line) {
    $text = $Line -replace '^\d{4}-\d{2}-\d{2}T\S+\s+', ''
    if ($text.TrimStart().StartsWith('{')) {
        $object = $text | ConvertFrom-Json; $parts = @()
        foreach ($field in @('level', 'logger', 'controller', 'controllerGroup', 'controllerKind', 'msg', 'message', 'error', 'errorVerbose')) {
            $value = $object.$field
            if ($value -is [string]) { $parts += $field + ': ' + $value }
            elseif ($field -eq 'error' -and $value.message -is [string]) { $parts += 'error: ' + $value.message }
        }
        $text = $parts -join ' | '
    }
    $text = $text -replace '(?i)\b[a-z][a-z0-9+.-]*://[^\s"''<>]+', '<url>'
    $text = $text -replace '\?[^\s"''<>]+', '<query>'
    if ($text -match '(?i)-----BEGIN|\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+|\beyJ[A-Za-z0-9_-]{15,}\.|\b(?:token|password|passwd|client[-_ ]?secret|access[-_ ]?token|refresh[-_ ]?token|private[-_ ]?key|authorization|credentials?)\s*["'']?\s*[:=]\s*["'']?\S+|[A-Za-z0-9+/]{80,}={0,2}') { return $null }
    return $text
}
$result = @{ status = 'not-read'; lines = @(); fileSha256 = '82b4d7cb02f8df889415321251faab65eeaf05c86a0d813a6779e9a8dff20706' }
try {
    foreach ($entry in @($directory, $path)) {
        $item = Get-Item -LiteralPath $entry -Force; $acl = Get-Acl -LiteralPath $entry
        if ([bool]$item.PSIsContainer -ne ($entry -ceq $directory) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Path type/reparse mismatch' }
        if ($allowed -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -or ($item.PSIsContainer -and -not $acl.AreAccessRulesProtected)) { throw 'Private owner/inheritance mismatch' }
        foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $allowed -notcontains $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value) { throw 'Private access too broad' }
        }
    }
    if ((Get-Item -LiteralPath $path).Length -gt 32768) { throw 'Saved file exceeds cap' }
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -gt 32768 -or (Get-Digest $bytes) -cne $result.fileSha256) { throw 'Exact saved file hash mismatch' }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($text.StartsWith([string][char]0xfeff)) { $text = $text.Substring(1) }
    foreach ($line in [regex]::Split($text, '\r\n|\n|\r')) {
        $digest = Get-Digest ([Text.Encoding]::UTF8.GetBytes($line))
        if ($selected -cnotcontains $digest) { continue }
        $safe = Get-SafeManagementText $line
        $row = @{ lineSha256 = $digest; timestamp = [regex]::Match($line, '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})').Value }
        if ($null -eq $safe) { $row.status = 'withheld-sensitive-material' }
        elseif ([string]::IsNullOrWhiteSpace($safe)) { $row.status = 'no-known-management-fields' }
        else { $row.status = 'sanitised-management-wording'; $row.truncated = $safe.Length -gt 2048; $row.text = $safe.Substring(0, [Math]::Min(2048, $safe.Length)) }
        $result.lines += $row
    }
    $result.status = if ($result.lines.Count -eq 2) { 'saved-manager-errors-read' } else { 'selected-lines-missing-no-fallback' }
} catch { $result.status = 'stopped-no-retry'; $result.errorCategory = $_.CategoryInfo.Category.ToString(); $result.sourceLine = [int]$_.InvocationInfo.ScriptLineNumber }
$result | ConvertTo-Json -Depth 5 -Compress
