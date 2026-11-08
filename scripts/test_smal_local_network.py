"""Local-only network phase tests. Never call Azure or apply a host network."""
import json
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'scripts/apply-smal-local-network.ps1').read_text()


class LocalNetworkTests(unittest.TestCase):
    def test_powershell_scripts_parse(self):
        for name in ['apply-smal-local-network.ps1', 'read-smal-local-network.ps1']:
            code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(ROOT / 'scripts' / name) + "',[ref]$t,[ref]$e);if($e.Count){$e | ForEach-Object Message;exit 1}"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)

    def test_real_route_overlap_function_handles_containment_and_default(self):
        function = re.search(r'function Test-LabPrefixOverlap \{\n.*?\n\}', SOURCE, re.S).group(0)
        cases = {'0.0.0.0/0': False, '10.0.0.0/8': True, '10.64.0.0/20': True, '10.64.15.255/32': True,
                 '10.64.16.0/24': False, '10.200.16.0/24': False, '172.16.0.0/24': False, '127.0.0.0/8': False,
                 '10.65.0.0/16': False, '10.63.255.255/32': False, '10.64.0.1/32': True}
        code = "$ErrorActionPreference='Stop';\n" + function + "\n@(" + ','.join("(Test-LabPrefixOverlap '" + prefix + "')" for prefix in cases) + ') | ConvertTo-Json -Compress'
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
        self.assertEqual(json.loads(result.stdout), list(cases.values()))

    def test_prechecks_precede_only_three_scoped_network_mutations(self):
        mutation = SOURCE.index('$created = New-VMSwitch')
        for guard in ['Existing NAT, switch or VM conflicts', 'HNS requires separate reconciled network inventory', 'Outer source differs', 'Existing route overlaps local infrastructure allocation', 'Azure VM identity differs']:
            self.assertLess(SOURCE.index(guard), mutation)
        self.assertIn('New-VMSwitch -Name $switchName -SwitchType Internal', SOURCE)
        self.assertIn("New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix '10.64.0.0/20'", SOURCE)
        self.assertIn('defaultRouteAndDnsUnchanged = $true', SOURCE)
        self.assertIn("Save-NetworkState 'switch-create'", SOURCE)
        self.assertIn("Save-NetworkState 'gateway-address-create'", SOURCE)
        self.assertIn("Save-NetworkState 'nat-create'", SOURCE)
        self.assertNotRegex(SOURCE, r'\bNew-VM\b')
        for forbidden in ['-SwitchType External', 'Set-NetRoute', 'Remove-NetRoute', 'Set-DnsClientServerAddress', 'Set-NetIPInterface', 'Set-NetFirewall', 'Remove-NetNat', 'Remove-VMSwitch', 'Format-Volume', 'az ', 'Invoke-Expression']:
            self.assertNotIn(forbidden, SOURCE)

    def test_observer_has_no_mutation(self):
        observer = (ROOT / 'scripts/read-smal-local-network.ps1').read_text()
        for forbidden in ['New-', 'Set-', 'Remove-', 'Start-', 'Stop-', 'Format-', 'Initialize-']:
            self.assertNotIn(forbidden, observer)


if __name__ == '__main__':
    unittest.main()
