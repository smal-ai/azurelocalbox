"""Read-only independent reconciliation after Premium conversion/startup recovery."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-29'
C = runpy.run_path(str(ROOT / 'scripts/convert-smal-host-premium.py'), run_name='premium_result_reads')
START = runpy.run_path(str(ROOT / 'scripts/start-smal-localbox.py'), run_name='premium_result_host')


def main():
    target = OUT / 'premium-disk-conversion-reconciled-result.json'
    record = {'beganAtUtc': datetime.now(timezone.utc).isoformat(), 'status': 'pending-read-only-reconciliation',
              'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'azureMutationPerformedByReconciliation': False, 'thirdNodePlanApplied': False, 'platformReadinessVerified': False}
    with target.open('x') as stream: stream.write(json.dumps(record, indent=2) + '\n')
    try:
        original = json.loads((OUT / 'premium-disk-conversion-after-cli-reconciliation.json').read_text())
        actual = C['disk_readback'](); C['verify_disks'](actual, original['disksBefore'], final=True)
        old = {row['id']: row for row in original['disksBefore']}
        for row in actual:
            for key in ['uniqueId', 'diskSizeGB', 'encryptionType', 'diskEncryptionSetId', 'securityType']:
                if row.get(key) != old[row['id']].get(key): raise RuntimeError('Disk identity/size/encryption metadata differs')
            if row['state'] != 'Attached': raise RuntimeError('Disk is not attached after recovery')
        record['disks'] = actual
        record['host'] = START['host_state']()
        if record['host'] != {'power': 'PowerState/running', 'agentReady': True}: raise RuntimeError('Host readiness not restored')
        capacity_path = ROOT / 'docs/deployment-2026-10-27/private-ssh-capacity-after-premium-20261029.json'
        arc_path = ROOT / 'docs/deployment-2026-10-27/private-ssh-arc-service-startup-details-20261029.json'
        startup_path = OUT / 'start-20261029-080708-7389325a.json'
        capacity = json.loads(capacity_path.read_text()); arc = json.loads(arc_path.read_text()); startup = json.loads(startup_path.read_text())
        if capacity.get('status') != 'complete' or arc.get('status') != 'complete' or startup.get('status') != 'complete-host-and-three-guests-running-heartbeats-healthy':
            raise RuntimeError('Complete independent guest/storage/startup evidence missing')
        data = capacity['result']
        if data['pool']['health'] != 'Healthy' or data['pool']['memberCount'] != 8 or data['virtualDisk']['health'] != 'Healthy' or data['virtualDisk']['uniqueId'] != 'D0CDB2F96D0E244E8B532E096F97FBBF': raise RuntimeError('Existing V pool/virtual-disk identity/health differs')
        if len(data['guests']) != 3 or any(row['state'] != 'Running' for row in data['guests']) or data['thirdNodeNamePresent'] or data['proposedWDrivePresent']: raise RuntimeError('Expected existing-only guest state differs')
        for row in arc['result']['nodes']:
            if row['bootstrap']['status'] != 'Succeeded' or len(row['services']) != 3 or any(service['status'] != 'Running' or service['exitCode'] != 0 for service in row['services']): raise RuntimeError('Arc bootstrap/services have not recovered')
        cloud = C['az'](['connectedmachine', 'list', '-g', 'rg-localbox-platform-weu-1', '--query', '[].{name:name,status:status,principalId:identity.principalId}'])
        expected = {'LB-NODE01': '9a1205c8-6ac3-4d02-ad6d-6166827c8d9d', 'LB-NODE02': 'b282b136-716d-4fa9-8e03-a4c754249a5e'}
        if len(cloud) != 2 or {row['name']: row['principalId'] for row in cloud} != expected or any(row['status'] != 'Connected' for row in cloud): raise RuntimeError('Azure Arc identities/health differ')
        record['arcMachines'] = cloud
        record['pool'] = data['pool']; record['virtualDisk'] = data['virtualDisk']
        record['guests'] = [{'name': row['name'], 'id': row['vmId'], 'state': row['state'], 'memoryBytes': row['memoryStartupBytes'], 'processors': row['processors']} for row in data['guests']]
        record['originalConversionAndStartupFailuresRetained'] = True
        record['proofSha256'] = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [capacity_path, arc_path, startup_path]}
        record['status'] = 'complete-nine-existing-premium-disks-host-guests-storage-and-arc-verified'
    except (RuntimeError, ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        record['status'] = 'failed-read-only-reconciliation'; record['errorType'] = type(error).__name__
        if isinstance(error, RuntimeError): record['error'] = str(error)
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat()
    target.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({'status': record['status'], 'receipt': str(target.relative_to(ROOT)), 'diskCount': len(record.get('disks', []))}, indent=2))
    return 0 if record['status'].startswith('complete-') else 2


if __name__ == '__main__':
    raise SystemExit(main())
