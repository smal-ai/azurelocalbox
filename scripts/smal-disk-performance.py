"""Convert only the approved two existing HDDs after a clean full-lab shutdown.

Original intents are durable. Lost responses are reconciled from current state,
never permission to repeat a stop, disk update or startup request.
"""
import argparse
import base64
from datetime import datetime, timezone, timedelta
import fcntl
import fnmatch
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
STATE = Path.home() / '.local/state/azurelocalbox'
CONFIG = json.loads((ROOT / 'config/smal-disk-performance.json').read_bytes())
SPEC = importlib.util.spec_from_file_location('smal_transport', ROOT / 'scripts/smal-private-powershell.py')
TRANSPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRANSPORT)
PATH = STATE / 'disk-performance.json'


def need(condition, message):
    if not condition:
        raise RuntimeError(message)


def now():
    return datetime.now(timezone.utc).isoformat()


def az(*parts, timeout=120):
    result = subprocess.run(['az', *parts, '--only-show-errors', '-o', 'json'],
                            capture_output=True, text=True, timeout=timeout)
    need(result.returncode == 0, 'Azure command failed. Reconcile its original intent; no automatic retry.')
    return json.loads(result.stdout) if result.stdout.strip() else None


def save(state):
    state['updatedAt'] = now()
    TRANSPORT.write_record(PATH, state)


def permissions():
    account = az('account', 'show', '--subscription', CONFIG['subscriptionId'])
    need(account['id'] == CONFIG['subscriptionId'] and account['tenantId'] == CONFIG['tenantId'], 'Wrong tenant/subscription')
    for group, actions in (
        ('rg-localbox-nodes-san-1', ('microsoft.compute/disks/write', 'microsoft.compute/virtualmachines/poweroff/action',
                                   'microsoft.compute/virtualmachines/deallocate/action', 'microsoft.compute/virtualmachines/start/action')),
        ('rg-smal-aks-weu-1', ('microsoft.hybridcontainerservice/provisionedclusterinstances/agentpools/write',))):
        url = ('https://management.azure.com/subscriptions/' + CONFIG['subscriptionId'] + '/resourceGroups/' + group +
               '/providers/Microsoft.Authorization/permissions?api-version=2022-04-01')
        rows = az('rest', '--method', 'get', '--url', url)['value']
        for action in actions:
            need(any(any(fnmatch.fnmatchcase(action, v.lower()) for v in row.get('actions', []))
                     and not any(fnmatch.fnmatchcase(action, v.lower()) for v in row.get('notActions', []))
                     for row in rows), 'Effective permission missing: ' + action)


def host():
    value = az('vm', 'show', '--ids', CONFIG['hostId'])
    need(value['id'].lower() == CONFIG['hostId'].lower() and value['hardwareProfile']['vmSize'] == CONFIG['hostSize'],
         'Exact existing outer host/profile differs')
    for selected in CONFIG['disks']:
        attachments = [d for d in value['storageProfile']['dataDisks'] if d['lun'] == selected['lun']]
        need(len(attachments) == 1 and attachments[0]['managedDisk']['id'].lower() == selected['id'].lower()
             and attachments[0].get('diskSizeGB', selected['sizeGiB']) == selected['sizeGiB'] and attachments[0]['caching'] == 'None',
             'Exact LUN/disk identity/size/caching differs')
    return value


def power():
    value = az('vm', 'get-instance-view', '--ids', CONFIG['hostId'])
    states = [s['code'] for s in value['instanceView']['statuses'] if s['code'].startswith('PowerState/')]
    need(len(states) == 1, 'Exact host power state unavailable')
    return states[0]


def wait_power(expected, seconds=600):
    deadline = time.monotonic() + seconds
    while True:
        current = power()
        if current == expected:
            return
        need(time.monotonic() < deadline, 'Original host lifecycle request has not reached ' + expected + ': ' + current)
        time.sleep(10)


