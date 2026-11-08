"""Offline deployment derivation, private secret-delivery and effect boundaries."""
import base64
import copy
import json
import os
from pathlib import Path
import runpy
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ClusterDeploymentTests(unittest.TestCase):
    def deployment_helpers(self):
        return runpy.run_path(str(ROOT / 'scripts/deploy-smal-cluster.py'), run_name='cluster_apply_test')

    def test_exact_live_raw_disk_vhd_and_ad_inputs_pass_but_drift_is_refused(self):
        h = self.deployment_helpers()
        proof = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-cluster-inputs-20261029.json').read_text())
        h['verify_inputs'](proof)
        for field, value in [('partitionStyle', 'GPT'), ('uniqueId', 'wrong'), ('isBoot', True)]:
            bad = copy.deepcopy(proof)
            bad['result']['nodes'][0]['guest']['disks'][1][field] = value
            with self.assertRaises(RuntimeError): h['verify_inputs'](bad)
        bad = copy.deepcopy(proof); bad['result']['nodes'][0]['backing'][1]['path'] = 'C:\\wrong.vhdx'
        with self.assertRaises(RuntimeError): h['verify_inputs'](bad)

    def test_witness_policy_constraint_is_fail_closed(self):
        h = self.deployment_helpers()
        witness = {'id': h['SCOPE'] + '/providers/Microsoft.Storage/storageAccounts/stlboxwitweu4766ea', 'publicNetworkAccess': 'Disabled', 'allowSharedKeyAccess': False}
        constraint = json.loads((ROOT / 'docs/deployment-2026-10-29/witness-deployment-blocker.json').read_text())
        with self.assertRaises(RuntimeError): h['require_witness_compatibility'](witness, constraint)
        witness['allowSharedKeyAccess'] = True
        with self.assertRaises(RuntimeError): h['require_witness_compatibility'](witness, constraint)
        self.assertFalse(constraint['enableSharedKeyAttempted'])
        self.assertEqual(constraint['readOnlySharedKeyContainerListErrorCode'], 'KeyBasedAuthenticationNotPermitted')
        source = (ROOT / 'scripts/deploy-smal-cluster.py').read_text()
        self.assertNotIn("'storage', 'account', 'update'", source)

    def test_preview_refuses_unlisted_or_missing_effects_and_never_retains_secret_bodies(self):
        h = self.deployment_helpers()
        data = {'status': 'Succeeded', 'changes': [{'changeType': 'Create', 'resourceId': rid, 'after': {'properties': {'value': 'NON-CREDENTIAL-SYNTHETIC'}}} for rid in h['expected_effects']('secrets')]}
        summary = h['check_preview']('secrets', data, set())
        self.assertNotIn('NON-CREDENTIAL-SYNTHETIC', json.dumps(summary))
        bad = copy.deepcopy(data); bad['changes'][0]['resourceId'] = h['VAULT']
        with self.assertRaises(RuntimeError): h['check_preview']('secrets', bad, set())
        bad = copy.deepcopy(data); bad['changes'].pop()
        with self.assertRaises(RuntimeError): h['check_preview']('secrets', bad, set())
        bad = copy.deepcopy(data); bad['changes'][0]['changeType'] = 'Modify'
        with self.assertRaises(RuntimeError): h['check_preview']('secrets', bad, set())

    def test_rsa_oaep_roundtrip_cross_runtime_uses_only_anonymous_private_key(self):
        h = self.deployment_helpers()
        fd, modulus = h['new_rsa_key']()
        try:
            self.assertEqual(len(base64.b64decode(modulus)), 512)
            payload = {'nonce': 'synthetic-only', 'values': {'local': 'NON-CREDENTIAL'}}
            encoded = base64.b64encode(json.dumps(payload).encode()).decode()
            script = "$r=[Security.Cryptography.RSA]::Create();$p=[Security.Cryptography.RSAParameters]::new();$p.Modulus=[Convert]::FromBase64String('" + modulus + "');$p.Exponent=[Convert]::FromBase64String('AQAB');$r.ImportParameters($p);try{[Convert]::ToBase64String($r.Encrypt([Convert]::FromBase64String('" + encoded + "'),[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))}finally{$r.Dispose()}"
            result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script], capture_output=True, text=True, check=True, timeout=30)
            self.assertEqual(h['decrypt_envelope'](fd, result.stdout.strip()), payload)
            tampered = bytearray(base64.b64decode(result.stdout.strip())); tampered[0] ^= 1
            with self.assertRaises(RuntimeError): h['decrypt_envelope'](fd, base64.b64encode(tampered).decode())
        finally:
            os.close(fd)

    def test_derivation_matches_pinned_source_and_contains_only_bounded_resources(self):
        h = runpy.run_path(str(ROOT / 'scripts/derive-smal-cluster-templates.py'), run_name='derive_test')
        built = h['build']()
        for name, template in built.items():
            self.assertEqual(template, json.loads((ROOT / 'infra/arm' / name).read_text()))
            text = json.dumps(template)
            self.assertNotIn('publicNetworkAccess', text)
            self.assertNotIn('Microsoft.Storage/storageAccounts",', text)
        self.assertEqual(set(built['localbox-cluster-prerequisites.json']['resources']), {'edgeDevices', 'HCICluster'})
        settings = built['localbox-cluster-settings.json']
        self.assertEqual(set(settings['resources']), {'DeploymentSettings'})
        self.assertNotIn('localAdminPassword', settings['parameters'])
        data = settings['resources']['DeploymentSettings']['properties']['deploymentConfiguration']['scaleUnits'][0]['deploymentData']
        self.assertTrue(data['securitySettings']['hvciProtection'])
        self.assertTrue(data['securitySettings']['drtmProtection'])
        self.assertEqual(settings['parameters']['enableStorageAutoIp']['defaultValue'], False)
        self.assertEqual(settings['parameters']['euLocation']['defaultValue'], True)
        intents = settings['parameters']['intentList']['defaultValue']
        self.assertEqual([x['adapter'] for x in intents], [['MGMT1', 'MGMT2'], ['STORAGEA', 'STORAGEB']])
        self.assertTrue(all(x['adapterPropertyOverrides'] == {'networkDirect': 'Disabled', 'jumboPacket': '1514'} for x in intents))
        secrets = built['localbox-platform-secrets.json']
        self.assertEqual(len(secrets['resources']), 3)
        self.assertTrue(all(x['type'] == 'Microsoft.KeyVault/vaults/secrets' for x in secrets['resources']))
        self.assertTrue(all(x['type'] == 'securestring' for x in secrets['parameters'].values()))

    def test_private_input_and_sealing_scripts_parse_without_cloud_mutations(self):
        for name in ['inspect-smal-cluster-inputs.ps1', 'seal-smal-platform-credentials.ps1']:
            path = ROOT / 'scripts' / name
            code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)
            source = path.read_text()
            for forbidden in ['Format-Volume', 'Initialize-Disk', 'Set-LocalUser', 'Get-AzAccessToken', 'Start-Transcript', 'Set-ADUser']:
                self.assertNotIn(forbidden, source)
        seal = (ROOT / 'scripts/seal-smal-platform-credentials.ps1').read_text()
        self.assertIn('RSAEncryptionPadding]::OaepSHA256', seal)
        self.assertIn("-Role 'cluster-node-admin'", seal)
        self.assertIn("-Role 'deployment-user'", seal)
        self.assertIn('ZeroFreeBSTR', seal)
        self.assertNotIn('WriteAllText', seal)


if __name__ == '__main__':
    unittest.main()
