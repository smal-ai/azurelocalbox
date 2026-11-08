"""Read-only apply precheck. Never deploys, grants roles or consumes guest credentials."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / 'docs/deployment-2026-10-27'
REQUIRED_GATES = [
    'hostCostApproval',
    'hostSecurityAndOperatingWindowApproval',
    'namedScopedDeploymentPrincipalAndSubnetJoin',
    'exactPlatformAndBootstrapPins',
    'versionMatchedSourceScopedEgressAndGovernanceAcceptance',
    'nestedPrefixRoutingDnsAndReturnPathAgreement',
    'finalPolicyAdmissionValidationAndWhatIf',
    'reviewedCommitAndPushBeforeApply',
]
HOST_ONLY_GATES = [
    'hostCostApproval',
    'hostOnlyDeploymentApproval',
    'namedScopedDeploymentPrincipalAndSubnetJoin',
    'standardSecurityCapability',
    'finalPolicyAdmissionValidationAndWhatIf',
    'reviewedCommitAndPushBeforeApply',
]
SATISFIED = {'approved', 'passed', 'approved-existing-identity-scoped-operations-no-new-grants'}


def az_json(args):
    result = subprocess.run(['az', *args, '-o', 'json', '--only-show-errors'],
                            text=True, capture_output=True, timeout=90)
    if result.returncode:
        raise RuntimeError('Azure read failed; raw output suppressed')
    return json.loads(result.stdout)


def main(offline=False, phase='platform'):
    plan = json.loads((DIRECTORY / 'plan.json').read_text())
    approval = json.loads((DIRECTORY / 'owner-approvals.json').read_text())
    gates = HOST_ONLY_GATES if phase == 'host-only' else REQUIRED_GATES
    pending = [name for name in gates if plan['gates'].get(name) not in SATISFIED]
    if not approval['hostCostProposalApproved'] or not plan['retailCostProposal']['approved']:
        pending.append('host-cost-approval')
    principal = approval['approvedExistingDeploymentPrincipalId']
    if plan['deploymentPrincipal']['approvedObjectId'] != principal:
        pending.append('matching-named-principal-approval')
    if phase == 'host-only' and not approval.get('hostOnlyDeploymentApproved'):
        pending.append('explicit-host-only-deployment-approval')
    if pending:
        print(json.dumps({'readyToApply': False, 'pending': pending, 'azureApplyAttempted': False}, indent=2))
        return 2
    if offline:
        print(json.dumps({'localGatesSatisfied': True, 'liveAzurePrecheck': 'not-run', 'azureApplyAttempted': False}))
        return 0
    identity = az_json(['account', 'show', '--subscription', plan['subscriptionId'],
                        '--query', '{id:id,tenantId:tenantId,state:state}'])
    signed_in = az_json(['ad', 'signed-in-user', 'show', '--query', '{id:id}'])
    if identity['id'] != plan['subscriptionId'] or identity['tenantId'] != plan['tenantId'] or signed_in['id'] != principal:
        raise RuntimeError('Azure identity/scope changed; stop for review')
    resources = az_json(['resource', 'list', '--subscription', plan['subscriptionId'],
                         '-g', plan['resourceGroup'], '--query', '[].{id:id,type:type}'])
    if resources:
        raise RuntimeError('Host resource group no longer empty; reconcile resources before applying')
    print(json.dumps({'readyForReviewedApply': True, 'azureApplyAttempted': False,
                      'warning': 'This precheck is not human approval, deployment or platform readiness.'}))
    return 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--phase', choices=['platform', 'host-only'], default='platform')
    options = parser.parse_args()
    try:
        sys.exit(main(options.offline, options.phase))
    except Exception as error:
        print(json.dumps({'readyToApply': False, 'errorType': type(error).__name__, 'azureApplyAttempted': False}))
        sys.exit(1)
