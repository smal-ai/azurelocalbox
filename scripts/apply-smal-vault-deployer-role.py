"""Apply exactly the approved conditional Secrets Officer grant at the new vault."""
from datetime import datetime, timezone
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / 'scripts/apply-smal-platform-rg.py'), run_name='vault_role_helpers')
az, SUB, RG, OUT = H['az'], H['SUB'], H['RG'], H['OUT']
VAULT = H['ID'] + '/providers/Microsoft.KeyVault/vaults/kv-lbox-weu-4766ea'
ROLE = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
TEMPLATE = 'infra/bicep/localbox-vault-deployer-role.bicep'
ACTION = 'localbox-vault-deployer-role-20261028'
UNCHANGED = {VAULT.lower(), (H['ID'] + '/providers/Microsoft.Storage/storageAccounts/stlboxdiagweu4766ea').lower(), (H['ID'] + '/providers/Microsoft.Storage/storageAccounts/stlboxwitweu4766ea').lower()}


def validate_preview(data):
    if data.get('status') != 'Succeeded': raise RuntimeError('Preview did not succeed')
    changes = []
    for row in data.get('changes', []):
        if row.get('changeType') == 'NoChange': continue
        if row.get('changeType') == 'Ignore' and row.get('resourceId', '').lower() in UNCHANGED and row.get('before') == row.get('after'):
            continue
        changes.append(row)
    if len(changes) != 1: raise RuntimeError('Expected exactly one new vault-scoped role')
    row = changes[0]; after = row.get('after', {}); p = after.get('properties', {})
    if (row.get('changeType') != 'Create'
            or not row.get('resourceId', '').lower().startswith((VAULT + '/providers/Microsoft.Authorization/roleAssignments/').lower())
            or after.get('type', '').lower() != 'microsoft.authorization/roleassignments'
            or p.get('principalId', '').lower() != H['PRINCIPAL']
            or p.get('principalType') not in [None, 'User']
            or p.get('roleDefinitionId', '').lower() != ('/subscriptions/' + SUB + '/providers/Microsoft.Authorization/roleDefinitions/' + ROLE).lower()
            or p.get('scope', VAULT).lower() != VAULT.lower()):
        raise RuntimeError('Role principal, definition or vault-only scope differs')


