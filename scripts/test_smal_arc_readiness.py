"""Offline Arc readiness checks. No Azure call, secret read, registration or repair."""
import copy
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]


class ArcReadinessTests(unittest.TestCase):
    def setUp(self):
        self.h = runpy.run_path(str(ROOT / 'scripts/inspect-smal-three-node-cloud-health.py'), run_name='arc_readiness_test')
        recorded = json.loads((ROOT / 'docs/deployment-2026-10-29/three-node-cloud-after-capacity-20261030.json').read_text())
        self.good = {'arcMachines': recorded['arcMachines'], 'bridge': recorded['bridgeResources'][0],
                     'customLocation': recorded['customLocationResources'][0]}


    def test_account_query_pins_lab_subscription_without_changing_cli_default(self):
        scope = self.h['arc_account'].__globals__
        command = Mock(return_value={'id': self.h['SUB'], 'tenantId': self.h['P']['A']['H']['TENANT'], 'state': 'Enabled'})
        with patch.dict(scope, az=command):
            account = self.h['arc_account']()
        self.assertEqual(account['id'], self.h['SUB'])
        command.assert_called_once_with(['account', 'show', '--subscription', self.h['SUB'], '--query', '{id:id,tenantId:tenantId,state:state}'])

    def test_provider_read_timeout_is_retained_without_retry_or_raw_auth_output(self):
        scope = self.h['main_arc_readiness'].__globals__
        deployment = dict(scope['D']); deployment['A'] = {'source_guard': Mock(return_value='reviewed-source')}
        account = {'id': self.h['SUB'], 'tenantId': self.h['P']['A']['H']['TENANT'], 'state': 'Enabled'}
        observe = Mock(side_effect=subprocess.TimeoutExpired('SYNTHETIC-PRIVATE-ARGUMENT', 120))
        with tempfile.TemporaryDirectory() as folder, patch.dict(scope, ROOT=Path(folder), OUT=Path(folder), D=deployment,
                arc_account=Mock(return_value=account), observe_arc=observe):
            self.assertEqual(self.h['main_arc_readiness'](60), 2)
            receipts = list(Path(folder).glob('arc-readiness-*.json'))
            self.assertEqual(len(receipts), 1)
            record = json.loads(receipts[0].read_text())
            self.assertEqual(record['status'], 'arc-read-failed-no-repair')
            self.assertEqual(record['errorType'], 'TimeoutExpired')
            self.assertNotIn('SYNTHETIC-PRIVATE-ARGUMENT', receipts[0].read_text())
            self.assertFalse(record['azureMutationPerformed'])
        observe.assert_called_once_with(60)
    def test_recorded_deployed_bindings_are_ready_without_standalone_os_or_disk_checks(self):
        self.assertEqual(self.h['arc_pending'](self.good), [])
        updated = copy.deepcopy(self.good)
        updated['arcMachines'][0]['osVersion'] = 'later-approved-os-build'
        self.assertEqual(self.h['arc_pending'](updated), [])

    def test_missing_extra_duplicate_or_changed_node_identity_is_refused(self):
        for mode in ('missing', 'extra', 'duplicate', 'principal', 'tenant', 'resource'):
            with self.subTest(mode=mode):
                data = copy.deepcopy(self.good)
                nodes = data['arcMachines']
                if mode == 'missing': nodes.pop()
                elif mode == 'extra': nodes.append(copy.deepcopy(nodes[0]))
                elif mode == 'duplicate': nodes[1] = copy.deepcopy(nodes[0])
                elif mode == 'principal': nodes[0]['identity']['principalId'] = 'different'
                elif mode == 'tenant': nodes[0]['identity']['tenantId'] = 'different'
                else: nodes[0]['id'] = '/another/resource'
                with self.assertRaises(RuntimeError): self.h['arc_pending'](data)

    def test_guest_heartbeat_does_not_make_disconnected_arc_ready(self):
        data = copy.deepcopy(self.good)
        data['arcMachines'][0].update(status='Disconnected', heartbeatReady=True)
        self.assertIn('LB-NODE01', self.h['arc_pending'](data)[0])

    def test_bridge_and_custom_location_must_be_ready_and_bound_to_exact_resource(self):
        for container, key, value in (('bridge', 'status', 'WaitingForHeartbeat'),
                                      ('bridge', 'provisioningState', 'Creating'),
                                      ('customLocation', 'provisioningState', 'Creating')):
            data = copy.deepcopy(self.good); data[container][key] = value
            self.assertTrue(self.h['arc_pending'](data))
        for key, value in (('hostResourceId', '/another/bridge'), ('id', '/another/location'), ('namespace', 'other')):
            data = copy.deepcopy(self.good); data['customLocation'][key] = value
            with self.assertRaises(RuntimeError): self.h['arc_pending'](data)

    def test_failed_provisioning_is_not_treated_as_postboot_convergence(self):
        for container in ('bridge', 'customLocation'):
            data = copy.deepcopy(self.good); data[container]['provisioningState'] = 'Failed'
            with self.assertRaises(RuntimeError): self.h['arc_pending'](data)
        data = copy.deepcopy(self.good); data['arcMachines'][0]['provisioningState'] = 'Canceled'
        with self.assertRaises(RuntimeError): self.h['arc_pending'](data)

    def test_single_ready_read_does_not_wait(self):
        collect = Mock(return_value=self.good); sleep = Mock()
        result = self.h['observe_arc'](600, collect, Mock(return_value=0), sleep)
        self.assertTrue(result['arcReadinessVerified'])
        collect.assert_called_once(); sleep.assert_not_called()

    def test_disconnected_node_can_converge_through_reads_only(self):
        pending = copy.deepcopy(self.good); pending['arcMachines'][0]['status'] = 'Disconnected'
        collect = Mock(side_effect=[pending, self.good]); sleep = Mock()
        result = self.h['observe_arc'](60, collect, Mock(side_effect=[0, 1]), sleep)
        self.assertTrue(result['arcReadinessVerified']); self.assertEqual(result['observations'], 2)
        sleep.assert_called_once_with(20)

    def test_pending_read_is_bounded_without_repairs_or_false_success(self):
        pending = copy.deepcopy(self.good); pending['bridge']['status'] = 'Starting'
        sleep = Mock(); collect = Mock(return_value=pending)
        result = self.h['observe_arc'](0, collect, Mock(return_value=0), sleep)
        self.assertFalse(result['arcReadinessVerified']); collect.assert_called_once(); sleep.assert_not_called()

    def test_read_failure_is_not_hidden_or_retried(self):
        collect = Mock(side_effect=RuntimeError('Azure read denied')); sleep = Mock()
        with self.assertRaises(RuntimeError): self.h['observe_arc'](60, collect, Mock(return_value=0), sleep)
        collect.assert_called_once(); sleep.assert_not_called()

    def test_collector_uses_only_existing_scoped_read_helpers(self):
        scope = self.h['arc_observation'].__globals__
        nodes = Mock(return_value=self.good['arcMachines']); projection = Mock(side_effect=[self.good['bridge'], self.good['customLocation']])
        platform = dict(scope['P']); platform['cloud_nodes'] = nodes
        with patch.dict(scope, P=platform, get_projection=projection):
            self.assertEqual(self.h['arc_observation'](), self.good)
        nodes.assert_called_once()
        self.assertEqual(projection.call_args_list[0].args[:2], (self.h['BRIDGE'], '2022-10-27'))
        self.assertEqual(projection.call_args_list[1].args[:2], (self.h['CUSTOM_LOCATION'], '2021-08-15'))


if __name__ == '__main__': unittest.main()
