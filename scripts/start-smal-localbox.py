"""Start the existing SMAL host and its exact four nested guests. Safe to rerun.

Requires existing Azure CLI sign-in/PIM access and the configured private VPN
profile. Connects/reconnects that profile when needed, without editing it. Does
not activate roles, change shutdown automation, or invoke registration/bootstrap.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import json
from pathlib import Path
import runpy
import socket
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
SUB = '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea'
TENANT = 'c6e67968-af25-4557-ab8b-06b693048d3b'
RG = 'rg-localbox-nodes-san-1'
HOST = 'LocalBox-Client'
VM_ID = f'/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Compute/virtualMachines/{HOST}'
GUESTS = {'LB-DC01': 'f94c71f1-6854-48b9-a9f1-8238c99366d0',
          'LB-NODE01': '3adff629-2f67-449b-ab32-8a8748c46f34',
          'LB-NODE02': '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3',
          'LB-NODE03': '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9'}
OUT = ROOT / 'docs/deployment-2026-10-29'
VPN = 'entlz-san-cert'


def az(args, timeout=90):
    result = subprocess.run(['az', *args, '--only-show-errors', '--output', 'json'],
                            capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        # Do not put CLI diagnostics, auth flows or cached credentials in receipts.
        raise RuntimeError('Azure CLI request failed. Check sign-in, PIM and scope in your terminal. No automatic activation or retry.')
    return json.loads(result.stdout) if result.stdout.strip() else None


def verify_account(account):
    # Authorisation belongs to Azure RBAC, not a historical operator's object ID.
    # Keep the approved target scope pinned and never switch identities or activate roles.
    if account.get('id') != SUB or account.get('tenantId') != TENANT or account.get('state') != 'Enabled':
        raise RuntimeError('Approved subscription/tenant differs.')


def verify_source():
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    for path in ['scripts/start-smal-localbox.py', 'scripts/start-smal-existing-guests.ps1', 'scripts/smal-private-powershell.py', 'docs/deployment-2026-10-29/node03-local-completion.json']:
        if (ROOT / path).read_bytes() != subprocess.check_output(['git', 'show', 'HEAD:' + path], cwd=ROOT):
            raise RuntimeError('Startup source differs from HEAD. Commit and push before use.')
    branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip()
    remote = subprocess.check_output(['git', 'ls-remote', '--heads', 'origin', 'refs/heads/' + branch], cwd=ROOT, text=True).split()
    if not remote or remote[0] != head:
        raise RuntimeError('Exact startup source must be pushed before use.')
    return head


def verify_private_route():
    for address in ['10.204.0.4', '10.200.16.4']:
        rows = json.loads(subprocess.check_output(['ip', '-j', 'route', 'get', address], text=True, timeout=10))
        if len(rows) != 1 or rows[0].get('dev') != 'tun0':
            raise RuntimeError('Private VPN route missing. Connect entlz-san-cert before starting LocalBox.')
    with socket.create_connection(('10.204.0.4', 53), timeout=10):
        pass


def nmcli(args):
    result = subprocess.run(['nmcli', '--wait', '90', *args], capture_output=True, text=True, timeout=100)
    if result.returncode:
        raise RuntimeError('Existing VPN operation failed. Check NetworkManager and the configured certificate in your terminal. No profile/authentication changes or automatic retry.')
    return result.stdout.strip()


def ensure_private_vpn(record, save):
    record['vpn'] = {'profile': VPN, 'connectRequested': False, 'disconnectRequested': False,
                     'profileOrCredentialsChanged': False, 'privatePathVerified': False}
    save()
    try:
        verify_private_route()
    except (RuntimeError, OSError, subprocess.SubprocessError):
        # An Active label is insufficient. Resolve only the existing named VPN,
        # then bind any connection operation to its exact returned UUID.
        profile = nmcli(['-g', 'connection.uuid,connection.type', 'connection', 'show', 'id', VPN]).splitlines()
        if len(profile) != 2 or profile[1] != 'vpn':
            raise RuntimeError('Expected existing VPN profile is missing, ambiguous or not a VPN. No profile will be created.')
        ident = str(uuid.UUID(profile[0]))
        active = nmcli(['-g', 'UUID', 'connection', 'show', '--active']).splitlines()
        record['vpn']['profileUuid'] = ident
        record['status'] = 'restoring-existing-private-vpn'
        if ident in active:
            record['vpn']['disconnectRequested'] = True; save()
            nmcli(['connection', 'down', 'uuid', ident])
        record['vpn']['connectRequested'] = True; save()
        nmcli(['connection', 'up', 'uuid', ident])
        # Exactly one recovery attempt, then fail closed before any Azure start.
        verify_private_route()
    record['vpn']['privatePathVerified'] = True
    save()


def host_state():
    data = az(['vm', 'get-instance-view', '--subscription', SUB, '-g', RG, '-n', HOST])
    if data.get('id', '').lower() != VM_ID.lower():
        raise RuntimeError('Exact outer host identity differs.')
    view = data.get('instanceView', {})
    powers = [row['code'] for row in view.get('statuses', []) if row.get('code', '').startswith('PowerState/')]
    if len(powers) > 1:
        raise RuntimeError('Outer host power state ambiguous.')
    # Azure can briefly omit PowerState after accepting a start request. Unknown
    # never authorises a start, but the bounded post-request observer can wait.
    return {'power': powers[0] if powers else 'PowerState/unknown', 'agentReady': any(row.get('code') == 'ProvisioningState/succeeded'
                                               for row in view.get('vmAgent', {}).get('statuses', []))}


def ensure_host(state, timeout, record, save):
    record['hostBefore'] = state
    record['hostStartRequested'] = False
    save()
    if state['power'] in ['PowerState/deallocated', 'PowerState/stopped']:
        record['status'] = 'host-start-request-pending'
        record['hostStartRequested'] = True
        save()
        # Exactly one request. A timeout is uncertain, not permission to replay.
        az(['vm', 'start', '--subscription', SUB, '-g', RG, '-n', HOST, '--no-wait'])
    elif state['power'] not in ['PowerState/running', 'PowerState/starting']:
        raise RuntimeError('Host is transitioning or in an unexpected state. Inspect before retrying.')
    record['status'] = 'waiting-for-host'
    save()
    deadline = time.monotonic() + timeout
    while True:
        state = host_state()
        record['hostLastObserved'] = state
        save()
        if state['power'] == 'PowerState/running' and state['agentReady']:
            return
        if time.monotonic() >= deadline:
            raise TimeoutError('Host did not become Running with agent Ready within the readiness limit.')
        time.sleep(10)


def verify_guest_result(receipt):
    if receipt.get('status') != 'complete':
        raise RuntimeError('Private guest operation incomplete. Inspect its receipt before another attempt.')
    data = receipt.get('result', {})
    rows = data.get('guests', [])
    if len(rows) != len(GUESTS) or {row['name']: row['id'].lower() for row in rows} != GUESTS:
        raise RuntimeError('Exact nested guest identities differ.')
    if any(row.get('after') != 'Running' or row.get('heartbeatReady') is not True for row in rows):
        raise RuntimeError('Not all guests are Running with a healthy Hyper-V heartbeat.')
    if data.get('registrationInvoked') is not False or data.get('registrationMarkersChanged') is not False:
        raise RuntimeError('Startup-only operation boundary differs.')


def main(host_timeout=900):
    # One local operator at a time. Lock contains no credentials.
    lock_path = Path('/tmp/opencode/smal-localbox-start.lock')
    with lock_path.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another LocalBox startup command is already running.') from None
        run = 'start-' + datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8]
        OUT.mkdir(exist_ok=True)
        path = OUT / (run + '.json')
        record = {'runId': run, 'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'status': 'preflight',
                  'hostId': VM_ID, 'shutdownAutomationChanged': False, 'roleActivationRequested': False,
                  'registrationInvoked': False, 'platformReadinessVerified': False}

        def save():
            path.write_text(json.dumps(record, indent=2) + '\n')

        with path.open('x') as stream:
            stream.write(json.dumps(record, indent=2) + '\n')
        try:
            record['sourceCommit'] = verify_source()
            ensure_private_vpn(record, save)
            verify_account(az(['account', 'show', '--subscription', SUB]))
            ensure_host(host_state(), host_timeout, record, save)
            record['status'] = 'starting-and-checking-nested-guests'
            record['privateGuestReceipt'] = 'docs/deployment-2026-10-27/private-ssh-' + run + '.json'
            save()
            helper = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='localbox_start_transport')
            # No automatic repeat after a failed/uncertain remote command.
            code = helper['main']('scripts/start-smal-existing-guests.ps1', run)
            guest_receipt = json.loads((ROOT / record['privateGuestReceipt']).read_text())
            if code != 0:
                raise RuntimeError('Nested startup incomplete. Inspect the private transport receipt. Do not blindly retry.')
            verify_guest_result(guest_receipt)
            record['guests'] = guest_receipt['result']['guests']
            record['status'] = 'complete-host-and-four-guests-running-heartbeats-healthy'
        except (subprocess.TimeoutExpired, TimeoutError):
            record['status'] = 'uncertain-or-readiness-timeout-inspect-before-retry'
        except (RuntimeError, ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
            record['status'] = 'failed-inspect-before-retry'
            record['errorType'] = type(error).__name__
            if isinstance(error, RuntimeError):
                record['error'] = str(error)
        except KeyboardInterrupt:
            record['status'] = 'interrupted-inspect-before-retry'
        record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat()
        save()
        print(json.dumps({'status': record['status'], 'receipt': str(path.relative_to(ROOT)),
                          'error': record.get('error'), 'platformReadinessVerified': False}, indent=2))
        return 0 if record['status'].startswith('complete-') else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host-timeout', type=int, default=900, help='Host readiness limit in seconds (60–3600).')
    args = parser.parse_args()
    if not 60 <= args.host_timeout <= 3600:
        parser.error('--host-timeout must be between 60 and 3600')
    sys.exit(main(args.host_timeout))
