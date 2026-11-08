import json
from pathlib import Path
import runpy
import tempfile
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / 'scripts/validate-smal-bootstrap-plan.py'), run_name='validator_test')


def fixture():
    host = dict(H['HOST'])
    disks = [{'resourceId': H['DISK_PREFIX'] + f'LocalBox-Client-DataDisk_{i}',
              'guestUniqueId': f'test-only-guest-disk-{i}', 'lun': i, 'sizeGiB': 256} for i in range(8)]
    plan = {'schemaVersion': 1, 'host': dict(host), 'network': {
        'allocations': {'infrastructure': '10.64.0.0/20', 'pods': '10.65.0.0/16', 'services': '10.66.0.0/24'},
        'subnets': {name: f'10.64.{i}.0/24' for i, name in enumerate(sorted(H['PURPOSES']))},
        'sourceTranslation': 'snat-to-outer-host', 'translatedSourceIp': '10.200.16.4',
        'centralResolver': '10.204.0.4', 'changeOuterDefaultRoute': False, 'azureNicIpForwarding': False,
        'sharedNetworkWrites': False, 'advertisedNestedPrefixes': [], 'hubStaticNestedRoutes': []},
        'storage': {'layout': 'Simple', 'fileSystem': 'NTFS', 'driveLetter': 'V',
                    'allocationUnitBytes': 65536, 'formatRequested': True, 'disks': disks}}
    inventory = {'schemaVersion': 1, 'host': dict(host), 'connectedEstateReviewComplete': True,
                 'connectedPrefixes': ['10.200.16.0/22', '10.202.0.0/24', '10.204.0.0/22', '172.16.0.0/24'],
                 'disks': [dict(disk, managedBy=H['VM'], state='Attached', isBoot=False,
                                isSystem=False, partitionStyle='RAW') for disk in disks]}
    return plan, inventory, bound_receipts(plan, inventory)


def bound_receipts(plan, inventory):
    return {'schemaVersion': 1, 'receipts': [
        {'scope': scope, 'status': 'approved', 'approverType': 'human', 'approverId': 'fixture-only-not-real-approval',
         'nativeReference': 'fixture-only-reference', 'planSha256': H['digest'](plan),
         'inventorySha256': H['digest'](inventory)} for scope in ['storage', 'nested-network']]}


