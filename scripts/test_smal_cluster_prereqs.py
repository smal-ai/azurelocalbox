"""Offline local preparation and one-RG cloud boundary tests."""
import copy
import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ClusterPrerequisiteTests(unittest.TestCase):
    def test_approval_is_the_exact_user_accepted_proposal(self):
        folder = ROOT / 'docs/deployment-2026-10-28'
        approval = json.loads((folder / 'cloud-apply-approval.json').read_text())
        self.assertTrue(approval['approved'])
        self.assertEqual(hashlib.sha256((folder / 'cloud-apply-proposal.json').read_bytes()).hexdigest(), approval['proposalJsonSha256'])
        self.assertEqual(hashlib.sha256((folder / 'cloud-apply-proposal.md').read_bytes()).hexdigest(), approval['proposalMarkdownSha256'])
        self.assertFalse(approval['existingArmTokenForwardingApproved'])

    def test_local_script_parses_and_does_not_weaken_global_policy(self):
        path = ROOT / 'scripts/prepare-smal-cluster-prereqs.ps1'
        code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)
        source = path.read_text()
        self.assertIn('-PasswordNeverExpires $false', source)
        self.assertIn('Set-GPInheritance -Target $ouDn -IsBlocked Yes', source)
        self.assertIn('Default domain account policy changed unexpectedly', source)
        self.assertIn('Enforced domain GPOs require review, not bypass filters', source)
        self.assertIn('New node login identity differs', source)
        for forbidden in ['Set-ADDefaultDomainPasswordPolicy', 'Remove-ADOrganizationalUnit', 'Remove-ADUser', 'Add-ADGroupMember', 'TrustedHosts', 'CredSSP', 'Format-Volume', 'Register-Az', 'Invoke-AzStackHciArcInitialization']:
            self.assertNotIn(forbidden, source)

    def test_new_rg_preview_refuses_every_other_effect(self):
        helpers = runpy.run_path(str(ROOT / 'scripts/apply-smal-platform-rg.py'), run_name='rg_preview_test')
        good = {'status': 'Succeeded', 'changes': [{'resourceId': helpers['ID'], 'changeType': 'Create', 'after': {'location': 'westeurope', 'type': 'Microsoft.Resources/resourceGroups'}}]}
        helpers['validate_preview'](good)
        for field, value in [('changeType', 'Modify'), ('resourceId', '/subscriptions/other/resourceGroups/other')]:
            bad = copy.deepcopy(good); bad['changes'][0][field] = value
            with self.assertRaises(RuntimeError): helpers['validate_preview'](bad)
        bad = copy.deepcopy(good); bad['changes'].append(copy.deepcopy(good['changes'][0]))
        with self.assertRaises(RuntimeError): helpers['validate_preview'](bad)
        bad = copy.deepcopy(good); bad['changes'][0]['after']['location'] = 'southafricanorth'
        with self.assertRaises(RuntimeError): helpers['validate_preview'](bad)

    def test_rg_template_compiles_to_only_one_owned_resource(self):
        result = subprocess.run(['az', 'bicep', 'build', '--file', str(ROOT / 'infra/bicep/localbox-platform-rg.bicep'), '--stdout', '--only-show-errors'], check=True, capture_output=True, text=True, timeout=90)
        data = json.loads(result.stdout)
        self.assertEqual(len(data['resources']), 1)
        resource = data['resources'][0]
        self.assertEqual(resource['type'], 'Microsoft.Resources/resourceGroups')
        self.assertEqual(resource['name'], 'rg-localbox-platform-weu-1')
        self.assertEqual(resource['location'], 'westeurope')
        self.assertNotIn('CostControl', resource['tags'])

    def test_rg_rendering_reconciliation_keeps_old_receipt_and_requires_absence(self):
        source = (ROOT / 'scripts/apply-smal-platform-rg.py').read_text()
        self.assertIn('--no-pretty-print', source)
        self.assertIn("'previewSha256' in prior", source)
        self.assertIn("'deploymentId' in prior", source)
        self.assertIn("record['originalReceiptRetained'] = True", source)
        self.assertIn('RG already exists, preserve rather than overwrite', source)
        self.assertIn('Deployment identity already exists, reconcile before retry', source)
        self.assertNotIn("'delete'", source)


if __name__ == '__main__':
    unittest.main()
