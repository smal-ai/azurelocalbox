"""Correct only the owned LCM secret's username encoding; never rotate a password.

Requires the exact terminal initial-validation error, one original secret version,
and constant-time agreement with the existing host-bound LCM credential. Publishes
one new version via private HTTPS. Prior secret/failed validation remain intact.
"""
import base64
import contextlib
from datetime import datetime, timezone
import hashlib
import hmac
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
REC = runpy.run_path(str(ROOT / 'scripts/smal-validation-recovery.py'),run_name='lcm_format_recovery_guard')
D = REC['D']; OUT = D['OUT']; NAME = D['NAME'] + '-AzureStackLCMUserCredential'
URI = 'https://kv-lbox-weu-4766ea.vault.azure.net/secrets/' + NAME


def private_vault(method,token,body=None):
    request = urllib.request.Request(URI + '?api-version=7.4',data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization':'Bearer ' + token,'Content-Type':'application/json'},method=method)
    try:
        with urllib.request.urlopen(request,timeout=60) as response: return json.load(response)
    except urllib.error.HTTPError:
        raise RuntimeError('Private vault request rejected. Raw response suppressed; inspect receipt before another write.') from None


def versions():
    return D['az'](['keyvault','secret','list-versions','--subscription',D['SUB'],'--vault-name','kv-lbox-weu-4766ea','--name',NAME,'--query','[].{id:id,enabled:attributes.enabled}'])


def sealed_lcm():
    fd,modulus = D['L']['new_rsa_key'](); nonce = uuid.uuid4().hex
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            code = D['T']['main']('scripts/seal-smal-lcm-format-fix.ps1','sealed-lcm-format-fix-20261029',{'modulus':modulus,'nonce':nonce})
        proof = json.loads((D['T']['OUT'] / 'private-ssh-sealed-lcm-format-fix-20261029.json').read_text())
        if code != 0 or proof.get('status') != 'complete': raise RuntimeError('Existing LCM envelope transport failed; no vault write requested')
        sealed = proof['result']
        if sealed['nonce'] != nonce or sealed['scheme'] != 'RSA4096-OAEP-SHA256': raise RuntimeError('LCM envelope scheme/nonce differs')
        value = D['L']['decrypt_envelope'](fd,sealed['ciphertext'])
        if value.get('nonce') != nonce or set(value.get('values',{})) != {'domain'}: raise RuntimeError('LCM-only envelope contents differ')
        encoded = value['values']['domain']; raw = base64.b64decode(encoded,validate=True)
        if not raw.startswith(b'lboxdeploy:') or len(raw) != len(b'lboxdeploy:') + 40: raise RuntimeError('LCM unqualified account/length differs')
        return encoded
    finally: os.close(fd)


def main():
    head = D['A']['source_guard'](['scripts/correct-smal-lcm-credential-format.py','scripts/smal-validation-recovery.py','scripts/deploy-smal-three-node-cluster.py',
        'scripts/seal-smal-lcm-format-fix.ps1','scripts/smal-private-powershell.py','docs/deployment-2026-10-29/three-node-cluster-validate-receipt.json',
        'docs/deployment-2026-10-29/three-node-validation-diagnostic.json'])
    path = OUT / 'lcm-credential-format-correction-receipt.json'
    record = {'beganAtUtc':datetime.now(timezone.utc).isoformat(),'sourceCommit':head,'status':'pending','secretName':NAME,
              'passwordRotated':False,'adAccountChanged':False,'localAdminSecretChanged':False,'clusterRecreated':False,'validateInvoked':False,
              'ownerArmTokenForwarded':False,'publicAccessChanged':False,'phase':'preflight'}
    with path.open('x') as stream: stream.write(json.dumps(record,indent=2) + '\n')
    def save(): path.write_text(json.dumps(record,indent=2) + '\n')
    token = None; value = None; current = None
    try:
        D['preflight'](); record['terminalInitialValidationProof'] = REC['current_failure']()
        record['privateInputsReceipt'] = D['inspect_inputs']('lcm-format-fix')
        published = D['previous']('secrets')
        if published['secretMetadata'] is None or NAME not in {row['name'] for row in published['secretMetadata']}: raise RuntimeError('Owned original LCM publication proof missing')
        before = versions()
        if len(before) != 1 or before[0]['enabled'] is not True: raise RuntimeError('LCM secret gained other versions or state differs. No overwrite authorised.')
        record['originalVersionId'] = before[0]['id']; save()
        value = sealed_lcm()
        raw = base64.b64decode(value,validate=True)
        expected_before = base64.b64encode(b'LOCALBOX\\' + raw).decode()
        auth = subprocess.run(['az','account','get-access-token','--subscription',D['SUB'],'--resource','https://vault.azure.net','--query','accessToken','--output','tsv','--only-show-errors'],capture_output=True,text=True,timeout=90)
        if auth.returncode: raise RuntimeError('Local vault-resource token acquisition failed; no host token forwarding or vault write')
        token = auth.stdout.strip(); auth = None
        current = private_vault('GET',token)
        if current['id'] != before[0]['id'] or not hmac.compare_digest(current['value'],expected_before): raise RuntimeError('Current credential does not exactly match the known original qualified host LCM value. Preserve it.')
        record['originalQualifiedValueMatchedHostCredential'] = True
        REC['current_failure']()
        if versions() != before: raise RuntimeError('LCM versions changed during inspection. No new version authorised.')
        record['phase'] = 'one-owned-lcm-new-version-put-pending'; save()
        after = private_vault('PUT',token,{'value':value,'contentType':'Secret','attributes':{'enabled':True}})
        if not after['id'].startswith(URI + '/') or after['id'] == before[0]['id']: raise RuntimeError('New owned LCM version identity differs')
        record['newVersionId'] = after['id']; after = None; save()
        actual = private_vault('GET',token)
        if actual['id'] != record['newVersionId'] or not hmac.compare_digest(actual['value'],value): raise RuntimeError('Private corrected LCM readback does not match exact unchanged-password format')
        metadata = versions()
        if len(metadata) != 2 or {row['id'] for row in metadata} != {before[0]['id'],record['newVersionId']}: raise RuntimeError('Unexpected secret version effect')
        record['versionsRetained'] = metadata; record['unqualifiedCredentialReadbackMatched'] = True
        record['vaultPublicAccessAfter'] = D['az'](['keyvault','show','--subscription',D['SUB'],'-n','kv-lbox-weu-4766ea','--query','properties.publicNetworkAccess'])
        if record['vaultPublicAccessAfter'] != 'Disabled': raise RuntimeError('Private vault boundary changed unexpectedly')
        record['phase'] = 'exact-username-only-correction-read-back'; record['status'] = 'complete-one-lcm-username-format-version-only'
    except (TimeoutError,subprocess.TimeoutExpired): record['status'] = 'uncertain-timeout-inspect-do-not-repeat'
    except (RuntimeError,ValueError,KeyError,OSError) as error:
        record['status'] = 'failed-inspect-before-resume'; record['errorType'] = type(error).__name__
        if isinstance(error,RuntimeError): record['error'] = str(error)
    token = None; value = None; current = None; record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat(); save()
    print(json.dumps(record,indent=2)); return 0 if record['status'].startswith('complete-') else 2


if __name__ == '__main__': raise SystemExit(main())
