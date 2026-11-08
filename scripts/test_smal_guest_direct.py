"""Offline PowerShell Direct boundary tests. Not guest/domain integration proof."""
from pathlib import Path
import json
import subprocess
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / 'scripts/smal-guest-direct-functions.ps1'


class GuestDirectTests(unittest.TestCase):
    def test_library_parses_and_only_defines_functions(self):
        code = "$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseFile('" + str(LIBRARY) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1};@($a.EndBlock.Statements|ForEach-Object {$_.GetType().Name})|ConvertTo-Json -Compress"
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
        self.assertEqual(json.loads(result.stdout), ['FunctionDefinitionAst'] * 6)

    def test_guest_admin_is_host_local_and_has_no_implicit_token_or_network_remoting(self):
        source = LIBRARY.read_text()
        self.assertIn('New-PSSession -VMId $VmId -Credential $Credential', source)
        self.assertIn('Invoke-Command -Session $Session', source)
        for forbidden in ['-ComputerName ', 'TrustedHosts', 'CredSSP', 'Connect-AzAccount', 'access_token', 'Invoke-Expression', 'Set-NetFirewall', 'Set-MpPreference', 'Disable-NetFirewall']:
            self.assertNotIn(forbidden, source)
        self.assertIn("@('AuthenticationError', 'SecurityError')", source)
        self.assertIn('avoid account lockout', source)

    def test_network_is_bound_to_guest_identity_and_exact_mac_mapping(self):
        source = LIBRARY.read_text()
        self.assertIn("$env:COMPUTERNAME -cne $ExpectedName", source)
        self.assertIn('Host MAC mapping missing or ambiguous', source)
        self.assertIn('Guest management IP already conflicts', source)
        self.assertIn('RegisterThisConnectionsAddress $false', source)
        self.assertIn("-DefaultGateway '10.64.0.1'", source)
        self.assertIn("-ServerAddresses '10.64.0.10'", source)
        self.assertIn('$wait.Elapsed.TotalSeconds -gt 180', source)
        self.assertIn('if ($protected) { break }', source)

    def test_cleanup_deletes_only_attributed_files_and_preserves_password_policy(self):
        source = LIBRARY.read_text()
        self.assertIn("$text.Contains('AzureLocalBox local-guests-20261028-01') -or $text.Contains($oldText)", source)
        self.assertIn('Remove-Item -LiteralPath $file.FullName -Force', source)
        self.assertNotIn('Remove-Item -Recurse', source)
        self.assertIn('Set-ADAccountPassword', source)
        self.assertIn('Set-LocalUser', source)
        for forbidden in ['Set-ADDefaultDomainPasswordPolicy', 'PasswordNeverExpires', 'AutoLogon', 'MinimumPasswordLength', 'Add-Computer']:
            self.assertNotIn(forbidden, source)

    def test_authentication_failure_stops_without_retrying_or_locking_account(self):
        code = "$ErrorActionPreference='Stop';. '" + str(LIBRARY) + "';$script:attempts=0;function New-PSSession {param($VMId,$Credential,$ErrorAction)$script:attempts++;throw [System.Management.Automation.ErrorRecord]::new([UnauthorizedAccessException]::new('synthetic'),'AccessDenied',[System.Management.Automation.ErrorCategory]::SecurityError,$null)};function Start-Sleep {throw 'UNEXPECTED_RETRY'};$credential=[pscredential]::new('synthetic-user',(ConvertTo-SecureString 'synthetic-not-a-deployment-value' -AsPlainText -Force));try{Wait-LabGuestSession -VmId '11111111-1111-1111-1111-111111111111' -ExpectedName 'LB-DC01' -Credential $credential}catch{if($_.Exception.Message -like '*Guest authentication failed*' -and $script:attempts -eq 1){exit 0};exit 2};exit 3"
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_setup_reader_accepts_active_writer_without_modifying_history(self):
        source = LIBRARY.read_text()
        function = re.search(r'        function Read-SharedSetupText \{\n.*?\n        \}', source, re.S).group(0)
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as directory:
            path = Path(directory) / 'synthetic-setup.log'
            text = 'Public synthetic setup history.'
            path.write_text(text)
            code = "$ErrorActionPreference='Stop';\n" + function + "\n$writer=[IO.FileStream]::new('" + str(path) + "',[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);try{Read-SharedSetupText '" + str(path) + "'}finally{$writer.Dispose()}"
            result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.stdout.strip(), text)
            self.assertEqual(path.read_text(), text)
        self.assertIn('unreadableSetupLogs = $unreadableLogs', source)
        self.assertIn('answerFileCleanupNeedsReview = $answersNeedReview', source)

    def test_clock_check_is_read_only_and_compares_actual_utc(self):
        code = ". '" + str(LIBRARY) + "';function Invoke-Command {param($Session,$ErrorAction,$ScriptBlock)@{utcNow=[datetime]::UtcNow.ToString('o');timeServiceRunning=$true;timeSource='time.windows.com,0x8'}};Get-LabGuestClockEvidence -Session $null|ConvertTo-Json -Compress"
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
        proof = json.loads(result.stdout)
        self.assertTrue(proof['selectedClockChecksPassed'])
        self.assertFalse(proof['clockManuallyAdjusted'])
        self.assertLess(abs(proof['observedOffsetSeconds']), 1)
        function = LIBRARY.read_text().split('function Get-LabGuestClockEvidence', 1)[1]
        for forbidden in ['Set-Date', '/config', '/resync', 'Start-Service', 'Set-ItemProperty']:
            self.assertNotIn(forbidden, function)


if __name__ == '__main__':
    unittest.main()
