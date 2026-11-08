"""Install reviewed NODE3 human-auth console only. Never invokes registration."""
from datetime import datetime, timezone
import json
from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
A = runpy.run_path(str(ROOT / 'scripts/smal-three-node-approval.py'), run_name='node03_console_install_guard')


def main():
    head = A['source_guard'](['scripts/install-smal-node03-console.py', 'scripts/register-smal-node03-console.py',
                              'scripts/register-smal-node03-console.ps1', 'scripts/install-smal-node03-arc-console.ps1', 'scripts/smal-private-powershell.py',
                              'scripts/smal-three-node-prelude.ps1', 'docs/deployment-2026-10-29/node03-local-completion.json'])
    path = A['OUT'] / 'node03-arc-console-install-receipt.json'
    record = {'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'sourceCommit': head, 'status': 'pending', 'registrationInvoked': False}
    with path.open('x') as stream: stream.write(json.dumps(record, indent=2) + '\n')
    try:
        local = json.loads((A['OUT'] / 'node03-local-completion.json').read_text())
        if local.get('status') != 'complete-local-only-human-arc-authentication-next' or local.get('commonCredentialLoginVerified') is not True: raise RuntimeError('Local NODE3 completion missing')
        disk = A['az'](['disk', 'show', '--ids', A['DISK_ID']])
        if disk['managedBy'].lower() != A['VM_ID'].lower(): raise RuntimeError('Exact approved disk attachment differs')
        transport = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='node03_console_install_transport')
        code = transport['main']('scripts/install-smal-node03-arc-console.ps1', 'install-node03-arc-console-20261029', three_node_context=A['context'](disk))
        installed = json.loads((transport['OUT'] / 'private-ssh-install-node03-arc-console-20261029.json').read_text())
        if code != 0 or installed.get('status') != 'complete' or installed['result']['status'] != 'installed-not-invoked' or installed['result']['registrationPerformed'] is not False:
            raise RuntimeError('Console installation incomplete; inspect, do not reinstall or register blindly')
        record['result'] = installed['result']; record['status'] = 'complete-installed-human-authentication-not-invoked'
    except (RuntimeError, ValueError, KeyError) as error:
        record['status'] = 'failed-inspect-before-resume'; record['errorType'] = type(error).__name__
        if isinstance(error, RuntimeError): record['error'] = str(error)
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat()
    path.write_text(json.dumps(record, indent=2) + '\n'); print(json.dumps(record, indent=2))
    return 0 if record['status'].startswith('complete-') else 2


if __name__ == '__main__':
    raise SystemExit(main())
