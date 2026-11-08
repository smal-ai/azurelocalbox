"""Exact approved three-node Arc/bootstrap/storage identity and role boundaries."""
import json
from pathlib import Path
import runpy
import uuid

ROOT = Path(__file__).resolve().parents[1]
A = runpy.run_path(str(ROOT / 'scripts/smal-three-node-approval.py'), run_name='three_node_platform_approval')
R = runpy.run_path(str(ROOT / 'scripts/apply-smal-arc-platform-roles.py'), run_name='three_node_original_role_helpers')
SUB, RG, SCOPE, VAULT = R['SUB'], R['RG'], R['SCOPE'], R['VAULT']
OUT = A['OUT']; az = A['az']
NODES = {**R['NODES'], 'LB-NODE03': 'bd9a2019-2109-4aba-9f4e-90a1d300325d'}
NODE03_EXPECTED = {(SCOPE.lower(), NODES['LB-NODE03'], role) for role in ['865ae368-6a45-4bd1-8fbf-0d5151f56fc1','c99c945f-8bd1-4fb1-a903-01460aae6068']}
NODE03_EXPECTED.add((VAULT.lower(), NODES['LB-NODE03'], '4633458b-17de-408a-b874-0445c86b69e6'))
ALL_EXPECTED = R['EXPECTED'] | NODE03_EXPECTED


def verify_cloud(nodes):
    if len(nodes) != 3 or {row['name']: row['identity']['principalId'] for row in nodes} != NODES: raise RuntimeError('Exact three Arc identities differ')
    for row in nodes:
        if (row['id'].lower() != (SCOPE + '/providers/Microsoft.HybridCompute/machines/' + row['name']).lower()
                or row.get('status') != 'Connected' or row.get('provisioningState') != 'Succeeded' or row.get('location') != 'westeurope'
                or row['identity'].get('tenantId') != A['H']['TENANT'] or row['identity'].get('type') != 'SystemAssigned'
                or row.get('osVersion') != '10.0.26100.33650'):
            raise RuntimeError('Expected Arc health/region/tenant/OS state differs')


def cloud_nodes():
    return az(['connectedmachine', 'list', '-g', RG, '--query', '[].{id:id,name:name,status:status,provisioningState:provisioningState,location:location,identity:identity,agentVersion:agentVersion,osVersion:osVersion}'])


