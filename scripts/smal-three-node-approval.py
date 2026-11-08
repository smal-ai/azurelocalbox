"""Shared exact-source/approval guard for the approved three-node effect set."""
import base64
import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-29'
H = runpy.run_path(str(ROOT / 'scripts/apply-smal-platform-rg.py'), run_name='three_node_base_guard')
SUB = H['SUB']; RG = 'rg-localbox-nodes-san-1'; HOST = 'LocalBox-Client'
VM_ID = f'/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Compute/virtualMachines/{HOST}'
DISK_ID = f'/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Compute/disks/LocalBox-Client-Node03-SSD-20261029'


def az(args, timeout=120):
    subscription = [] if args[0] == 'ad' else ['--subscription', SUB]
    result = subprocess.run(['az', *args, *subscription, '--only-show-errors', '--output', 'json'], capture_output=True, text=True, timeout=timeout)
    if result.returncode: raise RuntimeError('Azure action failed. Preserve receipt and inspect before continuing.')
    return json.loads(result.stdout) if result.stdout.strip() else None


def source_guard(paths=()):
    head = H['approval_source']()
    names = ['docs/deployment-2026-10-29/three-node-proposal.json', 'docs/deployment-2026-10-29/three-node-proposal.md',
             'docs/deployment-2026-10-29/three-node-approval.json', 'scripts/smal-three-node-approval.py', *paths]
    data = {}
    for name in names:
        value = (ROOT / name).read_bytes()
        if value != subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT): raise RuntimeError('Exact three-node source/approval differs from HEAD')
        data[name] = value
    approval = json.loads(data[names[2]])
    if approval.get('approved') is not True: raise RuntimeError('Three-node approval missing')
    for name, key in [(names[0], 'proposalJsonSha256'), (names[1], 'proposalMarkdownSha256')]:
        if hashlib.sha256(data[name]).hexdigest() != approval.get(key): raise RuntimeError('Exact approved three-node proposal hash differs')
    return head


def context(disk):
    if disk.get('id', '').lower() != DISK_ID.lower() or disk.get('diskSizeGB') != 2048 or disk.get('sku', {}).get('name') != 'Premium_LRS':
        raise RuntimeError('Exact approved new disk identity/size/SKU differs')
    uuid.UUID(disk['uniqueId'])
    return {'diskId': disk['id'], 'azureDiskUniqueId': disk['uniqueId'], 'lun': 8,
            'proposalBase64': base64.b64encode((OUT / 'three-node-proposal.json').read_bytes()).decode(),
            'approvalBase64': base64.b64encode((OUT / 'three-node-approval.json').read_bytes()).decode()}
