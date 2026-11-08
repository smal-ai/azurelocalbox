"""Read-only cloud acceptance evidence after a positively completed service Deploy.

No kubeconfig, credential value, raw service exception or signed URI is retained.
Collects facts only. Windows storage/recovery acceptance remains separate.
"""
from datetime import datetime, timezone
import argparse
import json
from pathlib import Path
import runpy
import re
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
D = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='three_node_cloud_acceptance')
P, az, OUT, SUB, RG = (D[key] for key in ['P','az','OUT','SUB','RG'])
BRIDGE = P['SCOPE'] + '/providers/Microsoft.ResourceConnector/appliances/smal-localbox01-arcbridge'
CUSTOM_LOCATION = P['SCOPE'] + '/providers/Microsoft.ExtendedLocation/customLocations/cl-localbox-smal-weu-1'


def get_projection(rid,version,query):
    return az(['rest','--method','get','--url','https://management.azure.com' + rid + '?api-version=' + version,'--query',query])


def audit_metadata(data):
    rows = data.get('value') if isinstance(data,dict) else data
    if not isinstance(rows,list): raise RuntimeError('Unexpected vault diagnostic-settings response shape')
    return [{'name':row.get('name'),'storageAccountId':row.get('storageAccountId'),'logs':row.get('logs')} for row in rows]


def arc_observation():
    # These helpers issue only scoped Azure reads. No guest secrets, kubeconfig or repair.
    return {
        'arcMachines': P['cloud_nodes'](),
        'bridge': get_projection(BRIDGE, '2022-10-27',
            '{id:id,name:name,location:location,provisioningState:properties.provisioningState,status:properties.status}'),
        'customLocation': get_projection(CUSTOM_LOCATION, '2021-08-15',
            '{id:id,name:name,location:location,provisioningState:properties.provisioningState,hostResourceId:properties.hostResourceId,namespace:properties.namespace}'),
    }


def arc_account():
    # The operator's CLI default may legitimately target another subscription.
    return az(['account', 'show', '--subscription', SUB, '--query', '{id:id,tenantId:tenantId,state:state}'])


def arc_pending(data):
    """Identity/binding drift fails; ordinary reported non-readiness can be observed."""
    nodes = data['arcMachines']
    if len(nodes) != 3 or {row['name']: row['identity']['principalId'] for row in nodes} != P['NODES']:
        raise RuntimeError('Exact three existing Arc node identities differ')
    pending = []
    for row in nodes:
        expected = P['SCOPE'] + '/providers/Microsoft.HybridCompute/machines/' + row['name']
        if (row['id'].lower() != expected.lower() or row['location'] != 'westeurope'
                or row['identity'].get('tenantId') != P['A']['H']['TENANT']
                or row['identity'].get('type') != 'SystemAssigned'):
            raise RuntimeError('Arc node scope, region or managed identity differs')
        if row.get('provisioningState') in ('Failed', 'Canceled'):
            raise RuntimeError('Arc node provisioning reports failure; no repair requested')
        if row.get('status') != 'Connected' or row.get('provisioningState') != 'Succeeded':
            pending.append(row['name'] + ': connection/provisioning not ready')
    bridge, location = data['bridge'], data['customLocation']
    if bridge['id'].lower() != BRIDGE.lower() or bridge.get('location') != 'westeurope':
        raise RuntimeError('Exact existing resource bridge differs')
    if (location['id'].lower() != CUSTOM_LOCATION.lower() or location.get('location') != 'westeurope'
            or location.get('hostResourceId', '').lower() != BRIDGE.lower()
            or location.get('namespace') != 'default'):
        raise RuntimeError('Exact custom-location bridge/namespace binding differs')
    if any(row.get('provisioningState') in ('Failed', 'Canceled') for row in (bridge, location)):
        raise RuntimeError('Bridge/custom-location provisioning reports failure; no repair requested')
    if bridge.get('provisioningState') != 'Succeeded' or bridge.get('status') != 'Running':
        pending.append('resource bridge not Running/Succeeded')
    if location.get('provisioningState') != 'Succeeded':
        pending.append('custom location not Succeeded')
    return pending


def observe_arc(wait_seconds, collect=None, clock=None, sleep=None):
    collect, clock, sleep = collect or arc_observation, clock or time.monotonic, sleep or time.sleep
    if not 0 <= wait_seconds <= 3600:
        raise ValueError('Arc observation bound must be 0–3600 seconds')
    deadline = clock() + wait_seconds
    count = 0
    while True:
        data = collect()
        count += 1
        pending = arc_pending(data)
        if not pending:
            return {'arcReadinessVerified': True, 'observations': count, 'pending': [], 'lastObservation': data}
        remaining = deadline - clock()
        if remaining <= 0:
            return {'arcReadinessVerified': False, 'observations': count, 'pending': pending, 'lastObservation': data}
        sleep(min(20, remaining))


