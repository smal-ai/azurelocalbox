import base64
import json
from pathlib import Path
import re
import subprocess
import tempfile
import runpy
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StorageJobTests(unittest.TestCase):
    def test_historical_loader_selector_is_hash_only_and_validated(self):
        helpers = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='legacy_selector_test')
        encoded = helpers['legacy_loader_for_hash']('a' * 64)
        text = base64.b64decode(encoded).decode('utf-16-le')
        self.assertIn('A' * 64, text)
        self.assertNotIn('private', text.lower())
        with self.assertRaises(RuntimeError): helpers['legacy_loader_for_hash']("bad' OR 1=1")

    def test_powershell_checkpoint_replacement_keeps_previous_state(self):
        source = (ROOT / 'scripts/smal-storage-worker.ps1').read_text()
        function = re.search(r'function Save-State \{\n.*?\n\}', source, re.S).group(0)
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as directory:
            code = "$ErrorActionPreference='Stop'; $root='" + directory + "'; $statePath=Join-Path $root 'state.json'; [IO.File]::WriteAllText($statePath,'{}'); $state=[ordered]@{runId='test';scope='storage-only';phase='initialising';status='running'};\n" + function + "\nSave-State; $state.phase='preflight'; Save-State; Get-Content $statePath -Raw"
            result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
            self.assertEqual(json.loads(result.stdout)['phase'], 'preflight')
            self.assertEqual(json.loads((Path(directory) / 'state.previous.json').read_text())['phase'], 'initialising')

    def test_large_reviewed_script_streams_with_integrity_and_not_windows_argv(self):
        helpers = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='stream_test')
        source = ("# é\n" * 20000 + "@{ok=$true}|ConvertTo-Json -Compress\n").encode()
        loader = helpers['stdin_loader'](source)
        self.assertLess(len(loader), 16000)
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', loader], input=source.decode(), encoding='utf-8', capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)['ok'])
        changed = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', loader], input=source.decode().replace('# é', '# è', 1), encoding='utf-8', capture_output=True, timeout=30)
        self.assertNotEqual(changed.returncode, 0)
        self.assertNotIn('-n', helpers['ssh_args'](12345, 'arcdemo', loader, stream_source=True))
        failing = b"throw 'synthetic-sensitive-value-must-not-be-logged'\n"
        failed = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', helpers['stdin_loader'](failing)], input=failing.decode(), encoding='utf-8', capture_output=True, timeout=30)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('ReviewedSourceFailure:', failed.stderr)
        self.assertNotIn('synthetic-sensitive-value-must-not-be-logged', failed.stderr)
        truncated = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', helpers['stdin_loader'](source)], input=source.decode()[:-10], encoding='utf-8', capture_output=True, timeout=30)
        self.assertNotEqual(truncated.returncode, 0)

    def test_real_installer_payload_is_rendered_and_requires_streaming(self):
        helpers = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='render_test')
        source = helpers['render_storage_installer'](
            (ROOT / 'scripts/start-smal-storage-job.ps1').read_bytes(),
            (ROOT / 'scripts/smal-storage-worker.ps1').read_bytes(),
            (ROOT / 'docs/deployment-2026-10-28/storage-job-manifest.json').read_bytes(), 'a' * 40)
        self.assertNotIn(b'__MANIFEST_', source)
        self.assertNotIn(b'__WORKER_', source)
        self.assertGreater(len(base64.b64encode(source.decode().encode('utf-16-le'))), 32767)
        self.assertLess(len(helpers['stdin_loader'](source)), 16000)

    def test_powershell_scripts_parse(self):
        for name in ['smal-storage-worker.ps1', 'start-smal-storage-job.ps1', 'read-smal-storage-job.ps1', 'recover-smal-storage-job.ps1', 'stop-smal-recovery-transport.ps1', 'inspect-smal-eval-media-access.ps1']:
            code = "$t=$null; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('" + str(ROOT / 'scripts' / name) + "',[ref]$t,[ref]$e); if($e.Count){$e | ForEach-Object Message; exit 1}"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True)

    def test_storage_mutations_follow_exact_identity_guards(self):
        worker = (ROOT / 'scripts/smal-storage-worker.ps1').read_text()
        self.assertLess(worker.index('Manifest differs'), worker.index('New-StoragePool'))
        self.assertLess(worker.index('Approved RAW data disk state changed'), worker.index('New-StoragePool'))
        self.assertIn('Where-Object UniqueId -CEQ $expected.guestUniqueId', worker)
        self.assertIn('$drive[0].SCSILogicalUnit -ne ($expected.lun + 1)', worker)
        self.assertIn('$physical[0].CanPool -ne $true', worker)
        self.assertIn('$disk[0].IsBoot -or $disk[0].IsSystem', worker)
        self.assertIn('$partition | Format-Volume', worker)
        self.assertIn('$cAfter.Size -ne $cBefore.Size', worker)
        self.assertNotIn('Get-PhysicalDisk -CanPool', worker)

    def test_single_instance_no_automatic_replay_or_cron(self):
        worker = (ROOT / 'scripts/smal-storage-worker.ps1').read_text()
        installer = (ROOT / 'scripts/start-smal-storage-job.ps1').read_text()
        self.assertIn('[IO.FileMode]::CreateNew', worker)
        self.assertIn(r'Global\AzureLocalBox-Storage-20261028-01', worker)
        self.assertIn('-MultipleInstances IgnoreNew', installer)
        self.assertNotIn('New-ScheduledTaskTrigger', installer)
        self.assertNotIn('RestartCount', installer)
        self.assertNotIn('-ExecutionPolicy Bypass', installer)
        self.assertIn('Storage job already exists', installer)

    def test_recovery_is_only_for_exact_no_storage_effects_checkpoint_failure(self):
        recovery = (ROOT / 'scripts/recover-smal-storage-job.ps1').read_text()
        self.assertIn('Storage effects exist. This recovery is not applicable.', recovery)
        self.assertIn('Original preflight failure no longer matches inspection', recovery)
        self.assertIn("'worker.before-recovery.ps1'", recovery)
        self.assertIn('originalMarkerRetained = $true', recovery)
        self.assertIn('[IO.FileMode]::CreateNew', recovery)
        for forbidden in ['Remove-Item', 'Format-Volume', 'Initialize-Disk', 'New-StoragePool', 'Stop-Process']:
            self.assertNotIn(forbidden, recovery)
        self.assertIn('@($task.Triggers | Where-Object { $null -ne $_ }).Count', recovery)

    def test_scope_and_manifest_are_explicit_and_never_cloud_or_nested_apply(self):
        manifest = json.loads((ROOT / 'docs/deployment-2026-10-28/storage-job-manifest.json').read_text())
        decisions = json.loads((ROOT / 'docs/deployment-2026-10-28/deployment-decisions.json').read_text())
        self.assertTrue(decisions['simpleStorageFormattingApproved'])
        self.assertEqual(len(manifest['disks']), 8)
        self.assertEqual({d['lun'] for d in manifest['disks']}, set(range(8)))
        for disk in manifest['disks']:
            self.assertEqual(disk['namespaceId'], disk['lun'] + 1)
            self.assertNotIn('OSDisk', disk['resourceId'])
        source = (ROOT / 'scripts/smal-storage-worker.ps1').read_text()
        for forbidden in ['Mount-DiskImage', 'New-VM', 'Start-VM', 'New-VMSwitch', 'New-NetNat',
                          'Connect-AzAccount', 'New-AzRoleAssignment', 'Add-MpPreference', 'Enable-WSManCredSSP']:
            self.assertNotIn(forbidden, source)

    def test_native_heartbeat_compiles_and_writes_only_its_public_status(self):
        worker = (ROOT / 'scripts/smal-storage-worker.ps1').read_text()
        csharp = re.search(r"Add-Type -TypeDefinition @'\n(.*?)\n'@", worker, re.S).group(1)
        encoded = base64.b64encode(csharp.encode()).decode()
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as directory:
            code = "$ErrorActionPreference='Stop'; Add-Type -TypeDefinition ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + encoded + "'))); [LocalBoxStorageHeartbeat]::Start('" + directory + "',$PID); try { $s=[Diagnostics.Stopwatch]::StartNew(); while(-not (Test-Path '" + directory + "/heartbeat.json') -and $s.Elapsed.TotalSeconds -lt 5){Start-Sleep -Milliseconds 10}; Get-Content '" + directory + "/heartbeat.json' -Raw } finally { [LocalBoxStorageHeartbeat]::Stop() }"
            result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
            heartbeat = json.loads(result.stdout)
            self.assertEqual(set(heartbeat), {'processId', 'atUtc'})
            self.assertGreater(heartbeat['processId'], 0)
