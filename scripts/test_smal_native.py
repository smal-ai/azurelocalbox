"""Authored native-resource shapes and mocked commands. No live Azure or guest effects."""
from contextlib import redirect_stdout
import base64
from copy import deepcopy
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location('offline_' + name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


performance = load('smal-disk-performance')
files = load('smal-files')
platform = load('smal-platform')


def host():
    return {'id': performance.CONFIG['hostId'], 'hardwareProfile': {'vmSize': performance.CONFIG['hostSize']},
            'storageProfile': {'dataDisks': [{'lun': row['lun'], 'caching': 'None',
                'diskSizeGB': row['sizeGiB'], 'managedDisk': {'id': row['id'], 'storageAccountType': 'Standard_LRS'}}
                for row in performance.CONFIG['disks']]}}


def disk(row, premium=False):
    return {'id': row['id'], 'uniqueId': row['uniqueId'], 'diskSizeGB': row['sizeGiB'],
            'managedBy': performance.CONFIG['hostId'], 'provisioningState': 'Succeeded',
            'sku': {'name': 'Premium_LRS' if premium else 'Standard_LRS'},
            'diskIOPSReadWrite': row['iops'] if premium else 500,
            'diskMBpsReadWrite': row['mbps'] if premium else 60}


def state(phase):
    return {'id': 'synthetic-original-operation', 'phase': phase, 'requests': {},
            'before': {'host': host(), 'disks': {str(row['lun']): disk(row) for row in performance.CONFIG['disks']}}}


class DiskBoundaryTests(unittest.TestCase):
    def test_disk_identity_size_and_attachment_are_required(self):
        selected = performance.CONFIG['disks'][0]
        for field, value in (('uniqueId', 'foreign'), ('diskSizeGB', 1), ('managedBy', '/another-host')):
            actual = disk(selected)
            actual[field] = value
            with self.subTest(field=field), patch.object(performance, 'az', return_value=actual), self.assertRaises(RuntimeError):
                performance.disk(selected)

    def test_wrong_lun_or_caching_is_refused(self):
        for defect in ('lun', 'caching'):
            actual = host()
            actual['storageProfile']['dataDisks'][0][defect] = 77 if defect == 'lun' else 'ReadWrite'
            with self.subTest(defect=defect), patch.object(performance, 'az', return_value=actual), self.assertRaises(RuntimeError):
                performance.host()

    def test_uncertain_disk_request_cannot_be_submitted_again(self):
        original = state('converting')
        original['requests']['8'] = {'id': 'original-disk-request', 'status': 'intent'}
        with patch.object(performance, 'permissions'), patch.object(performance, 'host', side_effect=host), \
             patch.object(performance, 'disk', side_effect=disk), patch.object(performance, 'power', return_value='PowerState/deallocated'), \
             patch.object(performance, 'save'), patch.object(performance, 'az') as azure:
            with self.assertRaisesRegex(RuntimeError, 'unresolved'):
                performance.run(original)
            azure.assert_not_called()
        self.assertEqual(original['requests']['8']['id'], 'original-disk-request')

    def test_completed_lifecycle_does_not_repeat_shutdown_update_or_start(self):
        original = state('restored')
        before = deepcopy(original)
        with patch.object(performance, 'permissions'), patch.object(performance, 'host', side_effect=host), \
             patch.object(performance, 'disk', side_effect=lambda row: disk(row, premium=True)), \
             patch.object(performance, 'native') as native, patch.object(performance, 'az') as azure, \
             patch.object(performance.subprocess, 'run') as process:
            self.assertEqual(performance.run(original), before)
            native.assert_not_called()
            azure.assert_not_called()
            process.assert_not_called()


class FileServiceBoundaryTests(unittest.TestCase):
    def test_explicit_probe_ids_are_node_bound_repeatable_and_bounded(self):
        name = files.probe_job_name('moc-new-worker', 'startup-abcd')
        self.assertEqual(name, files.probe_job_name('moc-new-worker', 'startup-abcd'))
        self.assertNotEqual(name, files.probe_job_name('moc-other-worker', 'startup-abcd'))
        self.assertNotEqual(name, files.probe_job_name('moc-new-worker', 'startup-efgh'))
        for node, identity in [('moc-new-worker', '../escape'), ('foreign/node', 'startup'),
                               ('moc-new-worker', 'x' * 21), ('x' * 63, 'startup')]:
            with self.subTest(node=node, identity=identity), self.assertRaises(ValueError):
                files.probe_job_name(node, identity)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/tmp/opencode')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.config = json.loads((ROOT / 'config/smal-files.json').read_bytes())

    def test_original_submission_is_observed_without_new_password_or_create(self):
        path = self.directory / 'smal-file-service-vm-submitted.json'
        original = b'{"status":"submitting-or-uncertain","id":"synthetic-original"}'
        path.write_bytes(original)
        tenant = json.loads((ROOT / 'config/smal-platform.json').read_bytes())['tenantId']
        def azure(*args):
            if args[:2] == ('account', 'show'):
                return {'id': files.SUBSCRIPTION, 'tenantId': tenant}
            if args[:3] == ('deployment', 'group', 'show'):
                return {'properties': {'provisioningState': 'Failed'}}
            raise AssertionError('No new native submission: ' + repr(args[:3]))
        with patch.object(files, 'STATE', self.directory), patch.object(files, 'az', side_effect=azure) as calls, \
             patch.object(files, 'private_json') as write, patch.object(files.secrets, 'token_urlsafe') as password, \
             redirect_stdout(io.StringIO()):
            self.assertEqual(files.deploy('vm', self.config), 0)
            self.assertEqual(files.deploy('vm', self.config), 0)
            write.assert_not_called()
            password.assert_not_called()
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(sum(call.args[:3] == ('deployment', 'group', 'show') for call in calls.call_args_list), 2)

    def test_uncertain_vm_refresh_only_observes_the_original(self):
        path = self.directory / 'vm-refresh-submitted.json'
        original = b'{"status":"submitting-or-uncertain","id":"synthetic-refresh"}'
        path.write_bytes(original)
        current = {'properties': {'vmId': self.config['armVmId'], 'status': {'powerState': 'Running'},
            'hardwareProfile': {'processors': 4, 'memoryMB': 8192}, 'provisioningState': 'Failed'}}
        with patch.object(files, 'STATE', self.directory), patch.object(files, 'az', return_value=current) as azure, \
             patch.object(files, 'private_json') as write, redirect_stdout(io.StringIO()):
            self.assertEqual(files.refresh(self.config), 0)
            self.assertEqual(azure.call_count, 1)
            self.assertEqual(azure.call_args.args[:3], ('rest', '--method', 'get'))
            write.assert_not_called()
        self.assertEqual(path.read_bytes(), original)


class RecoveryPlanTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/tmp/opencode')
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'plan.json'
        self.plan = {'operationId': 'aks-os-recovery-' + 'a' * 32, 'hciNode': 'LB-NODE03',
                     'vmId': '11111111-1111-4111-8111-111111111111', 'biosGuid': '22222222-2222-4222-8222-222222222222',
                     'clusterName': 'synthetic-aks', 'vmName': 'synthetic-aks-workload-example',
                     'osDiskPath': 'C:\\ClusterStorage\\UserStorage_1\\synthetic\\synthetic-aks-OSDisk-deadbeef.vhdx',
                     'osDiskId': '33333333-3333-4333-8333-333333333333', 'osDiskBytes': 200 * 1024**3,
                     'expiresAtUtc': '2030-01-01T10:00:00+00:00'}

    def write(self, value):
        self.path.write_text(json.dumps(value))
        self.path.chmod(0o600)

    def test_exact_private_plan_round_trips_without_material_or_field_changes(self):
        self.write(self.plan)
        self.assertEqual(base64.b64decode(platform.recovery_plan(self.path)), self.path.read_bytes())

    def test_foreign_disk_node_and_credential_overlays_fail_before_transport(self):
        cases = [self.plan | {'osDiskPath': self.plan['osDiskPath'].replace('OSDisk', 'data')},
                 self.plan | {'osDiskPath': self.plan['osDiskPath'].replace('synthetic\\', '..\\')},
                 self.plan | {'hciNode': 'FOREIGN-NODE'}, self.plan | {'vmName': 'foreign-workload'},
                 self.plan | {'vmId': 'not-a-guid'}, self.plan | {'osDiskBytes': True},
                 self.plan | {'expiresAtUtc': '2030-01-01T10:00:00'},
                 self.plan | {'password': 'synthetic-unselected-material'}]
        for value in cases:
            with self.subTest(value=value):
                self.write(value)
                with self.assertRaises(ValueError):
                    platform.recovery_plan(self.path)

    def test_shared_or_linked_plan_is_rejected(self):
        self.write(self.plan)
        self.path.chmod(0o644)
        with self.assertRaises(ValueError):
            platform.recovery_plan(self.path)
        self.path.chmod(0o600)
        linked = self.path.with_name('linked.json')
        linked.symlink_to(self.path)
        with self.assertRaises(ValueError):
            platform.recovery_plan(linked)

    def test_actual_powershell_journal_replaces_existing_state_without_a_backup_path(self):
        script = r'''param([string]$Source,[string]$Directory)
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$tree=[System.Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count) { throw 'Source parse failed' }
foreach($name in @('Save-Operation')) {
    $function=@($tree.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if($function.Count -ne 1) { throw 'Expected the actual canonical journal function' }
    . ([scriptblock]::Create($function[0].Extent.Text))
}
$path=Join-Path $Directory 'operation.json'
Save-Operation $path @{id='fixed';step=1}
Save-Operation $path @{id='fixed';step=2}
$observed=Get-Content $path -Raw | ConvertFrom-Json
if($observed.id -cne 'fixed' -or $observed.step -ne 2) { throw 'Atomic operation replacement failed' }
'''
        fixture = self.path.with_name('journal-fixture.ps1')
        fixture.write_text(script)
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-File', str(fixture),
                        '-Source', str(ROOT / 'scripts/smal-platform.ps1'), '-Directory', self.temp.name],
                       check=True, capture_output=True, text=True, timeout=30)


class WorkflowBoundaryTests(unittest.TestCase):
    def test_ci_is_pinned_readonly_and_never_dispatches_native_operations(self):
        text = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('pull_request:', text)
        self.assertIn('contents: read', text)
        self.assertIn('persist-credentials: false', text)
        self.assertIn('python -B scripts/canonical_ci.py', text)
        for forbidden in ('pull_request_target', 'self-hosted', 'azure/login', 'secrets.', 'id-token:',
                          'continue-on-error:', 'start-smal-localbox.py', 'smal-files.py',
                          'smal-capacity.py', 'smal-disk-performance.py'):
            self.assertNotIn(forbidden, text)
        for action in re.findall(r'^\s*- uses: (\S+)', text, re.MULTILINE):
            self.assertRegex(action, r'^[^@]+@[a-f0-9]{40}$')


if __name__ == '__main__':
    unittest.main()
