"""Asynchronous, evidence-only bootstrap readiness checkpoint. Never deploys anything.

Terminal 'blocked' means preparation was inspected, NOT that a bootstrap process is
running. A scheduled agent can continue offline engineering from this checkpoint.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-27'


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def evaluate(out):
    def read(name):
        return json.loads((out / name).read_text())
    contract = read('bootstrap-execution-contract.json')
    approval = read('current-2610-image-approval.json')
    image = read('private-ssh-stage-2610-image.json')
    pin = read('current-os-image-2610-pin.json')
    reboot = read('private-ssh-post-reboot-hyperv-check.json')
    expansion = read('private-ssh-os-volume-expansion.json')
    image_result = image.get('result', {})
    checks = {
        'recordedHostHyperVAndPrivateAccessPassed': (
            reboot.get('status') == 'complete' and reboot.get('strictPinnedHostKey') is True
            and reboot.get('result', {}).get('hyperVHostQuerySucceeded') is True),
        'recordedOsExpansionPassed': (
            expansion.get('status') == 'complete'
            and expansion.get('result', {}).get('dataDiskInventoryUnchanged') is True),
        'recordedCurrentIsoStagingPassed': (
            approval.get('downloadAndChecksumVerificationApproved') is True
            and image.get('status') == 'complete'
            and image_result.get('stagingStatus') == 'complete-sha256-verified'
            and image_result.get('bytes') == pin['contentLength']
            and image_result.get('sha256') == pin['publisherSha256']
            and image_result.get('mountedOrExecuted') is False),
    }
    blockers = [name for name, passed in checks.items() if not passed]
    entrypoint = contract.get('safeClusterEntrypoint')
    if not entrypoint or contract.get('safeClusterEntrypointReviewed') is not True:
        blockers.append('safe-cluster-bootstrap-implementation-not-ready')
    if contract.get('remainingDependenciesPinned') is not True:
        blockers.append('remaining-transitive-dependencies-not-pinned')
    for name, decision in contract.get('requiredApplyDecisions', {}).items():
        # A local string cannot confer authority. "approved" only removes this
        # readiness flag; real execution still needs exact independent scope review.
        if decision != 'approved':
            blockers.append(name)
    if not contract.get('requiredApplyDecisions'):
        blockers.append('apply-decision-contract-missing')
    return {
        'status': 'blocked' if blockers else 'ready-for-human-scope-review',
        'phase': 'apply-readiness-gates',
        'checks': checks,
        'blockers': blockers,
        'liveGuestInspectionPerformed': False,
        'clusterDeploymentStarted': False,
        'activeGuestBootstrapJob': None,
        'automaticApplyOrRetryPermitted': False,
        'nextAction': 'Continue safe implementation/dependency review and obtain the exact outstanding design/apply decisions. Do not execute legacy bootstrap.',
        'evidence': ['private-ssh-post-reboot-hyperv-check.json', 'private-ssh-os-volume-expansion.json',
                     'private-ssh-stage-2610-image.json', 'bootstrap-execution-contract.json'],
    }


def atomic_json(path, value):
    temporary = path.with_name(path.name + f'.{os.getpid()}.tmp')
    with temporary.open('x') as stream:
        stream.write(json.dumps(value, indent=2) + '\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def main(run_id):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,63}', run_id):
        raise RuntimeError('Invalid run identity')
    record_path = OUT / f'bootstrap-async-run-{run_id}.json'
    if record_path.exists():
        raise RuntimeError('Run already recorded. Read its result rather than repeat it.')
    lock_dir = Path.home() / '.local/state/azurelocalbox/bootstrap'
    lock_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (lock_dir / 'readiness.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        started = now()
        with record_path.open('x') as stream:
            stream.write(json.dumps({'runId': run_id, 'status': 'running', 'startedAtUtc': started,
                                     'pid': os.getpid(), 'clusterDeploymentStarted': False}, indent=2) + '\n')
        try:
            result = evaluate(OUT)
        except (OSError, ValueError, KeyError) as error:
            result = {'status': 'failed', 'phase': 'readiness-evidence', 'errorType': type(error).__name__,
                      'clusterDeploymentStarted': False, 'activeGuestBootstrapJob': None,
                      'automaticApplyOrRetryPermitted': False}
        result.update({'schemaVersion': 1, 'runId': run_id, 'mode': 'evidence-only-preflight',
                       'startedAtUtc': started, 'lastCheckedAtUtc': now(), 'pid': os.getpid(),
                       'scheduleId': 'smal-localbox-bootstrap-followup-20261027'})
        result['blockerFingerprint'] = hashlib.sha256(json.dumps(result.get('blockers', []), sort_keys=True).encode()).hexdigest()
        atomic_json(record_path, result)
        atomic_json(OUT / 'bootstrap-async-progress.json', result)
        with (OUT / 'bootstrap-async-history.jsonl').open('a') as history:
            event = {key: result[key] for key in ['runId', 'lastCheckedAtUtc', 'status', 'phase', 'blockerFingerprint', 'clusterDeploymentStarted']}
            history.write(json.dumps(event, sort_keys=True) + '\n')
            history.flush()
            os.fsync(history.fileno())
        print(json.dumps(result, indent=2))
        return 2 if result['status'] == 'failed' else 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True)
    args = parser.parse_args()
    raise SystemExit(main(args.run_id))
