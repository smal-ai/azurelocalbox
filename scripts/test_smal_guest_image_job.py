"""Offline job packaging/guard tests. No host/guest/secret mutation."""
import base64
import hashlib
import json
from pathlib import Path
import re
import runpy
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GuestImageJobTests(unittest.TestCase):
    def test_scripts_parse(self):
        for name in ['start-smal-guest-image-job.ps1', 'smal-guest-image-worker.ps1', 'read-smal-guest-image-job.ps1']:
            code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(ROOT / 'scripts' / name) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)

    def test_exact_bundle_and_manifest_render_without_floating_helpers(self):
        helpers = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='guest_image_render_test')
        files = {name: (ROOT / 'scripts' / name).read_bytes() for name in [
            'smal-guest-secret-functions.ps1', 'smal-guest-image-functions.ps1', 'smal-guest-vm-functions.ps1']}
        args = [(ROOT / 'scripts/start-smal-guest-image-job.ps1').read_bytes(),
                (ROOT / 'scripts/smal-guest-image-worker.ps1').read_bytes(),
                (ROOT / 'docs/deployment-2026-10-28/local-guest-image-manifest.json').read_bytes(), files, 'd' * 40]
        source = helpers['render_guest_image_installer'](*args)
        self.assertNotRegex(source, rb'__[A-Z_]+__')
        self.assertEqual(source, helpers['render_guest_image_installer'](*args))
        payloads = re.findall(rb"FromBase64String\('([A-Za-z0-9+/=]+)'\)", source)
        self.assertEqual(len(payloads), 3)
        manifest, worker, bundle = [base64.b64decode(value) for value in payloads]
        self.assertNotRegex(worker, rb'__[A-Z_]+__')
        self.assertIn(hashlib.sha256(bundle).hexdigest().upper().encode(), worker)
        records = json.loads(bundle)['files']
        self.assertEqual({item['name'] for item in records}, set(files))
        for item in records:
            self.assertEqual(base64.b64decode(item['base64']), files[item['name']])
            self.assertEqual(item['sha256'], hashlib.sha256(files[item['name']]).hexdigest().upper())
        self.assertFalse(json.loads(manifest)['bootGuestsInThisPhase'])

    def test_manifest_budgets_and_paths_match_approved_profile(self):
        manifest = json.loads((ROOT / 'docs/deployment-2026-10-28/local-guest-image-manifest.json').read_text())
        self.assertEqual(manifest['maximumVirtualDiskBytes'], (80 + 2 * 128 + 8 * 170) * 1024**3)
        self.assertEqual(manifest['minimumFreeBytes'], 200 * 1024**3)
        self.assertFalse(manifest['newAzureResources'])
        self.assertEqual([name for item in manifest['media'] for name in item['guests']], ['LB-DC01', 'LB-NODE01', 'LB-NODE02'])
        for media in manifest['media']:
            self.assertTrue(media['path'].startswith('C:\\ProgramData\\AzureLocalBox\\'))
            self.assertNotIn('\\\\', media['path'])

    def test_no_boot_registration_or_legacy_security_weakening(self):
        worker = (ROOT / 'scripts/smal-guest-image-worker.ps1').read_text()
        installer = (ROOT / 'scripts/start-smal-guest-image-job.ps1').read_text()
        for forbidden in ['Start-VM', 'Register-AzStackHCI', ' az ', 'Invoke-Expression', 'TrustedHosts', 'CredSSP', 'Set-MpPreference', 'Set-NetFirewall', 'Clear-Disk', 'Remove-Item']:
            self.assertNotIn(forbidden, worker + installer)
        self.assertIn('Complete image inspection missing', worker)
        self.assertIn('Existing VM/image/guardian conflicts', worker)
        self.assertIn('[IO.FileMode]::CreateNew', worker)
        self.assertIn('bootstrapCleanupAndRotationRequired = $true', worker)
        self.assertIn('-MultipleInstances IgnoreNew', installer)
        self.assertNotIn('-Trigger', installer)
        self.assertNotIn('-RestartCount', installer)

    def test_selected_images_match_successful_actual_inspection(self):
        receipt = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-guest-input-inspection-complete-20261028.json').read_text())
        self.assertEqual(receipt['status'], 'complete')
        observed = receipt['result']
        self.assertEqual(observed['lastTaskResult'], 0)
        self.assertEqual(observed['state']['status'], 'inspection-complete')
        manifest = json.loads((ROOT / 'docs/deployment-2026-10-28/local-guest-image-manifest.json').read_text())
        for media in manifest['media']:
            match = next(item for item in observed['state']['result']['media'] if item['kind'] == media['kind'])
            self.assertEqual(match['sha256'], media['sha256'])
            self.assertEqual(match['lengthBytes'], media['lengthBytes'])
            self.assertTrue(all(item['status'] == 'Valid' for item in match['signatures']))
            image = next(item for item in match['images'] if item['index'] == media['index'])
            self.assertEqual(image['version'], media['version'])
            self.assertEqual(image['edition'], media['edition'])
            self.assertEqual(image['architecture'], 9)
            self.assertEqual(image['installationType'], 'Server Core')

    def test_native_heartbeat_only_writes_public_liveness(self):
        worker = (ROOT / 'scripts/smal-guest-image-worker.ps1').read_text()
        csharp = re.search(r"Add-Type -TypeDefinition @'\n(.*?)\n'@", worker, re.S).group(1)
        encoded = base64.b64encode(csharp.encode()).decode()
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as directory:
            code = "$ErrorActionPreference='Stop';Add-Type -TypeDefinition ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + encoded + "')));[LocalBoxGuestImageHeartbeat]::Start('" + directory + "',$PID);try{$s=[Diagnostics.Stopwatch]::StartNew();while(-not(Test-Path '" + directory + "/heartbeat.json') -and $s.Elapsed.TotalSeconds -lt 5){Start-Sleep -Milliseconds 10};Get-Content '" + directory + "/heartbeat.json' -Raw}finally{[LocalBoxGuestImageHeartbeat]::Stop()}"
            result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
            self.assertEqual(set(json.loads(result.stdout)), {'processId', 'atUtc'})

    def test_checkpoint_retains_previous_state_and_append_only_public_events(self):
        worker = (ROOT / 'scripts/smal-guest-image-worker.ps1').read_text()
        function = re.search(r'function Save-GuestImageState \{\n.*?\n\}', worker, re.S).group(0)
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as directory:
            code = "$ErrorActionPreference='Stop';$root='" + directory + "';$statePath=Join-Path $root 'state.json';[IO.File]::WriteAllText($statePath,'{}');$state=[ordered]@{runId='synthetic';phase='initial';status='running';atUtc=$null};\n" + function + "\nSave-GuestImageState 'first';Save-GuestImageState 'second'"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)
            self.assertEqual(json.loads((Path(directory) / 'state.previous.json').read_text())['phase'], 'first')
            events = [json.loads(line) for line in (Path(directory) / 'events.jsonl').read_text().splitlines()]
            self.assertEqual([item['phase'] for item in events], ['first', 'second'])
            self.assertTrue(all(set(item) == {'runId', 'atUtc', 'phase', 'status'} for item in events))


if __name__ == '__main__':
    unittest.main()
