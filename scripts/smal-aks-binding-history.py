"""Read-only preservation verifier extracted from committed f28ff52 binding source.

The already applied PATCH has no executor in this migration. Original approval and
receipt remain at the old root. Importing source cannot authorise another PATCH.
"""
import copy
import hashlib
import json

SUB = '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea'
SCOPE = f'/subscriptions/{SUB}/resourceGroups/rg-localbox-platform-weu-1'
CL = SCOPE + '/providers/Microsoft.ExtendedLocation/customLocations/cl-localbox-smal-weu-1'
BRIDGE = SCOPE + '/providers/Microsoft.ResourceConnector/appliances/smal-localbox01-arcbridge'
EXT = BRIDGE + '/providers/Microsoft.KubernetesConfiguration/extensions/'
VM_EXT, AKS_EXT = EXT + 'vmss-hci', EXT + 'hybridaksextension'
EXPECTED_EXT = {VM_EXT: ('microsoft.azstackhci.operator', 'helm-operator2'),
                AKS_EXT: ('microsoft.hybridaksoperator', 'hybridaks-operator-system')}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def enabled_projection(values):
    result = {}
    for r in values:
        p = r['properties']
        extension = p['clusterExtensionId']
        require(extension in EXPECTED_EXT, 'Unexpected enabled extension/role')
        require(p['extensionType'].lower() == EXPECTED_EXT[extension][0], 'Enabled extension type mismatch')
        require(extension not in result, 'Duplicate enabled mapping')
        types = sorted([[t['resourceProviderNamespace'].lower(), t['resourceType'].lower(), t['apiVersion']]
                        for t in p['typesMetadata']])
        stable = copy.deepcopy(p)
        stable['typesMetadata'] = sorted(p['typesMetadata'], key=lambda t: json.dumps(t, sort_keys=True))
        result[extension] = {'propertiesSha256': sha(stable), 'allTypesSha256': sha(types), 'allTypesCount': len(types),
                             'types': [t for t in types if t[2] == '2024-01-01']}
    return result


def preservation(resource):
    result = copy.deepcopy(resource)
    result['properties'].pop('clusterExtensionIds', None)
    result['properties'].pop('provisioningState', None)
    result.pop('etag', None)
    for k in ('lastModifiedAt', 'lastModifiedBy', 'lastModifiedByType'):
        result.get('systemData', {}).pop(k, None)
    return result


def verify_retained(baseline, current):
    require(current['customLocation']['id'].lower() == CL.lower(), 'Wrong custom location')
    p = current['customLocation']['properties']
    require(p['clusterExtensionIds'] == [VM_EXT, AKS_EXT] and p['hostResourceId'].lower() == BRIDGE.lower()
            and p['namespace'] == 'default' and p['authentication'] == {} and p['provisioningState'] == 'Succeeded', 'Binding differs')
    require(preservation(current['customLocation']) == preservation(baseline['customLocation']), 'Unknown/preserved CL field drift')
    require(current['extensions'] == baseline['extensions'] and current['resourceBindings'] == baseline['resourceBindings'], 'Extension/four binding drift')
    require(current['enabled'][VM_EXT] == baseline['enabled'][VM_EXT], 'All original VM mapping properties/tuples must survive')
    for typ in ('skus', 'kubernetesversions', 'provisionedclusterinstances'):
        require(['microsoft.hybridcontainerservice', typ, '2024-01-01'] in current['enabled'][AKS_EXT]['types'], 'AKS required API/type absent')
    return 'retained-observation-verified-not-current-readiness'
