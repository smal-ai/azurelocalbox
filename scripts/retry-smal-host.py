"""One explicitly reconciled host retry after approved Standard-security registration.

Preserves the original apply receipt and existing private NIC. Never deletes safety
markers, changes features, grants roles, changes shared controls or runs bootstrap.
"""
import argparse
import json
from pathlib import Path
import runpy
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASE = runpy.run_path(str(ROOT / 'scripts/deploy-smal-host.py'), run_name='host_retry_helpers')
OUT = BASE['OUT']
SUB = BASE['SUB']
RG = BASE['RG']
VM_ID = BASE['VM_ID']
NIC_ID = f'/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Network/networkInterfaces/LocalBox-Client-NIC'
SUBNET_ID = f'/subscriptions/{SUB}/resourceGroups/rg-smal-network-san-1/providers/Microsoft.Network/virtualNetworks/vnet-smal-san-1/subnets/snet-localbox-host'
NAME = 'smal-host-20261027-retry1'
PREPARATION = 'host-retry1-reuse-nic'


def state_is_reconciled(snapshot):
    identity, principal = snapshot['identity'], snapshot['principal']
    if identity['id'] != SUB or identity['tenantId'] != BASE['TENANT'] or principal['id'] != BASE['PRINCIPAL']:
        return False
    if snapshot['feature']['state'] != 'Registered' or snapshot['disks']:
        return False
    resources = snapshot['resources']
    if len(resources) != 1 or resources[0]['id'].lower() != NIC_ID.lower():
        return False
    nic = snapshot['nic']
    ips = nic.get('ips') or []
    return (nic['id'].lower() == NIC_ID.lower() and nic['state'] == 'Succeeded'
            and not nic.get('vm') and not nic.get('forwarding') and len(ips) == 1
            and ips[0].get('ip') == '10.200.16.4' and not ips[0].get('publicIp')
            and ips[0]['subnet'].lower() == SUBNET_ID.lower())


def reconcile(phase):
    prior = json.loads((OUT / 'host-apply-receipt.json').read_text())
    approval = json.loads((OUT / 'owner-approvals.json').read_text())
    if prior.get('status') != 'failed' or 'UseStandardSecurityType' not in prior.get('error', ''):
        raise RuntimeError('Original operation is not the known, reconciled feature-registration failure')
    if not (approval.get('hostOnlyDeploymentApproved') and approval.get('hostCostProposalApproved')
            and approval.get('standardSecurityFeatureRegistrationApproved')
            and approval.get('approvedExistingDeploymentPrincipalId') == BASE['PRINCIPAL']):
        raise RuntimeError('Owner host/identity/capability approval missing')
    if not BASE['CREDENTIAL_FILE'].exists():
        raise RuntimeError('Retained original credential missing; do not regenerate during retry')
    read = BASE['az_read']
    snapshot = {
        'atSast': BASE['now'](),
        'identity': read(['account', 'show', '--subscription', SUB, '--query', '{id:id,tenantId:tenantId}']),
        'principal': read(['ad', 'signed-in-user', 'show', '--query', '{id:id}']),
        'feature': read(['feature', 'show', '--subscription', SUB, '--namespace', 'Microsoft.Compute',
                         '--name', 'UseStandardSecurityType', '--query', '{state:properties.state}']),
        'resources': read(['resource', 'list', '--subscription', SUB, '-g', RG, '--query', '[].{id:id,type:type}']),
        'disks': read(['disk', 'list', '--subscription', SUB, '-g', RG, '--query', '[].id']),
        'nic': read(['network', 'nic', 'show', '--subscription', SUB, '-g', RG, '-n', 'LocalBox-Client-NIC',
                     '--query', '{id:id,state:provisioningState,vm:virtualMachine.id,forwarding:enableIPForwarding,ips:ipConfigurations[].{ip:privateIPAddress,subnet:subnet.id,publicIp:publicIPAddress.id}}']),
    }
    BASE['write_record'](f'{PREPARATION}-{phase}-reconciliation.json', snapshot)
    if not state_is_reconciled(snapshot):
        raise RuntimeError('Live state differs from the specifically approved retry; stop and inspect')
    return snapshot


