"""Apply seven exact approved RG/vault roles after fresh Arc identity verification.

No new identities, subscription-wide grants, public-access settings or deployment
settings. One fixed receipt/deployment identity prevents automatic replay.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / 'scripts/apply-smal-platform-rg.py'), run_name='arc_role_helpers')
az, SUB, RG = H['az'], H['SUB'], H['RG']
OUT = ROOT / 'docs/deployment-2026-10-29'
SCOPE = H['ID']
VAULT = SCOPE + '/providers/Microsoft.KeyVault/vaults/kv-lbox-weu-4766ea'
RP = '4606be37-a04a-4716-a214-186a08bb7745'
NODES = {'LB-NODE01': '9a1205c8-6ac3-4d02-ad6d-6166827c8d9d', 'LB-NODE02': 'b282b136-716d-4fa9-8e03-a4c754249a5e'}
ROLES = {'f5819b54-e033-4d82-ac66-4fec3cbf3f4c': 'Azure Connected Machine Resource Manager',
         '865ae368-6a45-4bd1-8fbf-0d5151f56fc1': 'Azure Stack HCI Device Management Role',
         'c99c945f-8bd1-4fb1-a903-01460aae6068': 'Azure Stack HCI Connected InfraVMs',
         '4633458b-17de-408a-b874-0445c86b69e6': 'Key Vault Secrets User'}
TEMPLATE = 'infra/bicep/localbox-arc-platform-roles.bicep'
ACTION = 'localbox-arc-platform-roles-20261029'
EXPECTED = {(SCOPE.lower(), RP, 'f5819b54-e033-4d82-ac66-4fec3cbf3f4c')}
EXPECTED.update((SCOPE.lower(), node, role) for node in NODES.values() for role in ['865ae368-6a45-4bd1-8fbf-0d5151f56fc1', 'c99c945f-8bd1-4fb1-a903-01460aae6068'])
EXPECTED.update((VAULT.lower(), node, '4633458b-17de-408a-b874-0445c86b69e6') for node in NODES.values())


def binding(row):
    return (row.get('scope', '').lower(), row.get('principalId', '').lower(), row.get('roleDefinitionId', '').lower().rsplit('/', 1)[-1])


def verify_nodes(nodes, bootstrap):
    if len(nodes) != 2 or {row['name']: row['identity']['principalId'] for row in nodes} != NODES:
        raise RuntimeError('Exact inspected Arc machine identities differ')
    for row in nodes:
        expected_id = SCOPE + '/providers/Microsoft.HybridCompute/machines/' + row['name']
        if (row['id'].lower() != expected_id.lower() or row.get('status') != 'Connected'
                or row.get('provisioningState') != 'Succeeded' or row.get('location') != 'westeurope'
                or row['identity'].get('tenantId') != H['TENANT'] or row['identity'].get('type') != 'SystemAssigned'
                or row.get('osVersion') != '10.0.26100.33650'):
            raise RuntimeError('Arc health, identity, region or OS evidence differs')
    guests = bootstrap.get('result', {}).get('nodes', [])
    if bootstrap.get('status') != 'complete' or len(guests) != 2 or {row['name'] for row in guests} != set(NODES):
        raise RuntimeError('Independent private bootstrap inspection missing')
    for row in guests:
        if row.get('bootstrap', {}).get('status') != 'Succeeded':
            raise RuntimeError('Node bootstrap has not succeeded')


def validate_preview(data, unchanged, existing):
    if data.get('status') != 'Succeeded': raise RuntimeError('What-if failed')
    creates = set()
    for row in data.get('changes', []):
        kind = row.get('changeType')
        if kind in ['NoChange', 'Ignore'] and row.get('resourceId', '').lower() in unchanged and row.get('before') == row.get('after'):
            continue
        after = row.get('after', {})
        p = after.get('properties', {})
        resource_id = row.get('resourceId', '').lower()
        inferred = resource_id.rsplit('/providers/microsoft.authorization/roleassignments/', 1)[0]
        item = binding({**p, 'scope': p.get('scope', inferred)})
        if (kind not in ['Create', 'NoChange'] or after.get('type', '').lower() != 'microsoft.authorization/roleassignments'
                or item not in EXPECTED or p.get('principalType') not in [None, 'ServicePrincipal']
                or p.get('roleDefinitionId', '').lower() != '/subscriptions/' + SUB + '/providers/microsoft.authorization/roledefinitions/' + item[2]
                or inferred != item[0]):
            raise RuntimeError('Preview contains an unlisted effect or identity/role/scope')
        if kind == 'Create':
            if item in existing or item in creates: raise RuntimeError('Duplicate role effect')
            creates.add(item)
        elif item not in existing:
            raise RuntimeError('Unexpected role NoChange without independent readback')
    if creates != EXPECTED - existing:
        raise RuntimeError('Preview does not match exactly the missing approved role bindings')


def assignments():
    args = ['role', 'assignment', 'list', '--subscription', SUB, '--query', '[].{id:id,scope:scope,roleDefinitionId:roleDefinitionId,principalId:principalId,principalType:principalType}']
    return az([*args, '--scope', SCOPE]) + az([*args, '--scope', VAULT])


def main():
    head = H['approval_source']()
    approval = json.loads((H['OUT'] / 'cloud-apply-approval.json').read_text())
    if approval.get('listedRgAndVaultScopedRoleEffectsApproved') is not True: raise RuntimeError('Scoped role approval missing')
    for path in [TEMPLATE, 'scripts/apply-smal-arc-platform-roles.py', 'docs/deployment-2026-10-27/private-ssh-arc-registration-after-recovery-20261029.json']:
        if (ROOT / path).read_bytes() != subprocess.check_output(['git', 'show', 'HEAD:' + path], cwd=ROOT): raise RuntimeError('Role source or bootstrap proof differs from HEAD')
    path = OUT / 'arc-platform-roles-receipt.json'
    record = {'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'sourceCommit': head, 'status': 'pending',
              'deploymentName': ACTION, 'subscriptionWideGrantRequested': False, 'vaultPublicAccessChangeRequested': False,
              'clusterDeploymentRequested': False, 'platformReadinessVerified': False}
    with path.open('x') as stream: stream.write(json.dumps(record, indent=2) + '\n')
    try:
        if az(['ad', 'signed-in-user', 'show', '--query', 'id']) != H['PRINCIPAL']: raise RuntimeError('Approved identity changed')
        nodes = az(['connectedmachine', 'list', '--subscription', SUB, '-g', RG, '--query', '[].{id:id,name:name,status:status,provisioningState:provisioningState,location:location,identity:identity,agentVersion:agentVersion,osVersion:osVersion}'])
        proof = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-arc-registration-after-recovery-20261029.json').read_text())
        verify_nodes(nodes, proof)
        record['arcMachines'] = nodes
        rp = az(['ad', 'sp', 'show', '--id', RP, '--query', '{id:id,appId:appId,accountEnabled:accountEnabled}'])
        if rp != {'id': RP, 'appId': '1412d89f-b8a8-4111-b4fd-e82905cbd85d', 'accountEnabled': True}: raise RuntimeError('Existing first-party RP identity differs')
        record['firstPartyRp'] = rp
        for definition, name in ROLES.items():
            actual = az(['role', 'definition', 'list', '--subscription', SUB, '--name', definition, '--query', '[].{name:name,roleName:roleName,roleType:roleType}'])
            if actual != [{'name': definition, 'roleName': name, 'roleType': 'BuiltInRole'}]: raise RuntimeError('Built-in role definition differs')
        if az(['keyvault', 'show', '--subscription', SUB, '-n', 'kv-lbox-weu-4766ea', '--query', 'properties.publicNetworkAccess']) != 'Disabled': raise RuntimeError('Vault private boundary differs')
        before = assignments()
        record['assignmentsBefore'] = before
        existing = {binding(row) for row in before} & EXPECTED
        if any(row.get('principalType') != 'ServicePrincipal' for row in before if binding(row) in EXPECTED): raise RuntimeError('Existing role principal type differs')
        if az(['deployment', 'group', 'list', '--subscription', SUB, '-g', RG, '--query', "[?name=='" + ACTION + "'].name"]): raise RuntimeError('Deployment identity exists, inspect rather than repeat')
        unchanged = {row['id'].lower() for row in az(['resource', 'list', '--subscription', SUB, '-g', RG, '--query', '[].{id:id}'])}
        unchanged.update(row['id'].lower() for row in before if binding(row) not in EXPECTED)
        args = ['--subscription', SUB, '-g', RG, '-n', ACTION, '--template-file', str(ROOT / TEMPLATE)]
        preview = az(['deployment', 'group', 'what-if', *args, '--result-format', 'FullResourcePayloads', '--no-pretty-print'], timeout=300)
        preview_path = OUT / 'arc-platform-roles-what-if.json'
        with preview_path.open('x') as stream: stream.write(json.dumps(preview, indent=2) + '\n')
        validate_preview(preview, unchanged, existing)
        record['whatIfSha256'] = hashlib.sha256(preview_path.read_bytes()).hexdigest()
        record['newRoleBindingCount'] = len(EXPECTED - existing)
        record['status'] = 'apply-pending'; path.write_text(json.dumps(record, indent=2) + '\n')
        result = az(['deployment', 'group', 'create', *args], timeout=600)
        record['deploymentId'] = result['id']; record['deploymentState'] = result['properties']['provisioningState']
        after = assignments()
        selected = [row for row in after if binding(row) in EXPECTED]
        if len(selected) != 7 or {binding(row) for row in selected} != EXPECTED or any(row['principalType'] != 'ServicePrincipal' for row in selected): raise RuntimeError('Exact independent role readback differs')
        if record['deploymentState'] != 'Succeeded': raise RuntimeError('Role deployment did not succeed')
        record['assignmentsReadback'] = selected
        record['vaultPublicAccessAfter'] = az(['keyvault', 'show', '--subscription', SUB, '-n', 'kv-lbox-weu-4766ea', '--query', 'properties.publicNetworkAccess'])
        if record['vaultPublicAccessAfter'] != 'Disabled': raise RuntimeError('Vault private boundary changed unexpectedly')
        record['status'] = 'complete-seven-approved-rg-and-vault-role-bindings'
    except subprocess.TimeoutExpired: record['status'] = 'uncertain-timeout-do-not-repeat'
    except (RuntimeError, ValueError, KeyError) as error:
        record['status'] = 'failed-inspect-before-resume'; record['errorType'] = type(error).__name__
        if isinstance(error, RuntimeError): record['error'] = str(error)
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat()
    path.write_text(json.dumps(record, indent=2) + '\n'); print(json.dumps(record, indent=2))
    return 0 if record['status'].startswith('complete-') else 2


if __name__ == '__main__':
    raise SystemExit(main())
