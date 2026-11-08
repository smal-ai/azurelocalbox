"""Read-only bounded observation of the exact already-submitted three-node Deploy.

No Validate, Deploy, restart, repair, role or resource mutation. Retains the
original timeout and writes a separate observation, including terminal outcomes.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
D = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='existing_deploy_observer')
ORIGINAL = 'docs/deployment-2026-10-29/three-node-cluster-deploy-after-preview-reconciliation-receipt.json'
ACTION = 'localbox-three-node-deploy-20261029'


def verify_original(prior):
    expected_id = D['SCOPE'] + '/providers/Microsoft.Resources/deployments/' + ACTION
    current_hash = hashlib.sha256((ROOT / D['TEMPLATES']['deploy']).read_bytes()).hexdigest()
    if (prior.get('stage') != 'deploy' or prior.get('deploymentName') != ACTION
            or prior.get('deploymentId','').lower() != expected_id.lower()
            or prior.get('status') != 'uncertain-or-still-running-inspect-do-not-repeat'
            or prior.get('deploymentState') != 'Running' or prior.get('explicitRequestedMode') != 'Deploy'
            or prior.get('templateSha256') != current_hash or prior.get('originalPreSubmitRefusalRetained') is not True):
        raise RuntimeError('Not the exact retained pending Deploy request. Inspect; never replay.')
    return current_hash


def verify_follow_up(prior,template_hash):
    expected_id = D['SCOPE'] + '/providers/Microsoft.Resources/deployments/' + ACTION
    if (prior.get('stage') != 'deploy' or prior.get('deploymentName') != ACTION
            or prior.get('deploymentId','').lower() != expected_id.lower() or prior.get('templateSha256') != template_hash
            or prior.get('status') != 'uncertain-or-still-running-inspect-do-not-repeat' or prior.get('deploymentState') != 'Running'
            or prior.get('azureMutationPerformed') is not False or prior.get('deploySubmitted') is not False):
        raise RuntimeError('Not the exact retained pending read-only Deploy observation')


def main(wait_seconds,follow_up=False):
    paths = ['scripts/observe-smal-existing-deploy.py','scripts/deploy-smal-three-node-cluster.py',D['TEMPLATES']['deploy'],ORIGINAL]
    first_observation = 'docs/deployment-2026-10-29/three-node-cluster-deploy-observation-20261030.json'
    if follow_up: paths.append(first_observation)
    head = D['A']['source_guard'](paths)
    original = (ROOT / ORIGINAL).read_bytes(); prior = json.loads(original); template_hash = verify_original(prior)
    filename = 'three-node-cluster-deploy-observation-follow-up-20261030.json' if follow_up else 'three-node-cluster-deploy-observation-20261030.json'
    path = D['OUT'] / filename
    record = {'beganAtUtc':datetime.now(timezone.utc).isoformat(),'sourceCommit':head,'stage':'deploy','deploymentName':ACTION,
              'status':'observing-existing-deploy','templateSha256':template_hash,'originalTimeoutRetained':True,
              'originalTimeoutReceiptSha256':hashlib.sha256(original).hexdigest(),'azureMutationPerformed':False,
              'validateSubmitted':False,'deploySubmitted':False,'platformReadinessVerified':False}
    if follow_up:
        first_bytes = (ROOT / first_observation).read_bytes()
        verify_follow_up(json.loads(first_bytes),template_hash)
        record['priorObservationRetained'] = True
        record['priorObservationSha256'] = hashlib.sha256(first_bytes).hexdigest()
    with path.open('x') as stream: stream.write(json.dumps(record,indent=2) + '\n')
    def save(): path.write_text(json.dumps(record,indent=2) + '\n')
    try:
        deadline = time.monotonic() + wait_seconds
        while True:
            arm = D['az'](['deployment','group','show','--subscription',D['SUB'],'-g',D['RG'],'-n',ACTION,
                           '--query','{id:id,state:properties.provisioningState,code:properties.error.code}'])
            if arm['id'].lower() != prior['deploymentId'].lower(): raise RuntimeError('Observed deployment identity differs')
            cluster = D['L']['rest'](D['CLUSTER'])
            if cluster['identity']['principalId'] != '8c44672b-b729-4d3f-ad38-a0ac815ea265': raise RuntimeError('Existing cluster managed identity differs')
            record['clusterStatus'] = cluster['properties'].get('status')
            record['deploymentId'] = arm['id']; record['deploymentState'] = arm['state']; record['deploymentErrorCode'] = arm.get('code')
            record['serviceResult'] = D['service_result']('deploy')
            record['lastObservedAtUtc'] = datetime.now(timezone.utc).isoformat(); save()
            if arm['state'] in ['Failed','Canceled']:
                record['status'] = 'failed-existing-deploy-do-not-validate-or-replay'; break
            if arm['state'] == 'Succeeded' and D['service_passed'](record['serviceResult']):
                record['status'] = 'complete'; break
            if str(record['serviceResult']['action'].get('status','')).lower() in ['error','failed','canceled']:
                record['status'] = 'failed-reported-deploy-do-not-validate-or-replay'; break
            if time.monotonic() >= deadline:
                record['status'] = 'uncertain-or-still-running-inspect-do-not-repeat'; break
            time.sleep(30)
    except (TimeoutError,subprocess.TimeoutExpired): record['status'] = 'uncertain-observation-timeout-no-retry'
    except (RuntimeError,ValueError,KeyError,OSError) as error:
        record['status'] = 'observation-failed-no-retry'; record['errorType'] = type(error).__name__
        if isinstance(error,RuntimeError): record['error'] = str(error)
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat(); save(); print(json.dumps(record,indent=2))
    return 0 if record['status'] == 'complete' else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--wait-seconds',type=int,default=7200)
    parser.add_argument('--follow-up',action='store_true'); args = parser.parse_args()
    if not 60 <= args.wait_seconds <= 7200: parser.error('wait bound must be 60–7200 seconds')
    raise SystemExit(main(args.wait_seconds,args.follow_up))
