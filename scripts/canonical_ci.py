"""Credential-free source checks and mocked canonical-operation regressions.

PowerShell parses the maintained scripts and runs authored local fixtures. No Azure,
Bastion, SSH, guest, disk, BitLocker or SMB operation is invoked by this entry point.
"""
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PYTHON = ('start-smal-localbox.py', 'smal-private-powershell.py', 'smal-platform.py',
          'smal-capacity.py', 'smal-disk-performance.py', 'smal-files.py', 'canonical_ci.py')
POWERSHELL = ('start-smal-existing-guests.ps1', 'smal-platform.ps1', 'smal-capacity.ps1',
              'smal-disk-performance.ps1', 'smal-files.ps1')
SECRET = re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|'
                    rb'\beyJ[A-Za-z0-9_-]{18,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\b|'
                    rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b|'
                    rb'(?:AccountKey=|sig=)[A-Za-z0-9+/%]{40,}')
DATE = re.compile(r'20\d{2}(?:-\d{2}-\d{2}|\d{4})')
BICEP_SHA256 = 'ff5b194b042c220df4a50d6768ed1d6c39a32894bfdc4ff83d62b115d966a7ce'


def source_checks():
    names = filter(None, subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0'))
    for name in names:
        path = ROOT / name
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
    for name in PYTHON:
        path = ROOT / 'scripts' / name
        ast.parse(path.read_bytes(), filename=str(path))
    for path in (ROOT / 'config').glob('*.json'):
        json.loads(path.read_bytes())
    script = '''$errorsFound=@()
foreach($path in @(__PATHS__)) {
    $tokens=$null; $errors=$null
    $null=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    $errorsFound+=@($errors)
}
if($errorsFound.Count) { $errorsFound | Format-List; exit 1 }
'''.replace('__PATHS__', ','.join("'" + str(ROOT / 'scripts' / name).replace("'", "''") + "'" for name in POWERSHELL))
    subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
                   check=True, timeout=30)
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


def main():
    Path('/tmp/opencode').mkdir(parents=True, exist_ok=True)
    source_checks()
    bicep_checks()
    sys.path.insert(0, str(ROOT / 'scripts'))
    suite = unittest.TestSuite()
    for name in ('test_smal_canonical.py', 'test_smal_native.py'):
        suite.addTests(unittest.defaultTestLoader.discover(str(ROOT / 'scripts'), pattern=name))
    if not suite.countTestCases():
        raise ValueError('Canonical operations CI collected no tests')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful() or result.skipped:
        raise SystemExit('Canonical operations CI failed or skipped tests')
    print(json.dumps({'tests': result.testsRun, 'nativeEffects': False, 'status': 'passed'}))


if __name__ == '__main__':
    main()
