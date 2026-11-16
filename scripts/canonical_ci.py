"""Credential-free repository hygiene, workflow boundary and Bicep compilation checks.

Canonical SMAL day-two LocalBox operational scripts moved to smal-ai/smal-project
(`solution/infra/localbox/`). Enforce that they are not duplicated here while keeping
source hygiene and Bicep compilation verified.
"""
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MIGRATED = (
    'config/smal-platform.json',
    'config/smal-capacity.json',
    'config/smal-disk-performance.json',
    'config/smal-files.json',
    'scripts/start-smal-localbox.py',
    'scripts/start-smal-existing-guests.ps1',
    'scripts/smal-private-powershell.py',
    'scripts/smal-platform.py',
    'scripts/smal-platform.ps1',
    'scripts/smal-capacity.py',
    'scripts/smal-capacity.ps1',
    'scripts/smal-disk-performance.py',
    'scripts/smal-disk-performance.ps1',
    'scripts/smal-files.py',
    'scripts/smal-files.ps1',
    'scripts/test_smal_canonical.py',
    'scripts/test_smal_native.py',
)
SECRET = re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|'
                    rb'\beyJ[A-Za-z0-9_-]{18,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\b|'
                    rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b|'
                    rb'(?:AccountKey=|sig=)[A-Za-z0-9+/%]{40,}')
DATE = re.compile(r'20\d{2}(?:-\d{2}-\d{2}|\d{4})')
BICEP_SHA256 = 'ff5b194b042c220df4a50d6768ed1d6c39a32894bfdc4ff83d62b115d966a7ce'


def source_checks():
    names = [name for name in subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0') if name]
    for name in names:
        path = ROOT / name
        if not path.exists():
            continue
        if path.is_symlink():
            raise ValueError('Tracked source symlink requires review: ' + name)
        if path.name.startswith('.env') or path.suffix.lower() in ('.pfx', '.p12', '.key', '.sqlite', '.db', '.iso', '.vhdx'):
            raise ValueError('Private/runtime file in source: ' + name)
        if name.startswith('docs/deployment-') and path.suffix in ('.json', '.jsonl', '.log', '.csv', '.txt'):
            raise ValueError('Operational record belongs outside Git: ' + name)
        if name.startswith('scripts/') and path.suffix in ('.py', '.ps1', '.sh') and DATE.search(name):
            raise ValueError('Dated executable copy belongs outside maintained source: ' + name)
        if SECRET.search(path.read_bytes()):
            raise ValueError('Credential pattern in source: ' + name)
    ast.parse((ROOT / 'scripts/canonical_ci.py').read_bytes(), filename='scripts/canonical_ci.py')
    subprocess.run(['git', 'diff', '--check'], cwd=ROOT, check=True, timeout=30)


def bicep_checks():
    value = os.environ.get('BICEP_CLI')
    if not value:
        raise ValueError('Supply the existing checksum-pinned BICEP_CLI')
    binary = Path(value).resolve(strict=True)
    if hashlib.sha256(binary.read_bytes()).hexdigest() != BICEP_SHA256:
        raise ValueError('Bicep compiler checksum differs')
    with tempfile.TemporaryDirectory(prefix='localbox-bicep-', dir='/tmp/opencode') as scratch:
        for name in ('main.smal-host.bicep', 'main.localbox.bicep', 'main.bicep'):
            output = Path(scratch) / (name + '.json')
            subprocess.run([str(binary), 'build', str(ROOT / 'infra/bicep' / name), '--no-restore',
                            '--outfile', str(output)], check=True, timeout=120)
            json.loads(output.read_bytes())


class RepositoryBoundaryTests(unittest.TestCase):
    def test_migrated_smal_operational_suite_is_not_duplicated_here(self):
        for relative in MIGRATED:
            self.assertFalse((ROOT / relative).exists(), relative)
        guide = (ROOT / 'docs/operations/start-localbox.md').read_text()
        self.assertIn('solution/infra/localbox', guide)

    def test_ci_is_pinned_readonly_and_never_dispatches_native_operations(self):
        text = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('pull_request:', text)
        self.assertIn('contents: read', text)
        self.assertIn('persist-credentials: false', text)
        self.assertIn('python -B scripts/canonical_ci.py', text)
        for forbidden in ('pull_request_target', 'self-hosted', 'azure/login', 'secrets.', 'id-token:',
                          'continue-on-error:', 'start-smal-localbox.py', 'smal-files.py',
                          'smal-capacity.py', 'smal-disk-performance.py'):
            self.assertNotIn(forbidden, text)
        for action in re.findall(r'^\s*- uses: (\S+)', text, re.MULTILINE):
            self.assertRegex(action, r'^[^@]+@[a-f0-9]{40}$')


def main():
    Path('/tmp/opencode').mkdir(parents=True, exist_ok=True)
    source_checks()
    bicep_checks()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(RepositoryBoundaryTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful() or result.skipped:
        raise SystemExit('Canonical operations CI failed or skipped tests')
    print(json.dumps({'tests': result.testsRun, 'nativeEffects': False, 'status': 'passed'}))


if __name__ == '__main__':
    main()
