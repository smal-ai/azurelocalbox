from pathlib import Path
import runpy
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / 'scripts/reboot-smal-host.py'), run_name='restart_test')


class RebootTests(unittest.TestCase):
    def test_powershell_inspection_parses(self):
        source = ROOT / 'scripts/inspect-smal-hyperv.ps1'
        code = "$t=$null; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('" + str(source) + "',[ref]$t,[ref]$e); if($e.Count){$e | ForEach-Object Message; exit 1}"
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True)

    def test_expected_preconditions(self):
        installed = {'result': {'lastBootUtc': 'before'}}
        inspection = {'status': 'complete', 'strictPinnedHostKey': True, 'result': {
            'computer': 'LocalBox-Client', 'inspectionSucceeded': True, 'administrator': True, 'hyperV': 'Installed',
            'hyperVPowerShell': 'Installed', 'lastBootUtc': 'before'}}
        self.assertTrue(H['preconditions'](inspection, installed))
        inspection['result']['lastBootUtc'] = 'changed'
        self.assertFalse(H['preconditions'](inspection, installed))
        inspection['result']['lastBootUtc'] = 'before'
        inspection['strictPinnedHostKey'] = False
        self.assertFalse(H['preconditions'](inspection, installed))

    def test_reboot_guard_and_no_force(self):
        source = (ROOT / 'scripts/reboot-smal-host.py').read_text()
        self.assertIn("with target.open('x')", source)
        self.assertIn('if target.exists():', source)
        self.assertIn('uncertain-timeout-do-not-repeat', source)
        self.assertNotIn('--force', source)
        self.assertNotIn("'deallocate'", source)

    def test_inspection_is_read_only(self):
        source = (ROOT / 'scripts/inspect-smal-hyperv.ps1').read_text()
        for forbidden in ['New-VM', 'Start-VM', 'New-VMSwitch', 'New-NetNat', 'Format-Volume',
                          'Initialize-Disk', 'Restart-Computer', 'Set-VMHost', 'Add-MpPreference']:
            self.assertNotIn(forbidden, source)


if __name__ == '__main__':
    unittest.main()
