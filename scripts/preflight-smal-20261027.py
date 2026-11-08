"""Read-only deployment preflight. Uses current az sign-in, never legacy env/token files."""
import concurrent.futures
import datetime
import json
from pathlib import Path
import socket
import subprocess

SUB = '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea'
INFRA = '702382d0-3722-4630-8983-5580b92f0c1a'
TENANT = 'c6e67968-af25-4557-ab8b-06b693048d3b'
RG = 'rg-localbox-nodes-san-1'
NETWORK_RG = 'rg-smal-network-san-1'
HOST_SCOPE = f'/subscriptions/{SUB}/resourceGroups/{RG}'
VNET = f'/subscriptions/{SUB}/resourceGroups/{NETWORK_RG}/providers/Microsoft.Network/virtualNetworks/vnet-smal-san-1'
SUBNET = VNET + '/subnets/snet-localbox-host'
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-27'


def az_read(name, args, subscription=SUB):
    # Microsoft Graph is tenant-scoped and az ad rejects --subscription.
    # The caller verifies the tenant/subscription with account show first.
    scope_args = [] if args[0] == 'ad' else ['--subscription', subscription]
    command = ['az', *args, *scope_args, '-o', 'json', '--only-show-errors']
    result = subprocess.run(command, capture_output=True, text=True, timeout=180)
    return name, {
        'observedAtSast': datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=2))).isoformat(),
        'command': command, 'exitCode': result.returncode,
        'result': json.loads(result.stdout) if result.returncode == 0 and result.stdout.strip() else None,
        'error': result.stderr.strip() if result.returncode else None,
    }


def checks():
    yield 'identity', ['account', 'show', '--query', '{id:id,tenantId:tenantId,state:state,userType:user.type}']
    yield 'operatorObjectId', ['ad', 'signed-in-user', 'show', '--query', '{id:id}']
    yield 'hostGroup', ['group', 'show', '-n', RG, '--query', '{id:id,location:location,tags:tags}']
    yield 'hostResources', ['resource', 'list', '-g', RG, '--query', '[].{id:id,name:name,type:type,location:location}']
    yield 'localPlatformResources', ['resource', 'list', '--query', "[?type=='Microsoft.AzureStackHCI/clusters' || type=='Microsoft.ResourceConnector/appliances' || type=='Microsoft.Kubernetes/connectedClusters' || type=='Microsoft.HybridContainerService/provisionedClusters'].{id:id,name:name,type:type,location:location}"]
    yield 'vnets', ['network', 'vnet', 'list', '--query', '[].{id:id,name:name,region:location,prefixes:addressSpace.addressPrefixes,dns:dhcpOptions.dnsServers}']
    yield 'network', ['network', 'vnet', 'show', '-g', NETWORK_RG, '-n', 'vnet-smal-san-1', '--query', '{id:id,state:provisioningState,prefixes:addressSpace.addressPrefixes,dns:dhcpOptions.dnsServers,subnets:subnets[].{id:id,prefix:addressPrefix,nsg:networkSecurityGroup.id,routeTable:routeTable.id,allocations:length(ipConfigurations || `[]`),outbound:defaultOutboundAccess}}']
    yield 'hostNsg', ['network', 'nsg', 'show', '-g', NETWORK_RG, '-n', 'nsg-smal-localbox-san-1', '--query', '{id:id,rules:securityRules[].{name:name,priority:priority,access:access,direction:direction,protocol:protocol,source:sourceAddressPrefix,destination:destinationAddressPrefix,sourcePorts:sourcePortRange,destinationPorts:destinationPortRange,destinationPortRanges:destinationPortRanges}}']
    yield 'routeTable', ['network', 'route-table', 'show', '-g', NETWORK_RG, '-n', 'rt-smal-san-1', '--query', '{id:id,bgpDisabled:disableBgpRoutePropagation,routes:routes[].{name:name,prefix:addressPrefix,nextHop:nextHopType,ip:nextHopIpAddress}}']
    yield 'sku', ['vm', 'list-skus', '-l', 'southafricanorth', '--size', 'Standard_E32s_v6', '--all', '--query', "[?resourceType=='virtualMachines'].{name:name,family:family,restrictions:restrictions,capabilities:capabilities}"]
    yield 'quota', ['vm', 'list-usage', '-l', 'southafricanorth', '--query', '[].{name:name.value,current:currentValue,limit:limit}']
    yield 'windowsImages', ['vm', 'image', 'list', '-l', 'southafricanorth', '--publisher', 'MicrosoftWindowsServer', '--offer', 'WindowsServer', '--sku', '2025-datacenter-g2', '--all', '--query', '[-3:].{urn:urn,version:version}']
    yield 'hciLocations', ['provider', 'show', '-n', 'Microsoft.AzureStackHCI', '--query', "{state:registrationState,types:resourceTypes[?resourceType=='clusters'].{type:resourceType,locations:locations,apiVersions:apiVersions}}"]
    yield 'hostLocks', ['lock', 'list', '-g', RG, '--query', '[].{id:id,name:name,level:level}']
    for name, scope in [('hostPolicies', HOST_SCOPE), ('networkPolicies', f'/subscriptions/{SUB}/resourceGroups/{NETWORK_RG}')]:
        yield name, ['policy', 'assignment', 'list', '--scope', scope, '--filter', 'atScope()', '--query', '[].{id:id,name:name,displayName:displayName,scope:scope,definitionId:policyDefinitionId,enforcementMode:enforcementMode}']
    for name, scope in [('operatorHostPermissions', HOST_SCOPE), ('operatorSubnetPermissions', SUBNET)]:
        yield name, ['rest', '--method', 'get', '--url', f'https://management.azure.com{scope}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01', '--query', 'value[].{actions:actions,notActions:notActions,dataActions:dataActions,notDataActions:notDataActions}']


