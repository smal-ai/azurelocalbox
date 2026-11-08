"""Offline boundary tests for human-only official Arc device authentication."""
import base64
import json
from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class ArcConsoleTests(unittest.TestCase):
    def test_registration_diagnostic_exports_only_structured_log_facts(self):
        path = ROOT / 'scripts/inspect-smal-arc-registration.ps1'
        source = path.read_text()
        self.assertIn('rawLinesExported = $false', source)
        self.assertIn('mutationPerformed = $false', source)
        self.assertIn('Get-Content -LiteralPath $path -Tail 3000', source)
        for forbidden in ['azcmagent.exe" connect', 'Get-AzAccessToken', 'Start-Transcript', 'Remove-Item', 'Invoke-AzStackHciArcInitialization -']:
            self.assertNotIn(forbidden, source)
        code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)

    def test_powershell_scripts_parse(self):
        for name in ['register-smal-node-console.ps1', 'install-smal-arc-console.ps1', 'install-smal-arc-recovery-console.ps1']:
            code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(ROOT / 'scripts' / name) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)

    def test_recovery_requires_node2_exact_failure_and_current_owner_access(self):
        h = runpy.run_path(str(ROOT / 'scripts/register-smal-node-console.py'), run_name='recovery_boundary_test')
        proof = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-arc-registration-diagnosis-20261029.json').read_text())
        roles = [{'roleDefinitionName': 'Owner', 'scope': '/subscriptions/' + h['SUB']}]
        h['validate_recovery']('LB-NODE02', False, proof, roles)
        for node, inspect, actual_roles in [('LB-NODE01', False, roles), ('LB-NODE02', True, roles), ('LB-NODE02', False, [])]:
            with self.assertRaises(RuntimeError): h['validate_recovery'](node, inspect, proof, actual_roles)
        proof['result']['nodes'][1]['agentLog']['facts'] = []
        with self.assertRaises(RuntimeError): h['validate_recovery']('LB-NODE02', False, proof, roles)

    def test_recovery_preserves_original_attempt_and_does_not_run_on_install(self):
        source = (ROOT / 'scripts/register-smal-node-console.ps1').read_text()
        self.assertIn('if ($attemptCreated)', source)
        self.assertIn('.authorization-retry-20261029.state.json', source)
        self.assertIn('.authorization-retry-20261029.started', source)
        self.assertIn("$s.Response.Status -eq 'Failed'", source)
        self.assertNotIn('Remove-Item', source)
        installer = (ROOT / 'scripts/install-smal-arc-recovery-console.ps1').read_text()
        self.assertNotIn('Invoke-AzStackHciArcInitialization', installer)
        self.assertNotIn('New-PSSession', installer)
        helpers = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='recovery_render_test')
        rendered = helpers['render_arc_console'](installer.encode(), source.encode(), (ROOT / 'docs/deployment-2026-10-28/cloud-apply-approval.json').read_bytes(), 'a' * 40)
        self.assertNotRegex(rendered, rb'__[A-Z_]+__')

    def test_installer_only_delivers_pinned_console_and_approval(self):
        helpers = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='console_render_test')
        data = helpers['render_arc_console']((ROOT / 'scripts/install-smal-arc-console.ps1').read_bytes(), (ROOT / 'scripts/register-smal-node-console.ps1').read_bytes(), (ROOT / 'docs/deployment-2026-10-28/cloud-apply-approval.json').read_bytes(), 'a' * 40)
        self.assertNotRegex(data, rb'__[A-Z_]+__')
        installer = (ROOT / 'scripts/install-smal-arc-console.ps1').read_text()
        self.assertNotIn('Invoke-AzStackHciArcInitialization', installer)
        self.assertNotIn('New-PSSession', installer)
        self.assertIn('registrationPerformed = $false', installer)

    def test_console_omits_owner_token_and_fences_repeated_registration(self):
        source = (ROOT / 'scripts/register-smal-node-console.ps1').read_text()
        self.assertIn("-TargetSolutionVersion '12.2610.1004.41'", source)
        self.assertIn('[IO.FileMode]::CreateNew', source)
        self.assertIn("[ValidateSet('LB-NODE01','LB-NODE02')]", source)
        self.assertIn('Get-ArcBootstrapStatus', source)
        for forbidden in ['-ArmAccessToken', 'Get-AzAccessToken', 'Start-Transcript', 'Install-Module', 'Register-AzResourceProvider', 'Set-NetFirewall', 'CredSSP', 'TrustedHosts']:
            self.assertNotIn(forbidden, source)

    def test_launcher_refuses_headless_authentication_capture(self):
        h = runpy.run_path(str(ROOT / 'scripts/register-smal-node-console.py'), run_name='human_console_test')
        with patch.object(h['sys'].stdin, 'isatty', return_value=False):
            with self.assertRaises(RuntimeError): h['require_tty']()
        source = (ROOT / 'scripts/register-smal-node-console.py').read_text()
        self.assertIn('return subprocess.run(args, timeout=7200).returncode', source)
        self.assertNotIn('get-access-token', source)
        self.assertIn("'-o'", (ROOT / 'scripts/smal-private-powershell.py').read_text())

    def test_installed_console_did_not_register_and_all_guest_private_paths_pass(self):
        proof = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-install-arc-console-20261028.json').read_text())
        self.assertEqual(proof['status'], 'complete')
        self.assertFalse(proof['result']['registrationPerformed'])
        self.assertFalse(proof['result']['consoleOutputCaptured'])
        self.assertEqual(proof['result']['status'], 'installed-not-invoked')
        snapshot = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-guest-platform-private-path-20261028.json').read_text())
        self.assertEqual(snapshot['status'], 'complete')
        self.assertEqual(len(snapshot['result']['guests']), 3)
        for guest in snapshot['result']['guests']:
            self.assertEqual(len(guest['platformPrivateEndpoints']), 3)
            self.assertTrue(all(x['privateDnsMatched'] and x['normalTlsHttpResponseVerified'] for x in guest['platformPrivateEndpoints']))
        self.assertFalse(snapshot['result']['registrationPerformed'])


if __name__ == '__main__':
    unittest.main()
