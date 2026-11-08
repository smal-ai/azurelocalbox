"""Read/reconcile the deployed prerequisite state and inherited vault policy. No writes."""
from datetime import datetime, timezone
import argparse
import json
from pathlib import Path
import runpy
import re

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / 'scripts/apply-smal-platform-rg.py'), run_name='policy_read_helpers')
az, SUB, RG, OUT = H['az'], H['SUB'], H['RG'], H['OUT']
VAULT = H['ID'] + '/providers/Microsoft.KeyVault/vaults/kv-lbox-weu-4766ea'
MG = 'c6e67968-af25-4557-ab8b-06b693048d3b'


def main(receipt='platform-policy-conflict-readback'):
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,80}', receipt): raise RuntimeError('Invalid read-only receipt name')
    target = OUT / (receipt + '.json')
    with target.open('x') as stream:
        record = {'atUtc': datetime.now(timezone.utc).isoformat(), 'status': 'pending-read-only-reconciliation'}
        stream.write(json.dumps(record, indent=2) + '\n')
    vault = az(['keyvault', 'show', '--subscription', SUB, '--name', 'kv-lbox-weu-4766ea', '--query', '{id:id,publicNetworkAccess:properties.publicNetworkAccess,rbac:properties.enableRbacAuthorization,purgeProtection:properties.enablePurgeProtection,softDeleteDays:properties.softDeleteRetentionInDays}'])
    policy = az(['policy', 'definition', 'show', '--management-group', MG, '--name', 'KeyVault_PublicNetwork_Modify', '--query', '{id:id,displayName:displayName,rule:policyRule}'])
    events = az(['monitor', 'activity-log', 'list', '--subscription', SUB, '--resource-id', VAULT, '--offset', '2h', '--query', "[?operationName.value=='Microsoft.Authorization/policies/modify/action'].{atUtc:eventTimestamp,correlationId:correlationId,properties:properties}"])
    evidence = []
    for event in events:
        props = event.get('properties') or {}
        for item in json.loads(props.get('policies') or '[]'):
            if item.get('policyDefinitionName') != 'KeyVault_PublicNetwork_Modify': continue
            evidence.append({'atUtc': event['atUtc'], 'correlationId': event['correlationId'],
                             'definitionId': item['policyDefinitionId'], 'assignmentId': item['policyAssignmentId'],
                             'effect': item['policyDefinitionEffect'], 'modifiedFields': json.loads(props.get('fields') or '[]'),
                             'exemptionIds': item.get('policyExemptionIds')})
    record.update({'vault': vault, 'policyDefinition': policy, 'matchingModifyEvents': evidence,
                   'deploymentState': az(['deployment', 'group', 'show', '--subscription', SUB, '--resource-group', RG, '--name', 'localbox-platform-prereqs-20261028', '--query', 'properties.provisioningState']),
                   'vaultAudit': az(['monitor', 'diagnostic-settings', 'list', '--subscription', SUB, '--resource', VAULT, '--query', '[].{id:id,name:name,storageAccountId:storageAccountId,logs:logs[].{category:category,enabled:enabled}}']),
                   'auditLifecycle': az(['storage', 'account', 'management-policy', 'show', '--subscription', SUB, '--resource-group', RG, '--account-name', 'stlboxdiagweu4766ea']),
                   'diagnosticLock': az(['lock', 'list', '--subscription', SUB, '--resource-group', RG, '--resource-name', 'stlboxdiagweu4766ea', '--resource-type', 'Microsoft.Storage/storageAccounts', '--query', '[].{id:id,name:name,level:level}']),
                   'stateQueryMayLagActivityLog': True, 'arcRegistrationOrClusterDeploymentPerformed': False,
                   'publicReenableOrPolicyExemptionAttempted': False, 'apiDowngradeToEvadePolicyAttempted': False,
                   'ignoreTagOrUnapprovedPerimeterCreated': False, 'originalApplyReceiptRetained': True})
    record['status'] = 'confirmed-policy-modification-blocks-approved-public-vault-boundary' if vault['publicNetworkAccess'] == 'Disabled' and evidence else 'needs-further-read-only-reconciliation'
    target.write_text(json.dumps(record, indent=2) + '\n'); print(json.dumps(record, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', default='platform-policy-conflict-readback')
    main(parser.parse_args().receipt)
