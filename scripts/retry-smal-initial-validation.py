"""One state-guarded initial-validation retry after exact LCM username correction.

Never applies to DeploymentFailed or active tasks. Updates only the existing
deploymentSettings resource via its documented CreateOrUpdate operation. Does not
reapply cluster, edges, identities, roles, secrets, licences or storage.
"""
import argparse
import contextlib
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
REC = runpy.run_path(str(ROOT / 'scripts/smal-validation-recovery.py'),run_name='initial_validation_retry_guard')
D = REC['D']; OUT = D['OUT']; ACTION = 'localbox-three-node-validate-lcm-format-20261029'


def validate_retry_preview(preview,owned):
    if preview.get('status') != 'Succeeded': raise RuntimeError('Corrected validation preview failed')
    seen = []
    for row in preview.get('changes',[]):
        rid = row.get('resourceId','').lower(); kind = row.get('changeType')
        if rid == D['SETTINGS'].lower():
            if kind not in ['NoChange','Modify']: raise RuntimeError('Retry must update the existing settings, never create/delete them')
            before = row.get('before',{}).get('properties',{}); after = row.get('after',{}).get('properties',{})
            for key in ['deploymentMode','arcNodeResourceIds','deploymentConfiguration']:
                previous = before.get(key); desired = after.get(key)
                if key == 'arcNodeResourceIds': previous,desired = ({str(rid).lower() for rid in previous or []},{str(rid).lower() for rid in desired or []})
                if previous != desired: raise RuntimeError('Configuration changed beyond the external LCM encoding correction')
            if after.get('deploymentMode') != 'Validate': raise RuntimeError('Retry may not start deployment')
            seen.append({'id':row['resourceId'],'changeType':kind})
        elif kind not in ['Ignore','NoChange'] or rid not in owned or row.get('before') != row.get('after'):
            raise RuntimeError('Unlisted resource effect in initial validation retry')
    if len(seen) != 1: raise RuntimeError('Exactly the existing deployment-settings resource must be previewed')
    return seen


def verify_echo_recovery(fix,proof):
    if fix.get('status') != 'complete-scoped-rule-and-three-node-echo-verified' or fix.get('gatewayAndDcEchoVerifiedOnAllThreeNodes') is not True:
        raise RuntimeError('Verified approved gateway echo correction missing')
    if proof.get('status') != 'complete' or proof.get('result',{}).get('mutationPerformed') is not False:
        raise RuntimeError('Complete read-only current gateway echo proof required')
    data = proof['result']; nodes = data.get('nodes',[])
    if len(nodes) != 3 or {row['name'] for row in nodes} != set(D['P']['NODES']): raise RuntimeError('Exact three-node network probe set differs')
    for node in nodes:
        if {row['destination']:row['echoReplyReceived'] for row in node['guest']['probes']} != {'10.64.0.1':True,'10.64.0.10':True}:
            raise RuntimeError('Current gateway/DC echoes did not pass on all three nodes')
    rules = [row for row in data.get('hostIcmpInboundRules',[]) if row['name'] == 'AzureLocalBox-InternalGateway-Echo-v4']
    if len(rules) != 1: raise RuntimeError('Exact scoped effective gateway echo rule missing')
    rule = rules[0]
    if (rule.get('enabled') != 'True' or rule.get('action') != 'Allow' or rule.get('protocol') != 'ICMPv4'
            or rule.get('icmpType') != ['8'] or rule.get('localAddress') != ['10.64.0.1']
            or set(rule.get('remoteAddress',[])) != {'10.64.0.11-10.64.0.13','10.64.0.20-10.64.0.30'}
            or rule.get('interfaceAlias') != ['vEthernet (LB-Fabric)']):
        raise RuntimeError('Current gateway echo rule scope drifted')


def verify_unsubmitted_gateway(prior,reconciliation):
    current_hash = hashlib.sha256((ROOT / D['TEMPLATES']['validate']).read_bytes()).hexdigest()
    if (prior.get('status') != 'failed-inspect-before-resume' or prior.get('stage') != 'validate'
            or prior.get('deploymentName') != 'localbox-three-node-validate-gateway-echo-20261029'
            or prior.get('templateSha256') != current_hash or prior.get('deploySubmitted') is not False
            or any(key in prior for key in ['previewChanges','deploymentId','deploymentState'])
            or not prior.get('currentGatewayEchoProof')):
        raise RuntimeError('Not the exact retained pre-preview gateway validation refusal')
    if (reconciliation.get('status') != 'read-only-reconciled-before-submission-authorization-refusal'
            or reconciliation.get('errorCode') != 'AuthorizationFailed'
            or reconciliation.get('deniedAction') != 'Microsoft.Resources/deployments/whatIf/action'
            or reconciliation.get('gatewayRetryOrDeployArmRecords') != []
            or reconciliation.get('azureMutationPerformed') is not False):
        raise RuntimeError('Exact unsubmitted what-if authorisation-refusal proof missing')


