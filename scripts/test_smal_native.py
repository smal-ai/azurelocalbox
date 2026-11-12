"""Authored native-resource shapes and mocked commands. No live Azure or guest effects."""
from contextlib import redirect_stdout
from copy import deepcopy
import importlib.util
import io
import json
from pathlib import Path
import re
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
