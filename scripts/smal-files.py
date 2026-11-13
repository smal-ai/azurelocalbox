"""Operate only the dedicated SMAL Windows file service through pinned private transport."""
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import uuid
from datetime import datetime, timedelta, timezone

ROOT = Path(__file__).resolve().parents[1]
STATE = Path.home() / '.local/state/smal/infra/data/smb'
SUBSCRIPTION = '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea'


def az(*arguments):
    result = subprocess.run(['az', *arguments, '--only-show-errors', '-o', 'json'],
                            capture_output=True, text=True, timeout=180)
    if result.returncode:
        raise RuntimeError(result.stderr[:4000])
    return json.loads(result.stdout) if result.stdout.strip() else None


def private_json(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with os.fdopen(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'w') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def resource_id(kind, name, config):
    return f'/subscriptions/{SUBSCRIPTION}/resourceGroups/{config["resourceGroup"]}/providers/{kind}/{name}'


def arm_template(action, c):
    extended = {'name': c['customLocationId'], 'type': 'CustomLocation'}
    tags = {'project': 'smal', 'component': 'file-service', 'owner': 'smal-fleet'}

    def resource(kind, name, properties, **kwargs):
        return {'type': 'Microsoft.AzureStackHCI/' + kind, 'apiVersion': '2024-01-01',
                'name': name, 'location': c['location'], 'extendedLocation': extended,
                'tags': tags, 'properties': properties, **kwargs}

    parameters = {}
    if action == 'network':
        resources = [resource('logicalNetworks', 'lnet-smal-files-weu-1', {
            'vmSwitchName': 'ConvergedSwitch(managementcompute)',
            'dhcpOptions': {'dnsServers': ['10.64.0.10']},
            'subnets': [{'name': 'files', 'properties': {
                'addressPrefix': '10.64.0.0/24', 'ipAllocationMethod': 'Static', 'vlan': 0,
                'ipPools': [{'start': c['address'], 'end': c['address']}],
                'routeTable': {'properties': {'routes': [{'properties': {
                    'addressPrefix': '0.0.0.0/0', 'nextHopIpAddress': '10.64.0.1'}}]}}}}]})]
    elif action == 'image':
        resources = [resource('galleryImages', 'smal-ws2025-eval', {
            'imagePath': c['sourceDirectory'] + '\\WindowsServer2025Evaluation.vhdx',
            'containerId': c['storageContainerId'], 'osType': 'Windows', 'hyperVGeneration': 'V2'})]
    elif action == 'vm':
        machine = resource_id('Microsoft.HybridCompute/machines', c['name'], c)
        nic = resource_id('Microsoft.AzureStackHCI/networkInterfaces', c['name'] + '-nic', c)
        disks = [resource_id('Microsoft.AzureStackHCI/virtualHardDisks', c['name'] + '-' + n, c)
                 for n in ('evidence', 'workflow')]
        resources = [{'type': 'Microsoft.HybridCompute/machines', 'apiVersion': '2023-10-03-preview',
                      'name': c['name'], 'location': c['location'], 'kind': 'HCI',
                      'identity': {'type': 'SystemAssigned'}, 'tags': tags, 'properties': {}},
                     resource('networkInterfaces', c['name'] + '-nic', {
                         'ipConfigurations': [{'name': 'ipconfig1', 'properties': {
                             'subnet': {'id': resource_id('Microsoft.AzureStackHCI/logicalNetworks', 'lnet-smal-files-weu-1', c)},
                             'privateIPAddress': c['address']}}],
                         'dnsSettings': {'dnsServers': ['10.64.0.10']}})]
        for name, size in (('evidence', 32), ('workflow', 8)):
            resources.append(resource('virtualHardDisks', c['name'] + '-' + name, {
                'containerId': c['storageContainerId'], 'diskSizeGB': size,
                'diskFileFormat': 'vhdx', 'dynamic': True, 'hyperVGeneration': 'V2'}))
        vm = resource('virtualMachineInstances', 'default', {
            'hardwareProfile': {'vmSize': 'Custom', 'processors': 4, 'memoryMB': 8192},
            'networkProfile': {'networkInterfaces': [{'id': nic}]},
            'osProfile': {'computerName': c['name'], 'adminUsername': 'smalguestadmin',
                          'adminPassword': "[parameters('guestAdminPassword')]",
                          'windowsConfiguration': {'provisionVMAgent': True, 'provisionVMConfigAgent': True}},
            'securityProfile': {'enableTPM': True, 'uefiSettings': {'secureBootEnabled': True}},
            'storageProfile': {'imageReference': {'id': resource_id('Microsoft.AzureStackHCI/galleryImages', 'smal-ws2025-eval', c)},
                               'vmConfigStoragePathId': c['vmStorageContainerId'],
                               'dataDisks': [{'id': item} for item in disks]}},
            scope=machine, dependsOn=[machine, nic, *disks])
        vm.pop('location')
        vm.pop('tags')
        resources.append(vm)
        parameters = {'guestAdminPassword': {'type': 'secureString'}}
    else:
        raise ValueError('Unknown ARM component')
    return {'$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#',
            'contentVersion': '1.0.0.0', 'parameters': parameters, 'resources': resources}


def deploy(action, config):
    account = az('account', 'show', '--subscription', SUBSCRIPTION)
    platform = json.loads((ROOT / 'config/smal-platform.json').read_bytes())
    if account['id'] != SUBSCRIPTION or account['tenantId'] != platform['tenantId']:
        raise ValueError('Wrong Azure account')
    name = 'smal-file-service-' + action
    intent = STATE / (name + '-submitted.json')
    if intent.exists():
        print(json.dumps(az('deployment', 'group', 'show', '--subscription', SUBSCRIPTION,
                            '-g', config['resourceGroup'], '-n', name), indent=2))
        return 0
    directory = STATE / ('submission-' + uuid.uuid4().hex)
    template = directory / 'template.json'
    private_json(template, arm_template(action, config))
    args = ['deployment', 'group', 'create', '--subscription', SUBSCRIPTION,
            '-g', config['resourceGroup'], '-n', name, '--mode', 'Incremental', '--template-file', str(template)]
    if action == 'vm':
        secret = STATE / 'guest-admin.json'
        if not secret.exists():
            private_json(secret, {'username': 'SMAL-SMB01\\smalguestadmin',
                                  'password': secrets.token_urlsafe(36) + '!aA9'})
        credentials = json.loads(secret.read_bytes())
        parameter_file = directory / 'parameters.json'
        private_json(parameter_file, {'guestAdminPassword': {'value': credentials['password']}})
        args += ['--parameters', '@' + str(parameter_file)]
    validation = az(*(['deployment', 'group', 'validate'] + args[3:]))
    private_json(directory / 'validation.json', validation)
    private_json(intent, {'deploymentName': name, 'directory': str(directory), 'status': 'submitting-or-uncertain'})
    result = az(*(args + ['--no-wait']))
    print(json.dumps({'deployment': name, 'submission': str(intent), 'result': result}, indent=2))
    return 0


def refresh(config):
    target = resource_id('Microsoft.HybridCompute/machines', config['name'], config) + '/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default'
    current = az('rest', '--method', 'get', '--url', 'https://management.azure.com' + target + '?api-version=2024-01-01')
    if current['properties']['vmId'] != config['armVmId'] or current['properties']['status']['powerState'] != 'Running':
        raise ValueError('Original running file VM required for refresh')
    if current['properties']['hardwareProfile']['processors'] != 4 or current['properties']['hardwareProfile']['memoryMB'] != 8192:
        raise ValueError('Original file VM profile differs')
    path = STATE / 'vm-refresh-submitted.json'
    if path.exists() or current['properties']['provisioningState'] == 'Succeeded':
        print(json.dumps(current, indent=2))
        return 0
    private_json(path, {'target': target, 'before': current, 'status': 'submitting-or-uncertain'})
    result = az('stack-hci-vm', 'update', '--subscription', SUBSCRIPTION, '-g', config['resourceGroup'],
                '--name', config['name'], '--enable-agent', 'true', '--enable-vm-config-agent', 'true')
    private_json(STATE / 'vm-refresh-result.json', result)
    print(json.dumps(result, indent=2))
    return 0


def probe_job_name(node_name, probe_id=None):
    if not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', node_name):
        raise ValueError('Concrete workload node name required')
    if probe_id is not None:
        if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,19}', probe_id):
            raise ValueError('Probe identity must be 1–20 lower-case name characters')
        name = 'smal-smb-write-read-' + probe_id + '-' + node_name
    else:
        name = 'smal-smb-write-read' if node_name == 'moc-lot89khy1qp' else 'smal-smb-write-read-' + node_name
    if len(name) > 63:
        raise ValueError('Bounded probe job name required')
    return name


