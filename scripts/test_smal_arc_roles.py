"""Offline exact-role and verified-node boundaries. No Azure writes."""
import copy
import json
from pathlib import Path
import runpy
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ArcRoleTests(unittest.TestCase):
    def setUp(self):
        self.h = runpy.run_path(str(ROOT / 'scripts/apply-smal-arc-platform-roles.py'), run_name='arc_roles_test')

    def good_preview(self):
        rows = []
        for index, (scope, principal, role) in enumerate(sorted(self.h['EXPECTED'])):
            rows.append({'resourceId': scope + '/providers/Microsoft.Authorization/roleAssignments/synthetic-' + str(index), 'changeType': 'Create',
                         'after': {'type': 'Microsoft.Authorization/roleAssignments', 'properties': {'scope': scope, 'principalId': principal,
                                   'roleDefinitionId': '/subscriptions/' + self.h['SUB'] + '/providers/Microsoft.Authorization/roleDefinitions/' + role}}})
        return {'status': 'Succeeded', 'changes': rows}

    def test_only_seven_exact_approved_scoped_effects_pass(self):
        data = self.good_preview()
        self.assertEqual(len(data['changes']), 7)
        self.h['validate_preview'](data, set(), set())
        for key, value in [('principalId', 'other'), ('scope', '/subscriptions/' + self.h['SUB']), ('roleDefinitionId', '/roles/Owner'), ('principalType', 'User')]:
            bad = copy.deepcopy(data); bad['changes'][0]['after']['properties'][key] = value
            with self.assertRaises(RuntimeError): self.h['validate_preview'](bad, set(), set())
        bad = copy.deepcopy(data); bad['changes'][0]['changeType'] = 'Modify'
        with self.assertRaises(RuntimeError): self.h['validate_preview'](bad, set(), set())
        bad = copy.deepcopy(data); bad['changes'].pop()
        with self.assertRaises(RuntimeError): self.h['validate_preview'](bad, set(), set())
        bad = copy.deepcopy(data); bad['changes'].append(copy.deepcopy(data['changes'][0]))
        with self.assertRaises(RuntimeError): self.h['validate_preview'](bad, set(), set())

    def test_existing_owned_resources_can_only_be_ignored_unchanged(self):
        data = self.good_preview()
        resource = self.h['VAULT'].lower()
        data['changes'].append({'resourceId': resource, 'changeType': 'Ignore', 'before': {'pna': 'Disabled'}, 'after': {'pna': 'Disabled'}})
        self.h['validate_preview'](data, {resource}, set())
        data['changes'][-1]['after']['pna'] = 'Enabled'
        with self.assertRaises(RuntimeError): self.h['validate_preview'](data, {resource}, set())

    def test_node_binding_requires_both_successful_bootstraps_and_exact_cloud_identity(self):
        proof = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-arc-registration-after-recovery-20261029.json').read_text())
        nodes = [{'name': name, 'id': self.h['SCOPE'] + '/providers/Microsoft.HybridCompute/machines/' + name,
                  'status': 'Connected', 'provisioningState': 'Succeeded', 'location': 'westeurope', 'osVersion': '10.0.26100.33650',
                  'identity': {'type': 'SystemAssigned', 'principalId': principal, 'tenantId': self.h['H']['TENANT']}}
                 for name, principal in self.h['NODES'].items()]
        self.h['verify_nodes'](nodes, proof)
        for key, value in [('location', 'southafricanorth'), ('status', 'Disconnected'), ('osVersion', 'unknown')]:
            bad = copy.deepcopy(nodes); bad[0][key] = value
            with self.assertRaises(RuntimeError): self.h['verify_nodes'](bad, proof)
        bad = copy.deepcopy(nodes); bad[1]['identity']['principalId'] = 'other'
        with self.assertRaises(RuntimeError): self.h['verify_nodes'](bad, proof)
        proof['result']['nodes'][1]['bootstrap']['status'] = 'Failed'
        with self.assertRaises(RuntimeError): self.h['verify_nodes'](nodes, proof)

    def test_bicep_has_only_role_resources_and_no_vault_configuration(self):
        result = subprocess.run(['az', 'bicep', 'build', '--file', str(ROOT / self.h['TEMPLATE']), '--stdout', '--only-show-errors'], check=True, capture_output=True, text=True, timeout=90)
        data = json.loads(result.stdout)
        self.assertTrue(all(row['type'] == 'Microsoft.Authorization/roleAssignments' for row in data['resources']))
        self.assertEqual(len(data['resources']), 2)
        self.assertNotIn('publicNetworkAccess', result.stdout)
        self.assertNotIn('deploymentSettings', result.stdout)
        for principal in [self.h['RP'], *self.h['NODES'].values()]: self.assertIn(principal, result.stdout)

    def test_live_role_receipt_matches_exact_seven_approved_bindings(self):
        receipt = json.loads((ROOT / 'docs/deployment-2026-10-29/arc-platform-roles-receipt.json').read_text())
        self.assertEqual(receipt['status'], 'complete-seven-approved-rg-and-vault-role-bindings')
        self.assertEqual(receipt['deploymentState'], 'Succeeded')
        self.assertEqual(receipt['newRoleBindingCount'], 7)
        self.assertEqual(receipt['vaultPublicAccessAfter'], 'Disabled')
        self.assertFalse(receipt['subscriptionWideGrantRequested'])
        self.assertFalse(receipt['clusterDeploymentRequested'])
        self.assertFalse(receipt['platformReadinessVerified'])
        self.assertEqual({self.h['binding'](row) for row in receipt['assignmentsReadback']}, self.h['EXPECTED'])
        self.assertTrue(all(row['principalType'] == 'ServicePrincipal' for row in receipt['assignmentsReadback']))
        preview = json.loads((ROOT / 'docs/deployment-2026-10-29/arc-platform-roles-what-if.json').read_text())
        unchanged = {row['resourceId'].lower() for row in preview['changes'] if row['changeType'] in ['NoChange', 'Ignore']}
        self.h['validate_preview'](preview, unchanged, set())


if __name__ == '__main__':
    unittest.main()
