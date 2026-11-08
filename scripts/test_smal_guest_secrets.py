"""Offline library tests. Do not generate any real deployment credential."""
import json
from pathlib import Path
import subprocess
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / 'scripts/smal-guest-secret-functions.ps1'


class GuestSecretTests(unittest.TestCase):
    def test_library_parses_and_loading_has_no_output_or_side_effect_calls(self):
        code = "$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseFile('" + str(LIBRARY) + "',[ref]$t,[ref]$e);if($e.Count){exit 1};@($a.EndBlock.Statements|ForEach-Object {$_.GetType().Name})|ConvertTo-Json -Compress"
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
        self.assertEqual(json.loads(result.stdout), ['FunctionDefinitionAst'] * 4)

    def test_synthetic_random_values_are_long_complex_and_distinct_without_printing(self):
        code = ". '" + str(LIBRARY) + "';$values=@(1..20|ForEach-Object {New-LabGuestSecretText});@{count=$values.Count;unique=@($values|Select-Object -Unique).Count;valid=@($values|Where-Object {$_.Length -eq 40 -and $_ -cmatch '[A-Z]' -and $_ -cmatch '[a-z]' -and $_ -match '[0-9]' -and $_ -match '[!@#%+=_\\-]'}).Count}|ConvertTo-Json -Compress"
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
        self.assertEqual(json.loads(result.stdout), {'count': 20, 'unique': 20, 'valid': 20})

    def test_answer_file_escapes_synthetic_xml_and_never_uses_autologon(self):
        value = 'Synthetic&<Secret>"' + 'x' * 40
        code = ". '" + str(LIBRARY) + "';New-LabGuestUnattendXml -ComputerName 'LB-DC01' -BootstrapSecret '" + value + "'"
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
        xml = ET.fromstring(result.stdout)
        ns = {'u': 'urn:schemas-microsoft-com:unattend'}
        self.assertEqual(xml.find('.//u:AdministratorPassword/u:Value', ns).text, value)
        self.assertEqual(xml.find('.//u:ComputerName', ns).text, 'LB-DC01')
        self.assertIsNone(xml.find('.//u:AutoLogon', ns))
        self.assertIsNone(xml.find('.//u:FirstLogonCommands', ns))
        self.assertIsNone(xml.find('.//u:RunSynchronous', ns))

    def test_persistence_is_machine_bound_exclusive_and_clears_byte_buffers(self):
        source = LIBRARY.read_text()
        self.assertIn('[Security.Cryptography.DataProtectionScope]::LocalMachine', source)
        self.assertIn('[IO.FileMode]::CreateNew', source)
        self.assertIn('[Array]::Clear($clear', source)
        self.assertIn('$secure.MakeReadOnly()', source)
        for forbidden in ['Export-Clixml', 'Write-Host', 'Write-Output', 'Set-Content', 'Start-Transcript', 'Invoke-Expression']:
            self.assertNotIn(forbidden, source)


if __name__ == '__main__':
    unittest.main()