class PlanValidatorTests(unittest.TestCase):
    def test_live_inventory_script_is_parseable_and_read_only(self):
        path = ROOT / 'scripts/inspect-smal-bootstrap-inventory.ps1'
        code = "$t=$null; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e); if($e.Count){$e | ForEach-Object Message; exit 1}"
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True)
        source = path.read_text()
        for forbidden in ['Format-Volume', 'Initialize-Disk', 'New-StoragePool', 'Mount-DiskImage',
                          'New-VM', 'Start-VM', 'New-NetNat', 'Set-Content', 'Get-Credential']:
            self.assertNotIn(forbidden, source)

    def test_repository_draft_retains_real_unknown_identities_and_approvals(self):
        out = ROOT / 'docs/deployment-2026-10-27'
        result = H['validate'](*(H['read_document'](out / name) for name in [
            'bootstrap-execution-plan.draft.json', 'bootstrap-inventory.draft.json',
            'bootstrap-approvals.draft.json']))
        self.assertEqual(result['status'], 'blocked')
        for error in ['connected-estate-review-incomplete', 'exact-bound-storage-and-network-receipts-required',
                      'guest-disk-identity-missing-or-not-literal', 'exact-lun-missing']:
            self.assertIn(error, result['errors'])

    def test_valid_fixture_is_review_only_never_execution_permission(self):
        result = H['validate'](*fixture())
        self.assertEqual(result['status'], 'valid-for-independent-review')
        self.assertFalse(result['automaticApplyPermitted'])
        self.assertFalse(result['resourceActionsPerformed'])
        self.assertFalse(result['approvalReferencesAuthenticated'])
        self.assertFalse(result['liveInventoryVerified'])

    def test_missing_and_agent_approval_rejected(self):
        plan, inventory, approvals = fixture()
        self.assertIn('exact-bound-storage-and-network-receipts-required', H['validate'](plan, inventory, {'schemaVersion': 1, 'receipts': []})['errors'])
        approvals['receipts'][0]['approverType'] = 'agent'
        self.assertIn('approval-evidence-missing-unbound-or-not-human', H['validate'](plan, inventory, approvals)['errors'])

    def test_approval_is_bound_to_both_documents(self):
        for which in ['plan', 'inventory']:
            plan, inventory, approvals = fixture()
            if which == 'plan': plan['storage']['layout'] = 'Mirror'
            else: inventory['connectedPrefixes'].append('192.168.10.0/24')
            self.assertIn('approval-evidence-missing-unbound-or-not-human', H['validate'](plan, inventory, approvals)['errors'])

    def test_nested_and_connected_overlap_rejected(self):
        plan, inventory, _ = fixture()
        plan['network']['allocations']['services'] = '10.65.0.0/24'
        self.assertIn('nested-prefix-overlap', H['validate'](plan, inventory, bound_receipts(plan, inventory))['errors'])
        plan, inventory, _ = fixture()
        inventory['connectedPrefixes'].append('10.64.0.0/16')
        self.assertIn('nested-prefix-conflicts-with-connected-estate', H['validate'](plan, inventory, bound_receipts(plan, inventory))['errors'])

    def test_subnet_overlap_and_containment_rejected(self):
        plan, inventory, _ = fixture()
        plan['network']['subnets']['management'] = plan['network']['subnets']['provider']
        self.assertIn('nested-prefix-overlap', H['validate'](plan, inventory, bound_receipts(plan, inventory))['errors'])
        plan['network']['subnets']['management'] = '10.99.0.0/24'
        self.assertIn('subnet-outside-infrastructure-allocation', H['validate'](plan, inventory, bound_receipts(plan, inventory))['errors'])

    def test_known_vpn_cannot_be_omitted_to_hide_overlap(self):
        plan, inventory, _ = fixture()
        inventory['connectedPrefixes'].remove('172.16.0.0/24')
        plan['network']['allocations']['pods'] = '172.16.0.0/16'
        errors = H['validate'](plan, inventory, bound_receipts(plan, inventory))['errors']
        self.assertIn('nested-prefix-conflicts-with-vpn', errors)
        self.assertIn('known-connected-prefix-not-covered', errors)

    def test_partial_estate_review_is_not_complete(self):
        plan, inventory, _ = fixture()
        inventory['connectedEstateReviewComplete'] = False
        self.assertIn('connected-estate-review-incomplete', H['validate'](plan, inventory, bound_receipts(plan, inventory))['errors'])

    def test_vpn_split_routes_cover_known_pool_and_public_host_routes_are_inventory(self):
        plan, inventory, _ = fixture()
        inventory['connectedPrefixes'].remove('172.16.0.0/24')
        inventory['connectedPrefixes'] += ['172.16.0.0/25', '172.16.0.128/25', '20.87.68.181/32']
        self.assertEqual(H['validate'](plan, inventory, bound_receipts(plan, inventory))['status'], 'valid-for-independent-review')

    def test_noncanonical_public_ipv6_and_default_prefixes_rejected(self):
        for value in ['10.64.0.1/20', '8.8.8.0/24', '::/0', '0.0.0.0/0', None]:
            plan, inventory, _ = fixture()
            plan['network']['allocations']['infrastructure'] = value
            self.assertEqual(H['validate'](plan, inventory, bound_receipts(plan, inventory))['status'], 'blocked')

    def test_outer_route_forwarding_and_shared_writes_rejected(self):
        for field in ['changeOuterDefaultRoute', 'azureNicIpForwarding', 'sharedNetworkWrites']:
            plan, inventory, _ = fixture()
            plan['network'][field] = True
            self.assertIn('outer-or-shared-network-change-not-permitted', H['validate'](plan, inventory, bound_receipts(plan, inventory))['errors'])
        plan['network']['advertisedNestedPrefixes'] = ['10.64.0.0/20']
        self.assertIn('nested-route-advertisement-not-permitted', H['validate'](plan, inventory, bound_receipts(plan, inventory))['errors'])

    def test_other_host_resolver_and_untranslated_source_rejected(self):
        plan, inventory, _ = fixture()
        plan['host']['privateIp'] = '10.200.16.5'
        plan['network']['centralResolver'] = '8.8.8.8'
        plan['network']['sourceTranslation'] = 'routed'
        errors = H['validate'](plan, inventory, bound_receipts(plan, inventory))['errors']
        self.assertIn('host-placement-differs-from-existing-contract', errors)
        self.assertIn('central-resolver-differs', errors)
        self.assertIn('unreviewed-routed-or-other-source-translation', errors)

    def test_boot_system_nonraw_and_wrong_attachment_rejected(self):
        for field, value in [('isBoot', True), ('isSystem', True), ('partitionStyle', 'GPT'),
                             ('managedBy', 'other-host'), ('state', 'Unattached'), ('sizeGiB', True)]:
            plan, inventory, _ = fixture()
            inventory['disks'][0][field] = value
            self.assertIn('inventory-disk-not-confirmed-unused-attached-data-disk', H['validate'](plan, inventory, bound_receipts(plan, inventory))['errors'])

    def test_guest_disk_identity_and_lun_must_be_exact(self):
        for field, value in [('guestUniqueId', None), ('guestUniqueId', '*'), ('lun', None), ('lun', False), ('lun', 64)]:
            plan, inventory, _ = fixture()
            plan['storage']['disks'][0][field] = value
            self.assertEqual(H['validate'](plan, inventory, bound_receipts(plan, inventory))['status'], 'blocked')
        plan, inventory, _ = fixture()
        plan['storage']['disks'][0]['guestUniqueId'] = 'different-literal-id'
        self.assertIn('planned-disk-does-not-match-inventory', H['validate'](plan, inventory, bound_receipts(plan, inventory))['errors'])
        plan, inventory, _ = fixture()
        inventory['disks'][0]['lun'] = False
        self.assertIn('inventory-guest-identity-or-lun-unverified', H['validate'](plan, inventory, bound_receipts(plan, inventory))['errors'])

    def test_disk_duplicates_missing_and_path_traversal_rejected(self):
        plan, inventory, _ = fixture()
        plan['storage']['disks'][1] = dict(plan['storage']['disks'][0])
        errors = H['validate'](plan, inventory, bound_receipts(plan, inventory))['errors']
        self.assertIn('planned-disk-set-not-exact', errors)
        self.assertIn('duplicate-guest-disk-identity-or-lun', errors)
        plan, inventory, _ = fixture()
        inventory['disks'][0]['resourceId'] = H['DISK_PREFIX'] + '../OSDisk'
        self.assertIn('disk-resource-id-not-canonical', H['validate'](plan, inventory, bound_receipts(plan, inventory))['errors'])

    def test_unknown_fields_wrong_types_and_nonfinite_data_fail_closed(self):
        plan, inventory, approvals = fixture()
        plan['network']['defaultRouteOverride'] = 'Internet'
        self.assertIn('network-schema', H['validate'](plan, inventory, approvals)['errors'])
        for bad in [None, [], True, {}, {'schemaVersion': True}, float('nan')]:
            for index in range(3):
                args = list(fixture())
                args[index] = bad
                self.assertEqual(H['validate'](*args)['status'], 'blocked')

    def test_duplicate_keys_and_nonfinite_json_are_rejected(self):
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as directory:
            path = Path(directory) / 'input.json'
            for text in ['{"x":1,"x":2}', '{"x":NaN}', '{"x":Infinity}']:
                path.write_text(text)
                with self.assertRaises(ValueError): H['read_document'](path)


if __name__ == '__main__':
    unittest.main()
