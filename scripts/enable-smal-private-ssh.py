"""Owner-approved, one-attempt private SSH setup with a local-only private key."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / 'scripts/smal-bootstrap-preflight.py'), run_name='ssh_setup_helpers')
OUT = H['OUT']
STATE = Path.home() / '.local/state/azurelocalbox/ssh'
KEY = STATE / 'localbox-client_ed25519'
KNOWN = STATE / 'known_hosts'
ALIAS = 'smal-localbox-client-20261027'
SCRIPT = ROOT / 'scripts/enable-smal-private-ssh.ps1'


def local_key():
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    if STATE.is_symlink() or STATE.stat().st_uid != os.getuid() or stat.S_IMODE(STATE.stat().st_mode) != 0o700:
        raise RuntimeError('SSH state directory is not owner-only')
    if not KEY.exists():
        if KEY.with_suffix('.pub').exists():
            raise RuntimeError('Orphaned public key exists. Do not replace.')
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', ALIAS, '-f', str(KEY)],
                       check=True, capture_output=True, text=True)
    if KEY.is_symlink() or KEY.stat().st_uid != os.getuid() or stat.S_IMODE(KEY.stat().st_mode) != 0o600:
        raise RuntimeError('Private key permissions differ from owner-only 0600')
    public = KEY.with_suffix('.pub').read_text().strip()
    if not re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/]+={0,3}( [a-zA-Z0-9@._-]+)?', public):
        raise RuntimeError('Invalid public key')
    return public


def pin_host_key(public):
    if not re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/]+={0,3}( [^\r\n]+)?', public):
        raise RuntimeError('Invalid host PUBLIC key')
    content = ALIAS + ' ' + ' '.join(public.split()[:2]) + '\n'
    if KNOWN.exists():
        if KNOWN.is_symlink() or KNOWN.read_text() != content:
            raise RuntimeError('Host key differs from existing trust. Do not overwrite.')
    else:
        fd = os.open(KNOWN, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)


def main(commit, inspect=False, retry_reconciled=False, inspect_retry=False, resume_verified=False, inspect_access=False, repair_service_filter=False):
    if inspect_retry or inspect_access:
        inspect = True
    if inspect and retry_reconciled:
        raise RuntimeError('Inspection and reconciled apply are separate operations')
    target = OUT / (('private-ssh-inspection2.json' if inspect_retry else 'private-ssh-inspection1.json') if inspect else ('private-ssh-setup-retry1.json' if retry_reconciled else 'private-ssh-setup.json'))
    if resume_verified:
        if inspect or retry_reconciled:
            raise RuntimeError('Resume is a separate operation')
        target = OUT / 'private-ssh-setup-resume1.json'
    if inspect_access:
        target = OUT / 'private-ssh-inspection3.json'
    if repair_service_filter:
        if inspect or retry_reconciled or resume_verified:
            raise RuntimeError('Firewall repair is a separate operation')
        target = OUT / 'private-ssh-firewall-repair.json'
    if target.exists():
        raise RuntimeError('SSH setup already recorded. Reconcile rather than repeat.')
    approval = json.loads((OUT / 'private-ssh-approval.json').read_text())
    if approval.get('oneOffRunCommandSshSetupApproved') is not True:
        raise RuntimeError('Specific setup approval missing')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    branch = subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip()
    remote = subprocess.check_output(['git', 'ls-remote', '--heads', 'origin', 'refs/heads/' + branch], text=True).split()
    if head != commit or not remote or remote[0] != commit:
        raise RuntimeError('Exact setup source must be committed and pushed')
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
        raise RuntimeError('Tracked files changed after commit')
    identity = H['read_az'](['account', 'show', '--subscription', H['SUB'], '--query', '{id:id,tenantId:tenantId}'])
    principal = H['read_az'](['ad', 'signed-in-user', 'show', '--query', '{id:id}'])
    if identity != {'id': H['SUB'], 'tenantId': H['TENANT']} or principal != {'id': H['PRINCIPAL']}:
        raise RuntimeError('Approved identity changed')
    admin = H['read_az'](['vm', 'show', '--subscription', H['SUB'], '-g', H['RG'], '-n', H['VM'], '--query', 'osProfile.adminUsername'])
    if not isinstance(admin, str) or not re.fullmatch(r'[a-zA-Z][a-zA-Z0-9_-]{0,31}', admin):
        raise RuntimeError('Unexpected existing admin account')
    if inspect:
        if inspect_access:
            prior = json.loads((OUT / 'private-ssh-setup-resume1.json').read_text())
            if prior.get('status') != 'complete-host-key-pinned-login-not-yet-tested':
                raise RuntimeError('Completed setup evidence required for listener inspection')
        else:
            prior = json.loads((OUT / ('private-ssh-setup-retry1.json' if inspect_retry else 'private-ssh-setup.json')).read_text())
            if prior.get('guestErrorLabel') != ('Guest firewall scope differs' if inspect_retry else 'Active non-default SSH configuration found'):
                raise RuntimeError('Inspection is only for the known rejected initial setup')
    if retry_reconciled:
        prior = json.loads((OUT / 'private-ssh-setup.json').read_text())
        inspection = json.loads((OUT / 'private-ssh-inspection1.json').read_text())
        evidence = inspection.get('result', {})
        if (prior.get('guestErrorLabel') != 'Active non-default SSH configuration found'
                or inspection.get('status') != 'complete-read-only-inspection'
                or evidence.get('configSha256') != 'FB46B8F386771448755C9D220B49FC3AE6EF1447CCCBB568B0BFE766DA1E54FE'
                or any(evidence.get(k) is not False for k in ['setupMarkerExists', 'backupExists', 'adminKeysExist'])):
            raise RuntimeError('Original no-change failure is not reconciled for a retry')
    if resume_verified:
        inspection = json.loads((OUT / 'private-ssh-inspection2.json').read_text())
        evidence = inspection.get('result', {})
        if (inspection.get('status') != 'complete-read-only-inspection'
                or evidence.get('configSha256') != '52ADEA08D10405087D4DC9091710C399328AE598C594B4CB70245B03D8FA44B4'
                or evidence.get('service') != 'Stopped' or evidence.get('markerStatus') != 'pending'
                or evidence.get('firewall', {}).get('remoteAddress') != ['10.202.0.0/255.255.255.192']):
            raise RuntimeError('Pending setup is not exactly reconciled for service-only resume')
    if repair_service_filter:
        evidence = json.loads((OUT / 'private-ssh-inspection3.json').read_text()).get('result', {})
        if evidence.get('service') != 'Running' or evidence.get('firewallService') != ['sshd'] or evidence.get('markerStatus') != 'complete':
            raise RuntimeError('Owned rule has not been reconciled for a service-filter repair')
    public = '' if inspect or repair_service_filter else local_key()
    source = (ROOT / 'scripts/inspect-smal-ssh-config.ps1').read_text() if inspect else SCRIPT.read_text()
    if repair_service_filter:
        source = (ROOT / 'scripts/repair-smal-ssh-firewall.ps1').read_text()
    record = {'beganAtSast': H['now'](), 'status': 'pending', 'commit': commit,
              'scriptSha256': hashlib.sha256(source.encode()).hexdigest(),
              'publicKeySha256': hashlib.sha256(public.encode()).hexdigest(),
              'privateKeyValueExported': False, 'bootstrapApplied': False}
    with target.open('x') as stream:
        stream.write(json.dumps(record, indent=2) + '\n')
    command = ['az', 'vm', 'run-command', 'invoke', '--subscription', H['SUB'], '-g', H['RG'], '-n', H['VM'],
               '--command-id', 'RunPowerShellScript', '--scripts', source,
               '--query', 'value[].{code:code,message:message}', '-o', 'json', '--only-show-errors']
    if not inspect and not repair_service_filter:
        command.extend(['--parameters', 'AdminUser=' + admin, 'PublicKey=' + public])
        if resume_verified:
            command.append('Operation=ResumeVerified')
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=300)
        record['exitCode'] = result.returncode
        if result.returncode:
            record['status'] = 'failed-raw-output-suppressed-inspect-before-retry'
        else:
            rows = json.loads(result.stdout)
            if any(row.get('message', '').strip() for row in rows if '/StdErr/' in row.get('code', '')):
                # Script contains no secrets. Retain only bounded known exception
                # labels, never arbitrary raw command output.
                stderr = '\n'.join(row.get('message', '') for row in rows if '/StdErr/' in row.get('code', ''))
                labels = ['Active non-default SSH configuration found', 'Unexpected existing SSH setup',
                          'Unowned explicit TCP22 allow rule exists', 'sshd rejected configuration',
                          'Effective SSH safety check failed', 'Guest firewall scope differs']
                record['guestErrorLabel'] = next((label for label in labels if label in stderr), 'inspect-guest-agent-operation-evidence')
                raise RuntimeError('Guest reported stderr')
            payload = json.loads('\n'.join(row['message'] for row in rows if '/StdOut/' in row.get('code', '')))
            allowed = {'computer', 'service', 'adminUser', 'passwordAuthentication', 'publicKeyAuthentication',
                       'forwarding', 'remoteAddress', 'remoteAddressObserved', 'defaultShell', 'hostPublicKey', 'configSha256', 'rebootPerformed', 'bootstrapApplied'}
            if inspect:
                allowed = {'computer', 'atUtc', 'configSha256', 'activeConfiguration', 'setupMarkerExists', 'backupExists', 'adminKeysExist', 'service', 'readOnly', 'firewall', 'markerStatus', 'defaultSshAllowRuleEnabled'}
                allowed |= {'servicePath', 'listeners', 'firewallProgram', 'firewallService', 'firewallProfiles', 'profileDefaults', 'recentSshEvents'}
            if repair_service_filter:
                allowed = {'computer', 'atUtc', 'serviceSidNone', 'serviceFilterBefore', 'serviceFilterAfter', 'remoteAddress', 'localPort', 'program', 'defaultSshAllowRuleEnabled', 'configSha256'}
            if set(payload) - allowed or payload.get('computer', '').lower() != H['VM'].lower():
                raise RuntimeError('Unexpected SSH setup evidence')
            if repair_service_filter:
                if payload.get('serviceSidNone') is not True or payload.get('serviceFilterAfter') != 'Any' or payload.get('defaultSshAllowRuleEnabled') != 'False':
                    raise RuntimeError('Service-filter repair not verified')
            elif inspect:
                if payload.get('readOnly') is not True:
                    raise RuntimeError('Unexpected inspection evidence')
            else:
                if payload.get('passwordAuthentication') is not False or payload.get('publicKeyAuthentication') is not True or payload.get('service') != 'Running' or payload.get('remoteAddress') != '10.202.0.0/26':
                    raise RuntimeError('SSH setup not verified')
                pin_host_key(payload['hostPublicKey'])
            record['result'] = payload
            record['status'] = 'complete-service-filter-repaired-login-not-yet-tested' if repair_service_filter else ('complete-read-only-inspection' if inspect else 'complete-host-key-pinned-login-not-yet-tested')
    except subprocess.TimeoutExpired:
        record['status'] = 'uncertain-timeout-do-not-repeat'
    except (RuntimeError, ValueError, KeyError) as error:
        record['status'] = 'failed-inspect-before-retry'
        record['errorType'] = type(error).__name__
    record['finishedAtSast'] = H['now']()
    target.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))
    return 0 if record['status'].startswith('complete-') else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--inspect', action='store_true')
    parser.add_argument('--retry-reconciled', action='store_true')
    parser.add_argument('--inspect-retry', action='store_true')
    parser.add_argument('--resume-verified', action='store_true')
    parser.add_argument('--inspect-access', action='store_true')
    parser.add_argument('--repair-service-filter', action='store_true')
    args = parser.parse_args()
    raise SystemExit(main(args.commit, args.inspect, args.retry_reconciled, args.inspect_retry, args.resume_verified, args.inspect_access, args.repair_service_filter))
