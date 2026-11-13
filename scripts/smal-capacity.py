"""Maintain only the existing empty NODE03 guest's selected compute profile.

Inspect is read-only. Expand records the original operation before maintenance.
Recover restores service for that operation without resubmitting a profile change.
"""
import argparse
import base64
import importlib.util
import fnmatch
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('inspect', 'expand', 'recover', 'continue', 'storage-inspect', 'grow-storage', 'restore-nested', 'quick-inspect', 'outer-storage', 'node-status', 'read-diagnostics'))
    parser.add_argument('--node', choices=('LB-NODE01', 'LB-NODE02', 'LB-NODE03'))
    parser.add_argument('--operation-id', help='Exact reconciled original operation for an explicitly released continuation')
    parser.add_argument('--timeout', type=int, default=1800)
    args = parser.parse_args()
    if (args.action in ('continue', 'grow-storage', 'restore-nested')) != bool(args.operation_id):
        parser.error('Continue, grow-storage and restore-nested require --operation-id')
    if (args.action == 'node-status') != bool(args.node):
        parser.error('Only node-status requires --node')
    if not 60 <= args.timeout <= 3600:
        parser.error('Timeout must be between 60 and 3600 seconds')
    parameters = {'Action': args.action.title().replace('-', '')}
    if args.node:
        parameters['NodeName'] = args.node
    if args.operation_id:
        from uuid import UUID
        parameters['OriginalOperationId'] = str(UUID(args.operation_id))
    for key, filename in (('ConfigurationBase64', 'smal-platform.json'),
                          ('CapacityBase64', 'smal-capacity.json')):
        parameters[key] = base64.b64encode((ROOT / 'config' / filename).read_bytes()).decode()
    spec = importlib.util.spec_from_file_location('smal_private_transport', ROOT / 'scripts/smal-private-powershell.py')
    transport = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(transport)
    if args.action in ('expand', 'continue', 'grow-storage', 'restore-nested'):
        config = json.loads((ROOT / 'config/smal-platform.json').read_bytes())
        url = ('https://management.azure.com/subscriptions/' + config['subscriptionId'] +
               '/resourceGroups/rg-smal-aks-weu-1/providers/Microsoft.Authorization/permissions?api-version=2022-04-01')
        permissions = transport.az('rest', '--method', 'get', '--url', url)
        required = 'microsoft.hybridcontainerservice/provisionedclusterinstances/agentpools/write'
        admitted = any(any(fnmatch.fnmatchcase(required, action.lower()) for action in row.get('actions', []))
                       and not any(fnmatch.fnmatchcase(required, action.lower()) for action in row.get('notActions', []))
                       for row in permissions.get('value', []))
        if not admitted:
            raise RuntimeError('Current deployment identity lacks the required Azure write permission. No dispatch.')
    return transport.main('scripts/smal-capacity.ps1', parameters=parameters, timeout=args.timeout)


if __name__ == '__main__':
    raise SystemExit(main())
