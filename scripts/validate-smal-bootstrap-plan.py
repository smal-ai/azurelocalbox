"""Pure draft-plan validation. A valid result is NEVER permission to apply it.

No discovery, credentials, subprocesses or resource changes. Approval documents are
structurally bound to content here, not authenticated. The actual human references,
fresh inventory and execution scope must be independently checked before any apply.
"""
import argparse
import hashlib
import ipaddress
import json
import re

SUB = '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea'
VM = f'/subscriptions/{SUB}/resourceGroups/rg-localbox-nodes-san-1/providers/Microsoft.Compute/virtualMachines/LocalBox-Client'
SUBNET = f'/subscriptions/{SUB}/resourceGroups/rg-smal-network-san-1/providers/Microsoft.Network/virtualNetworks/vnet-smal-san-1/subnets/snet-localbox-host'
DISK_PREFIX = f'/subscriptions/{SUB}/resourceGroups/rg-localbox-nodes-san-1/providers/Microsoft.Compute/disks/'
HOST = {'vmResourceId': VM, 'subnetResourceId': SUBNET, 'privateIp': '10.200.16.4'}
PURPOSES = {'management', 'provider', 'natTransit', 'hostInternal', 'storageA',
            'storageB', 'aksApiNodesAndVips', 'nestedVmNetwork'}


class InvalidDocument(ValueError):
    pass


def digest(value):
    content = json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)
    return hashlib.sha256(content.encode()).hexdigest()


