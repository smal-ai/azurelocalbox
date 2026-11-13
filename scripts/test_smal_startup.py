"""Offline daily-startup boundaries. Never starts Azure or Hyper-V machines."""
import copy
import json
from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]


class StartupTests(unittest.TestCase):
    def setUp(self):
        self.h = runpy.run_path(str(ROOT / 'scripts/start-smal-localbox.py'), run_name='startup_test')
        self.scope = self.h['ensure_host'].__globals__


    def test_startup_accepts_current_account_without_a_historical_user_id_pin(self):
        account = {'id': self.h['SUB'], 'tenantId': self.h['TENANT'], 'state': 'Enabled',
                   'user': {'name': 'personal-account@example.invalid', 'type': 'user'}}
        self.h['verify_account'](account)
        self.assertNotIn('PRINCIPAL', self.h)
        self.assertNotIn('signed-in-user', (ROOT / 'scripts/start-smal-localbox.py').read_text())

    def test_startup_still_rejects_wrong_subscription_tenant_or_disabled_account(self):
        good = {'id': self.h['SUB'], 'tenantId': self.h['TENANT'], 'state': 'Enabled'}
        for key, value in [('id', 'other-subscription'), ('tenantId', 'other-tenant'), ('state', 'Disabled')]:
            with self.subTest(field=key), self.assertRaisesRegex(RuntimeError, 'subscription/tenant'):
                self.h['verify_account'](good | {key: value})
    def test_node03_startup_binding_comes_from_completed_real_guest(self):
        proof = json.loads((ROOT / 'docs/deployment-2026-10-29/node03-local-completion.json').read_text())
        self.assertEqual(len(self.h['GUESTS']), 4)
        self.assertEqual(self.h['GUESTS']['LB-NODE03'], proof['vm']['vmId'])
        self.assertTrue(proof['commonCredentialLoginVerified'])
        self.assertFalse(proof['cleanup']['setupLogsNeedReview'])
        self.assertFalse(proof['cleanup']['answerFileCleanupNeedsReview'])

    def test_running_host_is_not_restarted(self):
        ready = {'power': 'PowerState/running', 'agentReady': True}
        record = {}
        with patch.dict(self.scope, az=Mock(), host_state=Mock(return_value=ready)):
            self.h['ensure_host'](ready, 60, record, Mock())
            self.scope['az'].assert_not_called()
        self.assertFalse(record['hostStartRequested'])

    def test_missing_power_state_during_start_is_observed_not_restarted(self):
        scope = self.h['host_state'].__globals__
        with patch.dict(scope, az=Mock(return_value={'id': self.h['VM_ID'], 'instanceView': {'statuses': [{'code': 'ProvisioningState/updating'}]}})):
            self.assertEqual(self.h['host_state'](), {'power': 'PowerState/unknown', 'agentReady': False})
        unknown = {'power': 'PowerState/unknown', 'agentReady': False}
        ready = {'power': 'PowerState/running', 'agentReady': True}
        clock = Mock(); clock.monotonic.return_value = 0
        command = Mock()
        with patch.dict(self.scope, az=command, host_state=Mock(side_effect=[unknown, ready]), time=clock):
            self.h['ensure_host']({'power': 'PowerState/starting', 'agentReady': False}, 60, {}, Mock())
        command.assert_not_called(); clock.sleep.assert_called_once_with(10)
        with patch.dict(self.scope, az=command):
            with self.assertRaises(RuntimeError): self.h['ensure_host'](unknown, 60, {}, Mock())
        command.assert_not_called()

    def test_stopped_host_gets_exactly_one_start_then_waits(self):
        for power in ['PowerState/stopped', 'PowerState/deallocated']:
            initial = {'power': power, 'agentReady': False}
            ready = {'power': 'PowerState/running', 'agentReady': True}
            record = {}
            command = Mock()
            with patch.dict(self.scope, az=command, host_state=Mock(return_value=ready)):
                self.h['ensure_host'](initial, 60, record, Mock())
            command.assert_called_once_with(['vm', 'start', '--subscription', self.h['SUB'], '-g', self.h['RG'], '-n', self.h['HOST'], '--no-wait'])
            self.assertTrue(record['hostStartRequested'])

    def test_starting_host_is_observed_without_duplicate_request(self):
        ready = {'power': 'PowerState/running', 'agentReady': True}
        command = Mock()
        with patch.dict(self.scope, az=command, host_state=Mock(return_value=ready)):
            self.h['ensure_host']({'power': 'PowerState/starting', 'agentReady': False}, 60, {}, Mock())
        command.assert_not_called()

    def test_shutdown_transition_is_refused(self):
        command = Mock()
        with patch.dict(self.scope, az=command):
            for power in ['PowerState/stopping', 'PowerState/deallocating', 'unknown']:
                with self.assertRaises(RuntimeError):
                    self.h['ensure_host']({'power': power}, 60, {}, Mock())
        command.assert_not_called()

    def test_uncertain_start_is_not_repeated(self):
        command = Mock(side_effect=subprocess.TimeoutExpired('az', 90))
        record = {}
        with patch.dict(self.scope, az=command):
            with self.assertRaises(subprocess.TimeoutExpired):
                self.h['ensure_host']({'power': 'PowerState/deallocated'}, 60, record, Mock())
        self.assertTrue(record['hostStartRequested'])
        self.assertEqual(command.call_count, 1)

    def test_wait_is_bounded_even_when_host_stays_down(self):
        state = {'power': 'PowerState/starting', 'agentReady': False}
        clock = Mock()
        clock.monotonic.side_effect = [0, 61]
        with patch.dict(self.scope, time=clock, host_state=Mock(return_value=state), az=Mock()):
            with self.assertRaises(TimeoutError):
                self.h['ensure_host'](state, 60, {}, Mock())
        clock.sleep.assert_not_called()

    def test_private_routes_required_not_vpn_active_label(self):
        scope = self.h['verify_private_route'].__globals__
        with patch.dict(scope, subprocess=Mock(check_output=Mock(return_value=json.dumps([{'dev': 'wlp195s0'}]))), socket=Mock()):
            with self.assertRaises(RuntimeError):
                self.h['verify_private_route']()
            scope['socket'].create_connection.assert_not_called()

    def test_healthy_private_path_does_not_touch_vpn(self):
        record = {}; command = Mock()
        with patch.dict(self.scope, verify_private_route=Mock(), nmcli=command):
            self.h['ensure_private_vpn'](record,Mock())
        command.assert_not_called()
        self.assertTrue(record['vpn']['privatePathVerified'])
        self.assertFalse(record['vpn']['connectRequested'])

    def test_disconnected_existing_vpn_is_connected_once_by_uuid(self):
        ident = '11111111-2222-4333-8444-555555555555'
        command = Mock(side_effect=[ident + '\nvpn','', 'connected'])
        check = Mock(side_effect=[RuntimeError('No route'),None]); record = {}
        with patch.dict(self.scope, verify_private_route=check, nmcli=command):
            self.h['ensure_private_vpn'](record,Mock())
        self.assertEqual(command.call_args_list[-1].args[0],['connection','up','uuid',ident])
        self.assertEqual(command.call_count,3)
        self.assertFalse(record['vpn']['disconnectRequested'])
        self.assertTrue(record['vpn']['privatePathVerified'])

    def test_stale_active_vpn_gets_one_down_up_and_real_path_recheck(self):
        ident = '11111111-2222-4333-8444-555555555555'
        command = Mock(side_effect=[ident + '\nvpn',ident,'disconnected','connected'])
        check = Mock(side_effect=[TimeoutError('Resolver unreachable'),None]); record = {}
        with patch.dict(self.scope, verify_private_route=check, nmcli=command):
            self.h['ensure_private_vpn'](record,Mock())
        self.assertEqual([call.args[0] for call in command.call_args_list[-2:]],
                         [['connection','down','uuid',ident],['connection','up','uuid',ident]])
        self.assertEqual(check.call_count,2)
        self.assertTrue(record['vpn']['disconnectRequested'])
        self.assertFalse(record['vpn']['profileOrCredentialsChanged'])

    def test_vpn_recovery_failure_is_not_repeated_or_marked_healthy(self):
        ident = '11111111-2222-4333-8444-555555555555'
        command = Mock(side_effect=[ident + '\nvpn','', 'connected']); record = {}
        with patch.dict(self.scope, verify_private_route=Mock(side_effect=RuntimeError('still missing')),nmcli=command):
            with self.assertRaises(RuntimeError): self.h['ensure_private_vpn'](record,Mock())
        self.assertEqual(command.call_count,3)
        self.assertFalse(record['vpn']['privatePathVerified'])

    def test_vpn_missing_wrong_type_or_ambiguous_never_creates_a_profile(self):
        for profile in ['', '11111111-2222-4333-8444-555555555555\nethernet','one\nvpn\ntwo\nvpn']:
            command = Mock(return_value=profile)
            with patch.dict(self.scope, verify_private_route=Mock(side_effect=RuntimeError('No route')),nmcli=command):
                with self.assertRaises(RuntimeError): self.h['ensure_private_vpn']({},Mock())
            self.assertEqual(command.call_count,1)

    def test_nmcli_failure_suppresses_raw_auth_diagnostics(self):
        runner = Mock(return_value=Mock(returncode=1,stdout='',stderr='SYNTHETIC-CREDENTIAL-DIAGNOSTIC'))
        with patch.object(self.scope['subprocess'],'run',runner):
            with self.assertRaises(RuntimeError) as error: self.h['nmcli'](['connection','up','uuid','synthetic'])
        self.assertNotIn('SYNTHETIC-CREDENTIAL-DIAGNOSTIC',str(error.exception))
        self.assertNotIn('--ask',runner.call_args.args[0])

    def test_daily_health_evidence_verifies_all_four_guests_without_claiming_deployment(self):
        record = json.loads((ROOT / 'docs/deployment-2026-10-29/daily-health-verified-20261030.json').read_text())
        self.assertEqual(record['status'],'startup-and-read-only-health-checks-passed')
        self.assertTrue(record['fourGuestHeartbeatsHealthy'])
        self.assertTrue(record['threeArcIdentitiesConnected'])
        self.assertTrue(record['threeBootstrapStatusesSucceeded'])
        self.assertEqual(record['exactApprovedRawDataDisksVerified'],12)
        self.assertFalse(record['validateOrDeploySubmitted'])
        self.assertFalse(record['platformReadinessVerified'])
        self.assertFalse(record['deploymentWritePermissionRetested'])

    def test_exact_guest_set_and_heartbeat_required(self):
        good = {'status': 'complete', 'result': {'registrationInvoked': False, 'registrationMarkersChanged': False,
                'guests': [{'name': name, 'id': vm_id, 'after': 'Running', 'heartbeatReady': True}
                           for name, vm_id in self.h['GUESTS'].items()]}}
        self.h['verify_guest_result'](good)
        for field, value in [('id', 'wrong'), ('after', 'Off'), ('heartbeatReady', False)]:
            bad = copy.deepcopy(good)
            bad['result']['guests'][0][field] = value
            with self.assertRaises(RuntimeError):
                self.h['verify_guest_result'](bad)
        bad = copy.deepcopy(good)
        bad['result']['guests'].append(bad['result']['guests'][0])
        with self.assertRaises(RuntimeError):
            self.h['verify_guest_result'](bad)

    def test_guest_script_parses_and_does_not_change_bootstrap_or_autostart(self):
        path = ROOT / 'scripts/start-smal-existing-guests.ps1'
        command = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', command], check=True, capture_output=True, timeout=30)
        source = path.read_text()
        for forbidden in ['Set-VM', 'Restart-VM', 'Remove-Item', 'Invoke-AzStackHciArcInitialization', 'New-VM']:
            self.assertNotIn(forbidden, source)
        self.assertIn("if ($before -ne 'Running') {", source)
        self.assertLess(source.index("Set-CapacityStartupPhase $capacityGate 'rpc-pending'"), source.index('Start-VM -VM $vm'))
        self.assertIn("Global\\AzureLocalBoxComputeCapacityR2", source)
        self.assertLess(source.index("name = 'LB-DC01'"), source.index("name = 'LB-NODE01'"))
        self.assertIn('AddSeconds(240)', source)
        for vm_id in self.h['GUESTS'].values():
            self.assertIn(vm_id, source)


if __name__ == '__main__':
    unittest.main()
