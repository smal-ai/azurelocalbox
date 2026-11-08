"""Offline preparation checks. No Azure, VM, service, event-log or authentication calls."""
import json
from pathlib import Path
import runpy
import subprocess
from datetime import datetime
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/read-smal-guest-transport-metadata-20261108.ps1'
HELPER = ROOT / 'scripts/smal-initial-read-functions.ps1'
T = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='guest_transport_scope_test')
G = T['initial_read_binding'].__globals__
BINDING = ROOT / 'docs/deployment-2026-11-08-guest-transport/operator-binding.json'


class GuestTransportMetadataTests(unittest.TestCase):
    def fake_az(self, args):
        if args[:2] == ['account','show']:
            return {'id': G['BASE']['SUB'], 'tenantId': G['BASE']['TENANT']}
        if args[:2] == ['ad','signed-in-user']:
            return {'id': 'fab70700-36e8-4cf5-ba5d-86ed49003fcf'}
        self.assertEqual(args[:3], ['rest','--method','get'])
        return {'value': [{'actions': ['*'], 'notActions': []}]}

    def test_new_scope_is_exact_and_legacy_identity_unchanged(self):
        clock = SimpleNamespace(now=lambda tz: datetime.fromisoformat('2026-11-08T18:30:00+00:00'), fromisoformat=datetime.fromisoformat)
        with patch.dict(G, datetime=clock), patch.dict(G['BASE'], read_az=self.fake_az), patch.object(G['subprocess'], 'check_output', return_value=BINDING.read_bytes()):
            result = T['initial_read_binding'](str(SCRIPT.relative_to(ROOT)))
        self.assertEqual(result['operatorObjectId'], 'fab70700-36e8-4cf5-ba5d-86ed49003fcf')
        self.assertEqual(len(result['entitlement']), 2)
        self.assertEqual(G['BASE']['PRINCIPAL'], '82f494a8-b9f5-46fc-b0f7-c70be0572a63')

    def test_unknown_source_cannot_select_new_scope(self):
        with self.assertRaisesRegex(RuntimeError, 'Unknown read-only observer scope'):
            T['initial_read_binding']('scripts/unreviewed.ps1')

    def test_outer_metadata_has_no_guest_login_or_effect(self):
        source = SCRIPT.read_text()
        for forbidden in ('New-ComputeSession', 'Read-LabGuestSecureSecret', 'New-PSSession -', 'Invoke-Command', 'Restart-Service', 'Start-Service', 'Set-VM', 'Stop-VM', 'Start-VM', 'Import-Module', 'Get-NetNatSession'):
            self.assertNotIn(forbidden, source)
        self.assertIn('guestAuthenticationAttempted = $false', source)
        self.assertIn('rawMessageOrXmlExported = $false', source)

    def test_exact_known_guests_and_event_limits(self):
        source = SCRIPT.read_text()
        for ident in ('3adff629-2f67-449b-ab32-8a8748c46f34','12a44e0c-cc08-4c4c-a812-fa0b56efdbc3','5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9'):
            self.assertIn(ident, source)
        self.assertIn('-MaxEvents 40', source)
        self.assertIn('traversalComplete = $events.Count -lt 40', source)

    def test_prepared_source_parses(self):
        source = HELPER.read_text() + '\n' + SCRIPT.read_text()
        body = "$s=ConvertFrom-Json @'\n" + json.dumps(source) + "\n'@;$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseInput($s,[ref]$tokens,[ref]$errors)|Out-Null;if($errors.Count){throw ($errors|Out-String)}"
        result = subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',body],capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stderr)


if __name__ == '__main__':
    unittest.main()
