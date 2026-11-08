"""Human-only NODE3 Arc device authentication over private Bastion/pinned-key SSH.

No stdout/stderr capture, token forwarding, browser automation or stored passwords.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import signal
import socket
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
OLD = runpy.run_path(str(ROOT / 'scripts/register-smal-node-console.py'), run_name='node03_existing_console_transport')
H, SSH, SUB, TENANT, PRINCIPAL = (OLD[key] for key in ['H', 'SSH', 'SUB', 'TENANT', 'PRINCIPAL'])
az_read = OLD['az_read']


def main(inspect_only=False):
    OLD['require_tty']()
    out = ROOT / 'docs/deployment-2026-10-29'
    consent = json.loads((out / 'three-node-approval.json').read_text())
    for suffix, key in [('json', 'proposalJsonSha256'), ('md', 'proposalMarkdownSha256')]:
        if hashlib.sha256((out / ('three-node-proposal.' + suffix)).read_bytes()).hexdigest() != consent.get(key): raise RuntimeError('Exact three-node proposal/approval differs')
    if consent.get('approved') is not True or consent.get('node03HumanDeviceCodeAuthenticationAndScopedRolesApproved') is not True: raise RuntimeError('Explicit NODE3 human-auth approval missing')
    account = az_read(['account', 'show', '--subscription', SUB, '--query', '{id:id,tenantId:tenantId,state:state}'])
    if account != {'id': SUB, 'tenantId': TENANT, 'state': 'Enabled'} or az_read(['ad', 'signed-in-user', 'show', '--query', 'id']) != PRINCIPAL: raise RuntimeError('Existing approved identity/context differs')
    if not inspect_only:
        names = az_read(['resource', 'list', '--subscription', SUB, '-g', 'rg-localbox-platform-weu-1', '--resource-type', 'Microsoft.HybridCompute/machines', '--query', '[].name'])
        if 'lb-node03' in {name.lower() for name in names}: raise RuntimeError('NODE3 Arc resource exists. Use --inspect and reconcile instead of registering again.')
        roles = az_read(['role', 'assignment', 'list', '--subscription', SUB, '--assignee', PRINCIPAL, '--scope', '/subscriptions/' + SUB + '/resourceGroups/rg-localbox-platform-weu-1', '--include-inherited', '--include-groups', '--query', '[].roleDefinitionName'])
        if 'Owner' not in roles: raise RuntimeError('Existing PIM role is not active. Reactivate it normally before fresh authentication. No grant/activation is performed here.')
    proof = json.loads((out / 'node03-local-completion.json').read_text())
    if proof.get('status') != 'complete-local-only-human-arc-authentication-next' or proof.get('commonCredentialLoginVerified') is not True: raise RuntimeError('Verified NODE3 local completion missing')
    vm_id = str(uuid.UUID(proof['vm']['vmId']))
    package = json.loads((H['OUT'] / 'private-ssh-install-node03-arc-console-20261029.json').read_text())
    result = package.get('result', {})
    if package.get('status') != 'complete' or result.get('status') != 'installed-not-invoked' or result.get('vmId') != vm_id or result.get('registrationPerformed') is not False: raise RuntimeError('Exact verified NODE3 console installation missing')
    script = result['scriptPath']; digest = result['scriptSha256']
    if script != r'C:\ProgramData\AzureLocalBox\Bootstrap\arc-node03-console-20261029-01\Register-Node03.ps1' or not re.fullmatch(r'[0-9A-F]{64}', digest): raise RuntimeError('Exact console path/hash differs')
    setup = json.loads((H['OUT'] / 'private-ssh-setup-resume1.json').read_text()); SSH['pin_host_key'](setup['result']['hostPublicKey'])
    for address in ['10.204.0.4', '10.200.16.4']:
        if json.loads(subprocess.check_output(['ip', '-j', 'route', 'get', address], text=True))[0].get('dev') != 'tun0': raise RuntimeError('Private VPN route missing')
    with socket.create_connection(('10.204.0.4', 53), timeout=5): pass
    with socket.socket() as reserve: reserve.bind(('127.0.0.1', 0)); port = reserve.getsockname()[1]
    command = "$ErrorActionPreference='Stop';if((Get-FileHash '" + script + "').Hash -cne '" + digest + "'){throw 'Installed console hash differs'};& '" + script + "'" + (' -InspectOnly' if inspect_only else '')
    encoded = base64.b64encode(command.encode('utf-16-le')).decode()
    tunnel = subprocess.Popen(['az', 'network', 'bastion', 'tunnel', '--subscription', '702382d0-3722-4630-8983-5580b92f0c1a', '-g', 'rg-bastion-san-1', '-n', 'bas-test-san-1', '--target-resource-id', H['VM_ID'], '--resource-port', '22', '--port', str(port), '--timeout', '7200', '--only-show-errors'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        deadline = time.monotonic() + 70
        while time.monotonic() < deadline and tunnel.poll() is None:
            listeners = subprocess.check_output(['ss', '-H', '-ltn', 'sport', '=', ':' + str(port)], text=True).strip().splitlines()
            if listeners:
                if any('127.0.0.1:' + str(port) not in row for row in listeners): raise RuntimeError('Bastion listener not loopback-only')
                break
            time.sleep(1)
        else: raise RuntimeError('Private tunnel not ready')
        args = [arg for arg in H['ssh_args'](port, setup['result']['adminUser'], encoded) if arg not in ['-n', '-T', '-v']]
        args.insert(1, '-tt'); args[-1] = 'powershell.exe -NoLogo -NoProfile -EncodedCommand ' + encoded
        print('Complete official Microsoft device authentication in this human terminal. Keep PIM active. Do not paste codes or credentials into chat/files.', flush=True)
        return subprocess.run(args, timeout=7200).returncode
    finally:
        try: os.killpg(tunnel.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        try: tunnel.wait(timeout=10)
        except subprocess.TimeoutExpired: os.killpg(tunnel.pid, signal.SIGKILL); tunnel.wait(timeout=5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--inspect', action='store_true')
    raise SystemExit(main(parser.parse_args().inspect))
