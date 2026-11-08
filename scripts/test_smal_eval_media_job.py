"""Offline regression tests for the approved download-only task. No Azure calls."""
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
WORKER = (ROOT / 'scripts/smal-eval-media-worker.ps1').read_text()


class EvaluationMediaTests(unittest.TestCase):
    def test_powershell_scripts_parse(self):
        for name in ['smal-eval-media-worker.ps1', 'start-smal-eval-media-job.ps1', 'read-smal-eval-media-job.ps1', 'inspect-smal-guest-inputs.ps1', 'read-smal-guest-inspection.ps1', 'stop-smal-guest-inspection.ps1', 'start-smal-guest-input-job.ps1', 'smal-guest-input-worker.ps1', 'read-smal-guest-input-job.ps1', 'recover-smal-guest-input-hash.ps1']:
            path = ROOT / 'scripts' / name
            code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e | ForEach-Object Message;exit 1}"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)

    def test_exact_pinned_approved_origin_and_measured_not_publisher_hash(self):
        manifest = json.loads((ROOT / 'docs/deployment-2026-10-28/eval-media-job-manifest.json').read_text())
        observed = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-eval-media-access-post-wildcard-20261028.json').read_text())['result']
        self.assertEqual(manifest['etag'], observed['etag'])
        self.assertEqual(manifest['lengthBytes'], observed['bytes'])
        self.assertIsNone(manifest['publisherSha256'])
        self.assertFalse(manifest['mountOrExecutionApprovedByThisJob'])
        self.assertIn("$request.Headers['If-Match'] = $m.etag", WORKER)
        self.assertIn('$request.AllowAutoRedirect = $false', WORKER)
        self.assertNotIn('ServerCertificateValidationCallback', WORKER)

    def test_once_only_preserves_failures_and_has_no_recurring_trigger(self):
        installer = (ROOT / 'scripts/start-smal-eval-media-job.ps1').read_text()
        self.assertIn('[IO.FileMode]::CreateNew', WORKER)
        self.assertIn('Existing media must be inspected, never overwritten', WORKER)
        self.assertIn('Inspect rather than reinstall.', installer)
        self.assertIn('-MultipleInstances IgnoreNew', installer)
        for forbidden in ['-Trigger', '-ExecutionPolicy Bypass', '-RestartCount', 'Remove-Item', 'Resume-BitsTransfer']:
            self.assertNotIn(forbidden, installer + WORKER)
        for forbidden in ['Mount-DiskImage', 'New-VM', 'Format-Volume', 'Invoke-Expression', 'TrustedHosts', 'Register-AzStackHCI']:
            self.assertNotIn(forbidden, installer + WORKER)

    def test_checkpoint_roundtrip_and_previous_copy(self):
        function = re.search(r'function Save-MediaState \{\n.*?\n\}', WORKER, re.S).group(0)
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as directory:
            code = "$ErrorActionPreference='Stop';$root='" + directory + "';$statePath=Join-Path $root 'state.json';[IO.File]::WriteAllText($statePath,'{}');$state=[ordered]@{phase='first';lastUpdatedAtUtc=$null};\n" + function + "\nSave-MediaState;$state.phase='second';Save-MediaState"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)
            self.assertEqual(json.loads((Path(directory) / 'state.json').read_text())['phase'], 'second')
            self.assertEqual(json.loads((Path(directory) / 'state.previous.json').read_text())['phase'], 'first')

    def test_stream_copy_and_hash_rejects_truncation_and_excess(self):
        # Execute the actual production copy/length/hash/publication block offline.
        block = WORKER.split('    [byte[]]$buffer =', 1)[1].split("    $state.status = 'media-downloaded'", 1)[0]
        block = '    [byte[]]$buffer =' + block
        content = b'public synthetic evaluation media\n' * 40
        encoded = base64.b64encode(content).decode()
        for expected_length, succeeds in [(len(content), True), (len(content) - 1, False), (len(content) + 1, False)]:
            with self.subTest(expected_length=expected_length), tempfile.TemporaryDirectory(dir='/tmp/opencode') as directory:
                code = "$ErrorActionPreference='Stop';$root='" + directory + "';$partial=Join-Path $root 'media.partial';$final=Join-Path $root 'media.iso';$m=@{lengthBytes=" + str(expected_length) + "};$state=@{bytesWritten=0L};function Save-MediaState {};$inputStream=[IO.MemoryStream]::new([Convert]::FromBase64String('" + encoded + "'));$outputStream=[IO.File]::Open($partial,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{\n" + block + "\n$state | ConvertTo-Json -Compress}catch{exit 1}finally{if($outputStream){$outputStream.Dispose()};$inputStream.Dispose()}"
                result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                final = Path(directory) / 'media.iso'
                self.assertEqual(final.exists(), succeeds)
                if succeeds:
                    self.assertEqual(final.read_bytes(), content)
                    self.assertEqual(json.loads(result.stdout)['measuredSha256'], hashlib.sha256(content).hexdigest().upper())
                else:
                    self.assertTrue((Path(directory) / 'media.partial').exists())

    def test_renderer_includes_exact_manifest_worker_and_commit(self):
        helpers = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='eval_media_render_test')
        source = helpers['render_storage_installer'](
            (ROOT / 'scripts/start-smal-eval-media-job.ps1').read_bytes(),
            (ROOT / 'scripts/smal-eval-media-worker.ps1').read_bytes(),
            (ROOT / 'docs/deployment-2026-10-28/eval-media-job-manifest.json').read_bytes(), 'b' * 40)
        for marker in [b'__MANIFEST_', b'__WORKER_', b'__SOURCE_COMMIT__']:
            self.assertNotIn(marker, source)
        self.assertIn(b'b' * 40, source)

    def test_guest_inspection_is_durable_read_only_and_bounds_hns(self):
        worker = (ROOT / 'scripts/smal-guest-input-worker.ps1').read_text()
        self.assertIn("Save-Inspection 'hyperv-query'", worker)
        self.assertIn("Save-Inspection 'nat-query'", worker)
        self.assertIn("Save-Inspection 'bounded-hns-query'", worker)
        self.assertIn('$child.WaitForExit(20000)', worker)
        self.assertIn('$child.Kill()', worker)
        self.assertIn('-Access ReadOnly', worker)
        self.assertIn('finally {', worker)
        for forbidden in ['New-VM', 'New-NetNat', 'New-VMSwitch', 'Format-Volume', 'Remove-Item', 'Start-Service']:
            self.assertNotIn(forbidden, worker)
        cleanup = (ROOT / 'scripts/stop-smal-guest-inspection.ps1').read_text()
        self.assertIn("Name='powershell.exe' AND CommandLine LIKE", cleanup)
        self.assertIn('$row.CreationDate', cleanup)
        self.assertNotIn('Dismount-DiskImage', cleanup)

    def test_guest_inspection_installer_renders_all_dependencies(self):
        helpers = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='input_render_test')
        source = helpers['render_storage_installer'](
            (ROOT / 'scripts/start-smal-guest-input-job.ps1').read_bytes(),
            (ROOT / 'scripts/smal-guest-input-worker.ps1').read_bytes(),
            (ROOT / 'docs/deployment-2026-10-28/guest-input-job-manifest.json').read_bytes(), 'c' * 40)
        self.assertNotIn(b'__MANIFEST_', source)
        self.assertNotIn(b'__WORKER_', source)
        self.assertNotIn(b'__SOURCE_COMMIT__', source)

    def test_guest_consent_is_bound_to_exact_proposal(self):
        decisions = json.loads((ROOT / 'docs/deployment-2026-10-28/deployment-decisions.json').read_text())
        proposal = (ROOT / 'docs/deployment-2026-10-28/local-guest-apply-proposal.md').read_bytes()
        self.assertEqual(hashlib.sha256(proposal).hexdigest(), decisions['localGuestPlanSha256'])
        self.assertTrue(decisions['localGuestPlanApproved'])
        self.assertTrue(decisions['hostBoundDpapiGuestSecretsApproved'])

    def test_buffered_hash_matches_sha256_and_records_exact_read_bytes(self):
        worker = (ROOT / 'scripts/smal-guest-input-worker.ps1').read_text()
        function = re.search(r'function Get-BufferedInspectionHash \{\n.*?\n\}', worker, re.S).group(0)
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as directory:
            path = Path(directory) / 'public-synthetic-media.bin'
            data = bytes(range(256)) * 17000 + b'final partial block'
            path.write_bytes(data)
            code = "$ErrorActionPreference='Stop';$state=@{hashBytesRead=0L;phase='test'};function Save-Inspection {}\n" + function + "\n$hash=Get-BufferedInspectionHash -Path '" + str(path) + "';@{hash=$hash;bytes=$state.hashBytesRead}|ConvertTo-Json -Compress"
            result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
            self.assertEqual(json.loads(result.stdout), {'hash': hashlib.sha256(data).hexdigest().upper(), 'bytes': len(data)})

    def test_hash_recovery_is_exact_read_only_phase_and_preserves_original(self):
        source = (ROOT / 'scripts/recover-smal-guest-input-hash.ps1').read_text()
        self.assertIn("$state.phase -ne 'azure-local-hash-check'", source)
        self.assertIn("'worker.before-buffered-hash.ps1'", source)
        self.assertIn("'state.before-buffered-hash.json'", source)
        self.assertIn('Stop-ScheduledTask -TaskName $taskName', source)
        self.assertLess(source.index('Media attached; hash-only recovery not applicable'), source.index('Stop-ScheduledTask'))
        self.assertIn('Inspection advanced during stop; preserve and inspect', source)
        for forbidden in ['Remove-Item', 'Format-Volume', 'Stop-Service', 'Stop-Process', 'Mount-DiskImage', 'New-NetNat']:
            self.assertNotIn(forbidden, source)


if __name__ == '__main__':
    unittest.main()
