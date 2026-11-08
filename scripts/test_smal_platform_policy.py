"""Read-only policy reconciliation and actual unexpected-effect stop evidence."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PlatformPolicyTests(unittest.TestCase):
    def test_completed_deployment_is_not_relabelled_as_missing_resources(self):
        folder = ROOT / 'docs/deployment-2026-10-28'
        original = json.loads((folder / 'platform-prereqs-apply-receipt.json').read_text())
        observed = json.loads((folder / 'platform-policy-conflict-reconciled.json').read_text())
        self.assertEqual(original['deploymentState'], 'Succeeded')
        self.assertEqual(original['status'], 'failed-inspect-before-resume')
        self.assertEqual(observed['deploymentState'], 'Succeeded')
        self.assertEqual(observed['vault']['publicNetworkAccess'], 'Disabled')
        self.assertTrue(observed['matchingModifyEvents'])
        self.assertTrue(all(x['effect'] == 'modify' and x['definitionId'].endswith('/KeyVault_PublicNetwork_Modify') for x in observed['matchingModifyEvents']))
        self.assertFalse(observed['publicReenableOrPolicyExemptionAttempted'])
        self.assertFalse(observed['apiDowngradeToEvadePolicyAttempted'])
        self.assertFalse(observed['arcRegistrationOrClusterDeploymentPerformed'])

    def test_policy_observer_has_no_mutation_or_credential_query(self):
        text = (ROOT / 'scripts/inspect-smal-platform-policy-conflict.py').read_text()
        for forbidden in ["'create'", "'update'", "'delete'", "'register'", "'set'", "'get-access-token'", "'list-keys'"]:
            self.assertNotIn(forbidden, text)
        self.assertIn('target.open(\'x\')', text)


if __name__ == '__main__':
    unittest.main()