def verify_local(proof, require_ad=False, validated_ad_members=False):
    if proof.get('status') != 'complete': raise RuntimeError('Complete three-node private inspection required')
    data = proof['result']; rows = data.get('nodes', [])
    bound = json.loads((OUT / 'three-node-local-identity-bindings.json').read_text())['nodes']
    if len(rows) != 3 or {row['name']: row['vmId'] for row in rows} != {name: row['vmId'] for name, row in bound.items()} or len(data.get('guests', [])) != 4:
        raise RuntimeError('Exact current node/guest set differs')
    for row in rows:
        name = row['name']; guest = row['guest']; binding = bound[name]
        expected_role = 3 if validated_ad_members else 2
        if row['state'] != 'Running' or row['memoryBytes'] != 64 * 1024**3 or row['processors'] != 8 or guest['name'] != name or guest['build'] != '26100.33650' or guest['domainRole'] != expected_role or guest['bootstrapStatus'] != 'Succeeded' or guest['nonPrimordialPoolCount'] != 0 or guest['defenderEnabled'] is not True or guest['firewallEnabled'] is not True:
            raise RuntimeError('Expected node domain role/bootstrap/protection differs')
        if validated_ad_members and (guest.get('domain') != 'ad.localbox.test' or guest.get('partOfDomain') is not True):
            raise RuntimeError('Validated node must be a member of the exact approved AD domain')
        host_macs = {adapter['Name']: adapter['MacAddress'].replace('-', '').upper() for adapter in row['hostAdapters']}
        guest_macs = {adapter['Name']: adapter['MacAddress'].replace('-', '').upper() for adapter in guest['adapters']}
        if host_macs != binding['liveMacs'] or host_macs != guest_macs or any(adapter['Status'] != 'Up' for adapter in guest['adapters']): raise RuntimeError('Live approved NIC identity/status differs')
        expected_ip = '10.64.0.' + {'LB-NODE01':'11','LB-NODE02':'12','LB-NODE03':'13'}[name]
        if not any(ip['InterfaceAlias'] == 'MGMT1' and ip['IPAddress'] == expected_ip and ip['PrefixLength'] == 24 for ip in guest['ipv4']): raise RuntimeError('Management address differs')
        if len(guest['platformPaths']) != 3 or any(path['addresses'] != [path['expectedIp']] or path['tlsHttpStatus'] is None for path in guest['platformPaths']): raise RuntimeError('Private platform paths differ')
        if len(row['hostDisks']) != 5 or len(guest['disks']) != 5: raise RuntimeError('Exact five-disk set differs')
        by_lun = {disk['lun']: disk for disk in binding['disks']}; by_id = {disk['uniqueId']: disk for disk in guest['disks']}
        for disk in row['hostDisks']:
            expected = by_lun[disk['lun']]; ident = uuid.UUID(disk['diskId']); unique = '60022480' + (ident.bytes_le[:6] + ident.bytes[-6:]).hex().upper()
            if disk['path'].lower() != expected['path'].lower() or disk['diskId'] != expected['vhdId'] or disk['size'] != expected['sizeBytes'] or disk['parentPath'] or unique != expected['guestUniqueId'] or unique not in by_id: raise RuntimeError('Exact approved VHD/guest identity binding differs')
            actual = by_id[unique]
            if actual['size'] != disk['size']: raise RuntimeError('Guest disk capacity differs')
            if expected['eligibleForS2D']:
                if actual['style'] != 'RAW' or actual['isBoot'] or actual['isSystem']: raise RuntimeError('Approved data drive is not blank or is a boot/system disk')
            elif actual['style'] != 'GPT' or not actual['isBoot'] or not actual['isSystem']: raise RuntimeError('OS disk identity differs')
    if any(v['health'] != 'Healthy' or (v['letter'] in ['V','W'] and v['free'] < 200 * 1024**3) for v in data['volumes']): raise RuntimeError('Volume health/free-space reserve differs')
    if require_ad:
        ad = data['ad']; lcm = ad['lcm']
        if ad['domain'] != 'ad.localbox.test' or ad['ou'] != 'OU=SMAL01,OU=AzureLocal,DC=ad,DC=localbox,DC=test' or ad['inheritanceBlocked'] is not True or lcm['enabled'] is not True or lcm['user'] != 'lboxdeploy' or lcm['expired'] or lcm['neverExpires'] or lcm['groupCount'] != 0:
            raise RuntimeError('Approved AD OU/LCM state differs')


def validate_node03_preview(data, owned):
    if data.get('status') != 'Succeeded': raise RuntimeError('NODE3 role preview failed')
    seen = set()
    for row in data.get('changes', []):
        kind = row.get('changeType'); rid = row.get('resourceId', '').lower()
        if kind in ['NoChange','Ignore'] and rid in owned and row.get('before') == row.get('after'): continue
        after = row.get('after', {}); p = after.get('properties', {}); inferred = rid.rsplit('/providers/microsoft.authorization/roleassignments/', 1)[0]
        item = R['binding']({**p, 'scope': p.get('scope', inferred)})
        if kind != 'Create' or after.get('type', '').lower() != 'microsoft.authorization/roleassignments' or item not in NODE03_EXPECTED or item in seen or inferred != item[0] or p.get('principalType') not in [None,'ServicePrincipal'] or p.get('roleDefinitionId', '').lower() != '/subscriptions/' + SUB + '/providers/microsoft.authorization/roledefinitions/' + item[2]:
            raise RuntimeError('Unlisted NODE3 role principal/definition/scope effect')
        seen.add(item)
    if seen != NODE03_EXPECTED: raise RuntimeError('Exactly the three approved NODE3 role creates are required')
