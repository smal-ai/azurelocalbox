"""Read-only success reconciliation. Retains the overly strict observer timeout.

No Validate/Deploy request, role change, domain operation or resource repair.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
D = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='validation_success_reconciliation')
ORIGINAL = 'docs/deployment-2026-10-29/three-node-cluster-validate-gateway-after-auth-reconciliation-receipt.json'
ACTION = 'localbox-three-node-validate-gateway-echo-20261029'


def main():
    head = D['A']['source_guard'](['scripts/reconcile-smal-gateway-validation-success.py','scripts/deploy-smal-three-node-cluster.py',
        'scripts/smal-three-node-platform.py','scripts/inspect-smal-three-node-live.ps1',D['TEMPLATES']['validate'],ORIGINAL])
    raw = (ROOT / ORIGINAL).read_bytes(); prior = json.loads(raw)
    template_hash = hashlib.sha256((ROOT / D['TEMPLATES']['validate']).read_bytes()).hexdigest()
    if (prior.get('status') != 'uncertain-or-still-running-inspect-do-not-repeat' or prior.get('deploymentName') != ACTION
            or prior.get('deploymentState') != 'Succeeded' or prior.get('templateSha256') != template_hash
            or prior.get('deploySubmitted') is not False): raise RuntimeError('Not the exact retained successful-ARM observer timeout')
    path = D['OUT'] / 'three-node-cluster-validation-success-reconciliation-20261030.json'
    record = {'beganAtUtc':datetime.now(timezone.utc).isoformat(),'sourceCommit':head,'stage':'validate','deploymentName':ACTION,
              'status':'pending-read-only-reconciliation','originalObserverTimeoutRetained':True,'originalObserverReceiptSha256':hashlib.sha256(raw).hexdigest(),
              'templateSha256':template_hash,'azureMutationPerformed':False,'validateSubmitted':False,'deploySubmitted':False,'platformReadinessVerified':False}
    with path.open('x') as stream: stream.write(json.dumps(record,indent=2) + '\n')
    try:
        D['preflight']()
        arm = D['az'](['deployment','group','show','--subscription',D['SUB'],'-g',D['RG'],'-n',ACTION,'--query','{id:id,state:properties.provisioningState}'])
        cluster = D['L']['rest'](D['CLUSTER']); settings = D['L']['rest'](D['SETTINGS'])
        deployed = (settings['properties'].get('reportedProperties') or {}).get('deploymentStatus') or {}
        if arm['id'].lower() != prior['deploymentId'].lower() or arm['state'] != 'Succeeded' or cluster['properties'].get('status') != 'ValidationSuccess' or cluster['identity']['principalId'] != '8c44672b-b729-4d3f-ad38-a0ac815ea265': raise RuntimeError('Exact successful validation/cluster identity not confirmed')
        if deployed.get('status') not in [None,'','NotStarted'] or deployed.get('steps'): raise RuntimeError('Deployment already started. This reconciliation is not applicable.')
        if D['az'](['deployment','group','list','--subscription',D['SUB'],'-g',D['RG'],'--query',"[?name=='localbox-three-node-deploy-20261029'].name"]): raise RuntimeError('Deploy ARM record already exists. Inspect, never replay.')
        result = D['service_result']('validate')
        if not D['service_passed'](result): raise RuntimeError('Positive current reported service validation not proven')
        record['deploymentId'] = arm['id']; record['deploymentState'] = arm['state']; record['clusterStatus'] = 'ValidationSuccess'; record['serviceResult'] = result
        record['privateInputsReceipt'] = D['inspect_inputs']('validated-success-reconciliation',validated_ad_members=True)
        record['status'] = 'complete'
    except (RuntimeError,ValueError,KeyError,OSError) as error:
        record['status'] = 'failed-read-only-reconciliation'; record['errorType'] = type(error).__name__
        if isinstance(error,RuntimeError): record['error'] = str(error)
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat(); path.write_text(json.dumps(record,indent=2) + '\n'); print(json.dumps(record,indent=2))
    return 0 if record['status'] == 'complete' else 2


if __name__ == '__main__': raise SystemExit(main())
