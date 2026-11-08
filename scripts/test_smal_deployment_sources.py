"""Static source audit checks. Nothing in upstream captures is executed/imported."""
import json
from pathlib import Path
import unittest
import runpy

ROOT = Path(__file__).resolve().parents[1]
CAPTURE = ROOT / 'docs/deployment-2026-10-28/upstream-review'


class DeploymentSourceTests(unittest.TestCase):
    def test_source_discovery_cannot_read_local_files_or_private_http_endpoints(self):
        helpers = runpy.run_path(str(ROOT / 'scripts/inspect-smal-deployment-sources.py'), run_name='static_source_test')
        for url in ['file:///home/user/private', 'http://169.254.169.254/metadata', 'https://localhost/test', 'https://api.github.com.evil.example/test']:
            with self.assertRaises(RuntimeError): helpers['get'](url)

    def test_selected_current_template_has_no_legacy_arb_app_secret_parameters(self):
        template = json.loads((CAPTURE / 'azuredeploy.json').read_text())
        self.assertNotIn('arbDeploymentAppSecret', template['parameters'])
        self.assertNotIn('arbDeploymentAppID', template['parameters'])
        self.assertEqual(template['parameters']['localAdminPassword']['type'], 'securestring')
        self.assertIn('deploymentMode', template['parameters'])

    def test_public_l1_retail_meter_is_unambiguous_and_not_a_contract_quote(self):
        rates = json.loads((CAPTURE / 'azure-local-retail-rates.json').read_text())
        self.assertIsNone(rates.get('NextPageLink'))
        selected = [x for x in rates['Items'] if x['productName'] == 'Azure Local'
                    and x['skuName'] == 'Standard' and x['meterName'] == 'Standard Monthly Service Fee'
                    and x['armRegionName'] == 'Global' and x['currencyCode'] == 'USD' and x['type'] == 'Consumption']
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0]['unitOfMeasure'], '1/Day')
        self.assertEqual(selected[0]['retailPrice'], 0.33)

    def test_audited_ad_module_is_not_treated_as_safe_just_because_pinned(self):
        text = (CAPTURE / 'ad-module-AsHciADArtifactsPreCreationTool.psm1').read_text(encoding='utf-8-sig')
        self.assertIn('-PasswordNeverExpires $true', text)
        self.assertIn('Remove-ADOrganizationalUnit -Recursive -Confirm:$false', text)
        receipt = json.loads((CAPTURE / 'source-receipt.json').read_text())
        self.assertFalse(receipt['moduleImportedOrExecuted'])
        self.assertTrue(receipt['adModule']['packageSha512MatchesGallery'])


if __name__ == '__main__':
    unittest.main()
