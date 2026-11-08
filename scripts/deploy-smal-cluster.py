"""Bounded approved Azure Local deployment stages. No automatic replay.

Stages: secrets, prerequisites, cluster-role, validate, deploy.
Each apply has a create-only receipt and fixed ARM deployment identity. Private
credential material is used only in process memory and secure ARM parameters.
"""
import argparse
import base64
import contextlib
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import socket
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / 'scripts/apply-smal-platform-rg.py'), run_name='cluster_helpers')
R = runpy.run_path(str(ROOT / 'scripts/apply-smal-arc-platform-roles.py'), run_name='cluster_role_helpers')
TRANSPORT = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='cluster_private_transport')
OUT = ROOT / 'docs/deployment-2026-10-29'
SUB, RG, SCOPE = H['SUB'], H['RG'], H['ID']
CLUSTER = SCOPE + '/providers/Microsoft.AzureStackHCI/clusters/smal-localbox-01'
SETTINGS = CLUSTER + '/deploymentSettings/default'
VAULT = R['VAULT']
API = '2025-09-15-preview'
TEMPLATES = {'secrets': 'infra/arm/localbox-platform-secrets.json', 'prerequisites': 'infra/arm/localbox-cluster-prerequisites.json',
             'cluster-role': 'infra/bicep/localbox-cluster-vault-role.bicep', 'validate': 'infra/arm/localbox-cluster-settings.json', 'deploy': 'infra/arm/localbox-cluster-settings.json'}
SECRET_NAMES = ['smal-localbox-01-' + suffix for suffix in ['LocalAdminCredential', 'AzureStackLCMUserCredential', 'WitnessStorageKey']]


def az(args, parameters=None, timeout=120):
    result = subprocess.run(['az', *args, '--only-show-errors', '--output', 'json'],
                            input=json.dumps(parameters) if parameters is not None else None,
                            capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        # Error output can echo secure ARM bodies. Never persist or print it.
        raise RuntimeError('Azure request failed; inspect resource/deployment state. Raw diagnostics suppressed.')
    return json.loads(result.stdout) if result.stdout.strip() else None


def rest(resource):
    return az(['rest', '--method', 'get', '--url', 'https://management.azure.com' + resource + '?api-version=' + API])


def source_guard():
    head = H['approval_source']()
    approval = json.loads((H['OUT'] / 'cloud-apply-approval.json').read_text())
    if approval.get('listedRgAndVaultScopedRoleEffectsApproved') is not True or approval.get('s2dOnlyExactRawGuestDataDeviceAllowlistApproved') is not True:
        raise RuntimeError('Exact staged role/storage approval missing')
    names = [*set(TEMPLATES.values()), 'scripts/deploy-smal-cluster.py', 'scripts/derive-smal-cluster-templates.py',
             'scripts/seal-smal-platform-credentials.ps1', 'scripts/inspect-smal-cluster-inputs.ps1', 'scripts/smal-private-powershell.py',
             'docs/deployment-2026-10-29/witness-deployment-blocker.json']
    for name in names:
        if (ROOT / name).read_bytes() != subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT):
            raise RuntimeError('Exact deployment source differs from committed HEAD')
    derived = runpy.run_path(str(ROOT / 'scripts/derive-smal-cluster-templates.py'), run_name='cluster_derivation_check')['build']()
    for name, value in derived.items():
        if json.loads((ROOT / 'infra/arm' / name).read_text()) != value: raise RuntimeError('Derived template differs from pinned source/approved inputs')
    return head


