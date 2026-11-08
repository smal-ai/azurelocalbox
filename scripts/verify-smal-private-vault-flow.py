"""Verify ARM secret PUT and authenticated private GET using only a harmless marker.

No actual platform credential, owner token forwarding, public toggle or exemption.
The probe is soft-deleted after exact ID/value-hash verification, never purged.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import runpy
import socket
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / 'scripts/apply-smal-platform-rg.py'), run_name='private_probe_helpers')
az, SUB, RG, OUT = H['az'], H['SUB'], H['RG'], H['OUT']
HOST = 'kv-lbox-weu-4766ea.vault.azure.net'
VAULT = H['ID'] + '/providers/Microsoft.KeyVault/vaults/kv-lbox-weu-4766ea'
PROBE = 'localbox-private-path-probe-20261028'
ACTION = 'localbox-private-vault-probe-20261028'
TEMPLATE = 'infra/bicep/localbox-private-vault-probe.bicep'
URI_PREFIX = 'https://' + HOST + '/secrets/' + PROBE + '/'


def validate_preview(data):
    if data.get('status') != 'Succeeded': raise RuntimeError('Probe preview failed')
    relevant = []
    for row in data.get('changes', []):
        if row.get('changeType') == 'NoChange': continue
        if row.get('changeType') == 'Ignore' and row.get('resourceId', '').lower().startswith(H['ID'].lower() + '/providers/') and row.get('before') == row.get('after'):
            continue
        relevant.append(row)
    expected = (VAULT + '/secrets/' + PROBE).lower()
    if len(relevant) != 1 or relevant[0].get('changeType') != 'Create' or relevant[0].get('resourceId', '').lower() != expected:
        raise RuntimeError('Probe preview includes an unlisted effect')


def assert_private_boundary():
    addresses = {row[4][0] for row in socket.getaddrinfo(HOST, 443, family=socket.AF_INET)}
    if addresses != {'10.200.17.11'}: raise RuntimeError('Normal DNS is not the expected private endpoint')
    pna = az(['keyvault', 'show', '--subscription', SUB, '--name', 'kv-lbox-weu-4766ea', '--query', 'properties.publicNetworkAccess'])
    if pna != 'Disabled': raise RuntimeError('Vault must remain private throughout probe')
    return {'normalDnsAddresses': sorted(addresses), 'publicNetworkAccess': pna}


def main():
    head = H['approval_source']()
    for name in [TEMPLATE, 'scripts/verify-smal-private-vault-flow.py']:
        if (ROOT / name).read_bytes() != subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT): raise RuntimeError('Exact probe source differs from HEAD')
    path = OUT / 'private-vault-flow-probe.json'
    with path.open('x') as stream:
        record = {'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'status': 'pending', 'sourceCommit': head,
                  'scope': 'one-harmless-owned-vault-probe-only', 'actualCredentialUsedAsProbe': False,
                  'publicAccessChangeRequested': False, 'ownerTokenForwarded': False, 'purgeRequested': False,
                  'azureLocalRpFullDeploymentProven': False}
        stream.write(json.dumps(record, indent=2) + '\n')
    try:
        if az(['ad', 'signed-in-user', 'show', '--query', 'id']) != H['PRINCIPAL']: raise RuntimeError('Approved identity changed')
        record['before'] = assert_private_boundary()
        existing = az(['keyvault', 'secret', 'list', '--subscription', SUB, '--vault-name', 'kv-lbox-weu-4766ea', '--query', '[].name'])
        deleted = az(['keyvault', 'secret', 'list-deleted', '--subscription', SUB, '--vault-name', 'kv-lbox-weu-4766ea', '--query', '[].name'])
        if PROBE in existing or PROBE in deleted: raise RuntimeError('Probe identity exists; inspect instead of overwrite/recover')
        if az(['deployment', 'group', 'list', '--subscription', SUB, '--resource-group', RG, '--query', "[?name=='" + ACTION + "'].name"]): raise RuntimeError('Probe deployment identity already exists')
        # A public, random marker, never a deployment credential or access token.
        value = 'NON-CREDENTIAL-PRIVATE-FLOW-PROBE:' + str(uuid.uuid4())
        digest = hashlib.sha256(value.encode()).hexdigest()
        parameters = json.dumps({'probeValue': {'value': value}})
        base = ['az', 'deployment', 'group']
        args = ['--subscription', SUB, '--resource-group', RG, '--name', ACTION, '--template-file', str(ROOT / TEMPLATE), '--parameters', '@-', '--only-show-errors', '--output', 'json']
        preview = subprocess.run([*base, 'what-if', *args, '--result-format', 'FullResourcePayloads', '--no-pretty-print'], input=parameters, capture_output=True, text=True, timeout=300)
        if preview.returncode: raise RuntimeError('Probe preview rejected; raw output suppressed')
        data = json.loads(preview.stdout); validate_preview(data)
        # Secure parameter bodies/preview after-properties are not retained, even for this marker.
        record['previewChanges'] = [{'id': row.get('resourceId'), 'changeType': row.get('changeType')} for row in data.get('changes', [])]
        record['status'] = 'arm-put-pending'; path.write_text(json.dumps(record, indent=2) + '\n')
        result = subprocess.run([*base, 'create', *args], input=parameters, capture_output=True, text=True, timeout=600)
        if result.returncode: raise RuntimeError('ARM secret write failed; preserve probe identity and inspect')
        response = json.loads(result.stdout)
        record['deploymentId'] = response['id']; record['deploymentState'] = response['properties']['provisioningState']
        record['afterArmWrite'] = assert_private_boundary()
        actual = az(['keyvault', 'secret', 'show', '--subscription', SUB, '--vault-name', 'kv-lbox-weu-4766ea', '--name', PROBE])
        if not actual['id'].lower().startswith(URI_PREFIX.lower()) or hashlib.sha256(actual['value'].encode()).hexdigest() != digest:
            raise RuntimeError('Private authenticated readback identity/value mismatch; do not delete')
        record['privateAuthenticatedReadbackMatched'] = True
        record['probeVersionId'] = actual['id']
        versions = az(['keyvault', 'secret', 'list-versions', '--subscription', SUB, '--vault-name', 'kv-lbox-weu-4766ea', '--name', PROBE, '--query', '[].id'])
        if versions != [actual['id']]: raise RuntimeError('Probe gained another version; preserve instead of deleting it')
        record['status'] = 'owned-probe-soft-delete-pending'; path.write_text(json.dumps(record, indent=2) + '\n')
        removed = az(['keyvault', 'secret', 'delete', '--subscription', SUB, '--vault-name', 'kv-lbox-weu-4766ea', '--name', PROBE, '--query', '{id:id,deletedDate:deletedDate,scheduledPurgeDate:scheduledPurgeDate}'])
        record['softDeletedProbe'] = removed
        record['after'] = assert_private_boundary()
        record['status'] = 'arm-secret-write-and-private-authenticated-read-succeeded'
    except subprocess.TimeoutExpired: record['status'] = 'uncertain-timeout-do-not-repeat'
    except (RuntimeError, ValueError, KeyError) as error: record['status'] = 'failed-inspect-before-resume'; record['errorType'] = type(error).__name__
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat()
    path.write_text(json.dumps(record, indent=2) + '\n'); print(json.dumps(record, indent=2))
    return 0 if record['status'] == 'arm-secret-write-and-private-authenticated-read-succeeded' else 2


if __name__ == '__main__':
    raise SystemExit(main())
