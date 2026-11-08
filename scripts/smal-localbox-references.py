"""Hash-pinned read-only references to original authorised public receipts.

Never discover credentials, copy runtime state, initialise trust or authorise replay.
"""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = 'docs/deployment-2026-11-08-capacity/runtime-references.json'
ORIGIN = 'https://github.com/smal-ai/azurelocalbox'


def verify_origin():
    # Do not accept a different repository merely because it advertises the same SHA.
    origin = subprocess.check_output(['git', 'remote', 'get-url', 'origin'], cwd=ROOT, text=True).strip()
    if origin != ORIGIN:
        raise RuntimeError('Repository origin identity differs. Explicit migration review required')
    return origin


def original_bytes(name):
    verify_origin()
    manifest_path = ROOT / MANIFEST
    data = manifest_path.read_bytes()
    if manifest_path.is_symlink() or data != subprocess.check_output(['git', 'show', 'HEAD:' + MANIFEST], cwd=ROOT):
        raise RuntimeError('Reference manifest must be committed unchanged')
    manifest = json.loads(data)
    if manifest['repositoryOrigin'] != ORIGIN or manifest['historicalRoot'] != '/home/quintin/play/azurelocalbox' or name not in manifest['references']:
        raise RuntimeError('Unsupported original receipt reference')
    path = Path(manifest['historicalRoot']) / name
    if path.resolve() != path or not path.is_file():
        raise RuntimeError('Original receipt missing or symlinked. No replacement invented')
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != manifest['references'][name]:
        raise RuntimeError('Original receipt bytes changed. Re-review references')
    return data