def probe(config, node_name='moc-lot89khy1qp', probe_id=None):
    job_name = probe_job_name(node_name, probe_id)
    command = ['kubectl', '--kubeconfig', str(Path.home() / '.local/state/smal/infra/kubernetes/proxy-kubeconfig'),
               '--context', 'smal-aks', '--request-timeout=30s']

    def kubectl(*args, value=None, timeout=60):
        result = subprocess.run(command + list(args), input=json.dumps(value) if value else None,
                                capture_output=True, text=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(result.stderr[:4000])
        return result.stdout

    driver = json.loads(kubectl('get', 'csidriver', 'smb.csi.akshci.com', '-o', 'json'))
    node = json.loads(kubectl('get', 'node', node_name, '-o', 'json'))
    if driver['spec']['attachRequired'] or node['metadata']['labels'].get('smal.ai/pool') != 'workload':
        raise ValueError('Expected native SMB CSI and workload node')
    if not any(row['type'] == 'Ready' and row['status'] == 'True' for row in node['status']['conditions']):
        raise ValueError('Workload node is not Ready')
    namespace = 'smal-smb-probe'
    resources = [{'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': namespace, 'labels': {
        'smal.ai/owner': 'smb-deployment', 'pod-security.kubernetes.io/enforce': 'restricted'}}}]
    for role, account, share, size in (('evidence', 'smal_evidence_writer', 'smal-evidence', '32Gi'),
                                       ('workflow', 'smal_workflow_assets', 'smal-workflows', '8Gi')):
        credentials = json.loads((STATE / (account + '.json')).read_bytes())
        name = 'smal-smb-probe-' + role
        resources.extend([
            {'apiVersion': 'v1', 'kind': 'Secret', 'metadata': {'name': name, 'namespace': namespace},
             'type': 'Opaque', 'stringData': {'username': account, 'domain': 'SMAL-SMB01', 'password': credentials['password']}},
            {'apiVersion': 'v1', 'kind': 'PersistentVolume', 'metadata': {'name': name}, 'spec': {
                'capacity': {'storage': size}, 'accessModes': ['ReadWriteMany'], 'storageClassName': '',
                'persistentVolumeReclaimPolicy': 'Retain', 'claimRef': {'name': name, 'namespace': namespace},
                'mountOptions': ['vers=3.1.1', 'seal', 'nosuid', 'nodev', 'noexec', 'uid=10001', 'gid=10001',
                                 'file_mode=0600', 'dir_mode=0700'],
                'csi': {'driver': 'smb.csi.akshci.com', 'volumeHandle': name,
                        'volumeAttributes': {'source': '//' + config['address'] + '/' + share},
                        'nodeStageSecretRef': {'name': name, 'namespace': namespace}}}},
            {'apiVersion': 'v1', 'kind': 'PersistentVolumeClaim', 'metadata': {'name': name, 'namespace': namespace},
             'spec': {'storageClassName': '', 'volumeName': name, 'accessModes': ['ReadWriteMany'],
                      'resources': {'requests': {'storage': size}}}},
        ])
    script = '''set -eu
for share in evidence workflow; do
  path="/$share/.smal-native-probe-${HOSTNAME}"
  test ! -e "$path"
  printf '%s\\n' "SMAL authenticated SMB native write/read $share ${HOSTNAME}" > "$path.tmp"
  sync
  mv "$path.tmp" "$path"
  expected="SMAL authenticated SMB native write/read $share ${HOSTNAME}"
  test "$(cat "$path")" = "$expected"
  sha256sum "$path"
  rm "$path"
  awk -v p="/$share" '$2==p && $3=="cifs" {if($4 !~ /vers=3.1.1/ || $4 !~ /seal/) exit 1; found=1; print "encrypted SMB 3.1.1 mount verified: " p} END {if(!found) exit 1}' /proc/mounts
done
echo 'SMB_WRITE_READ_ACCEPTED'
'''
    resources.append({'apiVersion': 'batch/v1', 'kind': 'Job', 'metadata': {'name': job_name, 'namespace': namespace},
        'spec': {'backoffLimit': 0, 'activeDeadlineSeconds': 300, 'template': {'metadata': {'labels': {'app': 'smal-smb-probe'}},
        'spec': {'restartPolicy': 'Never', 'automountServiceAccountToken': False,
                 'nodeSelector': {'kubernetes.io/hostname': node_name, 'smal.ai/pool': 'workload'},
                 'securityContext': {'runAsNonRoot': True, 'runAsUser': 10001, 'runAsGroup': 10001,
                                     'seccompProfile': {'type': 'RuntimeDefault'}},
                 'containers': [{'name': 'probe', 'image': 'mcr.microsoft.com/oss/busybox/busybox:1.33.1',
                                 'command': ['/bin/sh', '-c', script],
                                 'resources': {'requests': {'cpu': '50m', 'memory': '32Mi'}, 'limits': {'cpu': '100m', 'memory': '64Mi'}},
                                 'securityContext': {'allowPrivilegeEscalation': False, 'readOnlyRootFilesystem': True,
                                                     'capabilities': {'drop': ['ALL']}},
                                 'volumeMounts': [{'name': role, 'mountPath': '/' + role} for role in ('evidence', 'workflow')]}],
                 'volumes': [{'name': role, 'persistentVolumeClaim': {'claimName': 'smal-smb-probe-' + role}}
                             for role in ('evidence', 'workflow')]}}}})
    manifest = {'apiVersion': 'v1', 'kind': 'List', 'items': resources}
    private_json(STATE / ('probe-manifest-' + uuid.uuid4().hex + '.json'), manifest)
    print(kubectl('apply', '-f', '-', value=manifest))
    print(kubectl('wait', '-n', namespace, 'job/' + job_name, '--for=condition=complete', '--timeout=330s', timeout=360))
    logs = kubectl('logs', '-n', namespace, 'job/' + job_name)
    private_json(STATE / ('probe-result-' + uuid.uuid4().hex + '.json'), {'logs': logs,
                 'job': json.loads(kubectl('get', 'job', '-n', namespace, job_name, '-o', 'json'))})
    print(logs)
    if 'SMB_WRITE_READ_ACCEPTED' not in logs:
        raise ValueError('Native SMB write/read acceptance missing')
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('inspect', 'prepare-image', 'inspect-native', 'guest-access', 'guest-inspect', 'configure-guest', 'restart-guest',
                                         'network', 'image', 'vm', 'refresh', 'inspect-arm', 'probe'))
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--node', default='moc-lot89khy1qp', help='Ready workload-pool node for the SMB acceptance probe')
    parser.add_argument('--probe-id', help='Fresh bounded verification identity. Reuse it only to observe the original Job.')
    args = parser.parse_args()
    config = json.loads((ROOT / 'config/smal-files.json').read_bytes())
    if args.action == 'probe':
        return probe(config, args.node, args.probe_id)
    if args.action == 'refresh':
        return refresh(config)
    if args.action in ('network', 'image', 'vm'):
        return deploy(args.action, config)
    if args.action == 'inspect-arm':
        print(json.dumps(az('resource', 'list', '--subscription', SUBSCRIPTION,
                            '-g', config['resourceGroup'], '--tag', 'component=file-service'), indent=2))
        return 0
    parameters = {
        'Action': {'inspect': 'Inspect', 'prepare-image': 'PrepareImage',
                   'inspect-native': 'InspectNative', 'guest-access': 'GuestAccess', 'guest-inspect': 'GuestInspect', 'configure-guest': 'ConfigureGuest', 'restart-guest': 'RestartGuest'}[args.action],
        'PlatformBase64': base64.b64encode((ROOT / 'config/smal-platform.json').read_bytes()).decode(),
        'FilesBase64': base64.b64encode((ROOT / 'config/smal-files.json').read_bytes()).decode(),
    }
    if args.action in ('inspect-native', 'guest-access', 'guest-inspect', 'configure-guest', 'restart-guest'):
        vm_id = resource_id('Microsoft.HybridCompute/machines', config['name'], config) + '/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default'
        vm = az('rest', '--method', 'get', '--url', 'https://management.azure.com' + vm_id + '?api-version=2024-01-01')
        native_id = vm['properties'].get('vmId') or vm['properties'].get('resourceUid')
        if not native_id:
            raise ValueError('ARM has not reported the native VM identity')
        if str(uuid.UUID(native_id)) != config['armVmId']:
            raise ValueError('Original ARM VM identity changed')
        parameters['VmId'] = str(uuid.UUID(config['hyperVVmId']))
        credentials = {'admin': json.loads((STATE / 'guest-admin.json').read_bytes())}
        if args.action == 'configure-guest':
            credentials['accounts'] = []
            for name in ('smal_evidence_writer', 'smal_workflow_assets'):
                path = STATE / (name + '.json')
                if not path.exists():
                    private_json(path, {'username': 'SMAL-SMB01\\' + name,
                                        'password': secrets.token_urlsafe(36) + '!aA9',
                                        'expiresAtUtc': (datetime.now(timezone.utc) + timedelta(days=365)).isoformat()})
                credentials['accounts'].append(json.loads(path.read_bytes()))
            source = Path('/home/quintin/play/smal-ai-infra/solution/infra/data')
            parameters['AccountSourceBase64'] = base64.b64encode((source / 'Set-ServiceAccount.ps1').read_bytes()).decode()
            parameters['ShareSourceBase64'] = base64.b64encode((source / 'Configure-FileService.ps1').read_bytes()).decode()
        parameters['SecretsBase64'] = base64.b64encode(json.dumps(credentials).encode()).decode()
    spec = importlib.util.spec_from_file_location('transport', ROOT / 'scripts/smal-private-powershell.py')
    transport = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(transport)
    return transport.main('scripts/smal-files.ps1', parameters=parameters, timeout=args.timeout)


if __name__ == '__main__':
    raise SystemExit(main())
