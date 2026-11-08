"""Bounded read-only observation of the approved one-shot NODE3 task. Never dispatches."""
import argparse
import contextlib
from datetime import datetime, timezone
import io
import json
from pathlib import Path
import runpy
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-29'


def verify_observation(proof, installed):
    if proof.get('status') != 'complete': raise RuntimeError('Private job observation failed. Inspect rather than reinstall.')
    data = proof['result']; expected = installed['result']
    if data['workerSha256'] != expected['workerSha256'] or data['bundleSha256'] != expected['bundleSha256'] or data['actualTriggerCount'] != 0 or data['principal'] not in ['SYSTEM', 'S-1-5-18']:
        raise RuntimeError('Exact one-shot job source/principal/trigger boundary differs')
    state = data['state']
    if state.get('sourceCommit') != expected['sourceCommit'] or state.get('azureRegistrationPerformed') is not False or state.get('clusterDeploymentPerformed') is not False:
        raise RuntimeError('Expected NODE3-only execution state differs')
    return data


def main(wait_seconds=1800):
    transport = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='node03_job_observer')
    installed = json.loads((OUT / 'three-node-install-node03-receipt.json').read_text())
    if installed.get('status') != 'complete': raise RuntimeError('Exact one-shot installation receipt missing')
    run = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6]
    deadline = time.monotonic() + wait_seconds; counter = 0; last = None; failed_reads = 0
    while True:
        counter += 1; name = 'node03-progress-' + run + '-' + str(counter)
        with contextlib.redirect_stdout(io.StringIO()): code = transport['main']('scripts/read-smal-node03-job.ps1', name)
        proof_path = transport['OUT'] / ('private-ssh-' + name + '.json')
        proof = json.loads(proof_path.read_text())
        if code != 0:
            failed_reads += 1
            # This retry is ONLY of the named read-only observer. Neither the
            # installer nor worker is ever dispatched/replayed here.
            if failed_reads <= 2 and time.monotonic() < deadline:
                print(json.dumps({'status': 'read-interrupted-worker-not-restarted', 'receipt': str(proof_path.relative_to(ROOT))}), flush=True)
                time.sleep(30)
                continue
            raise RuntimeError('Repeated private reads failed. Worker was not restarted. Inspect transport and existing state.')
        failed_reads = 0
        data = verify_observation(proof, installed); state = data['state']
        observed = {'phase': state['phase'], 'status': state['status'], 'taskState': data['taskState']}
        if observed != last:
            print(json.dumps({**observed, 'receipt': str(proof_path.relative_to(ROOT))}), flush=True); last = observed
        if data['taskState'] != 'Running':
            if data['lastTaskResult'] != 0 or state['status'] != 'complete-node03-local-bootstrap-cleanup-and-common-login':
                print(json.dumps({'errorType': state.get('errorType'), 'errorLine': state.get('errorLine'), 'lastTaskResult': data['lastTaskResult'], 'receipt': str(proof_path.relative_to(ROOT))}), flush=True)
                return 2
            target = OUT / 'node03-local-completion.json'
            record = {'status': 'complete-local-only-human-arc-authentication-next', 'observedAtUtc': data['atUtc'], 'sourceCommit': state['sourceCommit'], 'privateObservationReceipt': str(proof_path.relative_to(ROOT)),
                      'vm': state['vm'], 'hostDisks': state['hostDisks'], 'guestDisks': state['guestDisks'], 'cleanup': state['cleanup'], 'clock': state['clock'], 'connectivity': state['connectivity'], 'commonCredentialLoginVerified': state['commonCredentialLoginVerified'], 'arcRegistrationVerified': False, 'clusterDeploymentVerified': False}
            with target.open('x') as stream: stream.write(json.dumps(record, indent=2) + '\n')
            print(json.dumps({'status': record['status'], 'vmId': state['vm']['vmId'], 'completionReceipt': str(target.relative_to(ROOT))}), flush=True)
            return 0
        if time.monotonic() >= deadline:
            print(json.dumps({'status': 'still-running-observe-again-do-not-redispatch', 'receipt': str(proof_path.relative_to(ROOT))}), flush=True)
            return 3
        time.sleep(60)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--wait-seconds', type=int, default=1800)
    args = parser.parse_args()
    if not 30 <= args.wait_seconds <= 7200: parser.error('wait bound must be 30–7200 seconds')
    raise SystemExit(main(args.wait_seconds))
