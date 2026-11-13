"""Exercise the canonical transport and repeatable startup without native resources."""
import base64
import json
from pathlib import Path
import runpy
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TRANSPORT = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'))


class CanonicalTests(unittest.TestCase):
    def test_canonical_source_has_no_historical_capture_or_execution_date_dependency(self):
        names = ('start-smal-localbox.py', 'start-smal-existing-guests.ps1',
                 'smal-private-powershell.py', 'smal-platform.ps1')
        for name in names:
            with self.subTest(name=name):
                text = (ROOT / 'scripts' / name).read_text()
                self.assertNotRegex(text, r'(?<![A-Za-z0-9])20\d{2}(?:-\d{2}-\d{2}|\d{4})(?![A-Za-z0-9])')
                self.assertNotIn('docs/deployment-', text)

    def test_exact_length_transport_executes_complete_source(self):
        source = b"'{\"result\":\"complete\"}'"
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', TRANSPORT['loader'](source)],
                                input=source, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(json.loads(result.stdout), {'result': 'complete'})

    def test_changed_or_truncated_source_cannot_execute(self):
        source = b"'{\"result\":\"complete\"}'"
        for supplied in (source[:-1], source.replace(b'complete', b'modified')):
            with self.subTest(supplied=supplied):
                result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', TRANSPORT['loader'](source)],
                                        input=supplied, capture_output=True, timeout=30)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(b'"result"', result.stdout)

    def test_public_parameters_are_data_not_executable_source(self):
        _, _, source = TRANSPORT['source_bytes']('scripts/start-smal-existing-guests.ps1', {'ConfigurationBase64': "'; throw 'injected"})
        self.assertNotIn(b"'; throw 'injected", source)
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as directory:
            path = Path(directory) / 'outside.ps1'
            path.write_text("throw 'outside source'")
            with self.assertRaises(ValueError):
                TRANSPORT['source_bytes'](str(path), {})

    def test_receipt_replacement_is_atomic_and_private(self):
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as directory:
            path = Path(directory) / 'receipt.json'
            TRANSPORT['write_record'](path, {'status': 'pending'})
            TRANSPORT['write_record'](path, {'status': 'complete'})
            self.assertEqual(json.loads(path.read_bytes()), {'status': 'complete'})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual([p.name for p in path.parent.iterdir()], ['receipt.json'])

    def test_startup_twice_starts_each_guest_once_without_restarting_running_guests(self):
        config = json.loads((ROOT / 'config/smal-platform.json').read_bytes())
        encoded = base64.b64encode(json.dumps(config).encode()).decode()
        script = """
$ErrorActionPreference='Stop'
$env:COMPUTERNAME='LocalBox-Client'
$global:starts=0
$config=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__CONFIG__'))|ConvertFrom-Json
$global:vms=@{}
foreach($p in $config.guestIds.PSObject.Properties){
 $global:vms[$p.Value]=[pscustomobject]@{Id=$p.Value;Name=$p.Name;State='Off';Heartbeat='OkApplicationsHealthy'}
}
function Get-VM($Id){$global:vms[[string]$Id]}
function Start-VM($VM){$global:starts++;$VM.State='Running'}
$first=& '__SCRIPT__' -ConfigurationBase64 '__CONFIG__'|ConvertFrom-Json
$second=& '__SCRIPT__' -ConfigurationBase64 '__CONFIG__'|ConvertFrom-Json
@{starts=$global:starts;firstRequests=@($first.guests|Where-Object startRequested).Count;secondRequests=@($second.guests|Where-Object startRequested).Count}|ConvertTo-Json -Compress
""".replace('__CONFIG__', encoded).replace('__SCRIPT__', str(ROOT / 'scripts/start-smal-existing-guests.ps1'))
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'starts': 4, 'firstRequests': 4, 'secondRequests': 0})


if __name__ == '__main__':
    unittest.main()