def main(resume_preview=False):
    head = H['approval_source']()
    approval = json.loads((OUT / 'cloud-apply-approval.json').read_text())
    if approval.get('listedRgAndVaultScopedRoleEffectsApproved') is not True: raise RuntimeError('Explicit scoped-role approval missing')
    for path in [TEMPLATE, 'scripts/apply-smal-vault-deployer-role.py']:
        if (ROOT / path).read_bytes() != subprocess.check_output(['git', 'show', 'HEAD:' + path], cwd=ROOT): raise RuntimeError('Exact role source differs from HEAD')
    target = OUT / ('vault-deployer-role-reconciled.json' if resume_preview else 'vault-deployer-role-receipt.json')
    if resume_preview:
        prior_path = OUT / 'vault-deployer-role-receipt.json'
        prior = json.loads(prior_path.read_text())
        if prior.get('status') != 'failed-inspect-before-resume' or 'previewSha256' in prior or 'deploymentId' in prior:
            raise RuntimeError('No exact pre-apply preview refusal to reconcile')
    with target.open('x') as stream:
        record = {'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'status': 'pending', 'sourceCommit': head,
                  'deploymentName': ACTION, 'scope': VAULT, 'principalId': H['PRINCIPAL'], 'roleDefinitionId': ROLE,
                  'publicAccessOrVaultConfigurationChangeRequested': False, 'subscriptionWideGrantRequested': False}
        if resume_preview:
            record['originalPreApplyRefusalRetained'] = True
            record['originalReceiptSha256'] = hashlib.sha256(prior_path.read_bytes()).hexdigest()
        stream.write(json.dumps(record, indent=2) + '\n')
    try:
        if az(['ad', 'signed-in-user', 'show', '--query', 'id']) != H['PRINCIPAL']: raise RuntimeError('Approved identity changed')
        vault = az(['keyvault', 'show', '--subscription', SUB, '--name', 'kv-lbox-weu-4766ea', '--query', '{id:id,pna:properties.publicNetworkAccess,rbac:properties.enableRbacAuthorization}'])
        if vault['id'].lower() != VAULT.lower() or vault['pna'] != 'Disabled' or vault['rbac'] is not True: raise RuntimeError('Expected private RBAC vault differs')
        assignments = az(['role', 'assignment', 'list', '--subscription', SUB, '--assignee', H['PRINCIPAL'], '--scope', VAULT, '--include-inherited', '--include-groups', '--query', '[].{scope:scope,role:roleDefinitionName,principalType:principalType}'])
        record['effectiveAssignmentsBefore'] = assignments
        if any(x['role'] in ['Key Vault Secrets Officer', 'Key Vault Administrator'] for x in assignments): raise RuntimeError('Equivalent data role exists; inspect access instead of adding duplicate')
        if az(['deployment', 'group', 'list', '--subscription', SUB, '--resource-group', RG, '--query', "[?name=='" + ACTION + "'].name"]): raise RuntimeError('Role deployment identity already exists')
        args = ['--subscription', SUB, '--resource-group', RG, '--name', ACTION, '--template-file', str(ROOT / TEMPLATE)]
        preview = az(['deployment', 'group', 'what-if', *args, '--result-format', 'FullResourcePayloads', '--no-pretty-print'], timeout=300)
        preview_path = OUT / ('vault-deployer-role-what-if-reconciled.json' if resume_preview else 'vault-deployer-role-what-if.json')
        with preview_path.open('x') as stream: stream.write(json.dumps(preview, indent=2) + '\n')
        validate_preview(preview)
        record['previewSha256'] = hashlib.sha256(preview_path.read_bytes()).hexdigest()
        record['status'] = 'apply-pending'; target.write_text(json.dumps(record, indent=2) + '\n')
        result = az(['deployment', 'group', 'create', *args], timeout=600)
        record['deploymentId'] = result['id']; record['deploymentState'] = result['properties']['provisioningState']
        actual = az(['role', 'assignment', 'list', '--subscription', SUB, '--assignee-object-id', H['PRINCIPAL'], '--scope', VAULT, '--query', '[].{id:id,scope:scope,definition:roleDefinitionId,principal:principalId,principalType:principalType}'])
        selected = [x for x in actual if x['scope'].lower() == VAULT.lower() and x['definition'].lower().endswith('/' + ROLE) and x['principal'].lower() == H['PRINCIPAL'] and x['principalType'] == 'User']
        if len(selected) != 1 or record['deploymentState'] != 'Succeeded': raise RuntimeError('Independent role readback differs')
        record['assignment'] = selected[0]
        record['vaultPublicAccessAfter'] = az(['keyvault', 'show', '--subscription', SUB, '--name', 'kv-lbox-weu-4766ea', '--query', 'properties.publicNetworkAccess'])
        if record['vaultPublicAccessAfter'] != 'Disabled': raise RuntimeError('Private boundary changed unexpectedly')
        record['status'] = 'complete-one-vault-only-data-role'
    except subprocess.TimeoutExpired: record['status'] = 'uncertain-timeout-do-not-repeat'
    except (RuntimeError, ValueError, KeyError) as error: record['status'] = 'failed-inspect-before-resume'; record['errorType'] = type(error).__name__
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat()
    target.write_text(json.dumps(record, indent=2) + '\n'); print(json.dumps(record, indent=2))
    return 0 if record['status'] == 'complete-one-vault-only-data-role' else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resume-after-preview-reconciliation', action='store_true')
    raise SystemExit(main(parser.parse_args().resume_after_preview_reconciliation))
