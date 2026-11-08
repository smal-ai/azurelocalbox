import json
from pathlib import Path
import runpy
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPERS = runpy.run_path(str(ROOT / 'scripts/smal-bootstrap-preflight.py'), run_name='preflight_test')
SOURCE = (ROOT / 'scripts/smal-bootstrap-preflight.ps1').read_text()


class PreflightTests(unittest.TestCase):
    def test_powershell_parses(self):
        check = "$tokens=$null; $errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$tokens,[ref]$errors); if($errors.Count){$errors | ForEach-Object Message; exit 1}"
        # -Command argument binding varies across shells. Pass the fixed file as
        # a literal in the parser expression, not as an executable script.
        check = check.replace('$args[0]', "'" + str(ROOT / 'scripts/smal-bootstrap-preflight.ps1') + "'")
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', check], check=True, capture_output=True, text=True)

    def test_no_mutating_payload_commands(self):
        for command in ['Install-WindowsFeature', 'Enable-WindowsOptionalFeature', 'Initialize-Disk',
                        'Format-Volume', 'New-NetNat', 'New-VMSwitch', 'Restart-Computer',
                        'Set-ItemProperty', 'Set-ExecutionPolicy', 'Enable-WSManCredSSP',
                        'Set-MpPreference', 'Add-MpPreference', 'Invoke-Expression', 'Start-Process',
                        'Install-Module', 'Set-Content', 'Out-File', 'Connect-AzAccount']:
            self.assertNotIn(command.lower(), SOURCE.lower())

    def test_no_tls_bypass_or_auto_redirect(self):
        self.assertIn('$request.AllowAutoRedirect = $false', SOURCE)
        self.assertIn('$request.UseDefaultCredentials = $false', SOURCE)
        self.assertNotIn('ServerCertificateValidationCallback', SOURCE)
        self.assertNotIn('SkipCertificateCheck', SOURCE)
        self.assertIn("$request.Method = 'HEAD'", SOURCE)

    def test_output_budget_and_ntp_validation(self):
        self.assertIn('$json.Length -gt 3800', SOURCE)
        self.assertIn('$originMatches', SOURCE)
        self.assertIn('clockAdjusted = $false', SOURCE)

    def test_payload_valid(self):
        data = {'section': 'System', 'computer': 'LOCALBOX-CLIENT', 'authenticatedGuestLogin': False}
        envelope = [{'code': 'ComponentStatus/StdOut/succeeded', 'message': json.dumps(data)}]
        self.assertEqual(HELPERS['parse_output'](json.dumps(envelope), 'System'), data)

    def test_bad_output_rejected(self):
        cases = [
            [{'code': 'ComponentStatus/StdErr/succeeded', 'message': 'failed'}],
            [{'code': 'ComponentStatus/StdOut/succeeded', 'message': json.dumps({'password': 'secret'})}],
            [{'code': 'ComponentStatus/StdOut/succeeded', 'message': '{}'}],
            [],
        ]
        for case in cases:
            with self.subTest(case=case), self.assertRaises((RuntimeError, ValueError)):
                HELPERS['parse_output'](json.dumps(case), 'System')

    def test_scope_and_receipt_guards(self):
        runner = (ROOT / 'scripts/smal-bootstrap-preflight.py').read_text()
        self.assertIn("with target.open('x')", runner)
        self.assertIn("if target.exists():", runner)
        self.assertIn('uncertain-timeout-do-not-repeat', runner)
        self.assertIn("approval.get('runCommandReadOnlyApproved') is not True", runner)
        self.assertIn('Exact preflight source must be committed and pushed', runner)
        self.assertIn('Tracked files changed after commit', runner)
        self.assertNotIn('CREDENTIAL_FILE', runner)


if __name__ == '__main__':
    unittest.main()