def verify_inputs(proof):
    p = json.loads((H['OUT'] / 'cloud-apply-proposal.json').read_text())
    if proof.get('status') != 'complete': raise RuntimeError('Private input inspection incomplete')
    data = proof['result']; nodes = data.get('nodes', [])
    if len(nodes) != 2 or {row['name'] for row in nodes} != set(R['NODES']): raise RuntimeError('Exact node set differs')
    expected_vm_ids = {'LB-NODE01': '3adff629-2f67-449b-ab32-8a8748c46f34', 'LB-NODE02': '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3'}
    for row in nodes:
        guest = row['guest']; name = row['name']
        if (row['vmId'] != expected_vm_ids[name] or guest['name'] != name or guest['domainRole'] != 2
                or guest['build'] != '26100.33650' or guest['bootstrap'] != 'Succeeded'
                or guest['nonPrimordialPoolCount'] != 0 or guest['defenderEnabled'] is not True):
            raise RuntimeError('Standalone node/build/bootstrap/protection/pool state differs')
        adapters = guest['adapters']
        if len(adapters) != 4 or {x['Name'] for x in adapters} != {'MGMT1', 'MGMT2', 'STORAGEA', 'STORAGEB'} or any(x['Status'] != 'Up' for x in adapters):
            raise RuntimeError('Approved live adapters differ')
        address = '10.64.0.' + ('11' if name == 'LB-NODE01' else '12')
        if not any(x['InterfaceAlias'] == 'MGMT1' and x['IPAddress'] == address and x['PrefixLength'] == 24 for x in guest['ipv4']): raise RuntimeError('Node management address differs')
        disks = guest['disks']; backing = row['backing']
        if len(disks) != 5 or len(backing) != 5 or {x['lun'] for x in backing} != set(range(5)): raise RuntimeError('Exact five-disk backing set differs')
        raw = [disk for disk in disks if not disk['isBoot'] and not disk['isSystem']]
        if len(raw) != 4 or {disk['uniqueId'] for disk in raw} != set(p['dataDeviceAllowlist'][name]): raise RuntimeError('Exact approved S2D unique-ID allowlist differs')
        for disk in disks:
            matches = [item for item in backing if item['lun'] == disk['lun']]
            if len(matches) != 1: raise RuntimeError('Guest/host disk LUN mapping ambiguous')
            host = matches[0]; ident = uuid.UUID(host['diskId'])
            # Hyper-V SCSI NAA serial from VHD GUID bytes, independently checked
            # against the guest allowlist rather than relying on disk size/order.
            unique = '60022480' + (ident.bytes_le[:6] + ident.bytes[-6:]).hex().upper()
            path = 'V:\\AzureLocalBox\\Guests\\local-guests-20261028-01\\' + name + '\\' + ('OS.vhdx' if disk['lun'] == 0 else 'S2D-' + str(disk['lun']) + '.vhdx')
            if host['path'].lower() != path.lower() or host['parentPath'] or host['controllerType'] != 'SCSI' or host['controllerNumber'] != 0 or unique != disk['uniqueId'] or host['size'] != disk['size']:
                raise RuntimeError('Exact VHD path/GUID/LUN/guest unique-ID mapping differs')
            if disk['lun'] == 0:
                if not disk['isBoot'] or not disk['isSystem'] or disk['partitionStyle'] != 'GPT': raise RuntimeError('OS disk identity differs')
            elif disk['partitionStyle'] != 'RAW' or disk['size'] != p['dataDeviceSizeBytes']:
                raise RuntimeError('Approved data device is no longer blank or size differs')
    ad = data['ad']; lcm = ad['lcm']
    if (ad['domain'] != 'ad.localbox.test' or ad['ou'] != p['newClusterOu'] or ad['inheritanceBlocked'] is not True
            or lcm['user'] != 'lboxdeploy' or lcm['enabled'] is not True or lcm['expired'] or lcm['neverExpires'] or lcm['groupCount'] != 0):
        raise RuntimeError('Approved AD OU/LCM account state differs')


def private_inspection(stage):
    name = 'cluster-inputs-' + stage + '-20261029'
    code = TRANSPORT['main']('scripts/inspect-smal-cluster-inputs.ps1', name)
    proof = json.loads((TRANSPORT['OUT'] / ('private-ssh-' + name + '.json')).read_text())
    if code != 0: raise RuntimeError('Live private cluster input inspection failed')
    verify_inputs(proof)
    return str((TRANSPORT['OUT'] / ('private-ssh-' + name + '.json')).relative_to(ROOT))