def disk(selected):
    value = az('disk', 'show', '--ids', selected['id'])
    need(value['id'].lower() == selected['id'].lower() and value['uniqueId'] == selected['uniqueId']
         and value['diskSizeGB'] == selected['sizeGiB'] and value['managedBy'].lower() == CONFIG['hostId'].lower()
         and value['sku']['name'] in ('Standard_LRS', 'Premium_LRS') and value['provisioningState'] == 'Succeeded',
         'Exact original managed disk identity/size/attachment/state differs')
    if value['sku']['name'] == 'Premium_LRS':
        need(value['diskIOPSReadWrite'] == selected['iops'] and value['diskMBpsReadWrite'] == selected['mbps'],
             'Premium disk actual baseline differs')
    return value


def preserved_disk(value):
    excluded = {'sku', 'diskIOPSReadWrite', 'diskMBpsReadWrite', 'tier', 'provisioningState',
                'LastOwnershipUpdateTime', 'lastOwnershipUpdateTime', 'diskState', 'resourceGroup', 'systemData'}
    return {key: val for key, val in value.items() if key not in excluded}


def preserved_host_storage(value):
    value = json.loads(json.dumps(value['storageProfile']))
    selected_ids = {d['id'].lower() for d in CONFIG['disks']}
    for attached in value['dataDisks']:
        # ARM may omit cached attachment size while Deallocated. The exact disk
        # resource is independently checked for unchanged diskSizeGB/bytes.
        attached.pop('diskSizeGB', None)
        if attached['managedDisk']['id'].lower() in selected_ids:
            attached['managedDisk'].pop('storageAccountType', None)
    return value


def metrics():
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=15)
    value = az('monitor', 'metrics', 'list', '--resource', CONFIG['hostId'],
               '--metrics', 'Data Disk Latency', 'Data Disk IOPS Consumed Percentage', 'Data Disk Queue Depth',
               '--filter', "LUN eq '8' or LUN eq '9'", '--interval', 'PT1M', '--aggregation', 'Average', 'Maximum',
               '--start-time', start.isoformat(), '--end-time', end.isoformat())
    transport_value = {'observedAt': now(), 'start': start.isoformat(), 'end': end.isoformat(), 'metrics': value,
                       'scope': 'Post-conversion observation, not a matched-load benchmark'}
    TRANSPORT.write_record(STATE / 'disk-performance-metrics.json', transport_value)
    summary = []
    for metric in value.get('value', []):
        for series in metric.get('timeseries', []):
            data = [d for d in series.get('data', []) if d.get('average') is not None or d.get('maximum') is not None]
            summary.append({'name': metric['name']['value'], 'unit': metric['unit'],
                            'dimensions': series.get('metadatavalues', []), 'latest': data[-1] if data else None})
    return summary


