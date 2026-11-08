"""Deterministically derive bounded templates from the pinned reviewed quickstart.

Generation only. Does not authenticate, access credentials or deploy anything.
"""
import copy
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'docs/deployment-2026-10-28/upstream-review/azuredeploy.json'
SOURCE_SHA = 'a95bf9a734cc7433f171a31685193ea053941b24f33111bddc9552ce20195f58'
DEST = ROOT / 'infra/arm'


def build():
    raw = SOURCE.read_bytes()
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA: raise RuntimeError('Pinned upstream source differs')
    upstream = json.loads(raw)
    proposal = json.loads((ROOT / 'docs/deployment-2026-10-28/cloud-apply-proposal.json').read_text())
    scope = '/subscriptions/' + proposal['subscriptionId'] + '/resourceGroups/' + proposal['resourceGroup']
    machines = [scope + '/providers/Microsoft.HybridCompute/machines/' + name for name in ['LB-NODE01', 'LB-NODE02']]
    values = {
        'deploymentMode': 'Validate', 'keyVaultName': proposal['keyVaultName'], 'clusterName': proposal['clusterName'],
        'location': 'westeurope', 'arcNodeResourceIds': machines, 'witnessType': 'Cloud',
        'clusterWitnessStorageAccountName': proposal['witnessStorageAccountName'], 'domainFqdn': 'ad.localbox.test',
        'namingPrefix': 'SMAL01', 'adouPath': proposal['newClusterOu'], 'securityLevel': 'Recommended',
        'streamingDataClient': True, 'episodicDataUpload': True, 'euLocation': True, 'configurationMode': 'Express',
        'subnetMask': proposal['managementPool']['mask'], 'defaultGateway': proposal['managementPool']['gateway'],
        'startingIPAddress': proposal['managementPool']['start'], 'endingIPAddress': proposal['managementPool']['end'],
        'dnsServers': proposal['managementPool']['dns'], 'useDhcp': False,
        'physicalNodesSettings': [{'name': 'LB-NODE01', 'ipv4Address': '10.64.0.11'}, {'name': 'LB-NODE02', 'ipv4Address': '10.64.0.12'}],
        'storageNetworkList': proposal['storageNetworks'], 'storageConnectivitySwitchless': False, 'enableStorageAutoIp': False,
        'customLocation': proposal['customLocationName'],
        'intentList': [
            {'name': 'ManagementCompute', 'trafficType': ['Management', 'Compute'], 'adapter': ['MGMT1', 'MGMT2'],
             'overrideVirtualSwitchConfiguration': False, 'overrideQosPolicy': False, 'overrideAdapterProperty': True,
             'adapterPropertyOverrides': {'networkDirect': 'Disabled', 'jumboPacket': '1514'}},
            {'name': 'Storage', 'trafficType': ['Storage'], 'adapter': ['STORAGEA', 'STORAGEB'],
             'overrideVirtualSwitchConfiguration': False, 'overrideQosPolicy': False, 'overrideAdapterProperty': True,
             'adapterPropertyOverrides': {'networkDirect': 'Disabled', 'jumboPacket': '1514'}}
        ]
    }
    prerequisites = {key: copy.deepcopy(upstream[key]) for key in ['$schema', 'languageVersion', 'contentVersion']}
    prerequisites['parameters'] = {key: copy.deepcopy(upstream['parameters'][key]) for key in ['deploymentMode', 'arcNodeResourceIds', 'clusterName', 'location']}
    prerequisites['parameters']['deploymentMode']['allowedValues'] = ['Validate']
    prerequisites['resources'] = {key: copy.deepcopy(upstream['resources'][key]) for key in ['edgeDevices', 'HCICluster']}
    prerequisites['resources']['edgeDevices']['dependsOn'] = []
    prerequisites['resources']['HCICluster']['dependsOn'] = ['edgeDevices']
    # Only deployment settings. Cluster/edge resources and scoped role bindings are
    # separately reconciled before this service resource can be submitted.
    settings = {key: copy.deepcopy(upstream[key]) for key in ['$schema', 'languageVersion', 'contentVersion']}
    resource = copy.deepcopy(upstream['resources']['DeploymentSettings'])
    resource.pop('dependsOn')
    settings['resources'] = {'DeploymentSettings': resource}
    var_names = ['storageWitnessECEName', 'LocalAdminCredentialECEName', 'domainAdminCredentialECEName', 'storageWitnessSecretName',
                 'LocalAdminCredentialSecretName', 'domainAdminSecretName', 'witnessTypeVar', 'clusterWitnessStorageAccountNameVar',
                 'AzureServiceEndpointVar', 'KeyVaultDNS', 'deploymentSecretsList']
    settings['variables'] = {key: copy.deepcopy(upstream['variables'][key]) for key in var_names}
    # No SBE partner credentials/properties are requested by this lab.
    resource['properties']['deploymentConfiguration']['scaleUnits'][0].pop('sbePartnerInfo')
    text = json.dumps(settings)
    used = set(re.findall(r"parameters\('([^']+)'\)", text))
    settings['parameters'] = {key: copy.deepcopy(value) for key, value in upstream['parameters'].items() if key in used}
    for key in settings['parameters']:
        if key not in values:
            values[key] = settings['parameters'][key]['defaultValue']
    # Freeze every non-mode input, not just its default. Source/approval guards
    # reject runtime edits, and ARM itself rejects alternate deployment settings.
    for template in [prerequisites, settings]:
        for key, parameter in template['parameters'].items():
            parameter['defaultValue'] = values[key]
            if key != 'deploymentMode' and parameter['type'] != 'array': parameter['allowedValues'] = [values[key]]
    secret_names = {key: proposal['clusterName'] + '-' + suffix for key, suffix in [('local', 'LocalAdminCredential'), ('domain', 'AzureStackLCMUserCredential'), ('witness', 'WitnessStorageKey')]}
    secrets = {'$schema': upstream['$schema'], 'contentVersion': '1.0.0.0', 'parameters': {'localCredential': {'type': 'securestring'}, 'domainCredential': {'type': 'securestring'}}, 'resources': []}
    for key, parameter in [('local', 'localCredential'), ('domain', 'domainCredential'), ('witness', None)]:
        value = "[parameters('" + parameter + "')]" if parameter else "[base64(listKeys(resourceId('Microsoft.Storage/storageAccounts', '" + proposal['witnessStorageAccountName'] + "'), '2023-05-01').keys[0].value)]"
        secrets['resources'].append({'type': 'Microsoft.KeyVault/vaults/secrets', 'apiVersion': '2023-07-01',
                                     'name': proposal['keyVaultName'] + '/' + secret_names[key],
                                     'properties': {'contentType': 'Secret', 'value': value, 'attributes': {'enabled': True}}})
    return {'localbox-cluster-prerequisites.json': prerequisites, 'localbox-cluster-settings.json': settings, 'localbox-platform-secrets.json': secrets}


def main():
    DEST.mkdir(exist_ok=True)
    for name, template in build().items():
        (DEST / name).write_text(json.dumps(template, indent=2) + '\n')
        print(str((DEST / name).relative_to(ROOT)))


if __name__ == '__main__':
    main()