def main_arc_readiness(wait_seconds=600):
    head = D['A']['source_guard'](['scripts/inspect-smal-three-node-cloud-health.py',
        'scripts/deploy-smal-three-node-cluster.py', 'scripts/smal-three-node-platform.py',
        'scripts/test_smal_arc_readiness.py'])
    account = arc_account()
    if account != {'id': SUB, 'tenantId': P['A']['H']['TENANT'], 'state': 'Enabled'}:
        raise RuntimeError('Approved tenant/subscription differs; no identity switch requested')
    path = OUT / ('arc-readiness-' + datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8] + '.json')
    record = {'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'sourceCommit': head,
              'status': 'observing-arc-readiness', 'azureMutationPerformed': False,
              'registrationOrRepairRequested': False, 'platformReadinessVerified': False,
              'readinessScope': 'Reported three Arc connections, resource bridge and custom-location binding only'}
    with path.open('x') as stream: stream.write(json.dumps(record, indent=2) + '\n')
    try:
        record['result'] = observe_arc(wait_seconds)
        record['status'] = 'arc-ready' if record['result']['arcReadinessVerified'] else 'arc-pending-no-repair'
    except (subprocess.TimeoutExpired, RuntimeError, ValueError, KeyError, TypeError, OSError) as error:
        record['status'] = 'arc-read-failed-no-repair'; record['errorType'] = type(error).__name__
        if isinstance(error, RuntimeError): record['error'] = str(error)
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat()
    path.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({'status': record['status'], 'receipt': str(path.relative_to(ROOT)),
        'result': record.get('result'), 'error': record.get('error'), 'platformReadinessVerified': False}, indent=2))
    return 0 if record['status'] == 'arc-ready' else 2


def main(receipt='three-node-cloud-acceptance-observation.json'):
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,95}\.json',receipt): raise RuntimeError('Invalid read-only observation receipt name')
    D['A']['source_guard'](['scripts/inspect-smal-three-node-cloud-health.py','scripts/deploy-smal-three-node-cluster.py',
        'docs/deployment-2026-10-29/three-node-cluster-deploy-observation-follow-up-20261030.json'])
    completed = D['previous']('deploy')
    if not D['service_passed'](completed.get('serviceResult',{})): raise RuntimeError('Positive service Deploy success required before final acceptance inspection')
    path = OUT / receipt
    record = {'beganAtUtc':datetime.now(timezone.utc).isoformat(),'status':'pending-read-only','platformReadinessVerified':False,'azureMutationPerformed':False}
    with path.open('x') as stream: stream.write(json.dumps(record,indent=2) + '\n')
    try:
        record['arcMachines'] = P['cloud_nodes'](); P['verify_cloud'](record['arcMachines'])
        record['cluster'] = get_projection(D['CLUSTER'],D['API'],'{id:id,name:name,location:location,identity:identity,provisioningState:properties.provisioningState,status:properties.status,cloudId:properties.cloudId,lastSync:properties.lastSyncTimestamp}')
        record['serviceDeploy'] = D['service_result']('deploy')
        if not D['service_passed'](record['serviceDeploy']): raise RuntimeError('Current reported deployment outcome no longer positively succeeds')
        resources = az(['resource','list','--subscription',SUB,'-g',RG,'--query','[].{id:id,name:name,type:type,location:location}'])
        record['resources'] = resources
        bridges = [row for row in resources if row['type'].lower() == 'microsoft.resourceconnector/appliances']
        locations = [row for row in resources if row['type'].lower() == 'microsoft.extendedlocation/customlocations' and row['name'] == 'cl-localbox-smal-weu-1']
        record['bridgeResources'] = [get_projection(row['id'],'2022-10-27','{id:id,name:name,location:location,provisioningState:properties.provisioningState,status:properties.status,distribution:properties.distribution}') for row in bridges]
        record['customLocationResources'] = [get_projection(row['id'],'2021-08-15','{id:id,name:name,location:location,provisioningState:properties.provisioningState,hostResourceId:properties.hostResourceId,namespace:properties.namespace}') for row in locations]
        record['vault'] = az(['keyvault','show','--subscription',SUB,'-n','kv-lbox-weu-4766ea','--query','{id:id,pna:properties.publicNetworkAccess,rbac:properties.enableRbacAuthorization,purgeProtection:properties.enablePurgeProtection,softDeleteDays:properties.softDeleteRetentionInDays}'])
        audit = az(['monitor','diagnostic-settings','list','--subscription',SUB,'--resource',D['VAULT']])
        record['vaultAudit'] = audit_metadata(audit)
        record['storage'] = [az(['storage','account','show','--subscription',SUB,'-g',RG,'-n',name,'--query','{id:id,name:name,pna:publicNetworkAccess,sharedKey:allowSharedKeyAccess,sku:sku.name}']) for name in ['stlboxdiagweu4766ea','stlboxwitweu4766ea']]
        record['defender'] = az(['security','pricing','show','--subscription',SUB,'--name','VirtualMachines','--query','{tier:pricingTier,subPlan:subPlan,freeTrialRemaining:freeTrialRemainingTime}'])
        record['status'] = 'observed-cloud-state-requires-storage-recovery-and-owner-acceptance'
    except (RuntimeError,ValueError,KeyError,OSError) as error:
        record['status'] = 'failed-read-only-observation'; record['errorType'] = type(error).__name__
        if isinstance(error,RuntimeError): record['error'] = str(error)
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat(); path.write_text(json.dumps(record,indent=2) + '\n')
    print(json.dumps(record,indent=2))
    return 0 if record['status'].startswith('observed-') else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', default='three-node-cloud-acceptance-observation.json')
    parser.add_argument('--arc-readiness', action='store_true', help='Read-only post-start Arc connectivity/binding test, not full platform acceptance')
    parser.add_argument('--wait-seconds', type=int, default=600, help='Arc observation bound, 0 for one observation')
    args = parser.parse_args()
    if not 0 <= args.wait_seconds <= 3600: parser.error('Arc wait bound must be 0–3600 seconds')
    if args.arc_readiness and args.receipt != 'three-node-cloud-acceptance-observation.json':
        parser.error('--receipt applies only to the original full cloud observation')
    raise SystemExit(main_arc_readiness(args.wait_seconds) if args.arc_readiness else main(args.receipt))