def main(wait_seconds=1800,gateway_echo=False,resume_unsubmitted=False):
    paths = ['scripts/retry-smal-initial-validation.py','scripts/smal-validation-recovery.py','scripts/deploy-smal-three-node-cluster.py',
        'infra/arm/localbox-three-node-settings.json','docs/deployment-2026-10-29/three-node-cluster-validate-receipt.json',
        'docs/deployment-2026-10-29/lcm-credential-format-correction-receipt.json']
    action = ACTION; filename = 'three-node-cluster-validate-after-lcm-format-fix-receipt.json'
    expected_error = REC['ERROR']
    if gateway_echo:
        paths += ['docs/deployment-2026-10-29/gateway-echo-rule-approval.json','docs/deployment-2026-10-29/gateway-echo-rule-receipt.json',
                  'docs/deployment-2026-10-29/three-node-corrected-validation-observation.json','scripts/inspect-smal-infra-network-failure.ps1','scripts/smal-private-powershell.py']
        action = 'localbox-three-node-validate-gateway-echo-20261029'; filename = 'three-node-cluster-validate-after-gateway-echo-receipt.json'
        expected_error = REC['NETWORK_ERROR']
    if resume_unsubmitted:
        if not gateway_echo: raise RuntimeError('Only the exact unsubmitted gateway retry may be reconciled')
        prior_name = 'docs/deployment-2026-10-29/three-node-cluster-validate-after-gateway-echo-receipt.json'
        refusal_name = 'docs/deployment-2026-10-29/gateway-validation-unsubmitted-auth-reconciliation.json'
        paths += [prior_name,refusal_name,'docs/deployment-2026-10-29/gateway-validation-access-restored-20261030.json']
        filename = 'three-node-cluster-validate-gateway-after-auth-reconciliation-receipt.json'
    head = D['A']['source_guard'](paths)
    path = OUT / filename
    record = {'beganAtUtc':datetime.now(timezone.utc).isoformat(),'sourceCommit':head,'status':'pending','stage':'validate',
              'deploymentName':action,'initialValidationOnly':True,'deploySubmitted':False,'clusterReapplied':False,'rolesOrSecretsReapplied':False,'platformReadinessVerified':False}
    if resume_unsubmitted:
        prior_bytes = (ROOT / prior_name).read_bytes()
        verify_unsubmitted_gateway(json.loads(prior_bytes),json.loads((ROOT / refusal_name).read_text()))
        record['originalUnsubmittedRefusalRetained'] = True
        record['originalUnsubmittedReceiptSha256'] = hashlib.sha256(prior_bytes).hexdigest()
    with path.open('x') as stream: stream.write(json.dumps(record,indent=2) + '\n')
    def save(): path.write_text(json.dumps(record,indent=2) + '\n')
    try:
        D['preflight'](); record['terminalInitialValidationProof'] = REC['current_failure'](expected_error)
        if gateway_echo:
            approval = json.loads((OUT / 'gateway-echo-rule-approval.json').read_text())
            if approval.get('approved') is not True or approval.get('continueApprovedDeploymentAfterVerifiedConnectivityAndValidationGates') is not True: raise RuntimeError('Gateway correction/continuation approval missing')
            failed = json.loads((OUT / 'three-node-corrected-validation-observation.json').read_text())
            if failed.get('deploymentState') != 'Failed' or failed.get('deploySubmitted') is not False or failed.get('templateSha256') != hashlib.sha256((ROOT / D['TEMPLATES']['validate']).read_bytes()).hexdigest(): raise RuntimeError('Prior terminal network validation/configuration proof differs')
        original_path = OUT / 'three-node-cluster-validate-receipt.json'; original = json.loads(original_path.read_text())
        current_hash = hashlib.sha256((ROOT / D['TEMPLATES']['validate']).read_bytes()).hexdigest()
        if original.get('stage') != 'validate' or original.get('deploymentState') != 'Failed' or original.get('templateSha256') != current_hash: raise RuntimeError('Original failed validation/settings hash does not match exactly')
        fix = json.loads((OUT / 'lcm-credential-format-correction-receipt.json').read_text())
        if fix.get('status') != 'complete-one-lcm-username-format-version-only' or fix.get('unqualifiedCredentialReadbackMatched') is not True or fix.get('passwordRotated') is not False: raise RuntimeError('Exact successful username-only secret correction proof missing')
        current_secret = D['az'](['keyvault','secret','show','--subscription',D['SUB'],'--vault-name','kv-lbox-weu-4766ea','--name',D['NAME'] + '-AzureStackLCMUserCredential','--query','{id:id,enabled:attributes.enabled}'])
        if current_secret != {'id':fix['newVersionId'],'enabled':True}: raise RuntimeError('Corrected LCM secret latest metadata differs')
        if D['az'](['deployment','group','list','--subscription',D['SUB'],'-g',D['RG'],'--query',"[?name=='" + action + "'].name"]): raise RuntimeError('Retry deployment identity already exists. Inspect, never repeat.')
        input_stage = 'validate-gateway-auth-resume' if resume_unsubmitted else ('validate-gateway-echo-fix' if gateway_echo else 'validate-lcm-format-fix')
        record['privateInputsReceipt'] = D['inspect_inputs'](input_stage)
        if gateway_echo:
            network_name = 'infra-network-before-validation-auth-resume-20261030' if resume_unsubmitted else 'infra-network-before-validation-retry-20261029'
            with contextlib.redirect_stdout(io.StringIO()): code = D['T']['main']('scripts/inspect-smal-infra-network-failure.ps1',network_name)
            network_path = D['T']['OUT'] / ('private-ssh-' + network_name + '.json')
            if code != 0: raise RuntimeError('Current pre-retry network inspection failed')
            verify_echo_recovery(json.loads((OUT / 'gateway-echo-rule-receipt.json').read_text()),json.loads(network_path.read_text()))
            record['currentGatewayEchoProof'] = str(network_path.relative_to(ROOT))
        record['originalFailedReceiptSha256'] = hashlib.sha256(original_path.read_bytes()).hexdigest(); record['templateSha256'] = current_hash
        record['correctedLcmVersionId'] = fix['newVersionId']
        owned = {rid.lower() for rid in D['az'](['resource','list','--subscription',D['SUB'],'-g',D['RG'],'--query','[].id'])} | {row['id'].lower() for row in D['R']['assignments']()}
        args = ['--subscription',D['SUB'],'-g',D['RG'],'-n',action,'--template-file',str(ROOT / D['TEMPLATES']['validate']),'--parameters','@-']
        parameters = {'deploymentMode':{'value':'Validate'}}
        preview = D['az'](['deployment','group','what-if',*args,'--result-format','FullResourcePayloads','--no-pretty-print'],parameters,timeout=300)
        record['previewChanges'] = validate_retry_preview(preview,owned)
        # Recheck terminal/non-deployment state immediately before the single PUT.
        REC['current_failure'](expected_error)
        record['status'] = 'existing-settings-validation-retry-pending'; save()
        D['az'](['deployment','group','create',*args,'--no-wait'],parameters,timeout=180)
        record['status'] = 'submitted-observe-before-deploy'; save(); deadline = time.monotonic() + wait_seconds
        while True:
            arm = D['az'](['deployment','group','show','--subscription',D['SUB'],'-g',D['RG'],'-n',action,'--query','{id:id,state:properties.provisioningState,code:properties.error.code}'])
            record['deploymentId'] = arm['id']; record['deploymentState'] = arm['state']; record['deploymentErrorCode'] = arm.get('code'); save()
            if arm['state'] in ['Failed','Canceled']: raise RuntimeError('Corrected initial validation failed. Preserve this attempt; no automatic retry or Deploy.')
            if arm['state'] == 'Succeeded':
                result = D['service_result']('validate'); record['serviceResult'] = result; save()
                if D['service_passed'](result): break
                if str(result['action'].get('status','')).lower() in ['error','failed','canceled']: raise RuntimeError('Reported service validation did not pass')
            if time.monotonic() >= deadline: raise TimeoutError('Still pending or positive service success unproven')
            time.sleep(20)
        record['status'] = 'complete'
    except (TimeoutError,subprocess.TimeoutExpired): record['status'] = 'uncertain-or-still-running-inspect-do-not-repeat'
    except (RuntimeError,ValueError,KeyError,OSError) as error:
        record['status'] = 'failed-inspect-before-resume'; record['errorType'] = type(error).__name__
        if isinstance(error,RuntimeError): record['error'] = str(error)
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat(); save(); print(json.dumps(record,indent=2))
    return 0 if record['status'] == 'complete' else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--wait-seconds',type=int,default=1800)
    parser.add_argument('--after-gateway-echo-fix',action='store_true')
    parser.add_argument('--resume-unsubmitted-gateway',action='store_true'); args = parser.parse_args()
    if not 60 <= args.wait_seconds <= 7200: parser.error('wait bound must be 60–7200 seconds')
    if args.resume_unsubmitted_gateway and not args.after_gateway_echo_fix: parser.error('unsubmitted reconciliation requires --after-gateway-echo-fix')
    raise SystemExit(main(args.wait_seconds,args.after_gateway_echo_fix,args.resume_unsubmitted_gateway))
