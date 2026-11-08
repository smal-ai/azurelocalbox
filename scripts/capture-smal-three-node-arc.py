"""Read-only verified cloud Arc identity binding after the human NODE3 bootstrap."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
P = runpy.run_path(str(ROOT / 'scripts/smal-three-node-platform.py'), run_name='three_arc_capture')


if __name__ == '__main__':
    proof_path = ROOT / 'docs/deployment-2026-10-27/private-ssh-three-node-live-after-arc-20261029.json'
    local = json.loads(proof_path.read_text()); nodes = P['cloud_nodes']()
    P['verify_cloud'](nodes); P['verify_local'](local)
    record = {'status': 'verified-three-arc-identities-and-successful-local-bootstraps', 'observedAtUtc': datetime.now(timezone.utc).isoformat(),
              'arcMachines': nodes, 'privateProofSha256': hashlib.sha256(proof_path.read_bytes()).hexdigest(),
              'azureMutationPerformed': False, 'platformReadinessVerified': False}
    path = P['OUT'] / 'three-node-arc-verified.json'
    with path.open('x') as stream: stream.write(json.dumps(record, indent=2) + '\n')
    print(json.dumps({'status': record['status'], 'receipt': str(path.relative_to(ROOT)), 'nodeCount': len(nodes)}, indent=2))
