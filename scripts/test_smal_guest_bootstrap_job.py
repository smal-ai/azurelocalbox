"""Offline boundary tests for the one-shot local bootstrap continuation."""
import base64
import json
from pathlib import Path
import re
import runpy
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKER = (ROOT / 'scripts/smal-guest-bootstrap-worker.ps1').read_text()


class GuestBootstrapJobTests(unittest.TestCase):
    def test_scripts_parse(self):
        for name in ['start-smal-guest-bootstrap-job.ps1', 'smal-guest-bootstrap-worker.ps1', 'read-smal-guest-bootstrap-job.ps1', 'inspect-smal-guest-bootstrap-failure.ps1', 'recover-smal-guest-bootstrap-network.ps1', 'inspect-smal-node-cleanup-failure.ps1', 'recover-smal-node-cleanup.ps1']:
            code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(ROOT / 'scripts' / name) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)

    def test_packaging_is_exact_and_manifest_cannot_expand_cloud_scope(self):
        helpers = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='guest_boot_render_test')
        files = {name: (ROOT / 'scripts' / name).read_bytes() for name in ['smal-guest-secret-functions.ps1', 'smal-guest-direct-functions.ps1']}
        manifest = (ROOT / 'docs/deployment-2026-10-28/local-guest-bootstrap-manifest.json').read_bytes()
        source = helpers['render_guest_bootstrap_installer']((ROOT / 'scripts/start-smal-guest-bootstrap-job.ps1').read_bytes(), WORKER.encode(), manifest, files, 'e' * 40)
        self.assertNotRegex(source, rb'__[A-Z_]+__')
        payloads = [base64.b64decode(value) for value in re.findall(rb"FromBase64String\('([A-Za-z0-9+/=]+)'\)", source)]
        self.assertEqual(len(payloads), 3)
        self.assertNotRegex(payloads[1], rb'__[A-Z_]+__')
        self.assertEqual({item['name'] for item in json.loads(payloads[2])['files']}, set(files))
        data = json.loads(manifest)
        self.assertFalse(data['registerAzureResources'])
        self.assertFalse(data['joinNodesToDomain'])
        self.assertFalse(data['deployAksOrWorkloads'])
        dependency = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-guest-image-job-start-20261028.json').read_text())
        self.assertEqual(data['imageSourceCommit'], dependency['result']['sourceCommit'])
        self.assertEqual(data['imageWorkerSha256'], dependency['result']['workerSha256'])

    def test_dependency_is_waited_on_not_reinstalled_or_retried(self):
        self.assertIn("$images.status -eq 'guests-created-off'", WORKER)
        self.assertIn('Image dependency failed or stopped. No guest boot.', WORKER)
        self.assertIn('$m.imageWorkerSha256', WORKER)
        for forbidden in ['Start-ScheduledTask', 'Stop-ScheduledTask', 'Register-ScheduledTask', 'New-VM', 'Register-AzStackHCI', 'Connect-AzAccount', 'New-AzRoleAssignment', ' az ', 'Set-NetFirewall', 'CredSSP', 'TrustedHosts']:
            self.assertNotIn(forbidden, WORKER)
        installer = (ROOT / 'scripts/start-smal-guest-bootstrap-job.ps1').read_text()
        self.assertIn('-MultipleInstances IgnoreNew', installer)
        self.assertNotIn('-Trigger', installer)
        self.assertNotIn('-RestartCount', installer)

    def test_wrong_vm_identity_cannot_reach_boot(self):
        function = re.search(r'function Start-ExactGuest \{\n.*?\n\}', WORKER, re.S).group(0)
        code = "$ErrorActionPreference='Stop';$images=@{virtualMachines=@(@{vmName='LB-DC01';vmId='11111111-1111-1111-1111-111111111111'})};function Get-VM {param($Id)[pscustomobject]@{Name='OtherGuest';State='Off';Generation=2}};function Start-VM {throw 'UNEXPECTED_MUTATION'};\n" + function + "\ntry{Start-ExactGuest 'LB-DC01'}catch{if($_.Exception.Message -like '*Guest VM identity/state/security differs*'){exit 0};exit 2};exit 3"
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_reboots_are_inside_guest_sessions_not_outer_host(self):
        path = ROOT / 'scripts/smal-guest-bootstrap-worker.ps1'
        code = "$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);$items=@($a.FindAll({param($n)$n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Restart-Computer'},$true));foreach($item in $items){$p=$item.Parent;$found=$false;while($p){if($p -is [System.Management.Automation.Language.CommandAst] -and $p.GetCommandName() -eq 'Invoke-Command'){$found=$p.Extent.Text.Contains('-Session $session');break};$p=$p.Parent};if(-not $found){exit 1}};if($items.Count -ne 2){exit 2}"
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)

    def test_new_login_and_secret_cleanup_gate_the_local_result(self):
        self.assertIn('Complete-LabGuestBootstrapSecret', WORKER)
        self.assertIn("$state.newCredentialLoginVerified['LB-DC01'] = $true", WORKER)
        self.assertIn('$state.newCredentialLoginVerified[$row.name] = $true', WORKER)
        self.assertIn('$state.cleanup[$name].setupLogsNeedReview', WORKER)
        self.assertIn("'local-bootstrap-configured-checks-pending'", WORKER)
        self.assertIn('azureRegistrationPerformed = $false', WORKER)
        self.assertIn('clusterBootstrapComplete = $false', WORKER)

    def test_native_heartbeat_only_contains_process_and_timestamp(self):
        csharp = re.search(r"Add-Type -TypeDefinition @'\n(.*?)\n'@", WORKER, re.S).group(1)
        encoded = base64.b64encode(csharp.encode()).decode()
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as directory:
            code = "$ErrorActionPreference='Stop';Add-Type -TypeDefinition ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + encoded + "')));[LocalBoxGuestBootstrapHeartbeat]::Start('" + directory + "',$PID);try{$s=[Diagnostics.Stopwatch]::StartNew();while(-not(Test-Path '" + directory + "/heartbeat.json') -and $s.Elapsed.TotalSeconds -lt 5){Start-Sleep -Milliseconds 10};Get-Content '" + directory + "/heartbeat.json' -Raw}finally{[LocalBoxGuestBootstrapHeartbeat]::Stop()}"
            result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
            self.assertEqual(set(json.loads(result.stdout)), {'processId', 'atUtc'})

    def test_network_recovery_is_exact_and_never_recreates_images_or_vms(self):
        source = (ROOT / 'scripts/recover-smal-guest-bootstrap-network.ps1').read_text()
        self.assertIn("$state.phase -ne 'LB-DC01-configure-exact-guest-network'", source)
        self.assertIn('Network effects exist or adapter identity changed', source)
        self.assertIn('Guest protection is not ready', source)
        self.assertIn('Original source/marker differs', source)
        self.assertIn('originalMarkerRetained = $true', source)
        self.assertIn('[IO.FileMode]::CreateNew', source)
        self.assertIn('-ResumeVerified', source)
        self.assertIn("'worker.before-network-recovery.ps1'", WORKER)
        self.assertIn("'network-recovery-01.started'", WORKER)
        self.assertIn("Save-BootstrapState 'resume-existing-dc-no-repeat-boot'", WORKER)
        for forbidden in ['New-VM', 'Start-VM', 'New-VHD', 'Format-Volume', 'Initialize-Disk', 'Remove-Item', 'Stop-Service']:
            self.assertNotIn(forbidden, source)

    def test_network_recovery_renders_all_new_pinned_payloads(self):
        helpers = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='boot_network_recovery_render_test')
        files = {name: (ROOT / 'scripts' / name).read_bytes() for name in ['smal-guest-secret-functions.ps1', 'smal-guest-direct-functions.ps1']}
        source = helpers['render_guest_bootstrap_installer']((ROOT / 'scripts/recover-smal-guest-bootstrap-network.ps1').read_bytes(), WORKER.encode(), (ROOT / 'docs/deployment-2026-10-28/local-guest-bootstrap-manifest.json').read_bytes(), files, 'f' * 40)
        self.assertNotRegex(source, rb'__[A-Z_]+__')
        # Reconstruct the actual backup-name expression used by the recovery.
        code = "@('state.json','worker.ps1','bundle.json')|ForEach-Object {$_.Replace('.json','').Replace('.ps1','') + '.before-network-recovery.' + $(if($_.EndsWith('.ps1')){'ps1'}else{'json'})}|ConvertTo-Json -Compress"
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
        self.assertEqual(json.loads(result.stdout), ['state.before-network-recovery.json', 'worker.before-network-recovery.ps1', 'bundle.before-network-recovery.json'])

    def test_mutable_state_conversion_preserves_retained_proofs_and_arrays(self):
        function = re.search(r'function ConvertTo-MutableBootstrapValue \{\n.*?\n\}', WORKER, re.S).group(0)
        code = "$ErrorActionPreference='Stop';\n" + function + "\n$inputValue='{\"domain\":{\"dnsRoot\":\"ad.localbox.test\"},\"cleanup\":{\"LB-DC01\":{\"verified\":true}},\"empty\":[],\"single\":[{\"ip\":\"10.64.0.10\"}]}';$result=ConvertTo-MutableBootstrapValue ($inputValue|ConvertFrom-Json);$result.cleanup['LB-NODE01']=@{verified=$true};$result|ConvertTo-Json -Depth 9 -Compress"
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True, timeout=30)
        data = json.loads(result.stdout)
        self.assertEqual(data['domain']['dnsRoot'], 'ad.localbox.test')
        self.assertTrue(data['cleanup']['LB-DC01']['verified'])
        self.assertTrue(data['cleanup']['LB-NODE01']['verified'])
        self.assertEqual(data['empty'], [])
        self.assertEqual(data['single'], [{'ip': '10.64.0.10'}])

    def test_node_cleanup_recovery_preserves_dc_and_skips_completed_node_work(self):
        source = (ROOT / 'scripts/recover-smal-node-cleanup.ps1').read_text()
        self.assertIn("$state.phase -ne 'LB-NODE01-clean-owned-answer-files-and-rotate'", source)
        self.assertIn('dcAndNode01ConfigurationRetained = $true', source)
        self.assertIn('node01OriginalCredentialLoginVerified = $true', source)
        self.assertIn('-ResumeNodeCleanup', source)
        self.assertIn("'worker.before-node-cleanup-recovery.ps1'", WORKER)
        self.assertIn('$state = ConvertTo-MutableBootstrapValue $initial', WORKER)
        self.assertIn("if (-not $ResumeNodeCleanup) {", WORKER)
        self.assertIn('if (-not $resumeThisNode) {', WORKER)
        self.assertIn('$state.cleanup[$name].answerFileCleanupNeedsReview', WORKER)
        self.assertIn('$state.clockEvidence[$name].selectedClockChecksPassed', WORKER)
        for forbidden in ['New-VM', 'Start-VM', 'New-VHD', 'Format-Volume', 'Initialize-Disk', 'Install-ADDSForest', 'Remove-Item', 'Set-Date']:
            self.assertNotIn(forbidden, source)

    def test_completed_local_summary_matches_live_receipt_without_claiming_platform_readiness(self):
        summary = json.loads((ROOT / 'docs/deployment-2026-10-28/local-bootstrap-result.json').read_text())
        receipt = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-node-cleanup-recovery-progress-20261028-03.json').read_text())
        result = receipt['result']; state = result['state']
        self.assertEqual(receipt['status'], 'complete')
        self.assertEqual(result['lastTaskResult'], 0)
        self.assertEqual(summary['status'], state['status'])
        self.assertEqual(summary['completedAtUtc'], state['atUtc'])
        self.assertEqual(summary['independentlyObservedAtUtc'], result['atUtc'])
        self.assertEqual(len(summary['guests']), 3)
        for guest in summary['guests']:
            name = guest['name']
            self.assertTrue(state['newCredentialLoginVerified'][name])
            self.assertTrue(state['connectivity'][name]['transportChecksPassed'])
            self.assertTrue(state['natEvidence'][name]['observedSourceTranslation'])
            self.assertFalse(state['cleanup'][name]['setupLogsNeedReview'])
            self.assertFalse(state['cleanup'][name].get('answerFileCleanupNeedsReview', False))
        for name in ['LB-NODE01', 'LB-NODE02']:
            self.assertTrue(state['clockEvidence'][name]['selectedClockChecksPassed'])
            self.assertTrue(state['guestConfiguration'][name]['nestedHyperv']['vmmsRunning'])
        self.assertFalse(summary['platformReadinessVerified'])
        self.assertFalse(summary['clusterBootstrapComplete'])
        self.assertFalse(summary['azureRegistrationPerformed'])


if __name__ == '__main__':
    unittest.main()
