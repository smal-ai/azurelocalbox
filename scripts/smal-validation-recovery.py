"""Read-only gates distinguishing initial ValidationFailed from DeploymentFailed."""
import json
from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
D = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='initial_validation_recovery_reads')
ERROR = 'Domain user credential object cannot contain domain name as part of Username.'
NETWORK_ERROR = 'NetworkInfraConnection requirements not met. Review output and remediate.'


def exceptions(action):
    result = []
    for step in action.get('steps',[]) or []:
        result.extend(step.get('exception',[]) or []); result.extend(exceptions({'steps':step.get('steps') or []}))
    return result


def verify_initial_validation(cluster,settings,deployments,expected_error=ERROR):
    cp = cluster['properties']; props = settings['properties']; reported = props.get('reportedProperties') or {}
    validation = reported.get('validationStatus') or {}; deployed = reported.get('deploymentStatus') or {}
    if (cluster['id'].lower() != D['CLUSTER'].lower() or cp.get('status') != 'ValidationFailed' or cp.get('provisioningState') != 'Succeeded'
            or cluster['identity']['principalId'] != '8c44672b-b729-4d3f-ad38-a0ac815ea265'
            or settings['id'].lower() != D['SETTINGS'].lower() or props.get('deploymentMode') != 'Validate'
            or props.get('provisioningState') != 'Failed' or validation.get('status') != 'Error'
            or deployed.get('status') not in [None,'','NotStarted'] or deployed.get('steps') or deployments):
        raise RuntimeError('Not the exact terminal initial-validation failure. Never retry Validate after deployment starts/fails.')
    errors = exceptions(validation)
    if expected_error not in [ERROR,NETWORK_ERROR] or not errors or any(expected_error not in str(item) for item in errors): raise RuntimeError('Current failure does not match the exact diagnosed validation error')
    return {'clusterStatus':cp['status'],'mode':props['deploymentMode'],'provisioningState':props['provisioningState'],'validationStatus':validation['status'],
            'deploymentStatus':deployed.get('status'),'deployArmRecords':deployments,'knownLcmFormatErrorMatched':expected_error == ERROR,'knownInfraNetworkErrorMatched':expected_error == NETWORK_ERROR}


def current_failure(expected_error=ERROR):
    cluster = D['L']['rest'](D['CLUSTER']); settings = D['L']['rest'](D['SETTINGS'])
    deployments = D['az'](['deployment','group','list','--subscription',D['SUB'],'-g',D['RG'],'--query',"[?name=='localbox-three-node-deploy-20261029'].name"])
    return verify_initial_validation(cluster,settings,deployments,expected_error)