def require_witness_compatibility(account, constraint):
    expected = SCOPE + '/providers/Microsoft.Storage/storageAccounts/stlboxwitweu4766ea'
    if account.get('id', '').lower() != expected.lower() or account.get('publicNetworkAccess') != 'Disabled':
        raise RuntimeError('Exact private witness account differs')
    if constraint.get('sharedKeyPermittedByOwnerPolicy') is not True or account.get('allowSharedKeyAccess') is not True:
        raise RuntimeError('Two-node Cloud Witness blocked: Shared Key is disabled and prohibited by owner policy. No credentials or cluster resources will be created. A reviewed topology/witness decision is required.')


def cloud_preflight():
    account = az(['account', 'show', '--subscription', SUB])
    if account.get('id') != SUB or account.get('tenantId') != H['TENANT'] or az(['ad', 'signed-in-user', 'show', '--query', 'id']) != H['PRINCIPAL']:
        raise RuntimeError('Approved account/subscription/tenant differs')
    witness = az(['storage', 'account', 'show', '--subscription', SUB, '-g', RG, '-n', 'stlboxwitweu4766ea', '--query', '{id:id,publicNetworkAccess:publicNetworkAccess,allowSharedKeyAccess:allowSharedKeyAccess}'])
    constraint = json.loads((OUT / 'witness-deployment-blocker.json').read_text())
    require_witness_compatibility(witness, constraint)
    nodes = az(['connectedmachine', 'list', '--subscription', SUB, '-g', RG, '--query', '[].{id:id,name:name,status:status,provisioningState:provisioningState,location:location,identity:identity,agentVersion:agentVersion,osVersion:osVersion}'])
    bootstrap = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-arc-registration-after-recovery-20261029.json').read_text())
    R['verify_nodes'](nodes, bootstrap)
    assigned = R['assignments']()
    if {R['binding'](row) for row in assigned} & R['EXPECTED'] != R['EXPECTED']: raise RuntimeError('Approved seven prerequisite role bindings missing')
    addresses = {row[4][0] for row in socket.getaddrinfo('kv-lbox-weu-4766ea.vault.azure.net', 443, family=socket.AF_INET)}
    if addresses != {'10.200.17.11'}: raise RuntimeError('Vault private DNS differs')
    vault = az(['keyvault', 'show', '--subscription', SUB, '-n', 'kv-lbox-weu-4766ea', '--query', '{id:id,pna:properties.publicNetworkAccess,rbac:properties.enableRbacAuthorization}'])
    if vault['id'].lower() != VAULT.lower() or vault['pna'] != 'Disabled' or vault['rbac'] is not True: raise RuntimeError('Private RBAC vault differs')


def previous(stage):
    data = json.loads((OUT / ('cluster-' + stage + '-receipt.json')).read_text())
    if data.get('status') != 'complete' or data.get('deploymentState') != 'Succeeded': raise RuntimeError('Earlier stage has not independently succeeded: ' + stage)
    return data


def expected_effects(stage, cluster_principal=None):
    if stage == 'secrets': return {(VAULT + '/secrets/' + name).lower() for name in SECRET_NAMES}
    if stage == 'prerequisites': return {CLUSTER.lower(), *((SCOPE + '/providers/Microsoft.HybridCompute/machines/' + node + '/providers/Microsoft.AzureStackHCI/edgeDevices/default').lower() for node in R['NODES'])}
    if stage in ['validate', 'deploy']: return {SETTINGS.lower()}
    return None


