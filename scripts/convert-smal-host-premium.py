"""Convert only the nine explicitly requested existing host disks to Premium SSD.

No disk creation, resizing, replacement, reformatting, topology or policy change.
One create-only run receipt. Partial/uncertain operations are not automatically
replayed or rolled back. Existing guests are gracefully stopped before the host.
"""
from datetime import datetime, timezone
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-29'
H = runpy.run_path(str(ROOT / 'scripts/apply-smal-platform-rg.py'), run_name='premium_approval_helpers')
T = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='premium_private_transport')
SUB = H['SUB']; RG = 'rg-localbox-nodes-san-1'; HOST = 'LocalBox-Client'
VM_ID = '/subscriptions/' + SUB + '/resourceGroups/' + RG + '/providers/Microsoft.Compute/virtualMachines/' + HOST


def az(args, timeout=120):
    # Entra (az ad) commands reject --subscription. ARM commands remain explicit.
    subscription = [] if args[0] == 'ad' else ['--subscription', SUB]
    result = subprocess.run(['az', *args, *subscription, '--only-show-errors', '--output', 'json'], check=True, capture_output=True, text=True, timeout=timeout)
    return json.loads(result.stdout) if result.stdout.strip() else None


def verify_disks(rows, expected, final=False):
    if len(rows) != 9 or {row['id'].lower() for row in rows} != {row['id'].lower() for row in expected}:
        raise RuntimeError('Exact nine disk identities differ')
    by_id = {row['id'].lower(): row for row in expected}
    for row in rows:
        old = by_id[row['id'].lower()]
        allowed = ['Premium_LRS'] if final else ['Standard_LRS', 'Premium_LRS']
        if row.get('sku') not in allowed or row.get('diskSizeGB') != old['diskSizeGB'] or row.get('managedBy', '').lower() != VM_ID.lower():
            raise RuntimeError('Disk SKU, size or owner differs. No substitution authorised.')


def disk_readback():
    return az(['disk', 'list', '-g', RG, '--query', '[].{id:id,name:name,diskSizeGB:diskSizeGB,sku:sku.name,state:diskState,managedBy:managedBy,uniqueId:uniqueId,encryptionType:encryption.type,diskEncryptionSetId:encryption.diskEncryptionSetId,securityType:securityProfile.securityType}'])


def power():
    return az(['vm', 'get-instance-view', '-g', RG, '-n', HOST, '--query', "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]"])


def source_guard():
    head = H['approval_source']()
    for name in ['scripts/convert-smal-host-premium.py', 'scripts/stop-smal-guests-for-premium.ps1', 'scripts/smal-private-powershell.py',
                 'scripts/start-smal-localbox.py', 'scripts/start-smal-existing-guests.ps1',
                 'docs/deployment-2026-10-29/three-node-premium-cloud-sizing.json', 'docs/deployment-2026-10-29/premium-disk-conversion-authorisation.json']:
        if (ROOT / name).read_bytes() != subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT): raise RuntimeError('Exact disk conversion source/authorisation differs from HEAD')
    consent = json.loads((OUT / 'premium-disk-conversion-authorisation.json').read_text())
    if consent.get('humanInstruction') != 'please change the disks to Premium SSD, we need it to be performant.' or consent.get('targetSku') != 'Premium_LRS' or consent.get('newDiskPurchaseAuthorisedByThisInstruction') is not False:
        raise RuntimeError('Explicit existing-disk-only Premium request differs')
    return head


