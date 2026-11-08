"""Run an authorised, committed PowerShell script through loopback/private Bastion SSH.

This establishes a command transport, not permission to run arbitrary deployments.
Never put secrets in a script, argument or output. The private key stays local.
"""
import argparse
import base64
import json
import hashlib
import os
from pathlib import Path
import re
import runpy
import signal
import socket
import stat
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / 'scripts/enable-smal-private-ssh.py'), run_name='ssh_transport_helpers')
BASE = H['H']
OUT = H['OUT']
VM_ID = f"/subscriptions/{BASE['SUB']}/resourceGroups/{BASE['RG']}/providers/Microsoft.Compute/virtualMachines/{BASE['VM']}"


def ssh_args(port, admin, encoded, stream_source=False):
    return ['ssh', *([] if stream_source else ['-n']), '-v', '-F', '/dev/null', '-T', '-p', str(port), '-i', str(H['KEY']),
            '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none', '-o', 'BatchMode=yes',
            '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no',
            '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=' + str(H['KNOWN']),
            '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'HostKeyAlias=' + H['ALIAS'],
            '-o', 'HostKeyAlgorithms=ssh-ed25519', '-o', 'ConnectTimeout=15',
            '-o', 'ForwardAgent=no', '-o', 'ClearAllForwardings=yes',
            '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2',
            admin + '@127.0.0.1', 'powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + encoded]


def stdin_loader(source):
    if len(source) > 2 * 1024**2:
        raise RuntimeError('Reviewed script exceeds the source transport byte cap')
    expected = hashlib.sha256(source).hexdigest().upper()
    # One fixed short command reads the full reviewed UTF-8 source, checks it,
    # then invokes it as one script. Do not feed a sequence of unguarded stdin
    # statements to PowerShell or place a large payload on the Windows argv.
    # Windows OpenSSH can leave inherited stdin open after client EOF. Read the
    # exact pinned byte length instead of waiting for ReadToEnd().
    loader = "$ErrorActionPreference='Stop';try{$n=" + str(len(source)) + ";[byte[]]$b=New-Object byte[] $n;$i=[Console]::OpenStandardInput();$o=0;while($o -lt $n){$c=$i.Read($b,$o,$n-$o);if($c -le 0){throw 'Truncated reviewed source'};$o+=$c};$h=[Security.Cryptography.SHA256]::Create().ComputeHash($b);if([BitConverter]::ToString($h).Replace('-','') -cne '" + expected + "'){throw 'Reviewed script hash differs'};$s=[Text.UTF8Encoding]::new($false,$true).GetString($b);& ([ScriptBlock]::Create($s));exit 0}catch{[Console]::Error.WriteLine('ReviewedSourceFailure:'+ $_.Exception.GetType().Name + ':' + $_.InvocationInfo.ScriptLineNumber);exit 1}"
    return base64.b64encode(loader.encode('utf-16-le')).decode('ascii')


def legacy_loader_for_hash(expected):
    if not re.fullmatch(r'[a-fA-F0-9]{64}', expected):
        raise RuntimeError('Invalid historical source digest')
    loader = "$ErrorActionPreference='Stop';[Console]::InputEncoding=[Text.UTF8Encoding]::new($false);$s=[Console]::In.ReadToEnd();$h=[Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s));if([BitConverter]::ToString($h).Replace('-','') -cne '" + expected.upper() + "'){throw 'Reviewed script hash differs'};& ([ScriptBlock]::Create($s))"
    return base64.b64encode(loader.encode('utf-16-le')).decode('ascii')


def render_storage_installer(installer, worker, manifest, commit):
    manifest_hash = hashlib.sha256(manifest).hexdigest().upper()
    worker = worker.decode('utf-8').replace('__MANIFEST_SHA256__', manifest_hash).encode('utf-8')
    worker_hash = hashlib.sha256(worker).hexdigest().upper()
    return (installer.decode('utf-8').replace('__MANIFEST_BASE64__', base64.b64encode(manifest).decode())
            .replace('__WORKER_BASE64__', base64.b64encode(worker).decode())
            .replace('__MANIFEST_SHA256__', manifest_hash).replace('__WORKER_SHA256__', worker_hash)
            .replace('__SOURCE_COMMIT__', commit).encode('utf-8'))


def render_guest_bundle_installer(installer, worker, manifest, helpers, commit, expected):
    if set(helpers) != expected or not re.fullmatch(r'[a-f0-9]{40}', commit):
        raise RuntimeError('Exact guest helper set/source commit required')
    bundle = json.dumps({'schemaVersion': 1, 'files': [
        {'name': name, 'sha256': hashlib.sha256(data).hexdigest().upper(), 'base64': base64.b64encode(data).decode('ascii')}
        for name, data in sorted(helpers.items())]}, separators=(',', ':'), sort_keys=True).encode('utf-8')
    digest = hashlib.sha256(bundle).hexdigest().upper()
    installer = installer.decode('utf-8').replace('__BUNDLE_BASE64__', base64.b64encode(bundle).decode('ascii')).replace('__BUNDLE_SHA256__', digest).encode('utf-8')
    worker = worker.decode('utf-8').replace('__BUNDLE_SHA256__', digest).encode('utf-8')
    return render_storage_installer(installer, worker, manifest, commit)


def render_guest_image_installer(installer, worker, manifest, helpers, commit):
    expected = {'smal-guest-secret-functions.ps1', 'smal-guest-image-functions.ps1', 'smal-guest-vm-functions.ps1'}
    return render_guest_bundle_installer(installer, worker, manifest, helpers, commit, expected)


def render_guest_bootstrap_installer(installer, worker, manifest, helpers, commit):
    expected = {'smal-guest-secret-functions.ps1', 'smal-guest-direct-functions.ps1'}
    return render_guest_bundle_installer(installer, worker, manifest, helpers, commit, expected)


def render_arc_console(installer, console, approval, commit):
    approval_hash = hashlib.sha256(approval).hexdigest().upper()
    console = console.decode('utf-8').replace('__APPROVAL_SHA256__', approval_hash).replace('__SOURCE_COMMIT__', commit).encode('utf-8')
    digest = hashlib.sha256(console).hexdigest().upper()
    return (installer.decode('utf-8').replace('__CONSOLE_BASE64__', base64.b64encode(console).decode('ascii'))
            .replace('__APPROVAL_BASE64__', base64.b64encode(approval).decode('ascii')).replace('__CONSOLE_SHA256__', digest)
            .replace('__APPROVAL_SHA256__', approval_hash).replace('__SOURCE_COMMIT__', commit).encode('utf-8'))


def render_node03_console(installer, console, proof, approval, commit):
    if (proof.get('status') != 'complete-local-only-human-arc-authentication-next' or proof.get('commonCredentialLoginVerified') is not True
            or proof.get('vm', {}).get('vmName') != 'LB-NODE03' or proof.get('cleanup', {}).get('setupLogsNeedReview') is not False
            or proof.get('cleanup', {}).get('answerFileCleanupNeedsReview') is not False):
        raise RuntimeError('Exact successful NODE3 cleanup/login proof required before console installation')
    vm_id = str(uuid.UUID(proof['vm']['vmId']))
    digest = hashlib.sha256(approval).hexdigest().upper()
    console = console.decode().replace('__NODE03_VM_ID__', vm_id).replace('__NODE03_APPROVAL_SHA256__', digest).replace('__SOURCE_COMMIT__', commit).encode()
    return (installer.decode().replace('__NODE03_VM_ID__', vm_id).replace('__NODE03_CONSOLE_BASE64__', base64.b64encode(console).decode())
            .replace('__NODE03_CONSOLE_SHA256__', hashlib.sha256(console).hexdigest().upper()).encode())


def main(script, name, envelope_key=None, three_node_context=None, capacity_context=None):
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,63}', name):
        raise RuntimeError('Invalid receipt name')
    target = OUT / f'private-ssh-{name}.json'
    if target.exists():
        raise RuntimeError('Operation receipt exists. Inspect rather than repeat.')
    path = (ROOT / script).resolve()
    if not path.is_relative_to(ROOT / 'scripts') or path.suffix != '.ps1':
        raise RuntimeError('Only reviewed scripts under repository scripts/ are accepted')
    relative = str(path.relative_to(ROOT))
    if relative == 'scripts/stage-smal-2610-image.ps1':
        approval = json.loads((OUT / 'current-2610-image-approval.json').read_text())
        if (approval.get('downloadAndChecksumVerificationApproved') is not True
                or approval.get('licenceAndPrivacyAcceptanceForDownload') is not True
                or approval.get('solutionVersionSelected') != '12.2610.1004.41'):
            raise RuntimeError('Exact image/terms approval missing')
    source = path.read_bytes()
    committed = subprocess.check_output(['git', 'show', 'HEAD:' + relative], cwd=ROOT)
    if committed != source:
        raise RuntimeError('Script differs from committed source')
    if relative == 'scripts/allow-smal-internal-gateway-echo.ps1':
        guard = runpy.run_path(str(ROOT / 'scripts/smal-three-node-approval.py'),run_name='gateway_echo_approval_guard')
        approval_path = 'docs/deployment-2026-10-29/gateway-echo-rule-approval.json'
        guard['source_guard']([relative,'scripts/smal-private-powershell.py',approval_path])
        approval_bytes = (ROOT / approval_path).read_bytes()
        source = source.decode().replace('__GATEWAY_ECHO_APPROVAL_BASE64__',base64.b64encode(approval_bytes).decode()).replace('__GATEWAY_ECHO_APPROVAL_SHA256__',hashlib.sha256(approval_bytes).hexdigest().upper()).encode()
    if relative in ['scripts/seal-smal-platform-credentials.ps1','scripts/seal-smal-lcm-format-fix.ps1']:
        if (not isinstance(envelope_key, dict) or set(envelope_key) != {'modulus', 'nonce'}
                or not re.fullmatch(r'[0-9a-f]{32}', envelope_key['nonce'])
                or len(base64.b64decode(envelope_key['modulus'], validate=True)) != 512):
            raise RuntimeError('One-use RSA4096 public key and nonce required')
        approval_bytes = (ROOT / 'docs/deployment-2026-10-28/cloud-apply-approval.json').read_bytes()
        if approval_bytes != subprocess.check_output(['git', 'show', 'HEAD:docs/deployment-2026-10-28/cloud-apply-approval.json'], cwd=ROOT): raise RuntimeError('Approval source differs')
        source = (source.decode().replace('__RSA_MODULUS__', envelope_key['modulus']).replace('__ENVELOPE_NONCE__', envelope_key['nonce'])
                  .replace('__APPROVAL_SHA256__', hashlib.sha256(approval_bytes).hexdigest().upper()).encode())
        if relative == 'scripts/seal-smal-lcm-format-fix.ps1':
            guard = runpy.run_path(str(ROOT / 'scripts/smal-three-node-approval.py'),run_name='lcm_format_seal_approval')
            guard['source_guard']([relative,'scripts/smal-private-powershell.py'])
            source = source.decode().replace('__THREE_NODE_APPROVAL_SHA256__',hashlib.sha256((guard['OUT'] / 'three-node-approval.json').read_bytes()).hexdigest().upper()).encode()
    elif envelope_key is not None:
        raise RuntimeError('Envelope key is only accepted for approved credential sealing')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip()
    remote = subprocess.check_output(['git', 'ls-remote', '--heads', 'origin', 'refs/heads/' + branch], cwd=ROOT, text=True).split()
    if not remote or remote[0] != head:
        raise RuntimeError('Exact command source must be pushed')
    capacity_scripts = {'scripts/prepare-smal-capacity-expansion.ps1','scripts/format-smal-capacity-disk.ps1','scripts/add-smal-capacity-vhds.ps1','scripts/inspect-smal-capacity-interruption.ps1'}
    if relative in capacity_scripts:
        guard = runpy.run_path(str(ROOT / 'scripts/smal-capacity-expansion.py'),run_name='capacity_transport_guard')
        guard['source_guard']()
        if not isinstance(capacity_context,dict) or set(capacity_context) not in [{'planBase64','approvalBase64','azureDiskUniqueId'},{'planBase64','approvalBase64','azureDiskUniqueId','resumeBindingFix'}]:
            raise RuntimeError('Exact public capacity context required')
        if relative != 'scripts/prepare-smal-capacity-expansion.ps1': uuid.UUID(capacity_context['azureDiskUniqueId'])
        for key,path in [('planBase64',guard['PLAN_PATH']),('approvalBase64',guard['APPROVAL_PATH'])]:
            if base64.b64decode(capacity_context[key],validate=True) != (ROOT / path).read_bytes(): raise RuntimeError('Capacity plan/approval context differs from committed bytes')
        public = json.dumps(capacity_context,sort_keys=True,separators=(',',':')).encode()
        prelude = (ROOT / 'scripts/smal-capacity-prelude.ps1').read_text().replace('__CAPACITY_CONTEXT_BASE64__',base64.b64encode(public).decode()).replace('__CAPACITY_CONTEXT_SHA256__',hashlib.sha256(public).hexdigest().upper()).replace('__CAPACITY_SOURCE_COMMIT__',head)
        source = source.decode().replace('__CAPACITY_PRELUDE__',prelude).encode()
        if 'resumeBindingFix' in capacity_context:
            if relative != 'scripts/add-smal-capacity-vhds.ps1' or capacity_context['resumeBindingFix'] is not True: raise RuntimeError('First-file correction accepted only by the approved VHD stage')
            failed_name = 'docs/deployment-2026-10-27/private-ssh-capacity-add-vhds-20261030.json'
            admission_name = 'docs/deployment-2026-10-27/private-ssh-capacity-first-vhd-interruption-20261030.json'
            guard['D']['A']['source_guard']([failed_name,admission_name])
            failed = json.loads((ROOT / failed_name).read_text()); admission = json.loads((ROOT / admission_name).read_text())
            guard['verify_first_file_resume'](failed,admission,guard['load_plan']())
            proof = json.dumps(admission['result'],sort_keys=True,separators=(',',':')).encode()
            source = source.decode().replace('__CAPACITY_RESUME_ADMISSION_BASE64__',base64.b64encode(proof).decode()).encode()
    elif capacity_context is not None:
        raise RuntimeError('Capacity context accepted only by the three approved expansion scripts')
    three_node_scripts = {'scripts/prepare-smal-node03-disk.ps1', 'scripts/format-smal-node03-disk.ps1', 'scripts/inspect-smal-node03-disk.ps1', 'scripts/resize-smal-existing-nodes.ps1', 'scripts/install-smal-node03-job.ps1', 'scripts/install-smal-node03-arc-console.ps1'}
    if relative in three_node_scripts:
        guard = runpy.run_path(str(ROOT / 'scripts/smal-three-node-approval.py'), run_name='three_node_transport_guard')
        guard['source_guard']([relative, 'scripts/smal-private-powershell.py', 'scripts/smal-three-node-prelude.ps1'])
        if (not isinstance(three_node_context, dict) or set(three_node_context) != {'diskId', 'azureDiskUniqueId', 'lun', 'proposalBase64', 'approvalBase64'}
                or three_node_context.get('diskId', '').lower() != guard['DISK_ID'].lower() or three_node_context.get('lun') != 8): raise RuntimeError('Exact three-node public context missing')
        for key, path in [('proposalBase64', 'three-node-proposal.json'), ('approvalBase64', 'three-node-approval.json')]:
            if base64.b64decode(three_node_context[key], validate=True) != (guard['OUT'] / path).read_bytes(): raise RuntimeError('Context proposal/approval differs')
        public = json.dumps(three_node_context, sort_keys=True).encode()
        prelude = (ROOT / 'scripts/smal-three-node-prelude.ps1').read_text().replace('__THREE_NODE_CONTEXT_BASE64__', base64.b64encode(public).decode()).replace('__THREE_NODE_CONTEXT_SHA256__', hashlib.sha256(public).hexdigest().upper()).replace('__SOURCE_COMMIT__', head)
        source = source.decode().replace('__THREE_NODE_PRELUDE__', prelude).encode()
        if relative == 'scripts/install-smal-node03-arc-console.ps1':
            proof_name = 'docs/deployment-2026-10-29/node03-local-completion.json'
            guard['source_guard'](['scripts/register-smal-node03-console.ps1', proof_name])
            proof = json.loads((ROOT / proof_name).read_text())
            source = render_node03_console(source, (ROOT / 'scripts/register-smal-node03-console.ps1').read_bytes(), proof, (guard['OUT'] / 'three-node-approval.json').read_bytes(), head)
        if relative == 'scripts/install-smal-node03-job.ps1':
            dependencies = ['scripts/derive-smal-node03-helpers.py', 'scripts/smal-node03-worker.ps1',
                            'scripts/smal-guest-secret-functions.ps1', 'scripts/smal-guest-image-functions.ps1', 'scripts/smal-guest-vm-functions.ps1', 'scripts/smal-guest-direct-functions.ps1']
            derived = runpy.run_path(str(ROOT / 'scripts/derive-smal-node03-helpers.py'), run_name='node03_helper_derivation')['build']()
            for name, text in derived.items():
                path = 'scripts/node03/' + name
                if (ROOT / path).read_text() != text: raise RuntimeError('NODE3 generated helper differs from reviewed derivation')
                dependencies.append(path)
            guard['source_guard'](dependencies)
            bundle = json.dumps({'schemaVersion': 1, 'files': [{'name': name, 'sha256': hashlib.sha256(text.encode()).hexdigest().upper(), 'base64': base64.b64encode(text.encode()).decode()} for name, text in sorted(derived.items())]}, sort_keys=True, separators=(',', ':')).encode()
            bundle_hash = hashlib.sha256(bundle).hexdigest().upper()
            worker = (ROOT / 'scripts/smal-node03-worker.ps1').read_text().replace('__SOURCE_COMMIT__', head).replace('__NODE03_BUNDLE_SHA256__', bundle_hash).replace('__NODE03_APPROVAL_SHA256__', hashlib.sha256((guard['OUT'] / 'three-node-approval.json').read_bytes()).hexdigest().upper()).encode()
            source = (source.decode().replace('__NODE03_BUNDLE_BASE64__', base64.b64encode(bundle).decode()).replace('__NODE03_BUNDLE_SHA256__', bundle_hash)
                      .replace('__NODE03_WORKER_BASE64__', base64.b64encode(worker).decode()).replace('__NODE03_WORKER_SHA256__', hashlib.sha256(worker).hexdigest().upper()).encode())
    elif three_node_context is not None:
        raise RuntimeError('Public three-node context is only accepted for approved phase scripts')
    if relative in ['scripts/start-smal-storage-job.ps1', 'scripts/recover-smal-storage-job.ps1']:
        def exact_bytes(name):
            data = (ROOT / name).read_bytes()
            if data != subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT):
                raise RuntimeError('Storage dependency differs from committed source')
            return data
        decisions = json.loads(exact_bytes('docs/deployment-2026-10-28/deployment-decisions.json'))
        if decisions.get('simpleStorageFormattingApproved') is not True:
            raise RuntimeError('Explicit Simple storage approval missing')
        if relative == 'scripts/recover-smal-storage-job.ps1':
            checked = json.loads((OUT / 'private-ssh-storage-recovery-reconciliation-after-cleanup-20261028.json').read_text())
            evidence = checked.get('result', {})
            diagnostic = evidence.get('diagnostic', {})
            if (checked.get('status') != 'complete' or evidence.get('taskState') != 'Ready'
                    or evidence.get('lastTaskResult') != 1 or evidence.get('volume') is not None
                    or diagnostic.get('poolExists') is not False or diagnostic.get('virtualDiskExists') is not False
                    or diagnostic.get('temporaryProcessExists') is not False
                    or diagnostic.get('temporaryStatePhase') != 'initialising'
                    or diagnostic.get('rawDataDiskCount') != 8 or diagnostic.get('poolablePhysicalDiskCount') != 8
                    or diagnostic.get('recoveryProofExists') is not False
                    or diagnostic.get('recoveryWorkerBackupExists') is not False
                    or diagnostic.get('matchingHistoricalRecoveryProcesses') != []):
                raise RuntimeError('Exact preflight/no-storage-effects recovery not reconciled')
        manifest = exact_bytes('docs/deployment-2026-10-28/storage-job-manifest.json')
        source = render_storage_installer(source, exact_bytes('scripts/smal-storage-worker.ps1'), manifest, head)
    if relative in ['scripts/read-smal-storage-job.ps1', 'scripts/stop-smal-recovery-transport.ps1']:
        pending = OUT / 'private-ssh-storage-worker-recovery-20261028.json'
        encoded_legacy = ''
        if pending.exists():
            prior = json.loads(pending.read_text())
            encoded_legacy = legacy_loader_for_hash(prior['renderedSourceSha256'])
        source = source.decode('utf-8').replace('__PENDING_RECOVERY_LOADER__', encoded_legacy).encode('utf-8')
    if relative == 'scripts/start-smal-eval-media-job.ps1':
        def exact_media_bytes(name):
            data = (ROOT / name).read_bytes()
            if data != subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT):
                raise RuntimeError('Media dependency differs from committed source')
            return data
        decisions = json.loads(exact_media_bytes('docs/deployment-2026-10-28/deployment-decisions.json'))
        if decisions.get('managementEvaluationMediaAndTermsApproved') is not True:
            raise RuntimeError('Explicit Evaluation media and terms approval missing')
        source = render_storage_installer(source, exact_media_bytes('scripts/smal-eval-media-worker.ps1'),
                                          exact_media_bytes('docs/deployment-2026-10-28/eval-media-job-manifest.json'), head)
    if relative in ['scripts/read-smal-guest-inspection.ps1', 'scripts/stop-smal-guest-inspection.ps1']:
        prior = json.loads((OUT / 'private-ssh-guest-input-inspection-20261028.json').read_text())
        old_source = subprocess.check_output(['git', 'show', prior['commit'] + ':scripts/inspect-smal-guest-inputs.ps1'], cwd=ROOT)
        if hashlib.sha256(old_source).hexdigest() != prior['renderedSourceSha256']:
            raise RuntimeError('Exact historical inspection differs from receipt')
        selector = base64.b64encode(old_source.decode('utf-8').encode('utf-16-le')).decode('ascii')
        source = source.decode('utf-8').replace('__GUEST_INSPECTION_ENCODED__', selector).encode('utf-8')
    if relative in ['scripts/start-smal-guest-input-job.ps1', 'scripts/recover-smal-guest-input-hash.ps1']:
        def exact_input_bytes(name):
            data = (ROOT / name).read_bytes()
            if data != subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT):
                raise RuntimeError('Guest inspection dependency differs from committed source')
            return data
        decisions = json.loads(exact_input_bytes('docs/deployment-2026-10-28/deployment-decisions.json'))
        proposal = exact_input_bytes('docs/deployment-2026-10-28/local-guest-apply-proposal.md')
        if decisions.get('localGuestPlanApproved') is not True or hashlib.sha256(proposal).hexdigest() != decisions.get('localGuestPlanSha256'):
            raise RuntimeError('Exact guest plan approval missing')
        reconciliation = json.loads((OUT / 'private-ssh-guest-inspection-cleanup-readback-20261028.json').read_text())
        observed = reconciliation.get('result', {})
        if reconciliation.get('status') != 'complete' or observed.get('exactInspectionProcesses') != [] or any(item['attached'] for item in observed.get('media', [])) or len(observed.get('media', [])) != 2:
            raise RuntimeError('Prior inspection/process attachments not reconciled')
        source = render_storage_installer(source, exact_input_bytes('scripts/smal-guest-input-worker.ps1'),
                                          exact_input_bytes('docs/deployment-2026-10-28/guest-input-job-manifest.json'), head)
    if relative == 'scripts/apply-smal-local-network.ps1':
        decisions_path = 'docs/deployment-2026-10-28/deployment-decisions.json'
        proposal_path = 'docs/deployment-2026-10-28/local-guest-apply-proposal.md'
        decisions_bytes = (ROOT / decisions_path).read_bytes()
        proposal_bytes = (ROOT / proposal_path).read_bytes()
        for name, data in [(decisions_path, decisions_bytes), (proposal_path, proposal_bytes)]:
            if data != subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT):
                raise RuntimeError('Network approval source differs from committed bytes')
        decisions = json.loads(decisions_bytes)
        if decisions.get('localGuestPlanApproved') is not True or decisions.get('localAddressAllocationConfirmedByOwner') is not True or hashlib.sha256(proposal_bytes).hexdigest() != decisions.get('localGuestPlanSha256'):
            raise RuntimeError('Exact local network allocation approval missing')
        source = source.decode('utf-8').replace('__SOURCE_COMMIT__', head).encode('utf-8')
    if relative == 'scripts/activate-smal-dc-evaluation.ps1':
        decision_path = 'docs/deployment-2026-10-28/deployment-decisions.json'
        decision_bytes = (ROOT / decision_path).read_bytes()
        if decision_bytes != subprocess.check_output(['git', 'show', 'HEAD:' + decision_path], cwd=ROOT):
            raise RuntimeError('Evaluation consent differs from committed source')
        decisions = json.loads(decision_bytes)
        if decisions.get('managementEvaluationMediaAndTermsApproved') is not True or decisions.get('localGuestMediaInstallationAndRebootsApproved') is not True:
            raise RuntimeError('Accepted Evaluation use/terms approval missing')
        source = source.decode('utf-8').replace('__SOURCE_COMMIT__', head).encode('utf-8')
    if relative == 'scripts/prepare-smal-cluster-prereqs.ps1':
        names = ['docs/deployment-2026-10-28/cloud-apply-proposal.json',
                 'docs/deployment-2026-10-28/cloud-apply-proposal.md',
                 'docs/deployment-2026-10-28/cloud-apply-approval.json']
        data = {}
        for name in names:
            value = (ROOT / name).read_bytes()
            if value != subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT):
                raise RuntimeError('Cloud proposal/approval differs from committed source')
            data[name] = value
        approval = json.loads(data[names[2]])
        if (approval.get('approved') is not True or approval.get('sharedClusterOnlyNodeAdminCredentialApproved') is not True
                or approval.get('newClusterOuGpoBlockAndScopedLcmDelegationApproved') is not True
                or hashlib.sha256(data[names[0]]).hexdigest() != approval.get('proposalJsonSha256')
                or hashlib.sha256(data[names[1]]).hexdigest() != approval.get('proposalMarkdownSha256')):
            raise RuntimeError('Exact staged cloud/local prerequisite approval missing')
        source = source.decode('utf-8').replace('__SOURCE_COMMIT__', head).encode('utf-8')
    if relative in ['scripts/install-smal-arc-console.ps1', 'scripts/install-smal-arc-recovery-console.ps1']:
        values = {}
        for name in ['scripts/register-smal-node-console.ps1', 'docs/deployment-2026-10-28/cloud-apply-approval.json', 'docs/deployment-2026-10-28/cloud-apply-proposal.json', 'docs/deployment-2026-10-28/cloud-apply-proposal.md']:
            values[name] = (ROOT / name).read_bytes()
            if values[name] != subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT): raise RuntimeError('Console/approval source differs from HEAD')
        approval = json.loads(values['docs/deployment-2026-10-28/cloud-apply-approval.json'])
        if (approval.get('humanDeviceCodeAuthenticationApproved') is not True or approval.get('existingArmTokenForwardingApproved') is not False
                or hashlib.sha256(values['docs/deployment-2026-10-28/cloud-apply-proposal.json']).hexdigest() != approval.get('proposalJsonSha256')
                or hashlib.sha256(values['docs/deployment-2026-10-28/cloud-apply-proposal.md']).hexdigest() != approval.get('proposalMarkdownSha256')):
            raise RuntimeError('Exact device-code registration approval missing')
        source = render_arc_console(source, values['scripts/register-smal-node-console.ps1'], values['docs/deployment-2026-10-28/cloud-apply-approval.json'], head)
    if relative == 'scripts/start-smal-guest-image-job.ps1':
        def exact_guest_bytes(name):
            data = (ROOT / name).read_bytes()
            if data != subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT):
                raise RuntimeError('Guest image dependency differs from committed source')
            return data
        decisions = json.loads(exact_guest_bytes('docs/deployment-2026-10-28/deployment-decisions.json'))
        proposal = exact_guest_bytes('docs/deployment-2026-10-28/local-guest-apply-proposal.md')
        if (hashlib.sha256(proposal).hexdigest() != decisions.get('localGuestPlanSha256')
                or any(decisions.get(key) is not True for key in ['localGuestPlanApproved', 'localGuestMediaInstallationAndRebootsApproved', 'hostBoundDpapiGuestSecretsApproved', 'temporaryGuestImageAnswerFileSecretApproved'])):
            raise RuntimeError('Exact local guest/secret consent missing')
        inspection = json.loads((OUT / 'private-ssh-guest-input-inspection-complete-20261028.json').read_text())
        if inspection.get('status') != 'complete' or inspection.get('result', {}).get('state', {}).get('status') != 'inspection-complete':
            raise RuntimeError('Complete reconciled image inspection receipt required')
        helpers = {name: exact_guest_bytes('scripts/' + name) for name in [
            'smal-guest-secret-functions.ps1', 'smal-guest-image-functions.ps1', 'smal-guest-vm-functions.ps1']}
        source = render_guest_image_installer(source, exact_guest_bytes('scripts/smal-guest-image-worker.ps1'),
                                              exact_guest_bytes('docs/deployment-2026-10-28/local-guest-image-manifest.json'), helpers, head)
    if relative in ['scripts/start-smal-guest-bootstrap-job.ps1', 'scripts/recover-smal-guest-bootstrap-network.ps1', 'scripts/recover-smal-node-cleanup.ps1']:
        def exact_bootstrap_bytes(name):
            data = (ROOT / name).read_bytes()
            if data != subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT):
                raise RuntimeError('Guest bootstrap dependency differs from committed source')
            return data
        decisions = json.loads(exact_bootstrap_bytes('docs/deployment-2026-10-28/deployment-decisions.json'))
        proposal = exact_bootstrap_bytes('docs/deployment-2026-10-28/local-guest-apply-proposal.md')
        if (hashlib.sha256(proposal).hexdigest() != decisions.get('localGuestPlanSha256')
                or decisions.get('domainCreationApproved') != 'ad.localbox.test'
                or any(decisions.get(key) is not True for key in ['localGuestPlanApproved', 'localGuestMediaInstallationAndRebootsApproved', 'hostBoundDpapiGuestSecretsApproved', 'temporaryGuestImageAnswerFileSecretApproved'])):
            raise RuntimeError('Exact guest boot/domain/secret consent missing')
        manifest = exact_bootstrap_bytes('docs/deployment-2026-10-28/local-guest-bootstrap-manifest.json')
        dependency = json.loads((OUT / 'private-ssh-guest-image-job-start-20261028.json').read_text())
        pinned = json.loads(manifest)
        if (dependency.get('status') != 'complete' or dependency.get('result', {}).get('sourceCommit') != pinned['imageSourceCommit']
                or dependency.get('result', {}).get('workerSha256') != pinned['imageWorkerSha256']):
            raise RuntimeError('Exact image job launch not reconciled; do not queue boot')
        if relative == 'scripts/recover-smal-guest-bootstrap-network.ps1':
            observed = json.loads((OUT / 'private-ssh-guest-bootstrap-network-failure-inspection-20261028.json').read_text())
            guest = observed.get('result', {}).get('guest', {})
            if (observed.get('status') != 'complete' or guest.get('computer') != 'LB-DC01'
                    or guest.get('domainRole') != 2 or guest.get('adServiceExists') is not False
                    or guest.get('defaults') != [] or guest.get('profilesRejectedByOriginalGuard') != 0
                    or guest.get('protection', {}).get('RealTimeProtectionEnabled') is not True
                    or any(item['IPAddress'] != '127.0.0.1' and not item['IPAddress'].startswith('169.254.') for item in guest.get('ipv4', []))):
                raise RuntimeError('Exact no-network-effects pre-directory recovery evidence missing')
        if relative == 'scripts/recover-smal-node-cleanup.ps1':
            observed = json.loads((OUT / 'private-ssh-node01-cleanup-failure-inspection-20261028.json').read_text())
            result = observed.get('result', {})
            guest = result.get('guest', {})
            if (observed.get('status') != 'complete' or result.get('originalBootstrapLoginVerified') is not True
                    or guest.get('computer') != 'LB-NODE01' or guest.get('domainRole') != 2 or guest.get('vmmsRunning') is not True
                    or result.get('mutationPerformed') is not False):
                raise RuntimeError('Exact original-credential/standalone-node cleanup proof missing')
        helpers = {name: exact_bootstrap_bytes('scripts/' + name) for name in [
            'smal-guest-secret-functions.ps1', 'smal-guest-direct-functions.ps1']}
        source = render_guest_bootstrap_installer(source, exact_bootstrap_bytes('scripts/smal-guest-bootstrap-worker.ps1'), manifest, helpers, head)
    setup_path = OUT / 'private-ssh-setup-resume1.json'
    if not setup_path.exists():
        raise RuntimeError('Successful reconciled setup receipt missing')
    setup = json.loads(setup_path.read_text())
    if setup.get('status') != 'complete-host-key-pinned-login-not-yet-tested':
        raise RuntimeError('Successful setup evidence missing')
    if not H['KNOWN'].is_file() or H['KNOWN'].is_symlink() or stat.S_IMODE(H['KEY'].stat().st_mode) != 0o600:
        raise RuntimeError('Missing trust file or unsafe key permissions')
    H['pin_host_key'](setup['result']['hostPublicKey'])
    route = subprocess.run(['ip', '-j', 'route', 'get', '10.204.0.4'], capture_output=True, text=True, check=True)
    if json.loads(route.stdout)[0].get('dev') != 'tun0':
        raise RuntimeError('Actual VPN route is not present')
    with socket.create_connection(('10.204.0.4', 53), timeout=5):
        pass
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0))
        port = reserve.getsockname()[1]
    encoded = base64.b64encode(source.decode('utf-8').encode('utf-16-le')).decode('ascii')
    stream_source = len(encoded) > 16000 or relative == 'scripts/read-smal-node03-job.ps1'
    original_encoded_length = len(encoded)
    if stream_source:
        encoded = stdin_loader(source)
    record = {'beganAtSast': BASE['now'](), 'status': 'pending', 'commit': head, 'script': relative,
              'transport': 'VPN-private-Premium-Bastion-loopback-SSH22', 'strictPinnedHostKey': True,
              'passwordAuthentication': False, 'privateKeyValueExported': False}
    record['localPort'] = port
    record['scriptTransport'] = 'sha256-length-framed-utf8-stdin' if stream_source else 'encoded-command'
    record['renderedSourceSha256'] = hashlib.sha256(source).hexdigest()
    record['renderedSourceByteLength'] = len(source)
    record['unstreamedEncodedLength'] = original_encoded_length
    guest_timeout = {'scripts/prepare-smal-host-hyperv.ps1': 600,
                     'scripts/start-smal-existing-guests.ps1': 360,
                     'scripts/inspect-smal-arc-registration.ps1': 180,
                     'scripts/inspect-smal-cluster-inputs.ps1': 240,
                     'scripts/inspect-smal-three-node-live.ps1': 240,
                     'scripts/inspect-smal-three-node-final.ps1': 300,
                     'scripts/inspect-smal-bitlocker-gap.ps1': 300,
                     'scripts/prepare-smal-capacity-expansion.ps1': 300,
                     'scripts/format-smal-capacity-disk.ps1': 300,
                     'scripts/add-smal-capacity-vhds.ps1': 600,
                     'scripts/inspect-smal-capacity-interruption.ps1': 300,
                     'scripts/inspect-smal-infra-network-failure.ps1': 240,
                     'scripts/stop-smal-guests-for-premium.ps1': 240,
                     'scripts/format-smal-node03-disk.ps1': 240,
                     'scripts/resize-smal-existing-nodes.ps1': 1500,
                     'scripts/inspect-smal-guest-deployment-readiness.ps1': 300,
                     'scripts/activate-smal-dc-evaluation.ps1': 300,
                     'scripts/prepare-smal-cluster-prereqs.ps1': 600,
                     'scripts/inspect-smal-guest-inputs.ps1': 300,
                     'scripts/stage-smal-2610-image.ps1': 1500}.get(relative, 90)
    record['guestCommandTimeoutSeconds'] = guest_timeout
    with target.open('x') as stream:
        stream.write(json.dumps(record, indent=2) + '\n')
    command = ['az', 'network', 'bastion', 'tunnel', '--subscription', '702382d0-3722-4630-8983-5580b92f0c1a',
               '-g', 'rg-bastion-san-1', '-n', 'bas-test-san-1', '--target-resource-id', VM_ID,
               '--resource-port', '22', '--port', str(port), '--timeout', str(max(900, guest_timeout + 120)), '--only-show-errors']
    # Do not capture tunnel pipes: Azure CLI descendants can keep them open after
    # the parent exits. Isolate the process group and bound every cleanup wait.
    tunnel = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        deadline = time.monotonic() + 70
        while time.monotonic() < deadline and tunnel.poll() is None:
            listeners = subprocess.run(['ss', '-H', '-ltn', 'sport', '=', ':' + str(port)], capture_output=True, text=True, check=True).stdout.strip().splitlines()
            if listeners:
                if any('127.0.0.1:' + str(port) not in line for line in listeners):
                    raise RuntimeError('Bastion tunnel listener is not loopback-only')
                record['loopbackOnly'] = True
                break
            time.sleep(1)
        else:
            raise RuntimeError('Private Bastion tunnel not ready')
        io = {'input': source.decode('utf-8')} if stream_source else {'stdin': subprocess.DEVNULL}
        result = subprocess.run(ssh_args(port, setup['result']['adminUser'], encoded, stream_source), **io, capture_output=True, text=True, encoding='utf-8', timeout=guest_timeout)
        record['sshExitCode'] = result.returncode
        record['sshDiagnostics'] = {label: label in result.stderr for label in ['Server accepts key', 'Authenticated to', 'Sending command:', 'Exit status']}
        safe_error = re.search(r'ReviewedSourceFailure:([A-Za-z0-9._]+):([0-9]+)', result.stderr)
        if safe_error:
            record['reviewedSourceError'] = {'type': safe_error[1], 'line': int(safe_error[2])}
        if result.returncode:
            labels = ['Host key verification failed', 'Permission denied', 'Connection timed out', 'Connection reset', 'Connection closed']
            record['errorLabel'] = next((label for label in labels if label in result.stderr), 'command-failed-raw-output-suppressed')
            record['status'] = 'failed-do-not-automatically-repeat'
        else:
            if re.search(r'-----BEGIN|\beyJ[A-Za-z0-9_-]{15,}\.|(?i:password|access_token|refresh_token)', result.stdout):
                raise RuntimeError('Unexpected sensitive-pattern output suppressed')
            record['result'] = json.loads(result.stdout)
            record['status'] = 'complete'
        target.write_text(json.dumps(record, indent=2) + '\n')
    except subprocess.TimeoutExpired as error:
        record['status'] = 'uncertain-command-timeout-do-not-repeat'
        diagnostic = error.stderr or b''
        if isinstance(diagnostic, bytes):
            diagnostic = diagnostic.decode(errors='replace')
        record['sshDiagnostics'] = {label: label in diagnostic for label in ['Server accepts key', 'Authenticated to', 'Sending command:', 'Exit status']}
    except (RuntimeError, ValueError) as error:
        record['status'] = 'failed-inspect-before-retry'
        record['errorType'] = type(error).__name__
    finally:
        try:
            os.killpg(tunnel.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            tunnel.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(tunnel.pid, signal.SIGKILL)
            tunnel.wait(timeout=5)
        # Tunnel diagnostics can contain signed URLs. Never export raw output.
        record['tunnelProcessClosed'] = True
        for _ in range(10):
            record['localSocketAbsent'] = not subprocess.run(['ss', '-H', '-ltn', 'sport', '=', ':' + str(port)], capture_output=True, text=True, check=True).stdout.strip()
            if record['localSocketAbsent']:
                break
            time.sleep(0.2)
        record['finishedAtSast'] = BASE['now']()
        target.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))
    return 0 if record['status'] == 'complete' else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--script', required=True)
    parser.add_argument('--receipt', required=True)
    args = parser.parse_args()
    raise SystemExit(main(args.script, args.receipt))