def check_preview(stage, data, owned, cluster_principal=None):
    if data.get('status') != 'Succeeded': raise RuntimeError('What-if failed')
    wanted = expected_effects(stage, cluster_principal); seen = set(); summary = []
    for row in data.get('changes', []):
        kind = row.get('changeType'); rid = row.get('resourceId', '').lower()
        if kind in ['Ignore', 'NoChange'] and rid in owned and row.get('before') == row.get('after'):
            continue
        if stage == 'cluster-role':
            after = row.get('after', {}); p = after.get('properties', {})
            if (kind != 'Create' or not rid.startswith(VAULT.lower() + '/providers/microsoft.authorization/roleassignments/')
                    or after.get('type', '').lower() != 'microsoft.authorization/roleassignments'
                    or p.get('principalId') != cluster_principal or p.get('principalType') not in [None, 'ServicePrincipal']
                    or p.get('scope', VAULT).lower() != VAULT.lower()
                    or p.get('roleDefinitionId', '').lower() != '/subscriptions/' + SUB + '/providers/microsoft.authorization/roledefinitions/4633458b-17de-408a-b874-0445c86b69e6'):
                raise RuntimeError('Unlisted cluster identity role effect')
        else:
            permitted = ['Create', 'Modify'] if stage == 'deploy' else ['Create']
            if rid not in wanted or kind not in permitted: raise RuntimeError('Unexpected resource effect in ' + stage)
        if rid in seen: raise RuntimeError('Duplicate effect in preview')
        seen.add(rid); summary.append({'id': row['resourceId'], 'changeType': kind})
    if (stage == 'cluster-role' and len(seen) != 1) or (stage != 'cluster-role' and seen != wanted): raise RuntimeError('Preview missing expected effects')
    # Never retain secret after-properties, even when what-if used harmless markers.
    return summary


def new_rsa_key():
    # Linux anonymous RAM-backed descriptor. Neither private PEM nor credentials
    # are written to a filesystem path. Child OpenSSL receives the explicit fd.
    key = subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:4096'], capture_output=True, check=True, timeout=60).stdout
    fd = os.memfd_create('localbox-one-use-rsa', os.MFD_CLOEXEC)
    os.fchmod(fd, 0o600); os.write(fd, key); del key
    try:
        modulus = subprocess.run(['openssl', 'rsa', '-in', '/proc/self/fd/' + str(fd), '-modulus', '-noout'], pass_fds=(fd,), capture_output=True, check=True, timeout=15).stdout.decode().strip().split('=', 1)[1]
        return fd, base64.b64encode(bytes.fromhex(modulus)).decode()
    except BaseException:
        os.close(fd); raise


def decrypt_envelope(fd, ciphertext):
    os.lseek(fd, 0, os.SEEK_SET)
    result = subprocess.run(['openssl', 'pkeyutl', '-decrypt', '-inkey', '/proc/self/fd/' + str(fd), '-pkeyopt', 'rsa_padding_mode:oaep', '-pkeyopt', 'rsa_oaep_md:sha256', '-pkeyopt', 'rsa_mgf1_md:sha256'],
                            input=base64.b64decode(ciphertext, validate=True), pass_fds=(fd,), capture_output=True, timeout=15)
    if result.returncode: raise RuntimeError('Sealed envelope verification/decryption failed')
    return json.loads(result.stdout)


def secret_parameters():
    fd, modulus = new_rsa_key(); nonce = uuid.uuid4().hex
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            code = TRANSPORT['main']('scripts/seal-smal-platform-credentials.ps1', 'sealed-platform-credentials-20261029', {'modulus': modulus, 'nonce': nonce})
        proof = json.loads((TRANSPORT['OUT'] / 'private-ssh-sealed-platform-credentials-20261029.json').read_text())
        if code != 0 or proof.get('status') != 'complete': raise RuntimeError('Private credential sealing failed')
        sealed = proof['result']
        if sealed['nonce'] != nonce or sealed['scheme'] != 'RSA4096-OAEP-SHA256': raise RuntimeError('Envelope identity differs')
        envelope = decrypt_envelope(fd, sealed['ciphertext'])
        if envelope.get('nonce') != nonce or set(envelope.get('values', {})) != {'local', 'domain'}: raise RuntimeError('Decrypted envelope identity differs')
        values = envelope['values']
        for key, prefix in [('local', b'Administrator:'), ('domain', b'LOCALBOX\\lboxdeploy:')]:
            clear = base64.b64decode(values[key], validate=True)
            if not clear.startswith(prefix) or len(clear) != len(prefix) + 40: raise RuntimeError('Credential binding/format differs')
            del clear
        return {'localCredential': {'value': values['local']}, 'domainCredential': {'value': values['domain']}}
    finally:
        os.close(fd)


