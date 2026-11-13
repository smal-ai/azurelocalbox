"""Inspect or repair the existing lab through its canonical private transport."""
import argparse
import base64
from datetime import datetime
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import subprocess
from uuid import UUID

ROOT = Path(__file__).resolve().parents[1]
ACTIONS = {'inspect': 'Inspect', 'inspect-moc': 'InspectMoc', 'repair-moc': 'RepairMoc',
           'inspect-aks': 'InspectAks', 'inspect-node': 'InspectAksNode', 'inspect-access': 'InspectAccess',
           'inspect-performance': 'InspectPerformance', 'inspect-bridge': 'InspectBridge',
           'inspect-recovery': 'InspectAksRecovery'}


def encoded(value):
    return base64.b64encode(json.dumps(value).encode()).decode()


def private_key(path):
    path = path.expanduser()
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Use the existing owner-only AKS SSH private key')
    public = subprocess.run(['ssh-keygen', '-y', '-P', '', '-f', str(path)],
                            capture_output=True, text=True, check=True, timeout=10).stdout.split()[:2]
    if public != Path(str(path) + '.pub').read_text().split()[:2]:
        raise ValueError('Existing AKS private/public key binding differs')
    return base64.b64encode(path.read_bytes()).decode()


def recovery_plan(path):
    path = path.expanduser()
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 16384:
        raise ValueError('Recovery plan must be an owner-only regular runtime file')
    raw = path.read_bytes()
    value = json.loads(raw)
    required = {'operationId', 'hciNode', 'vmId', 'vmName', 'biosGuid', 'clusterName',
                'osDiskPath', 'osDiskId', 'osDiskBytes', 'expiresAtUtc'}
    if set(value) != required or not re.fullmatch(r'aks-os-recovery-[a-f0-9]{32}', value['operationId']):
        raise ValueError('Exact bounded recovery plan fields and operation identity required')
    for key in ('vmId', 'biosGuid', 'osDiskId'):
        UUID(value[key])
    if datetime.fromisoformat(value['expiresAtUtc']).tzinfo is None:
        raise ValueError('Recovery expiry must include its UTC offset')
    if (value['hciNode'] not in ('LB-NODE01', 'LB-NODE02', 'LB-NODE03')
            or not re.fullmatch(r'[a-z][a-z0-9-]{2,62}', value['clusterName'])
            or not value['vmName'].startswith(value['clusterName'] + '-')
            or type(value['osDiskBytes']) is not int or value['osDiskBytes'] <= 0
            or not value['osDiskPath'].startswith('C:\\ClusterStorage\\UserStorage_1\\')
            or not re.search(r'-OSDisk-[a-f0-9]{8}\.vhdx$', value['osDiskPath'])
            or '..' in value['osDiskPath'].split('\\')):
        raise ValueError('Exact existing AKS VM and OS disk identity required')
    return base64.b64encode(raw).decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=ACTIONS)
    parser.add_argument('--endpoint', action='append', default=[], help='Explicit nested IP:port for read-only connectivity checks')
    parser.add_argument('--vm-id', type=UUID)
    parser.add_argument('--vm-ip', type=ipaddress.IPv4Address)
    parser.add_argument('--api-ip', type=ipaddress.IPv4Address)
    parser.add_argument('--cluster-name')
    parser.add_argument('--ssh-key', type=Path)
    parser.add_argument('--bridge-kubeconfig', type=Path)
    parser.add_argument('--node-inspection', choices=('Basic', 'Bootstrap', 'Performance', 'ControlPlane', 'Kubernetes', 'Console'), default='Basic')
    parser.add_argument('--recovery-plan', type=Path)
    parser.add_argument('--timeout', type=int, default=300)
    args = parser.parse_args()
    if not 30 <= args.timeout <= 3600:
        parser.error('Timeout must be between 30 and 3600 seconds')
    parameters = {'Action': ACTIONS[args.action],
                  'ConfigurationBase64': base64.b64encode((ROOT / 'config/smal-platform.json').read_bytes()).decode()}
    if args.action == 'inspect-recovery':
        if not args.recovery_plan:
            parser.error('Recovery needs the exact private runtime plan')
        parameters.update(RecoveryPlanBase64=recovery_plan(args.recovery_plan))
    if args.endpoint:
        endpoints = []
        for value in args.endpoint:
            address, port = value.rsplit(':', 1)
            endpoints.append({'address': str(ipaddress.IPv4Address(address)), 'port': int(port)})
        parameters['DiagnosticEndpointsBase64'] = encoded(endpoints)
    if args.action == 'inspect-node':
        if not all((args.vm_id, args.cluster_name)):
            parser.error('Node inspection needs its observed VM ID and cluster name')
        parameters.update(AksVmId=str(args.vm_id), AksClusterName=args.cluster_name, NodeInspection=args.node_inspection)
        if args.node_inspection != 'Console':
            if not all((args.vm_ip, args.ssh_key)):
                parser.error('SSH node inspection needs its observed VM IP and existing SSH key')
            parameters.update(AksVmIp=str(args.vm_ip), SshPrivateKeyBase64=private_key(args.ssh_key))
        if args.node_inspection == 'Kubernetes':
            if not args.api_ip:
                parser.error('Kubernetes inspection needs the configured private API IP for TLS verification')
            parameters['AksApiIp'] = str(args.api_ip)
    if args.action == 'inspect-bridge':
        if not args.bridge_kubeconfig or not args.cluster_name:
            parser.error('Bridge inspection needs the existing private kubeconfig and cluster name')
        path = args.bridge_kubeconfig.expanduser()
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            parser.error('Bridge kubeconfig must be an owner-only regular file')
        parameters.update(BridgeKubeconfigBase64=base64.b64encode(path.read_bytes()).decode(), AksClusterName=args.cluster_name)
    spec = importlib.util.spec_from_file_location('smal_private_transport', ROOT / 'scripts/smal-private-powershell.py')
    transport = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(transport)
    return transport.main('scripts/smal-platform.ps1', parameters=parameters, timeout=args.timeout)


if __name__ == '__main__':
    raise SystemExit(main())
