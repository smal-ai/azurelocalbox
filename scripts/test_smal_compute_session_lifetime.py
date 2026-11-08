"""Exact helper lifetime tests with generated fixture credentials and mocked sessions."""
import json
import hashlib
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMMON = ROOT / 'scripts/smal-compute-capacity-20261108-common.ps1'


class ComputeSessionLifetimeTests(unittest.TestCase):
    def run_case(self, mode, actual_probe=False):
        source = COMMON.read_text()
        definition = source[source.index('function New-ComputeSession('):source.index('function Read-ComputeSnapshot(')]
        self.assertEqual(definition.count('. $helper'), 1)
        definition = definition.replace('. $helper', '# Test fixture replaces helper loading; no real files/credentials.')
        harness = r"""
$ErrorActionPreference='Stop'
$script:sequence=[Collections.Generic.List[string]]::new()
$script:authCount=0;$script:closeCount=0;$script:credential=$null
$script:secure=[Security.SecureString]::new();$script:secure.AppendChar('X');$script:secure.MakeReadOnly()
$plan=[pscustomobject]@{guestIds=[pscustomobject]@{'LB-NODE01'='3adff629-2f67-449b-ab32-8a8748c46f34'}}
function Assert-Compute($condition,$message){if(-not $condition){throw $message}}
function Get-VM {param($Id);[pscustomobject]@{Name='LB-NODE01';Id=[guid]$Id;State='Running'}}
function Join-Path {param($Path,$ChildPath);$Path+'\'+$ChildPath}
function Get-FileHash {param($Path);[pscustomobject]@{Hash=('A'*64)}}
function Get-Content {param($Path,[switch]$Raw)
 if($Path.EndsWith('bundle.json')){return ('{"files":[{"name":"smal-guest-secret-functions.ps1","sha256":"'+('A'*64)+'"}]}')}
 if($Path.EndsWith('credential-bindings.json')){return '{"nodes":{"LB-NODE01":{"vmId":"3adff629-2f67-449b-ab32-8a8748c46f34","role":"cluster-node-admin","secretDirectory":"C:\\ProgramData\\AzureLocalBox\\Bootstrap\\cluster-prereqs-20261028-01\\secrets","loginVerified":true}}}'}
 throw 'Unexpected fixture file read'
}
function Read-LabGuestSecureSecret {param($SecretDirectory,$Role);$script:sequence.Add('secret');return $script:secure}
function Test-FixtureUsable {
 try{[Security.SecureString].GetProperty('Length').GetValue($script:secure)|Out-Null;return $true}catch{return $false}
}
function New-PSSession {param($VMId,$Credential,$ErrorAction)
 $script:authCount++;$script:credential=$Credential;$script:sequence.Add('create')
 if($VMId.ToString() -cne '3adff629-2f67-449b-ab32-8a8748c46f34' -or $Credential.UserName -cne 'LB-NODE01\ASBuiltInAdmin'){throw 'Selector differs'}
 if(-not (Test-FixtureUsable)){throw 'Credential disposed before authentication'}
 if($mode -ceq 'create-failure'){throw 'Fixture create failure'}
 if($mode -ceq 'cached'){$script:cached=$Credential.GetNetworkCredential()}
 return [pscustomobject]@{marker='fixture-session';Runspace=[pscustomobject]@{ConnectionInfo=[pscustomobject]@{Credential=$Credential}}}
}
function Remove-PSSession {param($Session)
 if($Session.marker -cne 'fixture-session'){throw 'Wrong session closed'}
 $script:closeCount++;$script:sequence.Add('close')
 if(-not (Test-FixtureUsable)){throw 'Credential disposed before close'}
 if($mode -ceq 'close-failure'){throw 'Fixture close failure'}
}
"""
        harness += "\n$mode='" + mode + "'\n" + definition
        if actual_probe:
            harness += "\n$env:COMPUTERNAME='LocalBox-Client'\nfunction Invoke-Command {param($Session,$ErrorAction,$ScriptBlock);throw 'fixture-invoke-message'}\n"
            harness += (ROOT / 'scripts/read-smal-guest-transport-probe-20261108.ps1').read_text()
            result = subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',harness], capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertNotIn('fixture-invoke-message', result.stdout)
            return json.loads(result.stdout)
        harness += r"""
$failed=$false;$output=$null
try{
 if($mode -ceq 'legacy'){$output=New-ComputeSession -name 'LB-NODE01'}
 else{$output=New-ComputeSession -name 'LB-NODE01' -Read {
  param($session);$script:sequence.Add('invoke')
  if(-not (Test-FixtureUsable)){throw 'Credential disposed before invocation'}
  if($session.marker -cne 'fixture-session'){throw 'Wrong callback session'}
  if($mode -ceq 'invoke-failure'){throw 'Fixture invocation failure'}
  return [pscustomobject]@{onlyReadData='fixture-result'}
 }}
}catch{$failed=$true}
@{failed=$failed;authCount=$script:authCount;closeCount=$script:closeCount;credentialUsableAfter=Test-FixtureUsable
 sequence=@($script:sequence);outputMarker=$(if($output){$output.onlyReadData}else{$null})
 cachedCredentialExists=($null -ne $script:cached)}|ConvertTo-Json -Depth 5 -Compress
"""
        result = subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',harness], capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stderr)
        return json.loads(result.stdout)

    def test_read_callback_closes_before_disposal(self):
        row = self.run_case('success')
        self.assertFalse(row['failed'])
        self.assertEqual(row['sequence'], ['secret','create','invoke','close'])
        self.assertEqual(row['authCount'],1)
        self.assertEqual(row['closeCount'],1)
        self.assertFalse(row['credentialUsableAfter'])
        self.assertEqual(row['outputMarker'],'fixture-result')

    def test_create_failure_disposes_without_retry_or_close(self):
        row = self.run_case('create-failure')
        self.assertTrue(row['failed'])
        self.assertEqual(row['authCount'],1)
        self.assertEqual(row['closeCount'],0)
        self.assertFalse(row['credentialUsableAfter'])

    def test_invocation_failure_closes_and_disposes(self):
        row = self.run_case('invoke-failure')
        self.assertTrue(row['failed'])
        self.assertEqual(row['sequence'], ['secret','create','invoke','close'])
        self.assertEqual(row['authCount'],1)
        self.assertFalse(row['credentialUsableAfter'])

    def test_cached_credential_does_not_change_cleanup(self):
        row = self.run_case('cached')
        self.assertFalse(row['failed'])
        self.assertTrue(row['cachedCredentialExists'])
        self.assertEqual(row['closeCount'],1)
        self.assertFalse(row['credentialUsableAfter'])

    def test_legacy_return_contract_remains(self):
        row = self.run_case('legacy')
        self.assertFalse(row['failed'])
        self.assertEqual(row['sequence'],['secret','create'])
        self.assertEqual(row['closeCount'],0)
        self.assertFalse(row['credentialUsableAfter'])

    def test_close_failure_still_disposes(self):
        row = self.run_case('close-failure')
        self.assertTrue(row['failed'])
        self.assertEqual(row['closeCount'],1)
        self.assertFalse(row['credentialUsableAfter'])

    def test_probe_is_bounded_and_parses_with_helpers(self):
        probe = ROOT / 'scripts/read-smal-guest-transport-probe-20261108.ps1'
        source = probe.read_text()
        self.assertEqual(source.count('New-ComputeSession -name'),1)
        self.assertIn('authenticationAttempts = $null', source)
        for forbidden in ('Restart-Service','Start-Service','Set-VM','Start-VM','Stop-VM','Import-Module','Get-NetNatSession'):
            self.assertNotIn(forbidden,source)
        composed = '$ComputeCapacityLibraryOnly=$true\n' + COMMON.read_text() + '\n' + (ROOT/'scripts/smal-initial-read-functions.ps1').read_text() + '\n' + source
        body = "$s=ConvertFrom-Json @'\n" + json.dumps(composed) + "\n'@;$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseInput($s,[ref]$tokens,[ref]$errors)|Out-Null;if($errors.Count){throw ($errors|Out-String)}"
        result = subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',body],capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_actual_probe_error_identifier_is_digest_not_raw_message(self):
        row = self.run_case('success', actual_probe=True)
        self.assertEqual(row['status'], 'failed-diagnostic-no-automatic-retry')
        self.assertTrue(row['error']['rawMessageOrStackExported'] is False)
        self.assertNotIn('fullyQualifiedErrorId', row['error'])
        self.assertEqual(row['error']['fullyQualifiedErrorIdSha256'], hashlib.sha256(b'fixture-invoke-message').hexdigest())
        self.assertEqual(row['error']['fullyQualifiedErrorIdByteLength'], len(b'fixture-invoke-message'))


if __name__ == '__main__':
    unittest.main()
