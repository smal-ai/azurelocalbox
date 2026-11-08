"""One approved 2 TiB Premium disk, one checked LUN8 attachment and new-only format."""
from datetime import datetime, timezone
import json
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
A = runpy.run_path(str(ROOT / 'scripts/smal-three-node-approval.py'), run_name='node03_disk_guard')
az, OUT, SUB, RG, VM_ID, DISK_ID = (A[key] for key in ['az', 'OUT', 'SUB', 'RG', 'VM_ID', 'DISK_ID'])
TEMPLATE = 'infra/bicep/localbox-node03-disk.bicep'
ACTION = 'localbox-node03-disk-20261029'


def validate_preview(data, owned):
    if data.get('status') != 'Succeeded': raise RuntimeError('New disk preview failed')
    changes = []
    for row in data.get('changes', []):
        if row.get('changeType') in ['Ignore', 'NoChange'] and row.get('resourceId', '').lower() in owned and row.get('before') == row.get('after'): continue
        changes.append(row)
    if len(changes) != 1: raise RuntimeError('Exactly one new disk effect required')
    row = changes[0]; after = row.get('after', {}); p = after.get('properties', {})
    if (row.get('changeType') != 'Create' or row.get('resourceId', '').lower() != DISK_ID.lower()
            or after.get('type', '').lower() != 'microsoft.compute/disks' or after.get('location') != 'southafricanorth'
            or after.get('sku', {}).get('name') != 'Premium_LRS' or p.get('diskSizeGB') != 2048
            or p.get('creationData', {}).get('createOption') != 'Empty' or p.get('networkAccessPolicy') != 'DenyAll' or p.get('publicNetworkAccess') != 'Disabled'):
        raise RuntimeError('New disk size/SKU/private-access/effect differs')


def vm_projection():
    return az(['vm', 'show', '-g', RG, '-n', 'LocalBox-Client', '--query', '{id:id,sku:hardwareProfile.vmSize,osId:storageProfile.osDisk.managedDisk.id,data:storageProfile.dataDisks[].{id:managedDisk.id,lun:lun,caching:caching,deleteOption:deleteOption,size:diskSizeGB,sku:managedDisk.storageAccountType}}'])


