"""Offline compile and exact cloud prerequisite effect tests."""
import copy
import json
from pathlib import Path
import runpy
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PlatformResourceTests(unittest.TestCase):
    def test_template_compiles_without_roles_secrets_or_shared_network(self):
        result = subprocess.run(['az', 'bicep', 'build', '--file', str(ROOT / 'infra/bicep/localbox-platform-prereqs.bicep'), '--stdout', '--only-show-errors'], check=True, capture_output=True, text=True, timeout=90)
        data = json.loads(result.stdout)
        self.assertEqual(len(data['resources']), 6)
        types = {x['type'].lower() for x in data['resources']}
        for forbidden in ['microsoft.authorization/roleassignments', 'microsoft.keyvault/vaults/secrets', 'microsoft.hybridcompute/machines', 'microsoft.azurestackhci/clusters', 'microsoft.network/virtualnetworks']:
            self.assertNotIn(forbidden, types)
        vault = next(x for x in data['resources'] if x['type'] == 'Microsoft.KeyVault/vaults')
        self.assertTrue(vault['properties']['enablePurgeProtection'])
        self.assertTrue(vault['properties']['enableSoftDelete'])
        self.assertEqual(vault['properties']['publicNetworkAccess'], 'Enabled')
        accounts = [x for x in data['resources'] if x['type'] == 'Microsoft.Storage/storageAccounts']
        self.assertEqual(len(accounts), 2)
        self.assertTrue(all(x['properties']['publicNetworkAccess'] == 'Disabled' and not x['properties']['allowBlobPublicAccess'] for x in accounts))

    def test_preview_rejects_unlisted_resource_or_weakened_storage(self):
        h = runpy.run_path(str(ROOT / 'scripts/apply-smal-platform-prereqs.py'), run_name='platform_preview_test')
        rows = []
        for resource_id in h['EXPECTED']:
            kind = 'Microsoft.Storage/storageAccounts' if resource_id.endswith(('stlboxdiagweu4766ea', 'stlboxwitweu4766ea')) else 'other'
            props = {'publicNetworkAccess': 'Disabled', 'allowBlobPublicAccess': False, 'minimumTlsVersion': 'TLS1_2'} if kind != 'other' else {}
            if resource_id.endswith('kv-lbox-weu-4766ea'):
                kind = 'Microsoft.KeyVault/vaults'; props = {'publicNetworkAccess': 'Enabled', 'enableRbacAuthorization': True, 'enablePurgeProtection': True, 'softDeleteRetentionInDays': 90}
            rows.append({'resourceId': resource_id, 'changeType': 'Create', 'after': {'type': kind, 'properties': props}})
        good = {'status': 'Succeeded', 'changes': rows}; h['validate_preview'](good)
        bad = copy.deepcopy(good); bad['changes'][0]['changeType'] = 'Modify'
        with self.assertRaises(RuntimeError): h['validate_preview'](bad)
        bad = copy.deepcopy(good); bad['changes'][0]['resourceId'] += '-other'
        with self.assertRaises(RuntimeError): h['validate_preview'](bad)
        bad = copy.deepcopy(good)
        row = next(x for x in bad['changes'] if x['after']['type'] == 'Microsoft.Storage/storageAccounts')
        row['after']['properties']['publicNetworkAccess'] = 'Enabled'
        with self.assertRaises(RuntimeError): h['validate_preview'](bad)


if __name__ == '__main__':
    unittest.main()