def deploy(stage, wait_seconds=1200):
    head = source_guard()
    path = OUT / ('cluster-' + stage + '-receipt.json')
    action = 'localbox-cluster-' + stage + '-20261029'
    record = {'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'sourceCommit': head, 'stage': stage, 'deploymentName': action,
              'status': 'pending', 'publicAccessChangeRequested': False, 'subscriptionWideGrantRequested': False,
              'platformReadinessVerified': False}
    with path.open('x') as stream: stream.write(json.dumps(record, indent=2) + '\n')
    def save(): path.write_text(json.dumps(record, indent=2) + '\n')
    try:
        cloud_preflight()
        if az(['deployment', 'group', 'list', '--subscription', SUB, '-g', RG, '--query', "[?name=='" + action + "'].name"]): raise RuntimeError('Deployment identity already exists, reconcile before retry')
        parameters = None; principal = None
        if stage == 'secrets':
            proof = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-cluster-inputs-20261029.json').read_text()); verify_inputs(proof)
            active = az(['keyvault', 'secret', 'list', '--subscription', SUB, '--vault-name', 'kv-lbox-weu-4766ea', '--query', '[].name'])
            deleted = az(['keyvault', 'secret', 'list-deleted', '--subscription', SUB, '--vault-name', 'kv-lbox-weu-4766ea', '--query', '[].name'])
            if set(SECRET_NAMES) & (set(active) | set(deleted)): raise RuntimeError('Platform secret identity exists. No overwrite/recovery/version replay.')
            parameters = {'localCredential': {'value': 'NON-CREDENTIAL-PREVIEW'}, 'domainCredential': {'value': 'NON-CREDENTIAL-PREVIEW'}}
        elif stage == 'prerequisites':
            previous('secrets'); record['privateInputsReceipt'] = private_inspection(stage)
            resources = az(['resource', 'list', '--subscription', SUB, '-g', RG, '--query', '[].id'])
            if expected_effects(stage) & {rid.lower() for rid in resources}: raise RuntimeError('Cluster/edge prerequisite exists; inspect instead of replaying creation')
        elif stage == 'cluster-role':
            previous('prerequisites'); actual = rest(CLUSTER)
            if actual['id'].lower() != CLUSTER.lower() or actual['location'] != 'westeurope' or actual['identity']['tenantId'] != H['TENANT'] or actual['identity']['type'] != 'SystemAssigned': raise RuntimeError('Created cluster identity/region differs')
            principal = actual['identity']['principalId']; uuid.UUID(principal)
            record['inspectedClusterIdentity'] = actual['identity']
            parameters = {'clusterPrincipalId': {'value': principal}}
            if any(row.get('principalId') == principal and row.get('roleDefinitionId', '').endswith('/4633458b-17de-408a-b874-0445c86b69e6') for row in R['assignments']()): raise RuntimeError('Cluster vault role already exists; inspect instead of duplicating')
        elif stage in ['validate', 'deploy']:
            previous('cluster-role')
            if stage == 'deploy':
                previous('validate')
                if rest(SETTINGS)['properties'].get('provisioningState') != 'Succeeded': raise RuntimeError('Current deployment settings have not succeeded')
            record['privateInputsReceipt'] = private_inspection(stage)
            # Verify only metadata, not credential values. Secret existence alone
            # is not proof of node/RP data-plane acceptance.
            metadata = az(['keyvault', 'secret', 'list', '--subscription', SUB, '--vault-name', 'kv-lbox-weu-4766ea', '--query', '[].{name:name,enabled:attributes.enabled}'])
            if {row['name'] for row in metadata if row['enabled']} & set(SECRET_NAMES) != set(SECRET_NAMES): raise RuntimeError('Required enabled platform secret metadata missing')
            parameters = {'deploymentMode': {'value': 'Validate' if stage == 'validate' else 'Deploy'}}
        owned = {row['id'].lower() for row in az(['resource', 'list', '--subscription', SUB, '-g', RG, '--query', '[].{id:id}'])}
        args = ['--subscription', SUB, '-g', RG, '-n', action, '--template-file', str(ROOT / TEMPLATES[stage])]
        if parameters is not None: args += ['--parameters', '@-']
        preview = az(['deployment', 'group', 'what-if', *args, '--result-format', 'FullResourcePayloads', '--no-pretty-print'], parameters, timeout=300)
        record['previewChanges'] = check_preview(stage, preview, owned, principal)
        record['templateSha256'] = hashlib.sha256((ROOT / TEMPLATES[stage]).read_bytes()).hexdigest()
        if stage == 'secrets': parameters = secret_parameters()
        record['status'] = 'apply-pending'; save()
        az(['deployment', 'group', 'create', *args, '--no-wait'], parameters, timeout=180)
        parameters = None
        record['status'] = 'submitted-observe-before-continuing'; save()
        deadline = time.monotonic() + wait_seconds
        while True:
            deployment = az(['deployment', 'group', 'show', '--subscription', SUB, '-g', RG, '-n', action, '--query', '{id:id,state:properties.provisioningState,code:properties.error.code}'])
            record['deploymentId'] = deployment['id']; record['deploymentState'] = deployment['state']; record['deploymentErrorCode'] = deployment.get('code'); save()
            if deployment['state'] in ['Succeeded', 'Failed', 'Canceled']: break
            if time.monotonic() >= deadline: raise TimeoutError('Still submitted')
            time.sleep(20)
        if record['deploymentState'] != 'Succeeded': raise RuntimeError('ARM/service stage failed. Preserve state and inspect deployment operations, do not replay.')
        if stage == 'prerequisites':
            cluster = rest(CLUSTER); record['clusterReadback'] = {'id': cluster['id'], 'location': cluster['location'], 'identity': cluster['identity'], 'properties': cluster['properties']}
        elif stage == 'cluster-role':
            selected = [row for row in R['assignments']() if row.get('principalId') == principal and row.get('scope', '').lower() == VAULT.lower() and row.get('roleDefinitionId', '').endswith('/4633458b-17de-408a-b874-0445c86b69e6')]
            if len(selected) != 1: raise RuntimeError('Cluster vault role readback differs')
            record['clusterVaultRole'] = selected[0]
        elif stage in ['validate', 'deploy']:
            state = rest(SETTINGS); record['serviceProvisioningState'] = state['properties'].get('provisioningState')
            if record['serviceProvisioningState'] != 'Succeeded': raise RuntimeError('Service deployment settings did not succeed')
        else:
            record['secretMetadata'] = az(['keyvault', 'secret', 'list', '--subscription', SUB, '--vault-name', 'kv-lbox-weu-4766ea', '--query', '[].{name:name,id:id,enabled:attributes.enabled}'])
            if {row['name'] for row in record['secretMetadata'] if row['enabled']} & set(SECRET_NAMES) != set(SECRET_NAMES): raise RuntimeError('Published secret metadata readback differs')
        record['vaultPublicAccessAfter'] = az(['keyvault', 'show', '--subscription', SUB, '-n', 'kv-lbox-weu-4766ea', '--query', 'properties.publicNetworkAccess'])
        if record['vaultPublicAccessAfter'] != 'Disabled': raise RuntimeError('Vault private boundary changed unexpectedly')
        record['status'] = 'complete'
    except (subprocess.TimeoutExpired, TimeoutError): record['status'] = 'uncertain-or-still-running-inspect-do-not-repeat'
    except (RuntimeError, ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        record['status'] = 'failed-inspect-before-resume'; record['errorType'] = type(error).__name__
        if isinstance(error, RuntimeError): record['error'] = str(error)
    except KeyboardInterrupt: record['status'] = 'interrupted-inspect-do-not-repeat'
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat(); save()
    print(json.dumps(record, indent=2))
    return 0 if record['status'] == 'complete' else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=list(TEMPLATES))
    parser.add_argument('--wait-seconds', type=int, default=1200)
    options = parser.parse_args()
    if not 60 <= options.wait_seconds <= 3600: parser.error('wait limit must be 60–3600 seconds')
    raise SystemExit(deploy(options.stage, options.wait_seconds))
