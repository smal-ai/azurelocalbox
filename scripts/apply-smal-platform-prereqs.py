"""One approved owned-resource prerequisite deployment. Never returns secrets/keys."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / 'scripts/apply-smal-platform-rg.py'), run_name='platform_rg_helpers')
SUB, RG, OUT = H['SUB'], H['RG'], H['OUT']
az = H['az']
TEMPLATE = 'infra/bicep/localbox-platform-prereqs.bicep'
ACTION = 'localbox-platform-prereqs-20261028'
BASE = H['ID'] + '/providers/'
EXPECTED = {
    BASE + 'Microsoft.KeyVault/vaults/kv-lbox-weu-4766ea',
    BASE + 'Microsoft.Storage/storageAccounts/stlboxdiagweu4766ea',
    BASE + 'Microsoft.Storage/storageAccounts/stlboxwitweu4766ea',
    BASE + 'Microsoft.KeyVault/vaults/kv-lbox-weu-4766ea/providers/Microsoft.Insights/diagnosticSettings/localbox-vault-audit',
    BASE + 'Microsoft.Storage/storageAccounts/stlboxdiagweu4766ea/managementPolicies/default',
    BASE + 'Microsoft.Storage/storageAccounts/stlboxdiagweu4766ea/providers/Microsoft.Authorization/locks/localbox-diagnostics-retain'
}


def validate_preview(data):
    if data.get('status') != 'Succeeded': raise RuntimeError('Preview failed')
    changes = [x for x in data.get('changes', []) if x.get('changeType') != 'NoChange']
    if {x.get('resourceId', '').lower() for x in changes} != {x.lower() for x in EXPECTED} or any(x.get('changeType') != 'Create' for x in changes):
        raise RuntimeError('Preview not exactly the six approved new owned resources')
    for row in changes:
        after = row.get('after', {}); kind = after.get('type', '').lower(); props = after.get('properties', {})
        if kind == 'microsoft.keyvault/vaults':
            if props.get('publicNetworkAccess') != 'Enabled' or props.get('enableRbacAuthorization') is not True or props.get('enablePurgeProtection') is not True or props.get('softDeleteRetentionInDays') != 90:
                raise RuntimeError('New vault security boundary differs')
        if kind == 'microsoft.storage/storageaccounts':
            if props.get('publicNetworkAccess') != 'Disabled' or props.get('allowBlobPublicAccess') is not False or props.get('minimumTlsVersion') != 'TLS1_2':
                raise RuntimeError('New private storage boundary differs')


def main():
    head = H['approval_source']()
    for name in [TEMPLATE, 'scripts/apply-smal-platform-prereqs.py']:
        if (ROOT / name).read_bytes() != subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT): raise RuntimeError('Exact prerequisite source must be committed')
    path = OUT / 'platform-prereqs-apply-receipt.json'
    with path.open('x') as stream:
        record = {'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'status': 'pending', 'sourceCommit': head, 'deploymentName': ACTION, 'scope': 'six-new-owned-platform-prerequisites-only', 'secretsUploaded': False, 'rolesCreated': False, 'arcRegistrationPerformed': False}
        stream.write(json.dumps(record, indent=2) + '\n')
    try:
        account = az(['account', 'show', '--subscription', SUB, '--query', '{id:id,tenantId:tenantId,state:state}'])
        if account != {'id': SUB, 'tenantId': H['TENANT'], 'state': 'Enabled'} or az(['ad', 'signed-in-user', 'show', '--query', 'id']) != H['PRINCIPAL']: raise RuntimeError('Approved identity changed')
        if az(['group', 'show', '--subscription', SUB, '--name', RG, '--query', 'location']) != 'westeurope': raise RuntimeError('New owned RG differs')
        if az(['resource', 'list', '--subscription', SUB, '--resource-group', RG, '--query', '[].id']): raise RuntimeError('RG is not empty. Inspect rather than overwrite.')
        if az(['deployment', 'group', 'list', '--subscription', SUB, '--resource-group', RG, '--query', "[?name=='" + ACTION + "'].name"]): raise RuntimeError('Deployment identity exists. Reconcile.')
        args = ['--subscription', SUB, '--resource-group', RG, '--name', ACTION, '--template-file', str(ROOT / TEMPLATE)]
        preview = az(['deployment', 'group', 'what-if', *args, '--result-format', 'FullResourcePayloads', '--no-pretty-print'], timeout=300)
        preview_path = OUT / 'platform-prereqs-what-if.json'
        with preview_path.open('x') as stream: stream.write(json.dumps(preview, indent=2) + '\n')
        validate_preview(preview)
        record['previewSha256'] = hashlib.sha256(preview_path.read_bytes()).hexdigest()
        record['status'] = 'apply-pending'; path.write_text(json.dumps(record, indent=2) + '\n')
        response = az(['deployment', 'group', 'create', *args], timeout=900)
        record['deploymentId'] = response['id']; record['deploymentState'] = response['properties']['provisioningState']
        record['resources'] = az(['resource', 'list', '--subscription', SUB, '--resource-group', RG, '--query', '[].{id:id,type:type}'])
        if any(x['id'].lower() not in {i.lower() for i in EXPECTED} for x in record['resources']): raise RuntimeError('Unlisted resource detected; preserve and inspect')
        record['vault'] = az(['keyvault', 'show', '--subscription', SUB, '--name', 'kv-lbox-weu-4766ea', '--query', '{id:id,publicNetworkAccess:properties.publicNetworkAccess,rbac:properties.enableRbacAuthorization,purgeProtection:properties.enablePurgeProtection,softDeleteDays:properties.softDeleteRetentionInDays}'])
        record['storage'] = [az(['storage', 'account', 'show', '--subscription', SUB, '--resource-group', RG, '--name', name, '--query', '{id:id,publicNetworkAccess:publicNetworkAccess,allowBlobPublicAccess:allowBlobPublicAccess,tls:minimumTlsVersion}']) for name in ['stlboxdiagweu4766ea', 'stlboxwitweu4766ea']]
        if record['deploymentState'] != 'Succeeded' or record['vault']['publicNetworkAccess'] != 'Enabled' or not record['vault']['rbac'] or not record['vault']['purgeProtection'] or any(x['publicNetworkAccess'] != 'Disabled' or x['allowBlobPublicAccess'] is not False for x in record['storage']): raise RuntimeError('Independent configuration readback differs')
        record['status'] = 'complete-owned-prerequisites-only'
    except subprocess.TimeoutExpired: record['status'] = 'uncertain-timeout-do-not-repeat'
    except (RuntimeError, ValueError, KeyError) as error: record['status'] = 'failed-inspect-before-resume'; record['errorType'] = type(error).__name__
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat()
    path.write_text(json.dumps(record, indent=2) + '\n'); print(json.dumps(record, indent=2))
    return 0 if record['status'] == 'complete-owned-prerequisites-only' else 2


if __name__ == '__main__':
    raise SystemExit(main())