def native(action, operation_id, timeout=1800, confirmation_retry=False, guest_stop_binding_retry=False):
    parameters = {'Action': action, 'OperationId': operation_id,
                  'ConfigurationBase64': base64.b64encode((ROOT / 'config/smal-platform.json').read_bytes()).decode(),
                  'PerformanceBase64': base64.b64encode((ROOT / 'config/smal-disk-performance.json').read_bytes()).decode()}
    if confirmation_retry:
        parameters['ConfirmationRetry'] = True
    if guest_stop_binding_retry:
        parameters['GuestStopBindingRetry'] = True
    # The private transport's local lock is shared with all peer operations.
    with (STATE / 'transport.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return TRANSPORT.run('scripts/smal-disk-performance.ps1', parameters=parameters, timeout=timeout)


def run(state):
    permissions()
    current_host = host()
    for selected in CONFIG['disks']:
        current_disk = disk(selected)
        if 'before' in state:
            need(preserved_disk(current_disk) == preserved_disk(state['before']['disks'][str(selected['lun'])]),
                 'Unselected disk settings changed')
    if 'before' not in state:
        need(power() == 'PowerState/running', 'Initial operation requires the existing Running lab')
        state['before'] = {'host': current_host, 'disks': {str(d['lun']): disk(d) for d in CONFIG['disks']}}
        state['phase'] = 'shutdown-intent'; save(state)
        record, receipt = native('Shutdown', state['id'], timeout=3600)
        state['shutdownReceipt'] = str(receipt); save(state)
        need(record['status'] == 'complete' and record['result']['operation']['phase'] == 'all-guests-cleanly-off',
             'Original native graceful shutdown incomplete. No Azure power/deallocation or disk update.')
        state['phase'] = 'guests-cleanly-off'; save(state)
    if state['phase'] == 'shutdown-intent':
        record, receipt = native('Inspect', state['id'], timeout=300)
        state['shutdownInspectionReceipt'] = str(receipt); save(state)
        need(record['status'] == 'complete', 'Original shutdown inspection unresolved')
        phase = record['result'].get('originalOperation', {}).get('phase')
        if phase in ('admitted', 'cluster-stop-intent', 'outer-guest-shutdown-intent'):
            previous = json.loads(Path(state['shutdownReceipt']).read_bytes())
            need(previous['status'] == 'failed', 'Original shutdown request may still be executing. No repeat.')
            state.setdefault('shutdownHistory', []).append(state['shutdownReceipt']); save(state)
            # The native helper observes completed exact role shutdowns without
            # repeating them, and rejects any unresolved original stop intent.
            retry_confirmation = phase == 'cluster-stop-intent'
            if retry_confirmation:
                need('NonInteractive mode' in previous.get('error', '') and all(v['clusterService'] == 'Running'
                     for v in record['result'].get('clusterServices', [])), 'Original cluster stop did not fail before confirmation/effect')
            retry_binding = phase == 'outer-guest-shutdown-intent'
            if retry_binding:
                need("parameter name 'Id'" in previous.get('error', '') and all(v['clusterService'] == 'Stopped'
                     for v in record['result'].get('clusterServices', [])), 'Original outer stop did not fail before parameter binding/dispatch')
            record, receipt = native('Shutdown', state['id'], timeout=3600, confirmation_retry=retry_confirmation,
                                     guest_stop_binding_retry=retry_binding)
            state['shutdownReceipt'] = str(receipt); save(state)
            need(record['status'] == 'complete', 'Original shutdown continuation did not complete')
            phase = record['result']['operation']['phase']
        need(phase == 'all-guests-cleanly-off', 'Original shutdown unresolved. No Azure power or disk effect.')
        state['phase'] = 'guests-cleanly-off'; save(state)
    if state['phase'] == 'guests-cleanly-off':
        need(power() == 'PowerState/running', 'Unexpected host state before original Azure graceful stop')
        permissions()
        state['phase'] = 'host-stop-intent'; save(state)
        # No --skip-shutdown: Azure performs its normal graceful shutdown.
        az('vm', 'stop', '--ids', CONFIG['hostId'], '--no-wait')
    if state['phase'] == 'host-stop-intent':
        wait_power('PowerState/stopped')
        state['phase'] = 'host-stopped'; save(state)
    if state['phase'] == 'host-stopped':
        permissions()
        state['phase'] = 'deallocate-intent'; save(state)
        az('vm', 'deallocate', '--ids', CONFIG['hostId'], '--no-wait')
    if state['phase'] == 'deallocate-intent':
        wait_power('PowerState/deallocated')
        state['phase'] = 'deallocated'; save(state)
    if state['phase'] in ('deallocated', 'converting'):
        need(power() == 'PowerState/deallocated', 'Conversion requires the exact Deallocated host')
        host()
        state['phase'] = 'converting'; save(state)
        for selected in CONFIG['disks']:
            key = str(selected['lun'])
            current = disk(selected)
            if current['sku']['name'] == 'Premium_LRS':
                state['requests'].setdefault(key, {'id': state['id'] + '/disk-lun-' + key, 'status': 'observed-already-matching'})
                state['requests'][key]['after'] = current; save(state)
                continue
            need(key not in state['requests'], 'Original disk update intent remains unresolved on LUN ' + key + '. No replay.')
            permissions()
            need(power() == 'PowerState/deallocated', 'Host left Deallocated before disk update')
            request = {'id': state['id'] + '/disk-lun-' + key, 'diskId': selected['id'], 'startedAt': now(),
                       'status': 'intent', 'argv': ['az', 'disk', 'update', '--ids', selected['id'], '--sku', 'Premium_LRS']}
            state['requests'][key] = request; save(state)
            after = az('disk', 'update', '--ids', selected['id'], '--sku', 'Premium_LRS', timeout=600)
            request['status'] = 'returned'; request['returnedAt'] = now(); save(state)
            after = disk(selected)
            need(after['sku']['name'] == 'Premium_LRS' and preserved_disk(after) == preserved_disk(state['before']['disks'][key]),
                 'Disk conversion/readback changed unselected settings')
            request['status'] = 'verified'; request['after'] = after; save(state)
        host()
        state['phase'] = 'converted'; save(state)
    if state['phase'] == 'converted':
        permissions()
        state['phase'] = 'canonical-startup-intent'; save(state)
        result = subprocess.run(['python3', '-B', str(ROOT / 'scripts/start-smal-localbox.py')],
                                capture_output=True, text=True, timeout=1800)
        summary = json.loads(result.stdout)
        state['startup'] = summary; save(state)
        need(result.returncode == 0, 'Original canonical startup did not complete. Inspect its retained receipt.')
        state['phase'] = 'outer-guests-running'; save(state)
    if state['phase'] == 'canonical-startup-intent':
        need(state.get('startup', {}).get('status', '').startswith('complete-'), 'Original canonical startup unresolved. No repeat.')
        state['phase'] = 'outer-guests-running'; save(state)
    if state['phase'] in ('outer-guests-running', 'restore-intent'):
        permissions()
        need(power() == 'PowerState/running', 'Host not Running during original restore')
        state['phase'] = 'restore-intent'; save(state)
        record, receipt = native('Restore', state['id'], timeout=3600)
        state['restoreReceipt'] = str(receipt); save(state)
        need(record['status'] == 'complete' and record['result']['operation']['phase'] == 'restored',
             'Original HCI/nested restore is not verified')
        state['phase'] = 'restored'; save(state)
    for selected in CONFIG['disks']:
        current = disk(selected)
        need(current['sku']['name'] == 'Premium_LRS' and preserved_disk(current) == preserved_disk(state['before']['disks'][str(selected['lun'])]),
             'Final disk identity/settings differ')
    after_host = host()
    need(preserved_host_storage(after_host) == preserved_host_storage(state['before']['host'])
         and after_host['hardwareProfile'] == state['before']['host']['hardwareProfile'], 'Host storage/controller/profile changed')
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('inspect', 'run', 'metrics'))
    args = parser.parse_args()
    TRANSPORT.private_directory(STATE)
    with (STATE / 'disk-performance.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = json.loads(PATH.read_bytes()) if PATH.exists() else None
        if args.action == 'metrics':
            print(json.dumps(metrics(), indent=2)); return 0
        if args.action == 'inspect':
            summary = {'originalOperation': state, 'hostPower': power(), 'disks': [disk(d) for d in CONFIG['disks']]}
            if power() == 'PowerState/running':
                record, receipt = native('Inspect', state['id'] if state else 'inspection-only', timeout=600)
                summary['nativeReceipt'] = str(receipt); summary['native'] = record
            print(json.dumps(summary, indent=2)); return 0
        if state is None:
            state = {'id': str(uuid.uuid4()), 'phase': 'preflight', 'createdAt': now(), 'requests': {},
                     'sourceFiles': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                     for p in [ROOT / 'scripts/smal-disk-performance.py', ROOT / 'scripts/smal-disk-performance.ps1', ROOT / 'config/smal-disk-performance.json']}}
            save(state)
        try:
            run(state)
        except (RuntimeError, OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
            state.setdefault('failures', []).append({'at': now(), 'phase': state['phase'], 'error': str(error)})
            save(state)
            print(json.dumps({'id': state['id'], 'phase': state['phase'], 'error': str(error), 'state': str(PATH)}, indent=2)); return 2
        print(json.dumps({'id': state['id'], 'phase': state['phase'], 'state': str(PATH), 'restoreReceipt': state.get('restoreReceipt'),
                          'scope': 'Native lab/disk restoration only. Kubernetes readiness remains separately required.'}, indent=2))
        return 0


if __name__ == '__main__':
    raise SystemExit(main())
