"""Bind inspected VM/VHD/data-device identities for the approved three-node layout.

Public metadata only. No Azure writes, role grants, secret reads or disk actions.
NODE3's future Arc managed-identity principal is deliberately left unknown.
"""
import hashlib
import json
from pathlib import Path
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-29'
LIVE = ROOT / 'docs/deployment-2026-10-27/private-ssh-three-node-live-before-arc-20261029.json'


def build():
    receipt = json.loads(LIVE.read_text()); local = json.loads((OUT / 'node03-local-completion.json').read_text())
    old = json.loads((ROOT / 'docs/deployment-2026-10-28/cloud-apply-proposal.json').read_text())
    plan = json.loads((OUT / 'three-node-proposal.json').read_text())
    if receipt.get('status') != 'complete' or local.get('status') != 'complete-local-only-human-arc-authentication-next': raise RuntimeError('Complete independent three-node/local proofs missing')
    data = receipt['result']; rows = data['nodes']
    ids = {'LB-NODE01': '3adff629-2f67-449b-ab32-8a8748c46f34', 'LB-NODE02': '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3', 'LB-NODE03': local['vm']['vmId']}
    if len(rows) != 3 or {row['name']: row['vmId'] for row in rows} != ids or len(data['guests']) != 4: raise RuntimeError('Exact inspected node/guest set differs')
    result = {'schemaVersion': 1, 'status': 'local-identities-verified-node03-arc-principal-not-yet-known', 'observedAtUtc': data['atUtc'],
              'sourceProofSha256': hashlib.sha256(LIVE.read_bytes()).hexdigest(), 'nodes': {}, 'witnessTypeParameter': 'No Witness', 'serviceWitnessType': '',
              'node03ArcPrincipalId': None, 'node03ArcRegistrationVerified': False, 'clusterDeploymentVerified': False}
    for row in rows:
        name = row['name']; guest = row['guest']
        if row['state'] != 'Running' or row['memoryBytes'] != 64 * 1024**3 or row['processors'] != 8 or guest['name'] != name or guest['build'] != '26100.33650' or guest['domainRole'] != 2 or guest['nonPrimordialPoolCount'] != 0 or guest['defenderEnabled'] is not True or guest['firewallEnabled'] is not True:
            raise RuntimeError('Current approved standalone node shape/protection differs')
        host_macs = {adapter['Name']: adapter['MacAddress'].replace('-', '').upper() for adapter in row['hostAdapters']}
        guest_macs = {adapter['Name']: adapter['MacAddress'].replace('-', '').upper() for adapter in guest['adapters']}
        if host_macs != guest_macs or set(host_macs) != {'MGMT1','MGMT2','STORAGEA','STORAGEB'} or '000000000000' in host_macs.values(): raise RuntimeError('Live vNIC MAC/name mapping differs')
        if guest['bootstrapCommand'] != {'available': True, 'version': '1.0.0', 'sha256': '70B11110F8483898A5CB3667A92F26315361847437832826C58DE53320746F0F'}: raise RuntimeError('Pinned bootstrap module evidence differs')
        if len(guest['platformPaths']) != 3 or any(path['addresses'] != [path['expectedIp']] or path['tlsHttpStatus'] is None for path in guest['platformPaths']): raise RuntimeError('Normal private DNS/TLS path evidence differs')
        host = row['hostDisks']; disks = guest['disks']
        if len(host) != 5 or len(disks) != 5 or {disk['lun'] for disk in host} != set(range(5)): raise RuntimeError('Exact five-disk mapping differs')
        by_id = {disk['uniqueId']: disk for disk in disks}; bindings = []
        for disk in host:
            ident = uuid.UUID(disk['diskId']); unique = '60022480' + (ident.bytes_le[:6] + ident.bytes[-6:]).hex().upper()
            if unique not in by_id or disk['parentPath'] or by_id[unique]['size'] != disk['size']: raise RuntimeError('VHD GUID/guest identity or backing differs')
            suffix = 'OS.vhdx' if disk['lun'] == 0 else 'S2D-' + str(disk['lun']) + '.vhdx'
            expected_path = ('W:\\AzureLocalBox\\Guests\\three-node-20261029-01\\LB-NODE03\\' if name == 'LB-NODE03' else 'V:\\AzureLocalBox\\Guests\\local-guests-20261028-01\\' + name + '\\') + suffix
            if name == 'LB-NODE01' and disk['lun'] == 4: expected_path = plan['existingVhdRelocation']['destination']
            if disk['path'].lower() != expected_path.lower(): raise RuntimeError('Unlisted VHD location')
            observed = by_id[unique]
            if disk['lun'] == 0:
                if observed['style'] != 'GPT' or not observed['isBoot'] or not observed['isSystem']: raise RuntimeError('OS disk identity differs')
            elif observed['style'] != 'RAW' or observed['size'] != 170 * 1024**3 or observed['isBoot'] or observed['isSystem']:
                raise RuntimeError('Approved blank S2D device differs')
            bindings.append({'lun': disk['lun'], 'path': disk['path'], 'vhdId': disk['diskId'], 'guestUniqueId': unique, 'sizeBytes': disk['size'], 'eligibleForS2D': disk['lun'] != 0})
        allowed = sorted(binding['guestUniqueId'] for binding in bindings if binding['eligibleForS2D'])
        if name in old['dataDeviceAllowlist'] and allowed != sorted(old['dataDeviceAllowlist'][name]): raise RuntimeError('Original node data IDs changed')
        result['nodes'][name] = {'vmId': row['vmId'], 'liveMacs': host_macs, 'disks': bindings, 's2dDataDeviceAllowlist': allowed}
    return result


if __name__ == '__main__':
    path = OUT / 'three-node-local-identity-bindings.json'
    result = build()
    with path.open('x') as stream: stream.write(json.dumps(result, indent=2) + '\n')
    print(str(path.relative_to(ROOT)))
