"""Approved existing-node resize/move and one-shot NODE3 installation dispatch."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
A = runpy.run_path(str(ROOT / 'scripts/smal-three-node-approval.py'), run_name='three_node_local_guard')
OUT = A['OUT']
STAGES = {'resize': ('scripts/resize-smal-existing-nodes.ps1', 'existing-nodes-resize-20261029'), 'install-node03': ('scripts/install-smal-node03-job.ps1', 'install-node03-job-20261029')}


def main(stage):
    script, label = STAGES[stage]
    head = A['source_guard'](['scripts/apply-smal-three-node-local.py', script, 'scripts/smal-private-powershell.py', 'scripts/smal-three-node-prelude.ps1'])
    path = OUT / ('three-node-' + stage + '-receipt.json')
    record = {'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'sourceCommit': head, 'stage': stage, 'status': 'pending', 'existingArcRegistrationRepeated': False, 'clusterDeploymentInvoked': False}
    with path.open('x') as stream: stream.write(json.dumps(record, indent=2) + '\n')
    try:
        if A['az'](['ad', 'signed-in-user', 'show', '--query', 'id']) != A['H']['PRINCIPAL']: raise RuntimeError('Approved identity changed')
        disk = A['az'](['disk', 'show', '--ids', A['DISK_ID']])
        if disk['managedBy'].lower() != A['VM_ID'].lower(): raise RuntimeError('Approved new disk is not attached to exact host')
        transport = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='three_node_local_transport')
        proof = json.loads((transport['OUT'] / 'private-ssh-node03-disk-format-reconciled-20261029.json').read_text())
        if proof.get('status') != 'complete' or proof['result']['status'] != 'complete-new-lun8-only-formatted-w' or proof['result']['azureDiskUniqueId'] != disk['uniqueId']:
            raise RuntimeError('Exact successful new-only W format proof missing')
        if stage == 'install-node03':
            prior = json.loads((OUT / 'three-node-resize-receipt.json').read_text())
            if prior.get('status') != 'complete': raise RuntimeError('Existing-node phase not complete')
            names = A['az'](['resource', 'list', '-g', 'rg-localbox-platform-weu-1', '--resource-type', 'Microsoft.HybridCompute/machines', '--query', '[].name'])
            if 'lb-node03' in {name.lower() for name in names}: raise RuntimeError('NODE3 Arc resource already exists; inspect instead of reinstalling')
        record['status'] = 'remote-action-pending'; path.write_text(json.dumps(record, indent=2) + '\n')
        code = transport['main'](script, label, three_node_context=A['context'](disk))
        result = json.loads((transport['OUT'] / ('private-ssh-' + label + '.json')).read_text())
        if code != 0 or result.get('status') != 'complete': raise RuntimeError('Local phase failed or uncertain. Inspect existing host marker/state, do not replay.')
        record['result'] = result['result']
        expected = 'complete-existing-nodes-64gib-8vcpu-and-one-vhd-relocated' if stage == 'resize' else 'one-shot-node03-job-started'
        if record['result'].get('status') != expected: raise RuntimeError('Local phase did not report its exact bounded success')
        record['status'] = 'complete'
        if stage == 'install-node03': record['localNode03ReadinessVerified'] = False
    except subprocess.TimeoutExpired: record['status'] = 'uncertain-timeout-do-not-repeat'
    except (RuntimeError, ValueError, KeyError) as error:
        record['status'] = 'failed-inspect-before-resume'; record['errorType'] = type(error).__name__
        if isinstance(error, RuntimeError): record['error'] = str(error)
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat()
    path.write_text(json.dumps(record, indent=2) + '\n'); print(json.dumps(record, indent=2))
    return 0 if record['status'] == 'complete' else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('stage', choices=list(STAGES))
    raise SystemExit(main(parser.parse_args().stage))
