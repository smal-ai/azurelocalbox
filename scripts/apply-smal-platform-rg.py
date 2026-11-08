"""Create exactly the approved new platform RG after inspected one-resource what-if."""
from datetime import datetime, timezone
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-28'
SUB = '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea'
TENANT = 'c6e67968-af25-4557-ab8b-06b693048d3b'
PRINCIPAL = '82f494a8-b9f5-46fc-b0f7-c70be0572a63'
RG = 'rg-localbox-platform-weu-1'
ID = '/subscriptions/' + SUB + '/resourceGroups/' + RG
ACTION = 'localbox-platform-rg-20261028'
TEMPLATE = 'infra/bicep/localbox-platform-rg.bicep'


def az(args, timeout=120):
    result = subprocess.run(['az', *args, '--only-show-errors', '--output', 'json'], capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('Azure action failed; preserve receipt and reconcile, no automatic retry')
    return json.loads(result.stdout)


def validate_preview(preview):
    if preview.get('status') != 'Succeeded': raise RuntimeError('What-if did not succeed')
    changes = [x for x in preview.get('changes', []) if x.get('changeType') != 'NoChange']
    if len(changes) != 1 or changes[0].get('changeType') != 'Create' or changes[0].get('resourceId', '').lower() != ID.lower():
        raise RuntimeError('Preview is not exactly one new owned resource group')
    after = changes[0].get('after', {})
    if after.get('location') != 'westeurope' or after.get('type', '').lower() != 'microsoft.resources/resourcegroups':
        raise RuntimeError('Preview resource kind/location differs')


def approval_source():
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip()
    remote = subprocess.check_output(['git', 'ls-remote', '--heads', 'origin', 'refs/heads/' + branch], cwd=ROOT, text=True).split()
    if not remote or remote[0] != head: raise RuntimeError('Consequential source must be pushed')
    values = {}
    for path in [TEMPLATE, 'scripts/apply-smal-platform-rg.py', 'docs/deployment-2026-10-28/cloud-apply-proposal.json', 'docs/deployment-2026-10-28/cloud-apply-proposal.md', 'docs/deployment-2026-10-28/cloud-apply-approval.json']:
        data = (ROOT / path).read_bytes()
        if data != subprocess.check_output(['git', 'show', 'HEAD:' + path], cwd=ROOT): raise RuntimeError('Apply/approval source differs from HEAD')
        values[path] = data
    approval = json.loads(values['docs/deployment-2026-10-28/cloud-apply-approval.json'])
    for ext, key in [('json', 'proposalJsonSha256'), ('md', 'proposalMarkdownSha256')]:
        if hashlib.sha256(values['docs/deployment-2026-10-28/cloud-apply-proposal.' + ext]).hexdigest() != approval.get(key): raise RuntimeError('Exact proposal consent hash differs')
    if approval.get('approved') is not True or approval.get('westEuropeNewOwnedRgAndListedPlatformResourcesApproved') is not True: raise RuntimeError('Exact new RG approval missing')
    return head


def main(resume_preview=False):
    head = approval_source()
    target = OUT / ('platform-rg-apply-after-preview-reconciliation.json' if resume_preview else 'platform-rg-apply-receipt.json')
    if resume_preview:
        prior_path = OUT / 'platform-rg-apply-receipt.json'
        prior = json.loads(prior_path.read_text())
        if (prior.get('status') != 'failed-inspect-before-resume' or prior.get('errorType') != 'JSONDecodeError'
                or prior.get('deploymentName') != ACTION or 'previewSha256' in prior or 'deploymentId' in prior):
            raise RuntimeError('Exact pre-apply preview rendering failure not proven')
    with target.open('x') as stream:
        record = {'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'status': 'pending', 'sourceCommit': head, 'deploymentName': ACTION, 'scope': 'one-new-owned-platform-rg-only', 'resourceGroupId': ID}
        if resume_preview:
            record['originalReceiptRetained'] = True
            record['originalReceiptSha256'] = hashlib.sha256(prior_path.read_bytes()).hexdigest()
            record['resumeScope'] = 'reconciled-pre-apply-preview-rendering-only'
        stream.write(json.dumps(record, indent=2) + '\n')
    try:
        account = az(['account', 'show', '--subscription', SUB, '--query', '{id:id,tenantId:tenantId,state:state}'])
        principal = az(['ad', 'signed-in-user', 'show', '--query', 'id'])
        if account != {'id': SUB, 'tenantId': TENANT, 'state': 'Enabled'} or principal != PRINCIPAL: raise RuntimeError('Existing approved identity/context changed')
        if az(['group', 'exists', '--subscription', SUB, '--name', RG]) is not False: raise RuntimeError('RG already exists, preserve rather than overwrite')
        prior = az(['deployment', 'sub', 'list', '--subscription', SUB, '--query', "[?name=='" + ACTION + "'].name"])
        if prior: raise RuntimeError('Deployment identity already exists, reconcile before retry')
        preview = az(['deployment', 'sub', 'what-if', '--subscription', SUB, '--name', ACTION, '--location', 'westeurope', '--template-file', str(ROOT / TEMPLATE), '--result-format', 'FullResourcePayloads', '--no-pretty-print'], timeout=240)
        preview_path = OUT / ('platform-rg-what-if-reconciled.json' if resume_preview else 'platform-rg-what-if.json')
        with preview_path.open('x') as stream: stream.write(json.dumps(preview, indent=2) + '\n')
        validate_preview(preview)
        record['previewSha256'] = hashlib.sha256(preview_path.read_bytes()).hexdigest()
        record['status'] = 'apply-pending'; target.write_text(json.dumps(record, indent=2) + '\n')
        response = az(['deployment', 'sub', 'create', '--subscription', SUB, '--name', ACTION, '--location', 'westeurope', '--template-file', str(ROOT / TEMPLATE)], timeout=600)
        record['deploymentId'] = response['id']; record['deploymentState'] = response['properties']['provisioningState']
        actual = az(['group', 'show', '--subscription', SUB, '--name', RG, '--query', '{id:id,name:name,location:location,tags:tags,state:properties.provisioningState}'])
        if actual['id'].lower() != ID.lower() or actual['location'] != 'westeurope' or actual['state'] != 'Succeeded' or record['deploymentState'] != 'Succeeded': raise RuntimeError('Independent RG readback differs')
        record['result'] = actual
        record['resourceReadback'] = az(['resource', 'list', '--subscription', SUB, '--resource-group', RG, '--query', '[].{id:id,type:type}'])
        if record['resourceReadback']: raise RuntimeError('Unlisted resource appeared in the new RG; preserve and inspect')
        record['status'] = 'complete-one-rg-only'
    except subprocess.TimeoutExpired:
        record['status'] = 'uncertain-timeout-do-not-repeat'
    except (RuntimeError, ValueError, KeyError) as error:
        record['status'] = 'failed-inspect-before-resume'; record['errorType'] = type(error).__name__
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat()
    record['arcOrClusterOrRolesExplicitlyRequestedByTemplate'] = False
    target.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))
    return 0 if record['status'] == 'complete-one-rg-only' else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resume-after-preview-rendering', action='store_true')
    args = parser.parse_args()
    raise SystemExit(main(args.resume_after_preview_rendering))
