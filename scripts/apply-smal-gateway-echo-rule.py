"""Apply one human-approved internal gateway echo rule after terminal-state checks."""
import contextlib
from datetime import datetime, timezone
import io
import json
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REC = runpy.run_path(str(ROOT / 'scripts/smal-validation-recovery.py'),run_name='gateway_echo_state_guard')
D = REC['D']


def main():
    head = D['A']['source_guard'](['scripts/apply-smal-gateway-echo-rule.py','scripts/allow-smal-internal-gateway-echo.ps1',
        'scripts/smal-validation-recovery.py','scripts/smal-private-powershell.py','scripts/inspect-smal-infra-network-failure.ps1',
        'docs/deployment-2026-10-29/gateway-echo-rule-approval.json'])
    approval = json.loads((D['OUT'] / 'gateway-echo-rule-approval.json').read_text())
    if approval.get('approved') is not True or approval.get('humanAnswer') != 'Approve scoped echo rule': raise RuntimeError('Exact echo approval missing')
    path = D['OUT'] / 'gateway-echo-rule-receipt.json'
    record = {'beganAtUtc':datetime.now(timezone.utc).isoformat(),'sourceCommit':head,'status':'pending','validateSubmitted':False,'deploySubmitted':False}
    with path.open('x') as stream: stream.write(json.dumps(record,indent=2) + '\n')
    try:
        D['preflight'](); record['terminalValidationProof'] = REC['current_failure'](REC['NETWORK_ERROR'])
        with contextlib.redirect_stdout(io.StringIO()): code = D['T']['main']('scripts/allow-smal-internal-gateway-echo.ps1','gateway-echo-rule-20261029')
        proof = json.loads((D['T']['OUT'] / 'private-ssh-gateway-echo-rule-20261029.json').read_text())
        if code != 0 or proof.get('status') != 'complete' or proof.get('result',{}).get('status') != 'exact-approved-echo-rule-verified': raise RuntimeError('Echo rule operation incomplete. Inspect receipt, never blindly repeat.')
        record['ruleReadback'] = proof['result']
        with contextlib.redirect_stdout(io.StringIO()): code = D['T']['main']('scripts/inspect-smal-infra-network-failure.ps1','infra-network-after-echo-rule-20261029')
        probes = json.loads((D['T']['OUT'] / 'private-ssh-infra-network-after-echo-rule-20261029.json').read_text())
        rows = probes.get('result',{}).get('nodes',[])
        if code != 0 or probes.get('status') != 'complete' or len(rows) != 3: raise RuntimeError('Post-rule network inspection incomplete')
        for node in rows:
            if {r['destination']:r['echoReplyReceived'] for r in node['guest']['probes']} != {'10.64.0.1':True,'10.64.0.10':True}: raise RuntimeError('Gateway/DC echo probes did not pass on all three nodes')
        record['gatewayAndDcEchoVerifiedOnAllThreeNodes'] = True
        record['networkProof'] = 'docs/deployment-2026-10-27/private-ssh-infra-network-after-echo-rule-20261029.json'
        record['status'] = 'complete-scoped-rule-and-three-node-echo-verified'
    except (RuntimeError,ValueError,KeyError,OSError,subprocess.TimeoutExpired) as error:
        record['status'] = 'failed-or-uncertain-inspect-do-not-repeat'; record['errorType'] = type(error).__name__
        if isinstance(error,RuntimeError): record['error'] = str(error)
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat(); path.write_text(json.dumps(record,indent=2) + '\n'); print(json.dumps(record,indent=2))
    return 0 if record['status'].startswith('complete-') else 2


if __name__ == '__main__': raise SystemExit(main())
