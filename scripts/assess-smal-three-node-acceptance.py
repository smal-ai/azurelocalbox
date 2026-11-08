"""Offline assessment of independent post-Deploy observations. No Azure operations.

Verifies exact approved S2D membership and cloud bindings, but never substitutes
service success for encryption, recovery or capacity acceptance.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
D = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='offline_acceptance_helpers')
WINDOWS = 'docs/deployment-2026-10-27/private-ssh-final-cluster-storage-postdeploy-identity-20261030.json'
CLOUD = 'docs/deployment-2026-10-29/three-node-cloud-acceptance-corrected-observer-20261030.json'
BINDINGS = 'docs/deployment-2026-10-29/three-node-local-identity-bindings.json'
DISK_OBSERVATION = 'docs/deployment-2026-10-29/three-node-disk-and-audit-export-observation-20261030.json'


def verify_storage(proof,bindings):
    data = proof.get('result',{})
    if proof.get('status') != 'complete' or data.get('observationStatus') != 'complete-read-only' or data.get('mutationPerformed') is not False:
        raise RuntimeError('Complete independent read-only Windows observation required')
    nodes = data.get('nodes',[]); bound = bindings['nodes']
    if len(nodes) != 3 or {row['name']:row['vmId'] for row in nodes} != {name:row['vmId'] for name,row in bound.items()}:
        raise RuntimeError('Exact three-node VM identity set differs')
    approved = {disk['guestUniqueId']:disk['sizeBytes'] for row in bound.values() for disk in row['disks'] if disk['eligibleForS2D']}
    if len(approved) != 12: raise RuntimeError('Exactly twelve approved data identities required')
    pool_ids = set()
    for row in nodes:
        guest = row['guest']; name = row['name']; pools = guest.get('storagePools',[])
        if (row.get('state') != 'Running' or guest.get('name') != name or guest.get('domain') != 'ad.localbox.test'
                or guest.get('domainRole') != 3 or guest.get('clusterName') != D['NAME'] or guest.get('storageSpacesDirectState') != 'Enabled'
                or guest.get('defenderEnabled') is not True or guest.get('firewallEnabled') is not True): raise RuntimeError('Cluster/node/domain/protection state differs')
        if len(guest.get('clusterNodes',[])) != 3 or {n['name']:n['state'] for n in guest['clusterNodes']} != {n:'Up' for n in bound}:
            raise RuntimeError('All three exact cluster members must be Up')
        if guest.get('quorumType') != 'Majority' or guest.get('quorumResourceName') is not None: raise RuntimeError('Approved three-node No Witness quorum differs')
        if len(pools) != 1 or pools[0].get('health') != 'Healthy' or pools[0].get('operationalStatus') != ['OK']: raise RuntimeError('Exact healthy S2D pool required')
        pool = pools[0]; members = pool.get('members',[]); pool_ids.add(pool['uniqueId'])
        if len(members) != 12 or {m['uniqueId']:m['size'] for m in members} != approved or any(m.get('health') != 'Healthy' for m in members):
            raise RuntimeError('S2D pool must contain only the twelve exact approved healthy non-OS devices')
        os_ids = {d['guestUniqueId'] for d in bound[name]['disks'] if not d['eligibleForS2D']}
        boot = [d for d in guest.get('localDisks',[]) if d.get('isBoot') or d.get('isSystem')]
        if len(boot) != 1 or {d['uniqueId'] for d in boot} != os_ids or set(approved) & os_ids: raise RuntimeError('Exact excluded OS disk identity differs')
        disks = guest.get('virtualDisks',[])
        if {v['name'] for v in disks} != {'Infrastructure_1','ClusterPerformanceHistory','UserStorage_1','UserStorage_2','UserStorage_3'} or len(disks) != 5:
            raise RuntimeError('Expected Express infrastructure/user storage set differs')
        if any(v.get('health') != 'Healthy' or v.get('resiliency') != 'Mirror' or v.get('dataCopies') != 3 for v in disks): raise RuntimeError('Healthy three-copy mirrors required')
        csv = guest.get('csv',[])
        if len(csv) != 4 or any(v.get('state') != 'Online' or v.get('owner') not in bound for v in csv): raise RuntimeError('Four Online CSVs with approved owners required')
        if {v['name'] for v in csv} != {'Cluster Virtual Disk (' + name + ')' for name in ['Infrastructure_1','UserStorage_1','UserStorage_2','UserStorage_3']}:
            raise RuntimeError('Expected Express CSV names differ')
        if guest.get('storageJobs') != []: raise RuntimeError('Storage jobs still active; inspect before acceptance')
        if any(g.get('state') != 'Online' for g in guest.get('clusterGroups',[]) if g.get('name') != 'Available Storage'): raise RuntimeError('An active infrastructure cluster group is not Online')
    if len(pool_ids) != 1: raise RuntimeError('Nodes disagree on S2D pool identity')
    outer = data.get('outerPool',[])
    if len(outer) != 1 or outer[0].get('health') != 'Healthy' or outer[0].get('memberCount') != 8 or outer[0].get('uniqueId') != '{b8174816-65a9-46f7-87c1-b189be0b90e5}':
        raise RuntimeError('Original eight-member outer pool identity/health differs')
    if {v['letter'] for v in data.get('volumes',[])} != {'C','V','W'} or any(v['health'] != 'Healthy' for v in data['volumes']): raise RuntimeError('Healthy existing outer volumes required')
    return {'nodeCount':3,'approvedPoolMemberCount':12,'osDisksExcluded':True,'s2dPoolId':next(iter(pool_ids)),
            'noWitness':True,'onlineCsvCount':4,'threeCopyMirrorsHealthy':True,'activeStorageJobs':False,'originalOuterPoolPreserved':True}


def verify_cloud(proof):
    if proof.get('azureMutationPerformed') is not False or not D['service_passed'](proof.get('serviceDeploy',{})): raise RuntimeError('Positive independently observed service Deploy required')
    D['P']['verify_cloud'](proof['arcMachines'])
    bridge_id = D['SCOPE'] + '/providers/Microsoft.ResourceConnector/appliances/' + D['NAME'] + '-arcbridge'
    bridges = proof.get('bridgeResources',[]); locations = proof.get('customLocationResources',[])
    if len(bridges) != 1 or bridges[0]['id'].lower() != bridge_id.lower() or bridges[0].get('provisioningState') != 'Succeeded' or bridges[0].get('status') != 'Running': raise RuntimeError('Exact healthy resource bridge required')
    if len(locations) != 1 or locations[0].get('name') != 'cl-localbox-smal-weu-1' or locations[0].get('provisioningState') != 'Succeeded' or locations[0].get('hostResourceId','').lower() != bridge_id.lower(): raise RuntimeError('Exact custom-location bridge binding differs')
    vault = proof.get('vault',{})
    if vault.get('pna') != 'Disabled' or vault.get('rbac') is not True or vault.get('purgeProtection') is not True or vault.get('softDeleteDays') != 90: raise RuntimeError('Approved private vault protection differs')
    accounts = proof.get('storage',[])
    if len(accounts) != 2 or {r['name'] for r in accounts} != {'stlboxdiagweu4766ea','stlboxwitweu4766ea'} or any(r.get('pna') != 'Disabled' or r.get('sharedKey') is not False for r in accounts): raise RuntimeError('Private/no-Shared-Key storage boundary differs')
    audits = proof.get('vaultAudit') or []
    destination = D['SCOPE'] + '/providers/Microsoft.Storage/storageAccounts/stlboxdiagweu4766ea'
    if not any(row.get('name') == 'localbox-vault-audit' and row.get('storageAccountId','').lower() == destination.lower()
               and any(log.get('category') == 'AuditEvent' and log.get('enabled') is True for log in row.get('logs',[])) for row in audits): raise RuntimeError('Expected configured audit export not proven')
    return {'threeArcIdentitiesConnected':True,'resourceBridgeRunning':True,'customLocationSucceededAndBound':True,
            'privateAccessControlsPreserved':True,'vaultAuditExportConfigured':True}


def boot_encryption_issues(proof):
    issues = []
    for row in proof['result']['nodes']:
        boot = [v for v in row['guest'].get('encryption',[]) if v.get('volumeType') == 'OperatingSystem' and v.get('mountPoint') == 'C:']
        if len(boot) != 1 or boot[0].get('protectionStatus') != 'On' or boot[0].get('volumeStatus') != 'FullyEncrypted' or boot[0].get('encryptionPercentage') != 100:
            issues.append({'node':row['name'],'issue':'requested-boot-volume-encryption-not-verified','observed':boot})
    return issues


def capacity(proof):
    guest = proof['result']['nodes'][0]['guest']; pool = guest['storagePools'][0]; disks = guest['virtualDisks']; gib = 1024**3
    return {'poolSizeGiB':round(pool['size']/gib,2),'poolAllocatedGiB':round(pool['allocated']/gib,2),
            'poolUnallocatedGiB':round((pool['size']-pool['allocated'])/gib,2),
            'nominalUserVolumeGiB':round(sum(v['size'] for v in disks if v['name'].startswith('UserStorage_'))/gib,2),
            'userVolumesThinProvisioned':all(v['provisioning'] == 'Thin' for v in disks if v['name'].startswith('UserStorage_')),
            'additionalThreeCopyLogicalGiBBeforeReserveAndOverhead':round((pool['size']-pool['allocated'])/3/gib,2),
            'warning':'Nominal thin-volume/CSV free space is not physical capacity. Preserve repair reserve and account for three copies before allocating workloads.'}


def main():
    paths = [WINDOWS,CLOUD,BINDINGS,DISK_OBSERVATION]; proof = json.loads((ROOT / WINDOWS).read_text()); cloud = json.loads((ROOT / CLOUD).read_text()); bindings = json.loads((ROOT / BINDINGS).read_text())
    disk_observation = json.loads((ROOT / DISK_OBSERVATION).read_text())
    record = {'assessedAtUtc':datetime.now(timezone.utc).isoformat(),'status':'cluster-and-cloud-checks-passed-encryption-disk-tier-and-recovery-incomplete',
              'clusterStorage':verify_storage(proof,bindings),'cloud':verify_cloud(cloud),'bootEncryptionIssues':boot_encryption_issues(proof),
              'capacity':capacity(proof),'recoveryExportAndOwnershipAccepted':False,'platformReadinessVerified':False,'azureMutationPerformed':False,
              'premiumHostDisksVerified':disk_observation.get('allTenHostDisksRemainPremium') is True,
              'auditDeliveryVerified':disk_observation.get('auditDeliveryObserved') is True,
              'proofs':[{'path':p,'sha256':hashlib.sha256((ROOT / p).read_bytes()).hexdigest()} for p in paths]}
    path = D['OUT'] / 'three-node-independent-acceptance-assessment-20261030.json'
    with path.open('x') as stream: stream.write(json.dumps(record,indent=2) + '\n')
    print(json.dumps(record,indent=2))


if __name__ == '__main__': main()