def main():
    head = A['source_guard']([TEMPLATE, 'scripts/apply-smal-three-node-disk.py', 'scripts/smal-private-powershell.py', 'scripts/prepare-smal-node03-disk.ps1', 'scripts/format-smal-node03-disk.ps1', 'scripts/smal-three-node-prelude.ps1'])
    path = OUT / 'node03-disk-apply-receipt.json'
    record = {'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'sourceCommit': head, 'status': 'pending', 'phase': 'preflight', 'deploymentName': ACTION,
              'existingDiskSkuConversionRepeated': False, 'existingPoolOrVolumeFormatRequested': False, 'nodeCreationRequested': False}
    with path.open('x') as stream: stream.write(json.dumps(record, indent=2) + '\n')
    def save(): path.write_text(json.dumps(record, indent=2) + '\n')
    try:
        if az(['ad', 'signed-in-user', 'show', '--query', 'id']) != A['H']['PRINCIPAL']: raise RuntimeError('Approved identity changed')
        before = vm_projection()
        if before['id'].lower() != VM_ID.lower() or before['sku'] != 'Standard_E32s_v6' or len(before['data']) != 8 or {row['lun'] for row in before['data']} != set(range(8)) or any(row['sku'] != 'Premium_LRS' for row in before['data']): raise RuntimeError('Exact unchanged host/disk set differs')
        disks = az(['disk', 'list', '-g', RG, '--query', '[].{id:id,sku:sku.name,size:diskSizeGB,managedBy:managedBy}'])
        original = json.loads((OUT / 'premium-disk-conversion-reconciled-result.json').read_text())['disks']
        if len(disks) != 9 or {row['id'].lower() for row in disks} != {row['id'].lower() for row in original} or any(row['sku'] != 'Premium_LRS' or row['managedBy'].lower() != VM_ID.lower() for row in disks): raise RuntimeError('Existing disk identities/SKUs/ownership differ')
        owned = {row.lower() for row in az(['resource', 'list', '-g', RG, '--query', '[].id'])}
        if DISK_ID.lower() in owned or az(['deployment', 'group', 'list', '-g', RG, '--query', "[?name=='" + ACTION + "'].name"]): raise RuntimeError('Disk/deployment identity exists. Reconcile rather than repeat.')
        record['vmBefore'] = before; save()
        args = ['-g', RG, '-n', ACTION, '--template-file', str(ROOT / TEMPLATE)]
        preview = az(['deployment', 'group', 'what-if', *args, '--result-format', 'FullResourcePayloads', '--no-pretty-print'], timeout=300)
        with (OUT / 'node03-disk-what-if.json').open('x') as stream: stream.write(json.dumps(preview, indent=2) + '\n')
        validate_preview(preview, owned)
        record['phase'] = 'create-one-approved-disk-pending'; save()
        result = az(['deployment', 'group', 'create', *args], timeout=600)
        if result['properties']['provisioningState'] != 'Succeeded': raise RuntimeError('New disk deployment did not succeed')
        record['deploymentId'] = result['id']
        disk = az(['disk', 'show', '--ids', DISK_ID])
        context = A['context'](disk)
        if disk.get('managedBy') or disk.get('networkAccessPolicy') != 'DenyAll' or disk.get('publicNetworkAccess') != 'Disabled' or disk.get('burstingEnabled') is True: raise RuntimeError('New disk readback differs before attachment')
        record['newDisk'] = {key: disk.get(key) for key in ['id', 'uniqueId', 'diskSizeGB', 'sku', 'networkAccessPolicy', 'publicNetworkAccess', 'burstingEnabled']}; save()
        transport = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='node03_disk_transport')
        record['phase'] = 'capture-windows-pre-attachment-baseline'; save()
        if transport['main']('scripts/prepare-smal-node03-disk.ps1', 'node03-disk-baseline-20261029', three_node_context=context) != 0: raise RuntimeError('Before-attachment Windows identity admission failed')
        if vm_projection() != before: raise RuntimeError('Host storage changed during before-attachment observation')
        record['phase'] = 'attach-only-new-disk-lun8-pending'; save()
        az(['vm', 'disk', 'attach', '-g', RG, '--vm-name', 'LocalBox-Client', '--name', DISK_ID, '--lun', '8', '--caching', 'None'], timeout=600)
        after = vm_projection(); added = [row for row in after['data'] if row['lun'] == 8]
        if after['id'] != before['id'] or after['sku'] != before['sku'] or after['osId'] != before['osId'] or len(after['data']) != 9 or [row for row in after['data'] if row['lun'] != 8] != before['data'] or len(added) != 1:
            raise RuntimeError('Unexpected host storage effect after attachment')
        if added[0]['id'].lower() != DISK_ID.lower() or added[0]['sku'] != 'Premium_LRS' or added[0]['size'] != 2048 or added[0]['caching'] != 'None' or added[0]['deleteOption'] not in [None, 'Detach']:
            raise RuntimeError('New disk LUN/caching/retention readback differs')
        disk = az(['disk', 'show', '--ids', DISK_ID])
        if disk.get('managedBy', '').lower() != VM_ID.lower() or disk['uniqueId'] != context['azureDiskUniqueId']: raise RuntimeError('New disk actual attachment identity differs')
        record['vmAfter'] = after; record['phase'] = 'format-only-admitted-new-windows-disk'; save()
        if transport['main']('scripts/format-smal-node03-disk.ps1', 'node03-disk-format-20261029', three_node_context=context) != 0: raise RuntimeError('New-disk format incomplete. Inspect marker; do not repeat.')
        formatted = json.loads((transport['OUT'] / 'private-ssh-node03-disk-format-20261029.json').read_text())['result']
        if formatted['status'] != 'complete-new-lun8-only-formatted-w': raise RuntimeError('New W proof incomplete')
        record['windowsDiskProof'] = formatted; record['phase'] = 'new-w-verified'; record['status'] = 'complete-one-new-premium-disk-attached-and-new-only-formatted'
    except subprocess.TimeoutExpired: record['status'] = 'uncertain-timeout-do-not-repeat'
    except (RuntimeError, ValueError, KeyError) as error:
        record['status'] = 'failed-inspect-before-resume'; record['errorType'] = type(error).__name__
        if isinstance(error, RuntimeError): record['error'] = str(error)
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat(); save(); print(json.dumps(record, indent=2))
    return 0 if record['status'].startswith('complete-') else 2


if __name__ == '__main__':
    raise SystemExit(main())
