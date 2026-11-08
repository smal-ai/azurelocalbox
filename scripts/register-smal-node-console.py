"""Human TTY launcher: private Bastion/key-only SSH, official device-code console.

No stdout/stderr capture, transcript, token export or credential value arguments.
Run from the owner's terminal, not a headless tool or scheduled agent.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import runpy
import re
import signal
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='human_arc_transport')
SSH = H['H']
SUB = '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea'
TENANT = 'c6e67968-af25-4557-ab8b-06b693048d3b'
PRINCIPAL = '82f494a8-b9f5-46fc-b0f7-c70be0572a63'


def az_read(args):
    result = subprocess.run(['az', *args, '--output', 'json', '--only-show-errors'], check=True, capture_output=True, text=True, timeout=90)
    return json.loads(result.stdout)


def require_tty():
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise RuntimeError('Human terminal required. This launcher must not capture authentication output.')


def validate_recovery(node, inspect_only, proof, roles):
    if node != 'LB-NODE02' or inspect_only or proof.get('status') != 'complete':
        raise RuntimeError('Recovery is only for the diagnosed NODE2 authorization failure')
    nodes = [row for row in proof.get('result', {}).get('nodes', []) if row.get('name') == node]
    if len(nodes) != 1 or nodes[0].get('bootstrap', {}).get('status') != 'Failed':
        raise RuntimeError('Failed NODE2 diagnosis missing')
    facts = nodes[0].get('agentLog', {}).get('facts', [])
    if not any(row.get('authorizationDenied') is True and 'AuthorizationFailed' in row.get('armCodes', []) and 'Microsoft.HybridCompute/machines/write' in row.get('actions', []) for row in facts):
        raise RuntimeError('Exact machine-write authorization failure missing')
    # Reuse the same approved existing Owner role, never grant or activate it here.
    if not any(row.get('roleDefinitionName') == 'Owner' and row.get('scope', '').lower() in [('/subscriptions/' + SUB).lower(), ('/subscriptions/' + SUB + '/resourceGroups/rg-localbox-platform-weu-1').lower()] for row in roles):
        raise RuntimeError('Previously used Owner role is not active. Reactivate existing PIM access before fresh device authentication.')


def main(node, inspect_only=False, retry_authorization=False):
    require_tty()
    if node not in ['LB-NODE01', 'LB-NODE02']: raise RuntimeError('Only the two approved node names are permitted')
    approval = json.loads((ROOT / 'docs/deployment-2026-10-28/cloud-apply-approval.json').read_text())
    for suffix, key in [('json', 'proposalJsonSha256'), ('md', 'proposalMarkdownSha256')]:
        if hashlib.sha256((ROOT / ('docs/deployment-2026-10-28/cloud-apply-proposal.' + suffix)).read_bytes()).hexdigest() != approval.get(key): raise RuntimeError('Exact proposal consent differs')
    if approval.get('humanDeviceCodeAuthenticationApproved') is not True: raise RuntimeError('Explicit device-code approval missing')
    account = az_read(['account', 'show', '--subscription', SUB, '--query', '{id:id,tenantId:tenantId,state:state}'])
    if account != {'id': SUB, 'tenantId': TENANT, 'state': 'Enabled'} or az_read(['ad', 'signed-in-user', 'show', '--query', 'id']) != PRINCIPAL: raise RuntimeError('Existing approved identity changed. No activation/fallback.')
    if retry_authorization:
        proof = json.loads((H['OUT'] / 'private-ssh-arc-registration-diagnosis-20261029.json').read_text())
        roles = az_read(['role', 'assignment', 'list', '--subscription', SUB, '--assignee', PRINCIPAL, '--scope', '/subscriptions/' + SUB + '/resourceGroups/rg-localbox-platform-weu-1', '--include-inherited', '--include-groups'])
        validate_recovery(node, inspect_only, proof, roles)
    if not inspect_only:
        names = az_read(['resource', 'list', '--subscription', SUB, '--resource-group', 'rg-localbox-platform-weu-1', '--resource-type', 'Microsoft.HybridCompute/machines', '--query', '[].name'])
        if node.lower() in {name.lower() for name in names}: raise RuntimeError('Arc machine already exists. Use --inspect and reconcile instead of registering again.')
    receipt_name = 'private-ssh-install-arc-recovery-console-20261029.json' if retry_authorization else 'private-ssh-install-arc-console-20261028.json'
    receipt = json.loads((H['OUT'] / receipt_name).read_text())
    if receipt.get('status') != 'complete' or receipt.get('result', {}).get('status') != 'installed-not-invoked': raise RuntimeError('Verified console installation receipt missing')
    setup = json.loads((H['OUT'] / 'private-ssh-setup-resume1.json').read_text())
    SSH['pin_host_key'](setup['result']['hostPublicKey'])
    route = subprocess.check_output(['ip', '-j', 'route', 'get', '10.204.0.4'], text=True)
    if json.loads(route)[0].get('dev') != 'tun0': raise RuntimeError('Actual private VPN route absent')
    with socket.create_connection(('10.204.0.4', 53), timeout=5): pass
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0)); port = reserve.getsockname()[1]
    script = receipt['result']['scriptPath']; digest = receipt['result']['scriptSha256']
    package = 'arc-authz-recovery-20261029-01' if retry_authorization else 'arc-console-20261028-01'
    expected_path = 'C:\\ProgramData\\AzureLocalBox\\Bootstrap\\' + package + '\\Register-LocalBoxNode.ps1'
    if script != expected_path or not re.fullmatch(r'[0-9A-F]{64}', digest): raise RuntimeError('Exact installed console path/hash differs')
    command = "$ErrorActionPreference='Stop';if((Get-FileHash '" + script + "').Hash -cne '" + digest + "'){throw 'Installed console hash differs'};& '" + script + "' -NodeName '" + node + "'" + (' -InspectOnly' if inspect_only else '')
    if retry_authorization:
        command += ' -RetryAfterAuthorizationFailure'
    encoded = base64.b64encode(command.encode('utf-16-le')).decode('ascii')
    tunnel = subprocess.Popen(['az', 'network', 'bastion', 'tunnel', '--subscription', '702382d0-3722-4630-8983-5580b92f0c1a', '-g', 'rg-bastion-san-1', '-n', 'bas-test-san-1', '--target-resource-id', H['VM_ID'], '--resource-port', '22', '--port', str(port), '--timeout', '7200', '--only-show-errors'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        deadline = time.monotonic() + 70
        while time.monotonic() < deadline and tunnel.poll() is None:
            rows = subprocess.check_output(['ss', '-H', '-ltn', 'sport', '=', ':' + str(port)], text=True).strip().splitlines()
            if rows:
                if any('127.0.0.1:' + str(port) not in row for row in rows): raise RuntimeError('Bastion listener not loopback-only')
                break
            time.sleep(1)
        else: raise RuntimeError('Private Bastion tunnel not ready')
        args = H['ssh_args'](port, setup['result']['adminUser'], encoded)
        args = [arg for arg in args if arg not in ['-n', '-T', '-v']]
        args.insert(1, '-tt')
        args[-1] = 'powershell.exe -NoLogo -NoProfile -EncodedCommand ' + encoded
        print('Official Microsoft authentication will appear in this terminal. Use the approved account/tenant. Do not copy codes or credentials into chat or files.', flush=True)
        # Intentionally inherit the HUMAN terminal. Never capture authentication streams.
        return subprocess.run(args, timeout=7200).returncode
    finally:
        try: os.killpg(tunnel.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        try: tunnel.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(tunnel.pid, signal.SIGKILL); tunnel.wait(timeout=5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node', choices=['LB-NODE01', 'LB-NODE02'], required=True)
    parser.add_argument('--inspect', action='store_true')
    parser.add_argument('--retry-after-authorization-failure', action='store_true', help='One guarded NODE2-only retry after the diagnosed machine-write denial. Fresh human authentication required.')
    args = parser.parse_args()
    raise SystemExit(main(args.node, args.inspect, args.retry_after_authorization_failure))
