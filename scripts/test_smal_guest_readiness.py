"""Read-only deployment-readiness observer boundary tests."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'scripts/inspect-smal-guest-deployment-readiness.ps1'


class GuestReadinessTests(unittest.TestCase):
    def test_powershell_parses(self):
        for path in [SOURCE, ROOT / 'scripts/activate-smal-dc-evaluation.ps1']:
            code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)

    def test_observer_has_no_guest_or_cloud_apply(self):
        source = SOURCE.read_text()
        for forbidden in ['Activate(', '/ato', 'Install-WindowsUpdate', 'New-ADUser', 'New-ADOrganizationalUnit', 'Set-GPInheritance', 'Register-Az', 'Invoke-AzStackHciArcInitialization -', 'Get-AzAccessToken', 'Set-Date']:
            self.assertNotIn(forbidden, source)
        self.assertIn('New-PSSession -VMId $vm.Id', source)
        self.assertIn("-Role $secretRole", source)
        self.assertIn('Verified cluster credential binding differs', source)
        self.assertIn('licenseStatus = $_.LicenseStatus', source)
        self.assertNotIn('partialKey =', source)
        self.assertIn('updateApplicabilityAssessed = $false', source)

    def test_activation_is_only_the_already_accepted_evaluation_and_never_installs_a_key(self):
        source = (ROOT / 'scripts/activate-smal-dc-evaluation.ps1').read_text()
        self.assertIn("$version.EditionID -cne 'ServerStandardEval'", source)
        self.assertIn("$before -ne 2", source)
        self.assertIn('if ($before -ne 1)', source)
        self.assertIn('-MethodName Activate', source)
        self.assertIn('activation attempt exists. Inspect, never repeat blindly.', source)
        for forbidden in ['InstallProductKey', 'SetProductKey', '/ipk', '/rearm', 'Set-Date', 'Register-Az', 'Invoke-AzStackHciArcInitialization']:
            self.assertNotIn(forbidden, source)

    def test_void_activation_result_does_not_override_observed_licensed_state(self):
        code = "$cases=@(@{status=1;code=$null},@{status=1;code=0},@{status=2;code=$null},@{status=1;code=5});@($cases|ForEach-Object {$after=@{LicenseStatus=$_.status};$returnCode=$_.code;$after.LicenseStatus -eq 1 -and ($null -eq $returnCode -or $returnCode -eq 0)})|ConvertTo-Json -Compress"
        import json
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
        self.assertEqual(json.loads(result.stdout), [True, True, False, False])

    def test_independent_activation_readback_is_licensed_without_repeating_activation(self):
        import json
        receipt = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-guest-readiness-after-eval-activation-20261028.json').read_text())
        self.assertEqual(receipt['status'], 'complete')
        self.assertFalse(receipt['result']['activationPerformed'])
        dc = next(x for x in receipt['result']['guests'] if x['name'] == 'LB-DC01')
        self.assertEqual(dc['licenses'][0]['licenseStatus'], 1)
        self.assertGreater(dc['licenses'][0]['graceMinutes'], 250000)


if __name__ == '__main__':
    unittest.main()
