"""Apply exactly NODE3's three approved scoped role bindings. Preserve prior roles."""
from datetime import datetime, timezone
import json
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
P = runpy.run_path(str(ROOT / 'scripts/smal-three-node-platform.py'), run_name='node03_role_apply')
A, R, az, OUT = (P[key] for key in ['A','R','az','OUT'])
TEMPLATE = 'infra/bicep/localbox-node03-platform-roles.bicep'
ACTION = 'localbox-node03-platform-roles-20261029'


def main():
    head = A['source_guard']([TEMPLATE, 'scripts/apply-smal-node03-platform-roles.py', 'scripts/smal-three-node-platform.py',
                              'docs/deployment-2026-10-29/three-node-arc-verified.json', 'docs/deployment-2026-10-29/three-node-local-identity-bindings.json'])
    path = OUT / 'node03-platform-roles-receipt.json'
    record = {'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'sourceCommit': head, 'status': 'pending', 'deploymentName': ACTION,
              'subscriptionWideGrantRequested': False, 'publicAccessChangeRequested': False, 'platformReadinessVerified': False}
    with path.open('x') as stream: stream.write(json.dumps(record, indent=2) + '\n')
    def save(): path.write_text(json.dumps(record, indent=2) + '\n')
    try:
        if az(['ad','signed-in-user','show','--query','id']) != A['H']['PRINCIPAL']: raise RuntimeError('Approved identity changed')
        nodes = P['cloud_nodes'](); P['verify_cloud'](nodes); record['arcMachines'] = nodes
        if az(['keyvault','show','-n','kv-lbox-weu-4766ea','--query','properties.publicNetworkAccess']) != 'Disabled': raise RuntimeError('Vault private boundary differs')
        before = R['assignments'](); existing = {R['binding'](row) for row in before}
        if existing & P['NODE03_EXPECTED']: raise RuntimeError('Equivalent NODE3 roles already exist. Reconcile rather than duplicate.')
        if not R['EXPECTED'] <= existing: raise RuntimeError('Original seven scoped roles missing')
        record['assignmentsBefore'] = before
        if az(['deployment','group','list','-g',P['RG'],'--query',"[?name=='" + ACTION + "'].name"]): raise RuntimeError('Role deployment identity already exists')
        owned = {rid.lower() for rid in az(['resource','list','-g',P['RG'],'--query','[].id'])} | {row['id'].lower() for row in before}
        args = ['-g',P['RG'],'-n',ACTION,'--template-file',str(ROOT / TEMPLATE)]
        preview = az(['deployment','group','what-if',*args,'--result-format','FullResourcePayloads','--no-pretty-print'], timeout=300)
        with (OUT / 'node03-platform-roles-what-if.json').open('x') as stream: stream.write(json.dumps(preview, indent=2) + '\n')
        P['validate_node03_preview'](preview, owned)
        record['status'] = 'apply-pending'; save()
        result = az(['deployment','group','create',*args], timeout=600)
        record['deploymentId'] = result['id']; record['deploymentState'] = result['properties']['provisioningState']
        after = R['assignments'](); selected = [row for row in after if R['binding'](row) in P['NODE03_EXPECTED']]
        if record['deploymentState'] != 'Succeeded' or len(selected) != 3 or {R['binding'](row) for row in selected} != P['NODE03_EXPECTED'] or any(row['principalType'] != 'ServicePrincipal' for row in selected): raise RuntimeError('Exact independent NODE3 role readback differs')
        if {row['id'] for row in before} != {row['id'] for row in after if R['binding'](row) not in P['NODE03_EXPECTED']}: raise RuntimeError('Pre-existing role identities changed')
        record['assignmentsReadback'] = selected; record['status'] = 'complete-three-node03-scoped-roles'
    except subprocess.TimeoutExpired: record['status'] = 'uncertain-timeout-do-not-repeat'
    except (RuntimeError, ValueError, KeyError) as error:
        record['status'] = 'failed-inspect-before-resume'; record['errorType'] = type(error).__name__
        if isinstance(error, RuntimeError): record['error'] = str(error)
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat(); save(); print(json.dumps(record, indent=2))
    return 0 if record['status'].startswith('complete-') else 2


if __name__ == '__main__': raise SystemExit(main())
