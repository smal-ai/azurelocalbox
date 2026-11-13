"""Run repository PowerShell through the existing pinned private Bastion connection.

Source bytes identify a command. Timestamps describe its execution, not its authority
or identity. Receipts live in the operator's state directory, never in the checkout.
"""
import argparse
import base64
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import stat
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
STATE = Path.home() / '.local/state/azurelocalbox'
CONFIG = ROOT / 'config/smal-platform.json'


def now():
    return datetime.now(timezone.utc).isoformat()


def az(*arguments):
    result = subprocess.run(['az', *arguments, '--only-show-errors', '-o', 'json'],
                            capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError('Azure request failed. Check current sign-in and target permissions.')
    return json.loads(result.stdout) if result.stdout.strip() else None


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise RuntimeError('State directory must be an owner-only regular directory: ' + str(path))


def write_record(path, value):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    fd = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def source_bytes(script, parameters):
    path = (ROOT / script).resolve(strict=True)
    if not path.is_relative_to(ROOT / 'scripts') or path.suffix != '.ps1' or (ROOT / script).is_symlink():
        raise ValueError('Use a regular PowerShell source file in this repository scripts directory')
    source = path.read_bytes()
    source.decode('utf-8')
    if not source or len(source) > 2 * 1024**2:
        raise ValueError('PowerShell source is empty or exceeds 2 MiB')
    if not isinstance(parameters, dict) or any(not re.fullmatch('[A-Za-z][A-Za-z0-9]*', key) for key in parameters):
        raise ValueError('Parameters must be a JSON object with PowerShell parameter names')
    data = base64.b64encode(json.dumps(parameters, separators=(',', ':')).encode()).decode()
    wrapper = ("$ErrorActionPreference='Stop';try{$a=@{};$p=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + data + "'))|ConvertFrom-Json);"
               "foreach($v in $p.PSObject.Properties){$a[$v.Name]=$v.Value};& {\n" + source.decode() +
               "\n} @a}catch{[Console]::Error.WriteLine('SmalCommandFailure:'+ $_.Exception.GetType().Name+':'+$_.InvocationInfo.ScriptLineNumber+':'+$_.Exception.Message);exit 1}")
    return path, source, wrapper.encode()


def ssh_args(port, admin, encoded):
    key, known = STATE / 'ssh/localbox-client_ed25519', STATE / 'ssh/known_hosts'
    for path in (key, known):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise RuntimeError('Missing or unsafe existing SSH identity/trust file')
    entries = [line.split() for line in known.read_text().splitlines() if line and not line.startswith('#')]
    if len(entries) != 1 or len(entries[0]) != 3 or entries[0][1] != 'ssh-ed25519':
        raise RuntimeError('Expected the existing single pinned host key')
    return ['ssh', '-F', '/dev/null', '-T', '-p', str(port), '-i', str(key),
            '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none', '-o', 'BatchMode=yes',
            '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no',
            '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=' + str(known),
            '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'HostKeyAlias=' + entries[0][0],
            '-o', 'HostKeyAlgorithms=ssh-ed25519', '-o', 'ConnectTimeout=15',
            '-o', 'ForwardAgent=no', '-o', 'ClearAllForwardings=yes',
            '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2',
            admin + '@127.0.0.1', 'powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + encoded]


def loader(source):
    digest = hashlib.sha256(source).hexdigest().upper()
    text = ("$ErrorActionPreference='Stop';try{$n=" + str(len(source)) +
            ";[byte[]]$b=New-Object byte[] $n;$s=[Console]::OpenStandardInput();$o=0;"
            "while($o -lt $n){$c=$s.Read($b,$o,$n-$o);if($c -le 0){throw 'Truncated source'};$o+=$c};"
            "$h=[Security.Cryptography.SHA256]::Create().ComputeHash($b);"
            "if([BitConverter]::ToString($h).Replace('-','') -cne '" + digest + "'){throw 'Source hash differs'};"
            "& ([ScriptBlock]::Create([Text.UTF8Encoding]::new($false,$true).GetString($b)))"
            "}catch{[Console]::Error.WriteLine('SmalCommandFailure:'+ $_.Exception.GetType().Name+':'+$_.InvocationInfo.ScriptLineNumber+':'+$_.Exception.Message);exit 1}")
    return base64.b64encode(text.encode('utf-16-le')).decode()


def run(script, name=None, *, parameters=None, timeout=600):
    config = json.loads(CONFIG.read_bytes())
    path, original, source = source_bytes(script, parameters or {})
    name = name or 'command-' + uuid.uuid4().hex
    if not re.fullmatch('[a-z][a-z0-9-]{0,95}', name):
        raise ValueError('Receipt identifier must be a lower-case name or UUID, without a path')
    directory = STATE / 'receipts' / name
    private_directory(STATE / 'receipts')
    directory.mkdir(mode=0o700)  # Existing invocation identity cannot be overwritten.
    receipt = directory / 'receipt.json'
    record = {'id': name, 'script': str(path.relative_to(ROOT)), 'sourceSha256': hashlib.sha256(original).hexdigest(),
              'requestSha256': hashlib.sha256(source).hexdigest(), 'startedAt': now(), 'status': 'preflight',
              'transport': 'private-bastion-pinned-ssh', 'commandDispatched': False}
    write_record(receipt, record)
    tunnel = None
    try:
        account = az('account', 'show', '--subscription', config['subscriptionId'])
        if account['id'] != config['subscriptionId'] or account['tenantId'] != config['tenantId']:
            raise RuntimeError('Current account does not match the configured tenant/subscription')
        route = json.loads(subprocess.check_output(['ip', '-j', 'route', 'get', config['resolverIp']], text=True))
        if len(route) != 1 or route[0].get('dev') != 'tun0':
            raise RuntimeError('Existing private VPN route is unavailable')
        with socket.create_connection((config['resolverIp'], 53), timeout=5):
            pass
        admin = az('vm', 'show', '--ids', config['hostId'], '--subscription', config['subscriptionId'], '--query', 'osProfile.adminUsername')
        if not isinstance(admin, str) or not re.fullmatch('[A-Za-z][A-Za-z0-9_-]{0,31}', admin):
            raise RuntimeError('Unexpected host administrator name')
        with socket.socket() as reserve:
            reserve.bind(('127.0.0.1', 0))
            port = reserve.getsockname()[1]
        command = ssh_args(port, admin, loader(source))  # Verify local trust before opening a tunnel.
        bastion = config['bastion']
        tunnel = subprocess.Popen(['az', 'network', 'bastion', 'tunnel', '--subscription', bastion['subscriptionId'],
            '-g', bastion['resourceGroup'], '-n', bastion['name'], '--target-resource-id', config['hostId'],
            '--resource-port', '22', '--port', str(port), '--timeout', str(timeout + 120), '--only-show-errors'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        deadline = time.monotonic() + 70
        while tunnel.poll() is None and time.monotonic() < deadline:
            listeners = subprocess.check_output(['ss', '-H', '-ltn', 'sport', '=', ':' + str(port)], text=True).splitlines()
            if listeners:
                if any('127.0.0.1:' + str(port) not in line for line in listeners):
                    raise RuntimeError('Bastion tunnel is not loopback-only')
                break
            time.sleep(1)
        else:
            raise RuntimeError('Private Bastion tunnel did not become ready')
        record.update(commandDispatched=True, status='running')
        write_record(receipt, record)
        result = subprocess.run(command, input=source, capture_output=True, timeout=timeout)
        stdout, stderr = result.stdout.decode('utf-8'), result.stderr.decode('utf-8', errors='replace')
        record['exitCode'] = result.returncode
        if result.returncode:
            match = re.search(r'SmalCommandFailure:([^\r\n]+)', stderr)
            record.update(status='failed', error=(match[1][:1200] if match else 'SSH/PowerShell request failed'))
        else:
            if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY|\beyJ[A-Za-z0-9_-]{15,}\.|'
                         r'"(?i:password|access_token|refresh_token|client_secret)"\s*:\s*"[^"\s]+', stdout):
                raise RuntimeError('Sensitive-pattern command output suppressed')
            record.update(status='complete', result=json.loads(stdout))
    except subprocess.TimeoutExpired:
        record.update(status='uncertain' if record['commandDispatched'] else 'failed', error='Command timed out. Inspect current state before retrying.')
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
        record.update(status='uncertain' if record['commandDispatched'] else 'failed', error=str(error))
    finally:
        if tunnel is not None:
            try:
                os.killpg(tunnel.pid, signal.SIGTERM)
                tunnel.wait(timeout=10)
            except ProcessLookupError:
                pass
            except subprocess.TimeoutExpired:
                os.killpg(tunnel.pid, signal.SIGKILL)
                tunnel.wait(timeout=5)
        record['finishedAt'] = now()
        write_record(receipt, record)
    return record, receipt


def main(script, name=None, *, parameters=None, timeout=600):
    private_directory(STATE)
    with (STATE / 'transport.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        record, receipt = run(script, name, parameters=parameters, timeout=timeout)
    print(json.dumps({**record, 'receipt': str(receipt)}, indent=2))
    return 0 if record['status'] == 'complete' else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--script', required=True)
    parser.add_argument('--receipt')
    parser.add_argument('--parameters', type=Path, help='JSON object of public script parameters')
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    if not 30 <= args.timeout <= 3600:
        parser.error('--timeout must be between 30 and 3600 seconds')
    raise SystemExit(main(args.script, args.receipt,
                         parameters=json.loads(args.parameters.read_bytes()) if args.parameters else None,
                         timeout=args.timeout))
