"""Derive exact approved three-node No Witness templates. No Azure operations."""
import copy
import json
from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'infra/arm'


def build():
    original = runpy.run_path(str(ROOT / 'scripts/derive-smal-cluster-templates.py'), run_name='three_node_pinned_derivation')['build']()
    plan = json.loads((ROOT / 'docs/deployment-2026-10-29/three-node-proposal.json').read_text())
    approved = json.loads((ROOT / 'docs/deployment-2026-10-29/three-node-approval.json').read_text())
    if approved.get('approved') is not True or approved.get('threeNodeNoWitnessDeploymentApprovedSubjectToExactIdsAndEffectChecks') is not True or plan['cloudDelta']['witnessTypeParameter'] != 'No Witness':
        raise RuntimeError('Exact three-node No Witness approval required')
    prerequisites = copy.deepcopy(original['localbox-cluster-prerequisites.json'])
    settings = copy.deepcopy(original['localbox-cluster-settings.json'])
    secrets = copy.deepcopy(original['localbox-platform-secrets.json'])
    naming = json.loads((ROOT / 'docs/deployment-2026-10-29/cluster-name-correction-approval.json').read_text())
    if naming.get('approved') is not True or naming.get('humanAnswer') != 'Use smal-localbox01' or naming.get('clusterName') != 'smal-localbox01': raise RuntimeError('Exact cluster-name correction approval missing')
    scope = '/subscriptions/8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea/resourceGroups/rg-localbox-platform-weu-1'
    names = ['LB-NODE01','LB-NODE02','LB-NODE03']
    for template in [prerequisites, settings]:
        template['parameters']['arcNodeResourceIds']['defaultValue'] = [scope + '/providers/Microsoft.HybridCompute/machines/' + name for name in names]
        template['parameters']['clusterName']['defaultValue'] = naming['clusterName']
        template['parameters']['clusterName']['allowedValues'] = [naming['clusterName']]
    settings['parameters']['physicalNodesSettings']['defaultValue'] = [{'name': name, 'ipv4Address': '10.64.0.' + str(11 + index)} for index, name in enumerate(names)]
    settings['parameters']['witnessType']['defaultValue'] = 'No Witness'
    settings['parameters']['witnessType']['allowedValues'] = ['No Witness']
    settings['parameters']['witnessType']['metadata']['description'] = 'Approved three-node system, no external witness.'
    settings['parameters']['clusterWitnessStorageAccountName']['defaultValue'] = ''
    settings['parameters']['clusterWitnessStorageAccountName']['allowedValues'] = ['']
    for index, network in enumerate(settings['parameters']['storageNetworkList']['defaultValue']):
        network['storageAdapterIPInfo'].append({'physicalNode': 'LB-NODE03', 'ipv4Address': '10.64.' + str(4 + index) + '.13', 'subnetMask': '255.255.255.0'})
    # No key read, witness secret, witness URI or unused witness storage effect.
    variables = settings['variables']
    variables['deploymentSecretsList'] = [item for item in variables['deploymentSecretsList'] if "variables('storageWitnessSecretName')" not in item['secretName']]
    for key in ['storageWitnessECEName','storageWitnessSecretName']:
        variables.pop(key)
    secrets['resources'] = [item for item in secrets['resources'] if not item['name'].endswith('-WitnessStorageKey')]
    for item in secrets['resources']:
        item['name'] = item['name'].replace('/' + naming['originalClusterName'] + '-', '/' + naming['clusterName'] + '-')
    if len(secrets['resources']) != 2 or 'listKeys' in json.dumps(secrets) or 'WitnessStorageKey' in json.dumps(settings): raise RuntimeError('No-witness derivation retained a forbidden witness effect')
    for template in [prerequisites, settings]:
        for parameter in template['parameters'].values():
            value = parameter.get('defaultValue')
            if isinstance(value,str) and (len(value) < parameter.get('minLength',0) or len(value) > parameter.get('maxLength',2**31)):
                raise RuntimeError('Derived parameter default violates its pinned length constraints')
    return {'localbox-three-node-prerequisites.json': prerequisites, 'localbox-three-node-settings.json': settings, 'localbox-three-node-secrets.json': secrets}


if __name__ == '__main__':
    for name, template in build().items():
        path = DEST / name; path.write_text(json.dumps(template, indent=2) + '\n'); print(str(path.relative_to(ROOT)))