def read_document(path):
    def unique_keys(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise InvalidDocument('duplicate-json-key')
            value[key] = item
        return value

    def invalid_constant(_):
        raise InvalidDocument('non-finite-json-number')

    with open(path) as stream:
        return json.load(stream, object_pairs_hook=unique_keys, parse_constant=invalid_constant)


def shape(value, keys, label):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise InvalidDocument(label + '-schema')


def literal(value):
    return (isinstance(value, str) and 0 < len(value) <= 256 and value == value.strip()
            and not any(ord(c) < 32 or c in '*?[]' for c in value))


def network(value, private_only=True):
    if not isinstance(value, str):
        raise InvalidDocument('cidr-not-string')
    try:
        parsed = ipaddress.ip_network(value, strict=True)
    except ValueError:
        raise InvalidDocument('cidr-not-canonical') from None
    if value != str(parsed):
        raise InvalidDocument('cidr-not-canonical')
    if parsed.version != 4 or parsed.prefixlen == 0:
        raise InvalidDocument('cidr-not-nondefault-ipv4')
    # Connected inventory can include public host routes. Nested allocations must
    # be explicit RFC1918 space, not Python's broader is_private classification.
    if private_only and not any(parsed.subnet_of(ipaddress.ip_network(parent))
                                     for parent in ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']):
        raise InvalidDocument('cidr-not-rfc1918-ipv4')
    return parsed


def validate(plan, inventory, approvals):
    errors = []
    plan_hash = inventory_hash = None
    try:
        plan_hash, inventory_hash = digest(plan), digest(inventory)
        shape(plan, ['schemaVersion', 'host', 'network', 'storage'], 'plan')
        shape(inventory, ['schemaVersion', 'host', 'connectedPrefixes',
                          'connectedEstateReviewComplete', 'disks'], 'inventory')
        shape(approvals, ['schemaVersion', 'receipts'], 'approvals')
        if any(type(x.get('schemaVersion')) is not int or x['schemaVersion'] != 1
               for x in [plan, inventory, approvals]):
            raise InvalidDocument('unsupported-schema-version')
        for value in [plan['host'], inventory['host']]:
            shape(value, HOST, 'host')
            if value != HOST:
                errors.append('host-placement-differs-from-existing-contract')

        net = plan['network']
        shape(net, ['allocations', 'subnets', 'sourceTranslation', 'translatedSourceIp',
                    'centralResolver', 'changeOuterDefaultRoute', 'azureNicIpForwarding',
                    'sharedNetworkWrites', 'advertisedNestedPrefixes', 'hubStaticNestedRoutes'], 'network')
        shape(net['allocations'], ['infrastructure', 'pods', 'services'], 'allocations')
        shape(net['subnets'], PURPOSES, 'subnets')
        allocations = {name: network(cidr) for name, cidr in net['allocations'].items()}
        subnets = {name: network(cidr) for name, cidr in net['subnets'].items()}
        for group in [allocations, subnets]:
            pairs = list(group.items())
            for i, (_, left) in enumerate(pairs):
                if any(left.overlaps(right) for _, right in pairs[i + 1:]):
                    errors.append('nested-prefix-overlap')
        if any(not subnet.subnet_of(allocations['infrastructure']) for subnet in subnets.values()):
            errors.append('subnet-outside-infrastructure-allocation')
        if any(subnet.prefixlen != 24 for subnet in subnets.values()):
            errors.append('initial-profile-requires-24-bit-subnets')
        if not isinstance(inventory['connectedPrefixes'], list) or not inventory['connectedPrefixes']:
            raise InvalidDocument('connected-prefix-inventory-missing')
        connected = list(ipaddress.collapse_addresses(network(cidr, private_only=False)
                                                     for cidr in inventory['connectedPrefixes']))
        if any(left.overlaps(right) for left in allocations.values() for right in connected):
            errors.append('nested-prefix-conflicts-with-connected-estate')
        if inventory['connectedEstateReviewComplete'] is not True:
            errors.append('connected-estate-review-incomplete')
        # Always include the known VPN even if the supplied snapshot omits it.
        if any(left.overlaps(ipaddress.ip_network('172.16.0.0/24')) for left in allocations.values()):
            errors.append('nested-prefix-conflicts-with-vpn')
        for prefix in ['10.200.16.0/24', '10.202.0.0/26', '10.204.0.0/22', '172.16.0.0/24']:
            required = ipaddress.ip_network(prefix)
            if not any(required.subnet_of(item) for item in connected):
                errors.append('known-connected-prefix-not-covered')
        if net['sourceTranslation'] != 'snat-to-outer-host' or net['translatedSourceIp'] != HOST['privateIp']:
            errors.append('unreviewed-routed-or-other-source-translation')
        if net['centralResolver'] != '10.204.0.4':
            errors.append('central-resolver-differs')
        for field in ['changeOuterDefaultRoute', 'azureNicIpForwarding', 'sharedNetworkWrites']:
            if net[field] is not False:
                errors.append('outer-or-shared-network-change-not-permitted')
        if net['advertisedNestedPrefixes'] != [] or net['hubStaticNestedRoutes'] != []:
            errors.append('nested-route-advertisement-not-permitted')

        storage = plan['storage']
        shape(storage, ['layout', 'fileSystem', 'driveLetter', 'allocationUnitBytes',
                        'formatRequested', 'disks'], 'storage')
        if (storage['layout'] != 'Simple' or storage['fileSystem'] != 'NTFS'
                or storage['driveLetter'] != 'V' or type(storage['allocationUnitBytes']) is not int
                or storage['allocationUnitBytes'] != 65536 or storage['formatRequested'] is not True):
            errors.append('storage-profile-not-explicit-or-supported-for-review')
        if not isinstance(storage['disks'], list) or not isinstance(inventory['disks'], list):
            raise InvalidDocument('disk-list-schema')
        if len(storage['disks']) != 8 or len(inventory['disks']) != 8:
            errors.append('exact-eight-data-disks-required')
        observed = {}
        for disk in inventory['disks']:
            shape(disk, ['resourceId', 'guestUniqueId', 'lun', 'sizeGiB', 'managedBy',
                         'state', 'isBoot', 'isSystem', 'partitionStyle'], 'inventory-disk')
            rid = disk['resourceId']
            if not literal(rid) or not rid.lower().startswith(DISK_PREFIX.lower()):
                raise InvalidDocument('disk-resource-id-not-exact-owned-resource')
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,79}', rid[len(DISK_PREFIX):]):
                raise InvalidDocument('disk-resource-id-not-canonical')
            key = rid.lower()
            if key in observed:
                errors.append('duplicate-inventory-disk')
            observed[key] = disk
            if not literal(disk['guestUniqueId']) or type(disk['lun']) is not int or not 0 <= disk['lun'] <= 63:
                errors.append('inventory-guest-identity-or-lun-unverified')
            if (disk['isBoot'] is not False or disk['isSystem'] is not False
                    or disk['partitionStyle'] != 'RAW' or disk['state'] != 'Attached'
                    or disk['managedBy'] != VM or type(disk['sizeGiB']) is not int or disk['sizeGiB'] != 256):
                errors.append('inventory-disk-not-confirmed-unused-attached-data-disk')
        planned_ids, guest_ids, luns = [], [], []
        for disk in storage['disks']:
            shape(disk, ['resourceId', 'guestUniqueId', 'lun', 'sizeGiB'], 'planned-disk')
            if not literal(disk['resourceId']):
                raise InvalidDocument('planned-resource-id-not-literal')
            key = disk['resourceId'].lower()
            planned_ids.append(key)
            if not literal(disk['guestUniqueId']):
                errors.append('guest-disk-identity-missing-or-not-literal')
            else:
                guest_ids.append(disk['guestUniqueId'].lower())
            if type(disk['lun']) is not int or not 0 <= disk['lun'] <= 63:
                errors.append('exact-lun-missing')
            else:
                luns.append(disk['lun'])
            found = observed.get(key)
            if found is None or any(disk[field] != found[field] for field in ['guestUniqueId', 'lun', 'sizeGiB']):
                errors.append('planned-disk-does-not-match-inventory')
        if set(planned_ids) != set(observed) or len(set(planned_ids)) != len(planned_ids):
            errors.append('planned-disk-set-not-exact')
        if len(set(guest_ids)) != len(guest_ids) or len(set(luns)) != len(luns):
            errors.append('duplicate-guest-disk-identity-or-lun')

        if not isinstance(approvals['receipts'], list):
            raise InvalidDocument('approval-receipt-list-schema')
        scopes = []
        for receipt in approvals['receipts']:
            shape(receipt, ['scope', 'status', 'approverType', 'approverId', 'nativeReference',
                            'planSha256', 'inventorySha256'], 'approval-receipt')
            if (receipt['scope'] not in ['storage', 'nested-network'] or receipt['status'] != 'approved'
                    or receipt['approverType'] != 'human' or not literal(receipt['approverId'])
                    or not literal(receipt['nativeReference']) or receipt['planSha256'] != plan_hash
                    or receipt['inventorySha256'] != inventory_hash):
                errors.append('approval-evidence-missing-unbound-or-not-human')
            else:
                scopes.append(receipt['scope'])
        if sorted(scopes) != ['nested-network', 'storage']:
            errors.append('exact-bound-storage-and-network-receipts-required')
    except (InvalidDocument, TypeError, ValueError, KeyError) as error:
        errors.append(str(error) if isinstance(error, InvalidDocument) else 'malformed-document')
    errors = sorted(set(errors))
    return {'schemaVersion': 1, 'status': 'blocked' if errors else 'valid-for-independent-review',
            'errors': errors, 'planSha256': plan_hash, 'inventorySha256': inventory_hash,
            'approvalReferencesAuthenticated': False, 'liveInventoryVerified': False,
            'automaticApplyPermitted': False, 'resourceActionsPerformed': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', required=True)
    parser.add_argument('--inventory', required=True)
    parser.add_argument('--approvals', required=True)
    args = parser.parse_args()
    try:
        plan = read_document(args.plan)
        inventory = read_document(args.inventory)
        approvals = read_document(args.approvals)
        result = validate(plan, inventory, approvals)
    except (OSError, ValueError):
        result = {'status': 'blocked', 'errors': ['input-unreadable-or-invalid-json'],
                  'automaticApplyPermitted': False, 'resourceActionsPerformed': False}
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['status'] == 'valid-for-independent-review' else 2)
