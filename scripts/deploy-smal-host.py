"""Approved private outer-host phase. No bootstrap, network writes, RBAC or workloads.

New VM credential is generated/reused only inside this process and retained in an
owner-only state file outside the repository. Secure ARM parameters travel on stdin.
Never invoke with shell tracing or --debug. Uncertain apply effects require inspection.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import string
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-27'
SUB = '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea'
TENANT = 'c6e67968-af25-4557-ab8b-06b693048d3b'
PRINCIPAL = '82f494a8-b9f5-46fc-b0f7-c70be0572a63'
RG = 'rg-localbox-nodes-san-1'
VM_ID = f'/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Compute/virtualMachines/LocalBox-Client'
NAME = 'smal-host-20261027'
CREDENTIAL_FILE = Path.home() / '.local/state/azurelocalbox/credentials/smal-host-20261027.json'
TEMPLATE = Path('/tmp/opencode/localbox-20261027/smal-host-reviewed.json')


def now():
    return datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=2))).isoformat()


def write_record(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + '\n')


def sanitise(value, password):
    if isinstance(value, dict):
        return {k: '[redacted-secure-input]' if k.lower() in {'password', 'adminpassword', 'protectedsettings'}
                else sanitise(v, password) for k, v in value.items()}
    if isinstance(value, list):
        return [sanitise(v, password) for v in value]
    if isinstance(value, str):
        return value.replace(password, '[redacted-secure-input]') if password else value
    return value


def az_read(args):
    r = subprocess.run(['az', *args, '-o', 'json', '--only-show-errors'],
                       capture_output=True, text=True, timeout=120)
    if r.returncode:
        raise RuntimeError('Azure read failed; stop without changing permissions')
    return json.loads(r.stdout) if r.stdout.strip() else None


def verify_identity_and_empty_group():
    identity = az_read(['account', 'show', '--subscription', SUB,
                        '--query', '{id:id,tenantId:tenantId,state:state}'])
    principal = az_read(['ad', 'signed-in-user', 'show', '--query', '{id:id}'])
    if identity['id'] != SUB or identity['tenantId'] != TENANT or principal['id'] != PRINCIPAL:
        raise RuntimeError('Current identity differs from approved scope')
    feature = az_read(['feature', 'show', '--subscription', SUB, '--namespace', 'Microsoft.Compute',
                       '--name', 'UseStandardSecurityType', '--query', '{state:properties.state}'])
    if feature['state'] != 'Registered':
        raise RuntimeError('UseStandardSecurityType is not Registered; subscription feature change needs approval')
    resources = az_read(['resource', 'list', '--subscription', SUB, '-g', RG,
                         '--query', '[].{id:id,type:type}'])
    if resources:
        raise RuntimeError('Host resource group changed; inspect, do not overwrite')
    approval = json.loads((OUT / 'owner-approvals.json').read_text())
    if not (approval['hostCostProposalApproved'] and approval.get('hostOnlyDeploymentApproved')
            and approval['approvedExistingDeploymentPrincipalId'] == PRINCIPAL):
        raise RuntimeError('Explicit host-phase owner approval missing')


def credential():
    directory = CREDENTIAL_FILE.parent
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(directory.parent, 0o700)
    os.chmod(directory, 0o700)
    if CREDENTIAL_FILE.exists() or CREDENTIAL_FILE.is_symlink():
        metadata = CREDENTIAL_FILE.lstat()
        if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_uid != os.getuid():
            raise RuntimeError('Credential state permissions/owner invalid')
        stored = json.loads(CREDENTIAL_FILE.read_text())
        if stored['resourceId'] != VM_ID or stored['adminUsername'] != 'arcdemo':
            raise RuntimeError('Credential state belongs to another resource')
        return stored['adminUsername'], stored['password']
    # This is a new VM-local account credential, not an Entra token or reused lab secret.
    alphabet = string.ascii_letters + string.digits + '!%+-_'
    password = 'Aa9!' + ''.join(secrets.choice(alphabet) for _ in range(36))
    fd = os.open(CREDENTIAL_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump({'resourceId': VM_ID, 'adminUsername': 'arcdemo', 'password': password,
                   'createdAtSast': now(), 'purpose': 'owner-local-new-VM-admin-credential'}, stream)
        stream.flush()
        os.fsync(stream.fileno())
    return 'arcdemo', password


def compile_template():
    source = ROOT / 'infra/bicep/main.smal-host.bicep'
    r = subprocess.run(['az', 'bicep', 'build', '--file', str(source), '--stdout'],
                       capture_output=True, text=True, check=True, timeout=120)
    compiled = json.loads(r.stdout)
    types = sorted(resource['type'] for resource in compiled['resources'])
    if types != ['Microsoft.Compute/virtualMachines', 'Microsoft.Network/networkInterfaces']:
        raise RuntimeError('Template resource scope widened')
    if compiled['outputs']['bootstrapDeployed']['value'] is not False:
        raise RuntimeError('Bootstrap must remain disabled')
    if any(name in compiled['parameters'] for name in ['costCentre', 'reviewOn']):
        raise RuntimeError('Unrequested lab metadata is still required')
    TEMPLATE.parent.mkdir(exist_ok=True, parents=True)
    TEMPLATE.write_text(json.dumps(compiled))
    return hashlib.sha256(source.read_bytes()).hexdigest()


def secure_arm(verb, username, password, deployment_name=NAME, reuse_existing_nic=False):
    parameters = {'$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#',
                  'contentVersion': '1.0.0.0', 'parameters': {
                      'adminUsername': {'value': username}, 'adminPassword': {'value': password},
                      'imageVersion': {'value': '26100.33674.261024'}, 'hostPlanApproved': {'value': True}}}
    if reuse_existing_nic:
        parameters['parameters']['reuseExistingNic'] = {'value': True}
    command = ['az', 'deployment', 'group', verb, '--subscription', SUB, '-g', RG,
               '--name', deployment_name, '--template-file', str(TEMPLATE), '--parameters', '@/dev/stdin',
               '-o', 'json', '--only-show-errors']
    if verb == 'what-if':
        command.extend(['--no-pretty-print', '--result-format', 'FullResourcePayloads'])
    record = {'beganAtSast': now(), 'command': command, 'secureParameters': 'stdin-only-not-in-arguments-or-report'}
    try:
        r = subprocess.run(command, input=json.dumps(parameters), capture_output=True, text=True, timeout=900)
    except subprocess.TimeoutExpired:
        record.update({'finishedAtSast': now(), 'status': 'uncertain-stop-inspect-original-deployment-before-retry'})
        return record
    record.update({'finishedAtSast': now(), 'exitCode': r.returncode})
    # Never print, persist or return the raw subprocess stdout/stderr.
    clean_stdout = r.stdout.replace(password, '[redacted-secure-input]')
    clean_stderr = r.stderr.replace(password, '[redacted-secure-input]')
    if r.returncode:
        record.update({'status': 'failed', 'error': clean_stderr[:12000]})
    else:
        record.update({'status': 'succeeded',
                       'result': sanitise(json.loads(clean_stdout), password) if clean_stdout.strip() else None})
    return record


def allowed_preview(record):
    if record.get('status') != 'succeeded':
        return False
    result = record['result'] or {}
    if result.get('status') != 'Succeeded' or result.get('error'):
        return False
    vm_base = f'/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Compute/'
    allowed = {VM_ID.lower(),
               f'/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Network/networkInterfaces/LocalBox-Client-NIC'.lower(),
               (vm_base + 'disks/LocalBox-Client-OSDisk').lower(),
               *[(vm_base + f'disks/LocalBox-Client-DataDisk_{n}').lower() for n in range(8)]}
    actual = [c for c in result.get('changes', []) if c['changeType'] not in ['NoChange', 'Ignore']]
    return bool(actual) and all(c['changeType'] == 'Create' and c['resourceId'].lower() in allowed for c in actual)


def prepare():
    verify_identity_and_empty_group()
    source_hash = compile_template()
    username, password = credential()
    validation = secure_arm('validate', username, password)
    write_record('host-validation.json', validation)
    if validation['status'] != 'succeeded' or (validation.get('result') or {}).get('error'):
        print(json.dumps({'phase': 'validate', 'status': 'failed-see-redacted-record', 'azureResourceApplyAttempted': False}))
        return 2
    preview = secure_arm('what-if', username, password)
    write_record('host-what-if.json', preview)
    accepted = allowed_preview(preview)
    evidence = {'atSast': now(), 'templateSourceSha256': source_hash, 'scope': 'host-only',
                'validation': validation['status'], 'previewAllowedHostCreatesOnly': accepted,
                'credentialLocation': str(CREDENTIAL_FILE), 'credentialMode': '0600-owner-only-outside-repository',
                'credentialValueExported': False, 'azureResourceApplyAttempted': False}
    write_record('host-prepare.json', evidence)
    print(json.dumps(evidence, indent=2))
    if not accepted:
        return 2
    plan = json.loads((OUT / 'plan.json').read_text())
    plan['gates']['finalPolicyAdmissionValidationAndWhatIf'] = 'passed'
    plan['status'] = 'host-only-validated-preview-reviewed-awaiting-commit-push'
    write_record('plan.json', plan)
    return 0


def apply(commit):
    marker = OUT / 'host-apply-receipt.json'
    if marker.exists():
        raise RuntimeError('Apply already recorded; inspect original deployment, never repeat uncertain effects')
    verify_identity_and_empty_group()
    source_hash = compile_template()
    prepared = json.loads((OUT / 'host-prepare.json').read_text())
    if not prepared['previewAllowedHostCreatesOnly'] or prepared['templateSourceSha256'] != source_hash:
        raise RuntimeError('Reviewed preview missing or source changed')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    branch = subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip()
    if not commit or head != commit:
        raise RuntimeError('Exact reviewed commit required')
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
        raise RuntimeError('Tracked files changed after commit; review before apply')
    remote = subprocess.check_output(['git', 'ls-remote', '--heads', 'origin', 'refs/heads/' + branch], text=True).split()
    if not remote or remote[0] != commit:
        raise RuntimeError('Exact source commit is not pushed on the current branch')
    username, password = credential()
    write_record('host-apply-receipt.json', {'status': 'pending', 'beganAtSast': now(),
                                           'deployment': NAME, 'commit': commit, 'templateSourceSha256': source_hash})
    receipt = secure_arm('create', username, password)
    receipt.update({'deployment': NAME, 'commit': commit, 'templateSourceSha256': source_hash})
    write_record('host-apply-receipt.json', receipt)
    print(json.dumps({'deployment': NAME, 'status': receipt['status'], 'commit': commit,
                      'credentialLocation': str(CREDENTIAL_FILE), 'credentialValueExported': False}, indent=2))
    return 0 if receipt['status'] == 'succeeded' else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['prepare', 'apply'])
    parser.add_argument('--commit')
    options = parser.parse_args()
    try:
        sys.exit(prepare() if options.operation == 'prepare' else apply(options.commit))
    except Exception as error:
        print(json.dumps({'status': 'stopped', 'errorType': type(error).__name__,
                          'reason': str(error) if isinstance(error, RuntimeError) else 'inspect-local-safe-records'}))
        sys.exit(1)
