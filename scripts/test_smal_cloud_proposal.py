"""Offline constraints on the unapproved concrete cloud proposal."""
import ipaddress
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROPOSAL = ROOT / 'docs/deployment-2026-10-28/cloud-apply-proposal.json'


class CloudProposalTests(unittest.TestCase):
    def test_is_not_an_approval_or_unbounded_grant(self):
        p = json.loads(PROPOSAL.read_text())
        self.assertFalse(p['ownerApproved'])
        for field in ['newEntraApplications', 'subscriptionWideRoleGrants', 'ownerOrContributorRoleGrants', 'privilegeActivation', 'policyExemptionsOrBypassTags', 'smalApplicationPublicAccessChanges', 'outerStorageOrNodeOsReformat', 'aksOrWorkloadsOrModelsIncluded', 'recurringScheduleCreatedOrResumed', 'hardSpendingCapPromised', 'paidWindowsServerGuestSubscriptionEnabled']:
            self.assertFalse(p[field], field)
        self.assertTrue(p['stopOnUnexpectedRoleResourceCostPolicyOrNetworkEffect'])
        self.assertIn('new LocalBox platform RG only', [item['scope'] for item in p['roleEffects']])
        for item in p['roleEffects']:
            self.assertNotIn(item['role'], ['Owner', 'Contributor'])
            self.assertIn('new ', item['scope'])

    def test_explicit_new_vault_boundary_and_existing_private_subnet(self):
        p = json.loads(PROPOSAL.read_text())
        self.assertTrue(p['newPlatformVaultPublicDuringDeployment'])
        self.assertTrue(p['vaultPurgeProtection'])
        self.assertEqual(p['vaultSoftDeleteDays'], 90)
        self.assertEqual(p['privateEndpointCount'], 3)
        self.assertTrue(p['privateEndpointSubnetId'].endswith('/vnet-smal-san-1/subnets/snet-private-endpoints'))
        self.assertNotEqual(p['keyVaultName'], 'kv-smal-san-1')

    def test_infrastructure_pool_excludes_active_nodes_and_storage_has_no_gateway(self):
        p = json.loads(PROPOSAL.read_text())
        pool = p['managementPool']
        first, last = map(ipaddress.ip_address, [pool['start'], pool['end']])
        self.assertGreaterEqual(int(last) - int(first) + 1, 6)
        for value in ['10.64.0.1', '10.64.0.10', '10.64.0.11', '10.64.0.12']:
            self.assertFalse(first <= ipaddress.ip_address(value) <= last)
        self.assertFalse(p['storageAutoIp'])
        self.assertFalse(p['rdmaEnabled'])
        self.assertEqual(p['storageGateways'], [])
        ips = [item['ipv4Address'] for network in p['storageNetworks'] for item in network['storageAdapterIPInfo']]
        self.assertEqual(len(set(ips)), 4)
        self.assertTrue(all(ipaddress.ip_address(value) in ipaddress.ip_network('10.64.0.0/20') for value in ips))

    def test_public_fee_example_is_arithmetic_not_trial_or_contract_assumption(self):
        p = json.loads(PROPOSAL.read_text())
        self.assertAlmostEqual(p['publicL1UsdPerCoreDay'] * p['illustrativeCoreCountNotBillingAssessment'] * 30, p['illustrativeL1Usd30Days'])
        self.assertFalse(p['trialEligibilityAssumed'])
        self.assertFalse(p['azureHybridBenefitClaimed'])
        self.assertTrue(p['meteredStorageVaultMonitoringNetworkAndDefenderChargesAdditional'])

    def test_s2d_allowlist_is_exactly_the_observed_non_boot_raw_devices(self):
        p = json.loads(PROPOSAL.read_text())
        receipt = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-guest-deployment-readiness-20261028.json').read_text())
        self.assertEqual(receipt['status'], 'complete')
        for node in receipt['result']['guests']:
            if node['name'] not in p['dataDeviceAllowlist']:
                continue
            data = [disk for disk in node['disks'] if not disk['IsBoot'] and not disk['IsSystem']]
            self.assertEqual(len(data), 4)
            self.assertEqual({disk['UniqueId'] for disk in data}, set(p['dataDeviceAllowlist'][node['name']]))
            self.assertTrue(all(disk['Size'] == p['dataDeviceSizeBytes'] and disk['PartitionStyle'] == 'RAW' for disk in data))


if __name__ == '__main__':
    unittest.main()
