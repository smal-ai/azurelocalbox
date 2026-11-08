"""Read-only bounded observation of already-attached capacity. Never adds/replays."""
import argparse
import contextlib
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / 'scripts/smal-capacity-expansion.py'),run_name='capacity_growth_observer')


def main(wait_seconds):
    head = H['source_guard']()
    H['D']['A']['source_guard'](['scripts/observe-smal-capacity-growth.py',
        'docs/deployment-2026-10-30/capacity-expansion-add-vhds-after-id-binding-reconciliation-receipt.json',
        'docs/deployment-2026-10-30/capacity-expansion-verify-receipt.json'])
    plan = H['load_plan'](); baseline = H['previous']('prepare')['result']; added = H['previous']('add-vhds')['result']; formatted = H['previous']('format')['result']
    prior_path = H['OUT'] / 'capacity-expansion-verify-receipt.json'; prior = json.loads(prior_path.read_text())
    if prior.get('status') != 'failed-inspect-before-resume' or prior.get('error') != 'Exact twenty-four approved healthy pool members not yet observed; no automatic repair':
        raise RuntimeError('Not the exact retained in-progress auto-claim observation')
    path = H['OUT'] / 'capacity-expansion-converged-observation-20261030.json'
    record = {'beganAtUtc':datetime.now(timezone.utc).isoformat(),'sourceCommit':head,'status':'observing-existing-capacity',
              'azureMutationPerformed':False,'newDiskOrVhdOperationRequested':False,'platformReadinessVerified':False,
              'originalEarlyObservationRetained':True,'originalEarlyReceiptSha256':hashlib.sha256(prior_path.read_bytes()).hexdigest(),'observations':[]}
    with path.open('x') as stream: stream.write(json.dumps(record,indent=2) + '\n')
    def save(): path.write_text(json.dumps(record,indent=2) + '\n')
    try:
        deadline = time.monotonic() + wait_seconds; attempt = 0
        while True:
            H['D']['preflight'](); disks = H['disk_projection'](); H['verify_existing_disks'](disks,plan,with_new=True); H['verify_vm'](H['vm_projection'](),plan,attached=True)
            disk = H['D']['az'](['disk','show','--subscription',H['D']['SUB'],'--ids',plan['newDisk']['id']]); H['verify_new_disk'](disk,plan,attached=True)
            if disk['uniqueId'] != H['previous']('create')['newDisk']['uniqueId']: raise RuntimeError('New disk immutable identity changed')
            name = 'capacity-convergence-20261030-' + str(attempt)
            with contextlib.redirect_stdout(io.StringIO()): code = H['D']['T']['main']('scripts/inspect-smal-three-node-final.ps1',name)
            private = H['D']['T']['OUT'] / ('private-ssh-' + name + '.json'); proof = json.loads(private.read_text())
            if code != 0: raise RuntimeError('Read-only capacity observation failed')
            record['observations'].append(str(private.relative_to(ROOT))); save()
            try: result = H['verify_growth'](plan,baseline,added,proof)
            except RuntimeError as error:
                if str(error) not in ['Exact twenty-four approved healthy pool members not yet observed; no automatic repair','Nodes disagree on pool capacity','Pool capacity did not approximately double']:
                    raise
                record['lastPendingCondition'] = str(error); save()
                if time.monotonic() >= deadline: record['status'] = 'still-pending-inspect-no-replay'; break
                attempt += 1; time.sleep(20); continue
            record['result'] = result; record['outerVolumes'] = H['verify_outer_volumes'](proof,baseline,formatted,plan)
            data_gib = sum(r['sizeGiB'] for r in disks if r['id'].lower() != plan['vmBefore']['osId'].lower())
            if data_gib != 8192: raise RuntimeError('Exact doubled Azure data capacity differs')
            record['azureDataCapacityGiB'] = data_gib; record['allElevenHostDisksStandardLrs'] = all(r['sku'] == 'Standard_LRS' for r in disks)
            if record['allElevenHostDisksStandardLrs'] is not True: raise RuntimeError('Approved Standard_LRS tier differs')
            record['status'] = 'complete-capacity-doubled-existing-data-preserved'; break
    except (TimeoutError,subprocess.TimeoutExpired): record['status'] = 'uncertain-read-timeout-no-replay'
    except (RuntimeError,ValueError,KeyError,OSError) as error:
        record['status'] = 'read-observation-failed-no-replay'; record['errorType'] = type(error).__name__
        if isinstance(error,RuntimeError): record['error'] = str(error)
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat(); save(); print(json.dumps(record,indent=2))
    return 0 if record['status'].startswith('complete-') else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--wait-seconds',type=int,default=600); args = parser.parse_args()
    if not 60 <= args.wait_seconds <= 3600: parser.error('observation bound must be 60–3600 seconds')
    raise SystemExit(main(args.wait_seconds))
