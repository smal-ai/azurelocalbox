"""One explicitly approved VM restart. Never repeat a pending/uncertain action."""
import argparse
import json
import re
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / 'scripts/smal-bootstrap-preflight.py'), run_name='restart_helpers')
OUT = H['OUT']


def preconditions(inspection, installed):
    result = inspection.get('result', {})
    return (inspection.get('status') == 'complete'
            and result.get('computer') == H['VM']
            and result.get('inspectionSucceeded') is True
            and result.get('administrator') is True
            and result.get('hyperV') == 'Installed'
            and result.get('hyperVPowerShell') == 'Installed'
            and result.get('lastBootUtc') == installed['result']['lastBootUtc']
            and inspection.get('strictPinnedHostKey') is True)


def main(commit, inspection_name='private-ssh-pre-reboot-hyperv-check.json'):
    target = OUT / 'host-hyperv-restart-action.json'
    if target.exists():
        raise RuntimeError('Restart already recorded. Reconcile instead of repeating.')
    approval = json.loads((OUT / 'host-hyperv-reboot-approval.json').read_text())
    if approval.get('oneHostRebootApproved') is not True:
        raise RuntimeError('Explicit reboot approval missing')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    branch = subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip()
    remote = subprocess.check_output(['git', 'ls-remote', '--heads', 'origin', 'refs/heads/' + branch], text=True).split()
    if head != commit or not remote or remote[0] != commit:
        raise RuntimeError('Exact restart source must be committed and pushed')
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
        raise RuntimeError('Tracked files changed after commit')
    installed = json.loads((OUT / 'private-ssh-hyperv-prerequisite.json').read_text())
    if not re.fullmatch(r'private-ssh-pre-reboot-hyperv-check[0-9]*\.json', inspection_name):
        raise RuntimeError('Only a fixed pre-reboot inspection receipt is accepted')
    inspection = json.loads((OUT / inspection_name).read_text())
    if inspection.get('commit') != commit or inspection.get('script') != 'scripts/inspect-smal-hyperv.ps1':
        raise RuntimeError('Guest inspection must use this exact committed source')
    if not preconditions(inspection, installed):
        raise RuntimeError('Fresh private guest inspection differs from the approved pre-reboot state')
    identity = H['read_az'](['account', 'show', '--subscription', H['SUB'], '--query', '{id:id,tenantId:tenantId}'])
    principal = H['read_az'](['ad', 'signed-in-user', 'show', '--query', '{id:id}'])
    if identity != {'id': H['SUB'], 'tenantId': H['TENANT']} or principal != {'id': H['PRINCIPAL']}:
        raise RuntimeError('Approved Azure identity changed')
    state = H['read_az'](['vm', 'get-instance-view', '--subscription', H['SUB'], '-g', H['RG'], '-n', H['VM'], '--query', 'instanceView.statuses[].code'])
    if 'PowerState/running' not in state:
        raise RuntimeError('VM no longer Running; inspect before restart')
    command = ['az', 'vm', 'restart', '--subscription', H['SUB'], '-g', H['RG'], '-n', H['VM'], '--only-show-errors']
    record = {'beganAtSast': H['now'](), 'status': 'pending', 'commit': commit,
              'command': command, 'beforeLastBootUtc': inspection['result']['lastBootUtc'],
              'preRebootInspection': inspection_name,
              'approval': 'host-hyperv-reboot-approval.json', 'automaticRetryPermitted': False}
    with target.open('x') as stream:
        stream.write(json.dumps(record, indent=2) + '\n')
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=600)
        record['exitCode'] = result.returncode
        record['status'] = 'restart-action-acknowledged-guest-verification-pending' if result.returncode == 0 else 'restart-action-failed-inspect-before-any-retry'
    except subprocess.TimeoutExpired:
        record['status'] = 'uncertain-timeout-do-not-repeat'
    record['finishedAtSast'] = H['now']()
    target.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))
    return 0 if record['status'] == 'restart-action-acknowledged-guest-verification-pending' else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--inspection', default='private-ssh-pre-reboot-hyperv-check.json')
    args = parser.parse_args()
    raise SystemExit(main(args.commit, args.inspection))
