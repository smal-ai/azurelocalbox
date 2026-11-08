"""Focused offline observer tests. No ARM, SSH, guest or module-load calls."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import runpy
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
T = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='initial_observer_test')
G = T['initial_read_binding'].__globals__
BINDING = ROOT / 'docs/deployment-2026-11-08-initial-admission/operator-binding.json'
HELPER = ROOT / 'scripts/smal-initial-read-functions.ps1'


class InitialObserverTests(unittest.TestCase):
    def powershell(self, body):
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', body],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def fake_az(self, args):
        if args[:2] == ['account', 'show']:
            return {'id': G['BASE']['SUB'], 'tenantId': G['BASE']['TENANT']}
        if args[:2] == ['ad', 'signed-in-user']:
            return {'id': 'fab70700-36e8-4cf5-ba5d-86ed49003fcf'}
        self.assertEqual(args[:3], ['rest', '--method', 'get'])
        return {'value': [{'actions': ['*'], 'notActions': []}]}

    def binding_check(self, az, stamp='2026-11-08T15:00:00+00:00'):
        clock = SimpleNamespace(now=lambda tz: datetime.fromisoformat(stamp), fromisoformat=datetime.fromisoformat)
        with patch.dict(G, datetime=clock), patch.dict(G['BASE'], read_az=az), patch.object(G['subprocess'], 'check_output', return_value=BINDING.read_bytes()):
            return T['initial_read_binding']()

    def test_current_scope_does_not_replace_legacy_principal(self):
        self.assertEqual(G['BASE']['PRINCIPAL'], '82f494a8-b9f5-46fc-b0f7-c70be0572a63')
        result = self.binding_check(self.fake_az)
        self.assertEqual(result['bindingSha256'], hashlib.sha256(BINDING.read_bytes()).hexdigest())
        self.assertEqual(len(result['entitlement']), 2)

    def test_changed_operator_refused(self):
        def changed(args):
            return {'id': '82f494a8-b9f5-46fc-b0f7-c70be0572a63'} if args[:2] == ['ad', 'signed-in-user'] else self.fake_az(args)
        with self.assertRaisesRegex(RuntimeError, 'operator changed'):
            self.binding_check(changed)

    def test_permission_exclusion_refused(self):
        def denied(args):
            return {'value': [{'actions': ['*'], 'notActions': ['*/read']}]} if args[:3] == ['rest', '--method', 'get'] else self.fake_az(args)
        with self.assertRaisesRegex(RuntimeError, 'entitlement absent'):
            self.binding_check(denied)

    def test_incomplete_permission_traversal_refused(self):
        def paged(args):
            return {'value': [], 'nextLink': 'not-followed'} if args[:3] == ['rest', '--method', 'get'] else self.fake_az(args)
        with self.assertRaisesRegex(RuntimeError, 'traversal incomplete'):
            self.binding_check(paged)

    def test_cutoff_refused_before_authentication(self):
        def no_auth(args):
            self.fail('Authentication attempted beyond cutoff')
        with self.assertRaisesRegex(RuntimeError, 'observation window'):
            self.binding_check(no_auth, '2026-11-08T22:00:00+00:00')

    def test_all_composed_parts_parse(self):
        common = (ROOT / 'scripts/smal-compute-capacity-20261108-common.ps1').read_text()
        for relative in sorted(T['INITIAL_READS']):
            source = "$ComputeCapacityLibraryOnly=$true\n" + ('' if 'initial-host-' in relative else common) + '\n' + HELPER.read_text() + '\n' + (ROOT / relative).read_text()
            encoded = json.dumps(source)
            # JSON decoding avoids interpolating script text into a shell/PowerShell argument.
            body = "$s=ConvertFrom-Json @'\n" + encoded + "\n'@;$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseInput($s,[ref]$tokens,[ref]$errors)|Out-Null;if($errors.Count){throw ($errors|Out-String)}"
            self.powershell(body)

    def test_query_failure_is_not_complete_or_zero_capacity(self):
        body = ". '" + str(HELPER) + "';Read-InitialQuery 'missing' {throw 'unavailable'} | ConvertTo-Json -Depth 8 -Compress"
        row = json.loads(self.powershell(body))
        self.assertFalse(row['complete'])
        self.assertIsNone(row['count'])
        self.assertTrue(row['errorType'])

    def test_missing_fields_stay_null_and_bytes_stay_integer(self):
        body = ". '" + str(HELPER) + "';Select-InitialFields @{Size=[long]304942678016} @('Size','SizeRemaining') | ConvertTo-Json -Compress"
        row = json.loads(self.powershell(body))
        self.assertEqual(row['Size'], 304942678016)
        self.assertIsNone(row['SizeRemaining'])

    def test_signature_projection_omits_sensitive_names(self):
        body = ". '" + str(HELPER) + "';function Get-Example([string]$Name,[securestring]$Password){};Read-InitialCommand (Get-Command Get-Example) | ConvertTo-Json -Depth 10 -Compress"
        self.assertNotIn('password', self.powershell(body).lower())

    def test_no_forbidden_active_operations(self):
        for relative in sorted(T['INITIAL_READS']):
            source = (ROOT / relative).read_text()
            for forbidden in ('Import-Module', 'Get-NetNatSession', 'Read-ComputeSnapshot', 'Read-ComputeDcNetwork', 'Stop-VM', 'Start-VM', 'Set-VM', 'kubectl', 'Get-Logs'):
                self.assertNotIn(forbidden, source)
        storage = (ROOT / 'scripts/read-smal-initial-storage-20261108.ps1').read_text()
        self.assertIn(".Parameters.ContainsKey('VirtualDisk')", storage)
        self.assertIn(".Parameters.ContainsKey('Partition')", storage)


if __name__ == '__main__':
    unittest.main()