def main(resume_cli=False):
    head = source_guard()
    path = OUT / ('premium-disk-conversion-after-cli-reconciliation.json' if resume_cli else 'premium-disk-conversion-receipt.json')
    record = {'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'sourceCommit': head, 'status': 'pending', 'phase': 'preflight',
              'targetSku': 'Premium_LRS', 'newDisksCreated': False, 'diskSizesChanged': False, 'guestProfilesChanged': False,
              'policyOrShutdownAutomationChanged': False, 'platformReadinessVerified': False, 'diskEffects': []}
    if resume_cli:
        prior_path = OUT / 'premium-disk-conversion-receipt.json'
        prior_bytes = prior_path.read_bytes()
        if prior_bytes != subprocess.check_output(['git', 'show', 'HEAD:' + str(prior_path.relative_to(ROOT))], cwd=ROOT): raise RuntimeError('Original preflight failure receipt must be committed')
        prior = json.loads(prior_bytes)
        if (prior.get('status') != 'failed-inspect-before-resume' or prior.get('phase') != 'preflight'
                or prior.get('errorType') != 'CalledProcessError' or prior.get('diskEffects') != []
                or 'hostPowerBefore' in prior or 'disksBefore' in prior):
            raise RuntimeError('No exact zero-effect CLI preflight refusal to reconcile')
        record['originalZeroEffectFailureRetained'] = True
        record['originalReceiptSha256'] = hashlib.sha256(prior_bytes).hexdigest()
    with path.open('x') as stream: stream.write(json.dumps(record, indent=2) + '\n')
    def save(): path.write_text(json.dumps(record, indent=2) + '\n')
    try:
        if az(['ad', 'signed-in-user', 'show', '--query', 'id']) != H['PRINCIPAL']: raise RuntimeError('Approved identity changed')
        account = az(['account', 'show'])
        if account['id'] != SUB or account['tenantId'] != H['TENANT']: raise RuntimeError('Approved Azure context differs')
        vm = az(['vm', 'show', '-g', RG, '-n', HOST, '--query', '{id:id,sku:hardwareProfile.vmSize,luns:storageProfile.dataDisks[].lun}'])
        if vm['id'].lower() != VM_ID.lower() or vm['sku'] != 'Standard_E32s_v6' or sorted(vm['luns']) != list(range(8)): raise RuntimeError('Exact unchanged host configuration differs')
        roles = az(['role', 'assignment', 'list', '--assignee', H['PRINCIPAL'], '--scope', VM_ID, '--include-inherited', '--include-groups', '--query', '[].roleDefinitionName'])
        if 'Owner' not in roles: raise RuntimeError('Existing elevated access is absent. No automatic PIM activation.')
        expected = json.loads((OUT / 'three-node-premium-cloud-sizing.json').read_text())['disks']
        before = disk_readback(); verify_disks(before, expected)
        record['disksBefore'] = before; record['hostPowerBefore'] = power(); save()
        record['requestedFieldChangePreview'] = [{'id': row['id'], 'change': {'sku.name': {'before': row['sku'], 'after': 'Premium_LRS'}}} for row in before if row['sku'] != 'Premium_LRS']
        record['previewKind'] = 'local-exact-requested-field-diff-not-ARM-policy-what-if'
        save()
        if record['hostPowerBefore'] != 'PowerState/running': raise RuntimeError('Host must be running for safe exact-guest shutdown inspection')
        if all(row['sku'] == 'Premium_LRS' for row in before):
            record['status'] = 'complete-already-premium-no-stop-required'; record['disksAfter'] = before
        else:
            record['phase'] = 'graceful-guest-shutdown-pending'; save()
            code = T['main']('scripts/stop-smal-guests-for-premium.ps1', 'stop-guests-for-premium-20261029')
            if code != 0: raise RuntimeError('Guest shutdown incomplete. Host deallocation not requested.')
            record['phase'] = 'outer-host-stop-pending'; save()
            az(['vm', 'stop', '-g', RG, '-n', HOST], timeout=300)
            if power() != 'PowerState/stopped': raise RuntimeError('Host has not stopped; no disk updates requested')
            record['phase'] = 'outer-host-deallocation-pending'; save()
            az(['vm', 'deallocate', '-g', RG, '-n', HOST], timeout=300)
            if power() != 'PowerState/deallocated': raise RuntimeError('Host has not deallocated; no disk updates requested')
            verify_disks(disk_readback(), expected)
            for old in before:
                if old['sku'] == 'Premium_LRS': continue
                record['phase'] = 'one-existing-disk-sku-update-pending'; record['pendingDiskId'] = old['id']; save()
                actual = az(['disk', 'update', '--ids', old['id'], '--sku', 'Premium_LRS', '--query', '{id:id,diskSizeGB:diskSizeGB,sku:sku.name,managedBy:managedBy,uniqueId:uniqueId,encryptionType:encryption.type,diskEncryptionSetId:encryption.diskEncryptionSetId,securityType:securityProfile.securityType}'], timeout=300)
                if actual['id'].lower() != old['id'].lower() or actual['sku'] != 'Premium_LRS' or actual['diskSizeGB'] != old['diskSizeGB'] or actual['managedBy'].lower() != VM_ID.lower():
                    raise RuntimeError('Independent per-disk conversion readback differs')
                for key in ['uniqueId', 'encryptionType', 'diskEncryptionSetId', 'securityType']:
                    if actual.get(key) != old.get(key): raise RuntimeError('Disk identity/encryption/security metadata changed unexpectedly')
                record['diskEffects'].append(actual); record.pop('pendingDiskId', None); save()
            after = disk_readback(); verify_disks(after, expected, final=True); record['disksAfter'] = after
            record['phase'] = 'restore-existing-host-and-guests'; save()
            startup = runpy.run_path(str(ROOT / 'scripts/start-smal-localbox.py'), run_name='premium_existing_startup')
            if startup['main']() != 0: raise RuntimeError('Premium disks verified, but host/guest startup needs inspection')
            if power() != 'PowerState/running': raise RuntimeError('Host not running after startup')
            record['hostPowerAfter'] = 'PowerState/running'
            record['status'] = 'complete-nine-existing-disks-premium-host-and-guests-running'
    except subprocess.TimeoutExpired: record['status'] = 'uncertain-timeout-inspect-do-not-repeat'
    except (RuntimeError, ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        record['status'] = 'failed-inspect-before-resume'; record['errorType'] = type(error).__name__
        if isinstance(error, RuntimeError): record['error'] = str(error)
    except KeyboardInterrupt: record['status'] = 'interrupted-inspect-do-not-repeat'
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat(); save()
    print(json.dumps(record, indent=2))
    return 0 if record['status'].startswith('complete-') else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resume-after-cli-reconciliation', action='store_true')
    raise SystemExit(main(parser.parse_args().resume_after_cli_reconciliation))
