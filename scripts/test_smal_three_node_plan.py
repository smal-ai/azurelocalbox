"""Offline three-node sizing and read-only inventory boundaries."""
from pathlib import Path
import copy
import base64
import hashlib
from decimal import Decimal
import json
import runpy
import re
import uuid
import subprocess
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]


class ThreeNodePlanTests(unittest.TestCase):
    def test_live_three_node_bindings_and_installed_console_are_verified_without_registration(self):
        h = runpy.run_path(str(ROOT / 'scripts/bind-smal-three-node-identities.py'), run_name='three_node_live_bindings_test')
        bound = h['build']()
        self.assertEqual(bound, json.loads((ROOT / 'docs/deployment-2026-10-29/three-node-local-identity-bindings.json').read_text()))
        self.assertEqual(len(bound['nodes']), 3)
        self.assertEqual(sum(len(row['s2dDataDeviceAllowlist']) for row in bound['nodes'].values()), 12)
        self.assertIsNone(bound['node03ArcPrincipalId'])
        self.assertFalse(bound['node03ArcRegistrationVerified'])
        installed = json.loads((ROOT / 'docs/deployment-2026-10-29/node03-arc-console-install-receipt.json').read_text())
        self.assertEqual(installed['status'], 'complete-installed-human-authentication-not-invoked')
        self.assertEqual(installed['result']['vmId'], bound['nodes']['LB-NODE03']['vmId'])
        self.assertFalse(installed['registrationInvoked'])
        self.assertFalse(installed['result']['registrationPerformed'])
        self.assertFalse(installed['result']['consoleOutputCaptured'])
        startup = json.loads((ROOT / 'docs/deployment-2026-10-29/start-20261029-102241-6d02b948.json').read_text())
        self.assertEqual(startup['status'], 'complete-host-and-four-guests-running-heartbeats-healthy')
        self.assertEqual(len(startup['guests']), 4)
        self.assertTrue(all(not row['startRequested'] and row['heartbeatReady'] for row in startup['guests']))

    def test_node03_completion_preserves_exact_new_vhd_to_guest_disk_identity(self):
        proof = json.loads((ROOT / 'docs/deployment-2026-10-29/node03-local-completion.json').read_text())
        self.assertEqual(proof['status'], 'complete-local-only-human-arc-authentication-next')
        self.assertEqual(proof['vm']['vmId'], '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9')
        self.assertFalse(proof['arcRegistrationVerified'])
        self.assertFalse(proof['clusterDeploymentVerified'])
        expected = set()
        for disk in proof['hostDisks']:
            guid = uuid.UUID(disk['diskId'])
            expected.add('60022480' + (guid.bytes_le[:6] + guid.bytes[-6:]).hex().upper())
        self.assertEqual(expected, {disk['uniqueId'] for disk in proof['guestDisks']})
        raw = [disk for disk in proof['guestDisks'] if not disk['isBoot'] and not disk['isSystem']]
        self.assertEqual(len(raw), 4)
        self.assertTrue(all(disk['style'] == 'RAW' and disk['size'] == 170 * 1024**3 for disk in raw))
        self.assertTrue(proof['clock']['selectedClockChecksPassed'])
        self.assertTrue(proof['connectivity']['transportChecksPassed'])
        self.assertFalse(proof['cleanup']['setupLogsNeedReview'])
        self.assertFalse(proof['cleanup']['answerFileCleanupNeedsReview'])
        path = ROOT / 'scripts/inspect-smal-three-node-live.ps1'
        code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)
    def test_node03_authentication_console_requires_successful_cleanup_and_real_tty(self):
        h = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='node03_console_render_test')
        proof = {'status': 'complete-local-only-human-arc-authentication-next', 'commonCredentialLoginVerified': True,
                 'vm': {'vmName': 'LB-NODE03', 'vmId': '11111111-1111-4111-8111-111111111111'},
                 'cleanup': {'setupLogsNeedReview': False, 'answerFileCleanupNeedsReview': False}}
        installer = (ROOT / 'scripts/install-smal-node03-arc-console.ps1').read_bytes().replace(b'__THREE_NODE_PRELUDE__', b'')
        console = (ROOT / 'scripts/register-smal-node03-console.ps1').read_bytes()
        approval = (ROOT / 'docs/deployment-2026-10-29/three-node-approval.json').read_bytes()
        result = h['render_node03_console'](installer, console, proof, approval, 'a' * 40)
        self.assertNotRegex(result, rb'__[A-Z0-9_]+__')
        proof['cleanup']['setupLogsNeedReview'] = True
        with self.assertRaises(RuntimeError): h['render_node03_console'](installer, console, proof, approval, 'a' * 40)
        launcher = runpy.run_path(str(ROOT / 'scripts/register-smal-node03-console.py'), run_name='node03_tty_test')
        with patch.object(launcher['OLD']['sys'].stdin, 'isatty', return_value=False):
            with self.assertRaises(RuntimeError): launcher['main']()
        source = (ROOT / 'scripts/register-smal-node03-console.py').read_text()
        self.assertIn('return subprocess.run(args, timeout=7200).returncode', source)
        self.assertNotIn('get-access-token', source)
        for name in ['register-smal-node03-console.ps1', 'install-smal-node03-arc-console.ps1']:
            path = ROOT / 'scripts' / name
            code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)
        console_text = console.decode()
        for forbidden in ['-ArmAccessToken', 'Get-AzAccessToken', 'Start-Transcript', 'Install-Module']:
            self.assertNotIn(forbidden, console_text)
        self.assertIn('[IO.FileMode]::CreateNew', console_text)

    def test_node03_observer_requires_exact_job_hashes_principal_and_no_recurrence(self):
        h = runpy.run_path(str(ROOT / 'scripts/watch-smal-node03.py'), run_name='node03_observer_test')
        installed = {'result': {'workerSha256': 'A' * 64, 'bundleSha256': 'B' * 64, 'sourceCommit': 'c' * 40}}
        good = {'status': 'complete', 'result': {'workerSha256': 'A' * 64, 'bundleSha256': 'B' * 64, 'actualTriggerCount': 0, 'principal': 'SYSTEM',
                'state': {'sourceCommit': 'c' * 40, 'azureRegistrationPerformed': False, 'clusterDeploymentPerformed': False}}}
        h['verify_observation'](good, installed)
        for key, value in [('actualTriggerCount', 1), ('workerSha256', 'other'), ('principal', 'other-user')]:
            bad = copy.deepcopy(good); bad['result'][key] = value
            with self.assertRaises(RuntimeError): h['verify_observation'](bad, installed)
        bad = copy.deepcopy(good); bad['result']['state']['azureRegistrationPerformed'] = True
        with self.assertRaises(RuntimeError): h['verify_observation'](bad, installed)
        reader = (ROOT / 'scripts/read-smal-node03-job.ps1').read_text()
        self.assertIn('[IO.FileShare]::Delete', reader)
        self.assertIn('Read-Node03SharedJson', reader)

    def test_node03_helpers_are_exact_derivations_with_no_forest_creation(self):
        h = runpy.run_path(str(ROOT / 'scripts/derive-smal-node03-helpers.py'), run_name='node03_derive_test')
        for name, source in h['build']().items():
            path = ROOT / 'scripts/node03' / name
            self.assertEqual(path.read_text(), source)
            code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)
        self.assertNotIn('Install-ADDSForest', h['build']()['node03-direct.ps1'])
        self.assertNotIn('Set-ADAccountPassword', h['build']()['node03-direct.ps1'])
        self.assertIn("'LB-NODE03' = @{ memory = 64GB; processors = 8; nested = $true }", h['build']()['node03-vm.ps1'])
        self.assertIn('W:\\AzureLocalBox\\Guests\\three-node-20261029-01\\', h['build']()['node03-image.ps1'])

    def test_resize_job_and_worker_parse_and_keep_registration_out_of_local_work(self):
        for name in ['resize-smal-existing-nodes.ps1', 'install-smal-node03-job.ps1', 'smal-node03-worker.ps1', 'read-smal-node03-job.ps1']:
            path = ROOT / 'scripts' / name
            code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)
            self.assertNotIn('Invoke-AzStackHciArcInitialization', path.read_text())
        resize = (ROOT / 'scripts/resize-smal-existing-nodes.ps1').read_text()
        self.assertIn('-RetainVhdCopiesOnSource', resize)
        self.assertIn('relocationSourceSha256', resize)
        self.assertIn('Remove-Item -LiteralPath $move.source', resize)
        self.assertNotIn('Format-Volume', resize)
        self.assertNotIn('-TurnOff', resize)
        installer = (ROOT / 'scripts/install-smal-node03-job.ps1').read_text()
        self.assertNotIn('-Trigger', installer)
        self.assertNotIn('-AtStartup', installer)
        self.assertNotIn('RestartCount', installer)
        worker = (ROOT / 'scripts/smal-node03-worker.ps1').read_text()
        self.assertIn('[IO.FileMode]::CreateNew', worker)
        self.assertIn('Complete-LabGuestBootstrapSecret', worker)
        self.assertIn("-Role 'cluster-node-admin'", worker)
        self.assertIn('Inspect before another attempt to avoid account lockout.', (ROOT / 'scripts/node03/node03-direct.ps1').read_text())

    def test_node03_native_heartbeat_compiles_without_starting_it(self):
        worker = (ROOT / 'scripts/smal-node03-worker.ps1').read_text()
        code = re.search("Add-Type -TypeDefinition @'\\n(.*?)\\n'@", worker, re.S).group(1)
        encoded = base64.b64encode(code.encode()).decode()
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', "Add-Type -TypeDefinition ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + encoded + "')))"], capture_output=True, text=True, check=True, timeout=30)

    def test_exact_three_node_approval_hashes_and_public_context(self):
        out = ROOT / 'docs/deployment-2026-10-29'
        consent = json.loads((out / 'three-node-approval.json').read_text())
        self.assertTrue(consent['approved'])
        self.assertEqual(consent['humanAnswer'], 'Approved')
        for suffix, key in [('json', 'proposalJsonSha256'), ('md', 'proposalMarkdownSha256')]:
            self.assertEqual(hashlib.sha256((out / ('three-node-proposal.' + suffix)).read_bytes()).hexdigest(), consent[key])
        h = runpy.run_path(str(ROOT / 'scripts/smal-three-node-approval.py'), run_name='three_node_context_test')
        disk = {'id': h['DISK_ID'], 'uniqueId': '11111111-1111-4111-8111-111111111111', 'diskSizeGB': 2048, 'sku': {'name': 'Premium_LRS'}}
        context = h['context'](disk)
        self.assertEqual(base64.b64decode(context['approvalBase64']), (out / 'three-node-approval.json').read_bytes())
        self.assertEqual(context['lun'], 8)
        disk['diskSizeGB'] = 4096
        with self.assertRaises(RuntimeError): h['context'](disk)

    def test_new_disk_template_and_preview_cannot_modify_existing_storage(self):
        h = runpy.run_path(str(ROOT / 'scripts/apply-smal-three-node-disk.py'), run_name='new_disk_test')
        data = {'status': 'Succeeded', 'changes': [{'changeType': 'Create', 'resourceId': h['DISK_ID'], 'after': {'type': 'Microsoft.Compute/disks', 'location': 'southafricanorth', 'sku': {'name': 'Premium_LRS'}, 'properties': {'diskSizeGB': 2048, 'creationData': {'createOption': 'Empty'}, 'networkAccessPolicy': 'DenyAll', 'publicNetworkAccess': 'Disabled'}}}]}
        h['validate_preview'](data, set())
        for key, value in [('diskSizeGB', 4096), ('publicNetworkAccess', 'Enabled')]:
            bad = copy.deepcopy(data); bad['changes'][0]['after']['properties'][key] = value
            with self.assertRaises(RuntimeError): h['validate_preview'](bad, set())
        bad = copy.deepcopy(data); bad['changes'][0]['changeType'] = 'Modify'
        with self.assertRaises(RuntimeError): h['validate_preview'](bad, set())
        result = subprocess.run(['az', 'bicep', 'build', '--file', str(ROOT / h['TEMPLATE']), '--stdout', '--only-show-errors'], check=True, capture_output=True, text=True, timeout=90)
        template = json.loads(result.stdout)
        self.assertEqual(len(template['resources']), 1)
        self.assertEqual(template['resources'][0]['type'], 'Microsoft.Compute/disks')
        self.assertEqual(template['resources'][0]['properties']['diskSizeGB'], 2048)

    def test_new_disk_admission_scripts_parse_and_never_target_disk_zero_or_pool_format(self):
        for name in ['smal-three-node-prelude.ps1', 'prepare-smal-node03-disk.ps1', 'format-smal-node03-disk.ps1']:
            path = ROOT / 'scripts' / name
            code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)
        source = (ROOT / 'scripts/format-smal-node03-disk.ps1').read_text()
        self.assertIn('Initialize-Disk -UniqueId $record.windowsUniqueId', source)
        self.assertIn('$newPhysical.Count -eq 1', source)
        self.assertIn('$disk.IsBoot -or $disk.IsSystem', source)
        for forbidden in ['-DiskNumber 0', 'New-StoragePool', 'New-VirtualDisk', 'Clear-Disk', 'Resize-VirtualDisk']:
            self.assertNotIn(forbidden, source)

    def test_final_premium_reconciliation_keeps_three_node_plan_unapplied(self):
        receipt = json.loads((ROOT / 'docs/deployment-2026-10-29/premium-disk-conversion-reconciled-result.json').read_text())
        self.assertEqual(receipt['status'], 'complete-nine-existing-premium-disks-host-guests-storage-and-arc-verified')
        self.assertEqual(len(receipt['disks']), 9)
        self.assertTrue(all(row['sku'] == 'Premium_LRS' and row['state'] == 'Attached' for row in receipt['disks']))
        self.assertEqual(receipt['host'], {'power': 'PowerState/running', 'agentReady': True})
        self.assertEqual(len(receipt['guests']), 3)
        self.assertTrue(all(row['state'] == 'Running' for row in receipt['guests']))
        self.assertTrue(all(row['status'] == 'Connected' for row in receipt['arcMachines']))
        self.assertEqual(receipt['pool']['health'], 'Healthy')
        self.assertFalse(receipt['thirdNodePlanApplied'])
        self.assertFalse(receipt['platformReadinessVerified'])
        self.assertTrue(receipt['originalConversionAndStartupFailuresRetained'])

    def test_live_premium_conversion_preserved_existing_disk_identity_and_encryption(self):
        receipt = json.loads((ROOT / 'docs/deployment-2026-10-29/premium-disk-conversion-after-cli-reconciliation.json').read_text())
        self.assertEqual(len(receipt['diskEffects']), 9)
        self.assertEqual(len(receipt['disksAfter']), 9)
        self.assertTrue(all(row['sku'] == 'Premium_LRS' for row in receipt['disksAfter']))
        before = {row['id']: row for row in receipt['disksBefore']}
        for row in receipt['disksAfter']:
            for key in ['uniqueId', 'diskSizeGB', 'encryptionType', 'diskEncryptionSetId', 'securityType']:
                self.assertEqual(row.get(key), before[row['id']].get(key))
        self.assertFalse(receipt['newDisksCreated'])
        self.assertFalse(receipt['guestProfilesChanged'])
        # Preserve the truthful original restore failure. Later successful startup
        # is independent evidence, not a rewrite of the partial run receipt.
        self.assertEqual(receipt['phase'], 'restore-existing-host-and-guests')
        self.assertEqual(receipt['status'], 'failed-inspect-before-resume')
        restored = json.loads((ROOT / 'docs/deployment-2026-10-29/start-20261029-080708-7389325a.json').read_text())
        self.assertEqual(restored['status'], 'complete-host-and-three-guests-running-heartbeats-healthy')
    def test_entra_reads_omit_subscription_but_disk_commands_keep_it(self):
        h = runpy.run_path(str(ROOT / 'scripts/convert-smal-host-premium.py'), run_name='premium_cli_test')
        scope = h['az'].__globals__
        process = Mock(return_value=Mock(stdout='null'))
        with patch.dict(scope, subprocess=Mock(run=process)):
            h['az'](['ad', 'signed-in-user', 'show'])
            self.assertNotIn('--subscription', process.call_args.args[0])
            h['az'](['disk', 'list'])
            self.assertIn('--subscription', process.call_args.args[0])

    def test_proposed_three_node_capacity_and_premium_scope_are_bounded(self):
        h = runpy.run_path(str(ROOT / 'scripts/plan-smal-three-node.py'), run_name='three_node_plan_test')
        proposal = h['build']()
        self.assertFalse(proposal['ownerApproved'])
        self.assertFalse(proposal['hostResizeRequested'])
        self.assertEqual(proposal['hostSkuBeforeAndAfter'], 'Standard_E32s_v6')
        self.assertEqual(proposal['guestMemoryTotalBytes'], 196 * 1024**3)
        self.assertEqual(proposal['assignedVcpusTotal'], 26)
        self.assertTrue(all(x['memoryGiB'] == 64 and x['vcpus'] == 8 for x in proposal['guestTargetProfiles']))
        self.assertTrue(all(x['fits'] for x in proposal['volumeBudgets'].values()))
        self.assertEqual(len(proposal['diskConversions']), 9)
        self.assertTrue(all(x['skuAfter'] == 'Premium_LRS' for x in proposal['diskConversions']))
        self.assertEqual(proposal['newDisk']['sku'], 'Premium_LRS')
        self.assertEqual(proposal['newDisk']['sizeGiB'], 2048)
        self.assertFalse(proposal['newDisk']['joinExistingPool'])
        self.assertEqual(proposal['existingVhdRelocation']['lun'], 4)
        self.assertIsNone(proposal['newNode']['vmId'])
        self.assertIsNone(proposal['cloudDelta']['node03DataUniqueIdAllowlist'])
        self.assertEqual(proposal['cloudDelta']['witnessTypeParameter'], 'No Witness')
        self.assertFalse(proposal['cloudDelta']['witnessCredentialReadOrUpload'])
        costs = proposal['retailDiskCapacityUsdPerMonth']
        self.assertEqual(Decimal(costs['after']) - Decimal(costs['before']), Decimal(costs['delta']))
        self.assertEqual(Decimal(costs['additionalDisk']), Decimal('315.6'))
        for name, value in [('three-node-proposal.json', json.dumps(proposal, indent=2) + '\n'), ('three-node-proposal.md', h['markdown'](proposal))]:
            self.assertEqual((ROOT / 'docs/deployment-2026-10-29' / name).read_text(), value)

    def test_one_tib_addition_does_not_fit_full_virtual_growth_and_reserves(self):
        h = runpy.run_path(str(ROOT / 'scripts/plan-smal-three-node.py'), run_name='three_node_budget_test')
        self.assertFalse(h['budget'](1023 * 1024**3, 978 * 1024**3, 64 * 1024**3)['fits'])

    def test_premium_conversion_refuses_missing_foreign_resized_or_wrong_tier_disks(self):
        h = runpy.run_path(str(ROOT / 'scripts/convert-smal-host-premium.py'), run_name='premium_conversion_test')
        expected = json.loads((ROOT / 'docs/deployment-2026-10-29/three-node-premium-cloud-sizing.json').read_text())['disks']
        h['verify_disks'](expected, expected)
        premium = copy.deepcopy(expected)
        for row in premium: row['sku'] = 'Premium_LRS'
        h['verify_disks'](premium, expected, final=True)
        with self.assertRaises(RuntimeError): h['verify_disks'](expected, expected, final=True)
        for key, value in [('managedBy', '/other-vm'), ('diskSizeGB', 4096), ('sku', 'UltraSSD_LRS'), ('id', '/other-disk')]:
            bad = copy.deepcopy(expected); bad[0][key] = value
            with self.assertRaises(RuntimeError): h['verify_disks'](bad, expected)
        with self.assertRaises(RuntimeError): h['verify_disks'](expected[:-1], expected)

    def test_conversion_shutdown_is_graceful_and_never_resizes_or_formats(self):
        path = ROOT / 'scripts/stop-smal-guests-for-premium.ps1'
        code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)
        source = path.read_text()
        for forbidden in ['-TurnOff', '-Force', 'Set-VM', 'Format-Volume', 'Remove-VM', 'Resize-VHD']:
            self.assertNotIn(forbidden, source)
        script = (ROOT / 'scripts/convert-smal-host-premium.py').read_text()
        self.assertIn("'--sku', 'Premium_LRS'", script)
        self.assertNotIn("'disk', 'create'", script)
        self.assertNotIn("'--size-gb'", script)

    def test_capacity_inspection_parses_and_does_not_change_guests_or_storage(self):
        path = ROOT / 'scripts/inspect-smal-three-node-capacity.ps1'
        code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)
        source = path.read_text()
        for forbidden in ['Set-VM', 'Stop-VM', 'Resize-VHD', 'Move-VMStorage', 'Format-Volume', 'New-VHD', 'Remove-Item']:
            self.assertNotIn(forbidden, source)
        self.assertIn('mutationPerformed = $false', source)


if __name__ == '__main__':
    unittest.main()
