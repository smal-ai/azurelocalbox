"""Read-only bounded observation of the already-submitted corrected Validate.

Preserves the original timeout receipt. Never submits Validate or Deploy and never
changes an Azure resource. A separate receipt records any positive service result.
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
D = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='existing_validation_observer')
ORIGINAL = 'docs/deployment-2026-10-29/three-node-cluster-validate-after-lcm-format-fix-receipt.json'
ACTION = 'localbox-three-node-validate-lcm-format-20261029'


def verify_original(prior):
    expected_id = D['SCOPE'] + '/providers/Microsoft.Resources/deployments/' + ACTION
    current_hash = hashlib.sha256((ROOT / D['TEMPLATES']['validate']).read_bytes()).hexdigest()
    if (prior.get('stage') != 'validate' or prior.get('deploymentName') != ACTION
            or prior.get('deploymentId','').lower() != expected_id.lower()
            or prior.get('status') != 'uncertain-or-still-running-inspect-do-not-repeat'
            or prior.get('deploymentState') != 'Running' or prior.get('deploySubmitted') is not False
            or prior.get('templateSha256') != current_hash):
        raise RuntimeError('Not the exact retained pending corrected-validation request')
    return current_hash


def main(wait_seconds):
    head = D['A']['source_guard'](['scripts/observe-smal-corrected-validation.py',
        'scripts/deploy-smal-three-node-cluster.py',D['TEMPLATES']['validate'],ORIGINAL])
    original = (ROOT / ORIGINAL).read_bytes(); prior = json.loads(original)
    template_hash = verify_original(prior)
    path = D['OUT'] / 'three-node-corrected-validation-observation.json'
    record = {'beganAtUtc':datetime.now(timezone.utc).isoformat(),'sourceCommit':head,
              'stage':'validate','deploymentName':ACTION,'status':'observing-existing-request',
              'templateSha256':template_hash,'originalTimeoutReceiptSha256':hashlib.sha256(original).hexdigest(),
              'azureMutationPerformed':False,'validateSubmitted':False,'deploySubmitted':False,'platformReadinessVerified':False}
    with path.open('x') as stream: stream.write(json.dumps(record,indent=2) + '\n')
    def save(): path.write_text(json.dumps(record,indent=2) + '\n')
    try:
        deadline = time.monotonic() + wait_seconds
        while True:
            arm = D['az'](['deployment','group','show','--subscription',D['SUB'],'-g',D['RG'],'-n',ACTION,
                           '--query','{id:id,state:properties.provisioningState,code:properties.error.code}'])
            if arm['id'].lower() != prior['deploymentId'].lower(): raise RuntimeError('Observed deployment identity differs')
            record['deploymentId'] = arm['id']; record['deploymentState'] = arm['state']; record['deploymentErrorCode'] = arm.get('code')
            record['serviceResult'] = D['service_result']('validate')
            record['lastObservedAtUtc'] = datetime.now(timezone.utc).isoformat(); save()
            if arm['state'] in ['Failed','Canceled']:
                record['status'] = 'failed-existing-validation-no-retry'; break
            if arm['state'] == 'Succeeded' and D['service_passed'](record['serviceResult']):
                record['status'] = 'complete'; break
            if str(record['serviceResult']['action'].get('status','')).lower() in ['error','failed','canceled']:
                record['status'] = 'failed-reported-validation-no-retry'; break
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
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--wait-seconds',type=int,default=3600); args = parser.parse_args()
    if not 60 <= args.wait_seconds <= 7200: parser.error('wait bound must be 60–7200 seconds')
    raise SystemExit(main(args.wait_seconds))
