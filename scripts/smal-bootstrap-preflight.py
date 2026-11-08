"""One fixed, owner-approved read-only guest preflight per section.

Run Command is SYSTEM through the guest agent, not a Bastion login. No credentials
are needed. A pending/failed receipt is never erased to enable an automatic retry.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-27'
SCRIPT = ROOT / 'scripts/smal-bootstrap-preflight.ps1'
SUB = '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea'
TENANT = 'c6e67968-af25-4557-ab8b-06b693048d3b'
PRINCIPAL = '82f494a8-b9f5-46fc-b0f7-c70be0572a63'
VM = 'LocalBox-Client'
RG = 'rg-localbox-nodes-san-1'
SECTIONS = ('System', 'Network')


def now():
    return datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=2))).isoformat()


def read_az(args):
    result = subprocess.run(['az', *args, '-o', 'json', '--only-show-errors'],
                            capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError('Azure read failed; raw output suppressed')
    return json.loads(result.stdout)


def parse_output(output, section):
    rows = json.loads(output)
    if not isinstance(rows, list) or not rows:
        raise RuntimeError('Unexpected Run Command envelope')
    if any(row.get('message', '').strip() for row in rows if '/StdErr/' in row.get('code', '')):
        raise RuntimeError('Guest reported stderr; raw output suppressed')
    stdout = '\n'.join(row['message'] for row in rows if '/StdOut/' in row.get('code', ''))
    if re.search(r'-----BEGIN|\beyJ[A-Za-z0-9_-]{15,}\.|(?i:password|access_token|refresh_token)', stdout):
        raise RuntimeError('Unexpected sensitive-pattern output suppressed')
    payload = json.loads(stdout)
    allowed = {'section', 'atUtc', 'computer', 'authenticatedGuestLogin', 'os', 'capacity',
               'cpu', 'features', 'disks', 'volumes', 'dns', 'pendingReboot', 'localBoxPathExists',
               'defender', 'winrmRunning', 'ssh', 'trustedHosts', 'web', 'centralDns', 'ntp', 'limitations'}
    if not isinstance(payload, dict) or set(payload) - allowed:
        raise RuntimeError('Unexpected guest payload fields')
    if payload.get('section') != section or payload.get('computer', '').lower() != VM.lower():
        raise RuntimeError('Unexpected target/section in guest evidence')
    if payload.get('authenticatedGuestLogin') is not False:
        raise RuntimeError('Run Command is not guest authentication evidence')
    return payload


def main(section, commit):
    if section not in SECTIONS:
        raise RuntimeError('Only fixed preflight sections are allowed')
    target = OUT / f'bootstrap-preflight-{section.lower()}.json'
    if target.exists():
        raise RuntimeError('Preflight already recorded; inspect receipt before considering another operation')
    approval = json.loads((OUT / 'bootstrap-preflight-approval.json').read_text())
    if approval.get('runCommandReadOnlyApproved') is not True:
        raise RuntimeError('Specific Run Command inspection approval missing')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip()
    remote = subprocess.check_output(['git', 'ls-remote', '--heads', 'origin', 'refs/heads/' + branch], cwd=ROOT, text=True).split()
    if commit != head or not remote or remote[0] != commit:
        raise RuntimeError('Exact preflight source must be committed and pushed')
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=ROOT, text=True).strip():
        raise RuntimeError('Tracked files changed after commit')
    identity = read_az(['account', 'show', '--subscription', SUB, '--query', '{id:id,tenantId:tenantId}'])
    principal = read_az(['ad', 'signed-in-user', 'show', '--query', '{id:id}'])
    if identity != {'id': SUB, 'tenantId': TENANT} or principal != {'id': PRINCIPAL}:
        raise RuntimeError('Approved Azure identity changed')
    vm = read_az(['vm', 'get-instance-view', '--subscription', SUB, '-g', RG, '-n', VM,
                  '--query', '{state:provisioningState,statuses:instanceView.statuses[].code,agent:instanceView.vmAgent.statuses[].displayStatus}'])
    if vm['state'] != 'Succeeded' or 'PowerState/running' not in vm['statuses'] or 'Ready' not in vm['agent']:
        raise RuntimeError('Target VM is not running/agent ready')
    source = SCRIPT.read_text()
    record = {'beganAtSast': now(), 'status': 'pending', 'section': section, 'commit': commit,
              'scriptSha256': hashlib.sha256(source.encode()).hexdigest(),
              'administrationPath': 'Azure-VM-Run-Command-SYSTEM-owner-approved-read-only',
              'guestLoginVerified': False, 'bootstrapApplied': False}
    with target.open('x') as stream:
        stream.write(json.dumps(record, indent=2) + '\n')
    command = ['az', 'vm', 'run-command', 'invoke', '--subscription', SUB, '-g', RG, '-n', VM,
               '--command-id', 'RunPowerShellScript', '--scripts', source,
               '--parameters', f'Section={section}', '--query', 'value[].{code:code,message:message}',
               '-o', 'json', '--only-show-errors']
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=300)
        record['exitCode'] = result.returncode
        if result.returncode:
            record['status'] = 'failed-raw-output-suppressed-inspect-before-retry'
        else:
            record['result'] = parse_output(result.stdout, section)
            record['status'] = 'complete'
    except subprocess.TimeoutExpired:
        record['status'] = 'uncertain-timeout-do-not-repeat'
    except (RuntimeError, ValueError, KeyError) as error:
        record['status'] = 'failed-unparsed-output-suppressed'
        record['errorType'] = type(error).__name__
    record['finishedAtSast'] = now()
    target.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))
    return 0 if record['status'] == 'complete' else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('section', choices=SECTIONS)
    parser.add_argument('--commit', required=True)
    args = parser.parse_args()
    raise SystemExit(main(args.section, args.commit))