def preview_is_vm_create_only(record):
    if record.get('status') != 'succeeded':
        return False
    result = record.get('result') or {}
    if result.get('status') != 'Succeeded' or result.get('error'):
        return False
    active = [c for c in result.get('changes', []) if c['changeType'] not in ['NoChange', 'Ignore']]
    return len(active) == 1 and active[0]['changeType'] == 'Create' and active[0]['resourceId'].lower() == VM_ID.lower()


def prepare():
    target = OUT / f'{PREPARATION}-prepare.json'
    if target.exists() or (OUT / 'host-retry1-apply-receipt.json').exists():
        raise RuntimeError('Retry already prepared or attempted; inspect durable records rather than repeat')
    reconcile('prepare')
    source_hash = BASE['compile_template']()
    username, password = BASE['credential']()
    validation = BASE['secure_arm']('validate', username, password, NAME, reuse_existing_nic=True)
    BASE['write_record'](f'{PREPARATION}-validation.json', validation)
    if validation['status'] != 'succeeded' or (validation.get('result') or {}).get('error'):
        raise RuntimeError('Retry validation failed; inspect sanitised evidence')
    preview = BASE['secure_arm']('what-if', username, password, NAME, reuse_existing_nic=True)
    BASE['write_record'](f'{PREPARATION}-what-if.json', preview)
    accepted = preview_is_vm_create_only(preview)
    record = {'atSast': BASE['now'](), 'deployment': NAME, 'templateSourceSha256': source_hash,
              'validation': validation['status'], 'previewVmCreateOnlyExistingNicUnchanged': accepted,
              'preservedOriginalReceipt': 'host-apply-receipt.json', 'credentialRotated': False,
              'azureResourceApplyAttempted': False}
    BASE['write_record'](f'{PREPARATION}-prepare.json', record)
    print(json.dumps(record, indent=2))
    return 0 if accepted else 2


def apply(commit):
    marker = OUT / 'host-retry1-apply-receipt.json'
    if marker.exists():
        raise RuntimeError('Retry apply already recorded; reconcile before any further operation')
    reconcile('preapply')
    source_hash = BASE['compile_template']()
    prepared = json.loads((OUT / f'{PREPARATION}-prepare.json').read_text())
    if not prepared['previewVmCreateOnlyExistingNicUnchanged'] or prepared['templateSourceSha256'] != source_hash:
        raise RuntimeError('Exact reviewed retry preview missing or source changed')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    branch = subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip()
    remote = subprocess.check_output(['git', 'ls-remote', '--heads', 'origin', 'refs/heads/' + branch], text=True).split()
    if not commit or head != commit or not remote or remote[0] != commit:
        raise RuntimeError('Retry source is not the exact committed and pushed revision')
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
        raise RuntimeError('Tracked files changed after commit; stop before retry')
    username, password = BASE['credential']()
    BASE['write_record']('host-retry1-apply-receipt.json', {'status': 'pending', 'beganAtSast': BASE['now'](),
                                                       'deployment': NAME, 'commit': commit})
    receipt = BASE['secure_arm']('create', username, password, NAME, reuse_existing_nic=True)
    receipt.update({'deployment': NAME, 'commit': commit, 'templateSourceSha256': source_hash,
                    'preservedOriginalReceipt': 'host-apply-receipt.json', 'credentialRotated': False})
    BASE['write_record']('host-retry1-apply-receipt.json', receipt)
    print(json.dumps({'deployment': NAME, 'status': receipt['status'], 'commit': commit,
                      'credentialValueExported': False, 'bootstrapDeployed': False}, indent=2))
    return 0 if receipt['status'] == 'succeeded' else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['prepare', 'apply'])
    parser.add_argument('--commit')
    args = parser.parse_args()
    try:
        sys.exit(prepare() if args.operation == 'prepare' else apply(args.commit))
    except Exception as error:
        print(json.dumps({'status': 'stopped', 'errorType': type(error).__name__,
                          'reason': str(error) if isinstance(error, RuntimeError) else 'inspect-local-safe-records'}))
        sys.exit(1)
