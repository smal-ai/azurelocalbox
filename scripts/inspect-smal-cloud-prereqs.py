"""Read existing identity, provider states and inherited policy identities. No writes."""
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-28'
SUB = '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea'
TENANT = 'c6e67968-af25-4557-ab8b-06b693048d3b'
PRINCIPAL = '82f494a8-b9f5-46fc-b0f7-c70be0572a63'
PROVIDERS = ['Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity',
             'Microsoft.AzureStackHCI', 'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration',
             'Microsoft.ExtendedLocation', 'Microsoft.ResourceConnector', 'Microsoft.HybridContainerService',
             'Microsoft.Attestation', 'Microsoft.Storage', 'Microsoft.Insights', 'Microsoft.KeyVault']


def az(arguments):
    result = subprocess.run(['az', *arguments, '--only-show-errors', '--output', 'json'],
                            capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError('Read-only Azure query failed; raw diagnostics suppressed')
    return json.loads(result.stdout)


def verify_identity(account, principal):
    if account.get('id') != SUB or account.get('tenantId') != TENANT or account.get('state') != 'Enabled' or principal != PRINCIPAL:
        raise RuntimeError('Existing approved identity/subscription changed; no activation or fallback')


def summarise_providers(rows):
    # ARM namespaces are case-insensitive. The service returns microsoft.insights
    # in lower case, unlike most of the other namespace display forms.
    states = {row['namespace'].casefold(): row['registrationState'] for row in rows}
    return [{'namespace': name, 'registrationState': states.get(name.casefold(), 'not-returned'),
             'registered': states.get(name.casefold()) == 'Registered'} for name in PROVIDERS]


def inspect():
    account = az(['account', 'show', '--subscription', SUB,
                  '--query', '{id:id,tenantId:tenantId,state:state}'])
    principal = az(['ad', 'signed-in-user', 'show', '--query', 'id'])
    verify_identity(account, principal)
    provider_rows = az(['provider', 'list', '--subscription', SUB,
                        '--query', '[].{namespace:namespace,registrationState:registrationState}'])
    policies = az(['policy', 'assignment', 'list', '--scope', '/subscriptions/' + SUB, '--filter', 'atScope()',
                   '--query', '[].{id:id,name:name,displayName:displayName,scope:scope,definitionId:policyDefinitionId,enforcementMode:enforcementMode}'])
    # Never export arbitrary policy parameter values, tokens or access credentials.
    return {'atUtc': datetime.now(timezone.utc).isoformat(), 'subscriptionId': SUB, 'tenantId': TENANT,
            'approvedPrincipalId': principal, 'identityRechecked': True,
            'providerStates': summarise_providers(provider_rows), 'inheritedPolicyIdentities': policies,
            'policyRulesAndEffectiveRolePermissionsVerified': False, 'providerRegistrationPerformed': False,
            'roleAssignmentOrActivationPerformed': False, 'resourcesCreated': 0,
            'registrationRegionOrCloudCostsApproved': False, 'platformReadinessVerified': False}


def main(receipt):
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,63}', receipt):
        raise RuntimeError('Invalid receipt name')
    path = OUT / (receipt + '.json')
    with path.open('x') as stream:
        record = {'status': 'pending', 'scope': 'read-only-cloud-prerequisite-observation'}
        stream.write(json.dumps(record, indent=2) + '\n')
    try:
        record['result'] = inspect()
        record['status'] = 'complete'
    except (RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        record['status'] = 'failed-no-mutation'
        record['errorType'] = type(error).__name__
    path.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))
    return 0 if record['status'] == 'complete' else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', required=True)
    args = parser.parse_args()
    raise SystemExit(main(args.receipt))
