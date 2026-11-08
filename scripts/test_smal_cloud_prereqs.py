"""Offline tests. No Azure operations."""
from pathlib import Path
import runpy
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
HELPERS = runpy.run_path(str(ROOT / 'scripts/inspect-smal-cloud-prereqs.py'), run_name='cloud_read_test')


class CloudPrerequisiteTests(unittest.TestCase):
    def test_identity_change_stops_instead_of_activating_or_using_another_principal(self):
        good = {'id': HELPERS['SUB'], 'tenantId': HELPERS['TENANT'], 'state': 'Enabled'}
        HELPERS['verify_identity'](good, HELPERS['PRINCIPAL'])
        for key in ['id', 'tenantId', 'state']:
            bad = {**good, key: 'different'}
            with self.assertRaises(RuntimeError): HELPERS['verify_identity'](bad, HELPERS['PRINCIPAL'])
        with self.assertRaises(RuntimeError): HELPERS['verify_identity'](good, 'different')

    def test_missing_or_unregistered_provider_is_not_marked_registered(self):
        rows = [{'namespace': 'Microsoft.AzureStackHCI', 'registrationState': 'Registered'},
                {'namespace': 'Microsoft.KeyVault', 'registrationState': 'NotRegistered'}]
        result = {row['namespace']: row for row in HELPERS['summarise_providers'](rows)}
        self.assertTrue(result['Microsoft.AzureStackHCI']['registered'])
        self.assertFalse(result['Microsoft.KeyVault']['registered'])
        self.assertFalse(result['Microsoft.Attestation']['registered'])

    def test_namespace_display_case_does_not_invent_a_missing_provider(self):
        rows = [{'namespace': 'microsoft.insights', 'registrationState': 'Registered'}]
        result = {row['namespace']: row for row in HELPERS['summarise_providers'](rows)}
        self.assertTrue(result['Microsoft.Insights']['registered'])
        self.assertEqual(result['Microsoft.Insights']['registrationState'], 'Registered')

    def test_inspection_only_uses_exact_read_commands_and_at_scope_filter(self):
        calls = []
        def fake(arguments):
            calls.append(arguments)
            if arguments[:2] == ['account', 'show']:
                return {'id': HELPERS['SUB'], 'tenantId': HELPERS['TENANT'], 'state': 'Enabled'}
            if arguments[:3] == ['ad', 'signed-in-user', 'show']: return HELPERS['PRINCIPAL']
            return []
        with patch.dict(HELPERS['inspect'].__globals__, {'az': fake}):
            result = HELPERS['inspect']()
        self.assertEqual(len(calls), 4)
        self.assertIn('atScope()', calls[-1])
        self.assertNotIn('parameters', calls[-1][-1])
        self.assertEqual(result['resourcesCreated'], 0)
        self.assertFalse(result['providerRegistrationPerformed'])
        self.assertFalse(result['platformReadinessVerified'])
        for call in calls:
            self.assertFalse(set(call) & {'create', 'register', 'update', 'delete', 'activate', 'get-access-token'})


if __name__ == '__main__':
    unittest.main()
