"""Read-only validation diagnostics with credential/token/query redaction."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import runpy

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-29'


def redact(text):
    text = re.sub(r'(?s)-----BEGIN [^-]+-----.*?-----END [^-]+-----','[REDACTED_KEY_MATERIAL]',str(text))
    text = re.sub(r'''(?i)(["']?[A-Za-z_]*(?:password|secret|token|accesskey|accountkey)[A-Za-z_]*["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}]+)''',r'\1[REDACTED]',text)
    text = re.sub(r'''(?i)(https?://[^\s?"<>]+)\?[^\s"<>]+''',r'\1?[REDACTED_QUERY]',text)
    text = re.sub(r'[A-Za-z0-9!@#%+=_/\-]{40,}','[REDACTED_LONG_VALUE]',text)
    text = re.sub(r'(?i)(enter\s+(?:the\s+)?code\s*[:=]?\s*)[A-Z0-9-]{6,15}',r'\1[REDACTED_DEVICE_CODE]',text)
    return text


def step_diagnostics(action):
    return {'status':action.get('status'),'steps':[{'name':step.get('name'),'status':step.get('status'),'index':step.get('fullStepIndex'),
            'exceptions':[{'sha256':hashlib.sha256(str(item).encode()).hexdigest(),'redactedExcerpt':redact(item)[:14000]} for item in step.get('exception',[]) or []],
            'children':step_diagnostics({'steps':step.get('steps') or []})['steps']} for step in action.get('steps',[]) or []]}


if __name__ == '__main__':
    d = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='validation_diagnostic_reads')
    actual = d['L']['rest'](d['SETTINGS'])
    properties = actual['properties']; action = (properties.get('reportedProperties') or {}).get('validationStatus') or {}
    record = {'observedAtUtc':datetime.now(timezone.utc).isoformat(),'status':'read-only-redacted-diagnostic',
              'resourceId':actual['id'],'provisioningState':properties.get('provisioningState'),'mode':properties.get('deploymentMode'),
              'validation':step_diagnostics(action),'azureMutationPerformed':False,'deploySubmitted':False,'rawExceptionsRetained':False}
    path = OUT / 'three-node-validation-diagnostic.json'
    with path.open('x') as stream: stream.write(json.dumps(record,indent=2) + '\n')
    print(json.dumps(record,indent=2))