if __name__ == '__main__':
    OUT.mkdir(exist_ok=True)
    identity = az_read('identity', next(args for name, args in checks() if name == 'identity'))[1]
    assert identity['exitCode'] == 0 and identity['result']['tenantId'] == TENANT and identity['result']['id'] == SUB
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = dict(pool.map(lambda item: az_read(*item), checks()))
    for name, args, sub in [
        ('infraVnets', ['network', 'vnet', 'list', '--query', '[].{id:id,prefixes:addressSpace.addressPrefixes}'], INFRA),
        ('bastion', ['network', 'bastion', 'show', '-g', 'rg-bastion-san-1', '-n', 'bas-test-san-1', '--query', '{id:id,state:provisioningState,sku:sku.name,dnsName:dnsName,privateOnly:enablePrivateOnly,tunneling:enableTunneling}'], INFRA),
    ]:
        key, value = az_read(name, args, sub)
        results[key] = value
    results['quota']['result'] = [x for x in results['quota']['result'] or [] if x['name'].lower() in {'cores', 'standardesv6family'}]
    local = {}
    for address in ['10.204.0.4', '10.200.16.4']:
        r = subprocess.run(['ip', '-j', 'route', 'get', address], text=True, capture_output=True, timeout=10)
        local[address] = json.loads(r.stdout) if r.returncode == 0 else {'status': 'route-unavailable'}
    try:
        with socket.create_connection(('10.204.0.4', 53), timeout=3):
            local['resolverTcp53'] = 'reachable'
    except OSError:
        local['resolverTcp53'] = 'unreachable'
    local['host'] = socket.gethostname()
    results['actualDeploymentHost'] = local
    target = OUT / 'preflight.json'
    if target.exists():
        raise SystemExit('Existing preflight preserved. Use a new dated snapshot for a repeat.')
    target.write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps({k: v for k, v in results.items() if k in ['quota', 'actualDeploymentHost']}, indent=2))
    print(json.dumps({k: {'exitCode': v['exitCode'], 'count': len(v['result']) if isinstance(v.get('result'), list) else None} for k, v in results.items() if isinstance(v, dict) and 'exitCode' in v}, indent=2))
