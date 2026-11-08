"""Sealed one-effect capacity controller. Preparation/rendering is entirely offline.

Dispatch/observation are operational entry points, not approval. They require fresh
source-bound admission, exact independent review/parent GO, pushed source and original
history. No automatic replay, recovery, host start or credential management exists.
"""
import argparse
import base64
import copy
from datetime import datetime, timezone
import fcntl
import hashlib
import json
from pathlib import Path
import re
import runpy
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-11-08-capacity'
C = runpy.run_path(str(ROOT / 'scripts/smal-compute-capacity-20261108.py'), run_name='capacity_r2_helpers')
I = runpy.run_path(str(ROOT / 'scripts/smal-capacity-interlock.py'), run_name='capacity_r2_interlock')
M = runpy.run_path(str(ROOT / 'scripts/smal-capacity-maintenance-r2.py'), run_name='capacity_r2_health')
FILES = ['scripts/smal-capacity-r2.py', 'scripts/smal-capacity-interlock.py',
         'scripts/smal-capacity-maintenance-r2.py', 'scripts/smal-capacity-dispatch-r2.ps1',
         'scripts/smal-compute-capacity-20261108-worker.ps1', 'scripts/smal-capacity-startup-interlock.ps1',
         'scripts/smal-localbox-references.py', 'scripts/smal-compute-capacity-20261108.py',
         'scripts/smal-compute-capacity-20261108-common.ps1', 'scripts/smal-compute-capacity-20261108-stage.ps1',
         'scripts/smal-private-powershell.py', 'scripts/start-smal-localbox.py', 'scripts/start-smal-existing-guests.ps1',
         'scripts/test_smal_capacity_r2.py', 'scripts/test_smal_compute_capacity_20261108.py', 'scripts/test_smal_startup.py',
         'scripts/test_smal_capacity_r2_flow.py',
         'docs/deployment-2026-11-08-capacity/runtime-references.json',
         'docs/deployment-2026-11-08-capacity/r2-preparation.md', 'docs/deployment-2026-11-08-capacity/README.md',
         'docs/operations/start-localbox.md', 'scripts/smal-aks-binding-history.py',
         'docs/deployment-2026-11-08-capacity/binding-history.json',
         'docs/deployment-2026-11-08-capacity/plan.pending.json']
sha, require, fresh = C['digest'], C['require'], C['fresh']
# Preparation delivery, not an executable release. No plan/CLI flag can override this.
# Activation requires a separately reviewed source change and exact new source map/GO.
EFFECTS_ENABLED = False


def contract(plan, owners):
    require(len(owners) == 24 and set(owners) == {m['id'] for m in plan['baseline']['clusterStatic']['members']}
            and all(list(owners.values()).count(n) == 8 for n in C['NODES']), 'Exact physically connected owner map required')
    profiles = {n: dict(cpu=c, memory=m) for n, (c, m) in C['original_profiles']().items()}
    states = {n: 'Running' for n in C['GUESTS']}
    stages = {}
    previous = None

    def add(name, effect, health, host_cpu, node=None, guest=None, change=None, startup=None):
        nonlocal previous
        before_profiles, before_states = copy.deepcopy(profiles), dict(states)
        if change:
            change()
        stages[name] = dict(key=name, effect=effect, node=node, guest=guest, health=health,
                            compensating=name.startswith('comp-') or effect in ('resume', 'canonical-startup'),
                            observeHealth='stopped' if effect == 'cluster-stop' else health,
                            hostCpu=host_cpu, hostMinimumMemoryGiB=250 if host_cpu == 32 else 500,
                            beforeProfiles=before_profiles, afterProfiles=copy.deepcopy(profiles),
                            beforeStates=before_states, afterStates=dict(states),
                            predecessors=[] if previous is None else [previous], startupKey=startup)
        if node:
            before_state, after_state = {
                'drain': ('Up', 'Paused'), 'guest-stop': ('Paused', 'Down'),
                'memory': ('Down', 'Down'), 'cpu': ('Down', 'Down'),
                'startup-grant': ('Down', 'Down'), 'canonical-startup': ('Down', 'Paused'),
                'resume': ('Paused', 'Up'), 'converge': ('Up', 'Up')
            }[effect]
            stages[name].update(beforeClusterState=before_state, afterClusterState=after_state)
        previous = name

    add('cluster-stop', 'cluster-stop', 'strict', 32)
    for n in [*C['NODES'], 'LB-DC01']:
        add('shutdown-' + n.lower(), 'guest-stop', 'stopped', 32, guest=n, change=lambda n=n: states.update({n: 'Off'}))
    add('grant-outer', 'startup-grant', 'stopped', 32, startup='startup-outer')
    stages['grant-outer']['startupHostCpu'] = 64
    add('deallocate', 'azure-deallocate', 'stopped', 32)
    add('host-size', 'azure-size', 'stopped', 32)
    add('startup-outer', 'canonical-startup', 'stopped', 64, change=lambda: states.update({n: 'Running' for n in states}))
    stages['startup-outer']['observeHealth'] = 'strict'
    for n in C['NODES']:
        tag = n.lower()
        add('drain-' + tag, 'drain', 'strict', 64, node=n)
        stages['drain-' + tag]['observeHealth'] = 'maintenance'
        add('stop-' + tag, 'guest-stop', 'maintenance', 64, node=n, guest=n, change=lambda n=n: states.update({n: 'Off'}))
        add('memory-' + tag, 'memory', 'maintenance', 64, node=n, change=lambda n=n: profiles[n].update(memory=128 * 1024**3))
        add('cpu-' + tag, 'cpu', 'maintenance', 64, node=n, change=lambda n=n: profiles[n].update(cpu=16))
        add('grant-' + tag, 'startup-grant', 'maintenance', 64, node=n, startup='startup-' + tag)
        add('startup-' + tag, 'canonical-startup', 'maintenance', 64, node=n, change=lambda n=n: states.update({n: 'Running'}))
        add('resume-' + tag, 'resume', 'maintenance', 64, node=n)
        # Strict convergence is an explicit GET-only certificate, not a request to Resume twice.
        add('converge-' + tag, 'converge', 'strict', 64, node=n)
    add('complete', 'complete', 'strict', 64)
    # Explicit recovery branches preserve the last settled profile, never revert CPU/RAM
    # or replay a failed key. They terminate in compensation convergence, not completion.
    normal = copy.deepcopy(stages)
    for n in C['NODES']:
        tag = n.lower()
        for boundary in ('drain', 'stop', 'memory', 'cpu'):
            origin = boundary + '-' + tag
            original = normal[origin]
            profiles = copy.deepcopy(original['afterProfiles']); states = dict(original['afterStates'])
            previous = origin
            suffix = boundary + '-' + tag
            if boundary != 'drain':
                add('comp-grant-' + suffix, 'startup-grant', 'maintenance', 64, node=n, startup='comp-start-' + suffix)
                add('comp-start-' + suffix, 'canonical-startup', 'maintenance', 64, node=n, change=lambda n=n: states.update({n: 'Running'}))
            add('comp-resume-' + suffix, 'resume', 'maintenance', 64, node=n)
            add('comp-converge-' + suffix, 'converge', 'strict', 64, node=n)
    return dict(version=2, deviceOwners=owners, stages=stages,
                transportTimeoutSeconds=90, convergenceMaximumSeconds=600,
                compensation='resume-only-after-original-effect-settlement-and-exact-known-maintenance-profile')


def validate(plan, approved=False):
    C['validate_plan'](plan, approved=approved)
    t = plan['transitionContract']
    require(t == contract(plan, t['deviceOwners']), 'Sealed transition/one-effect/order contract differs')
    bridge = plan['baseline']['clusterStatic']['nestedVms'][0]
    require(bridge['cpu'] == 4 and bridge['memory'] == 8 * 1024**3
            and len(bridge['adapters']) == 1 and bridge['adapters'][0]['mac'].upper() == '02EC000B0000', 'Exact infrastructure profile/MAC missing')
    disks = plan['baseline']['cloud']['disks']
    require(len({d['id'] for d in disks}) == 11 and sorted(d['diskSizeGB'] for d in disks) == [256] * 8 + [1024, 2048, 4096], 'Exact eleven disks/8TiB data capacity unproved')
    if approved:
        review = plan['independentReview']
        require(review['decision'] == 'accept-exact-r2-source-and-plan' and review['reviewer'] != 'implementation-worker'
                and re.fullmatch('[a-f0-9]{64}', review['sourceFileMapSha256']), 'Independent R2 review absent')
        require(plan['disruptionHoldReleased'] is True, 'Physical disruption HELD')
        require(plan['runtimeReadiness']['trustReferencesVerified'] is True
                and plan['runtimeReadiness']['catalogueContinuationSettled'] is True, 'Runtime trust/catalogue prerequisite absent')


def source_guard(plan):
    require(EFFECTS_ENABLED, 'R2 operational route disabled in preparation source. Independent activation review required')
    validate(plan, approved=True)
    refs = runpy.run_path(str(ROOT / 'scripts/smal-localbox-references.py'), run_name='r2_origin_guard')
    refs['verify_origin']()
    names = [*FILES, 'docs/deployment-2026-11-08-capacity/plan.sealed.json']
    file_map = {}
    for name in names:
        data = (ROOT / name).read_bytes()
        require(data == subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT), 'Uncommitted source/plan: ' + name)
        if name != names[-1]:
            file_map[name] = hashlib.sha256(data).hexdigest()
    require(plan == json.loads((OUT / 'plan.sealed.json').read_text()), 'Exact owned sealed plan required')
    require(sha(file_map) == plan['independentReview']['sourceFileMapSha256'], 'Independent source review digest differs')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip()
    remote = subprocess.check_output(['git', 'ls-remote', '--heads', 'origin', 'refs/heads/' + branch], cwd=ROOT, text=True).split()
    require(remote and remote[0] == head, 'Exact source must be pushed')
    return head


def context(plan, stage, mode, settlements=None):
    validate(plan, approved=True)
    require(stage in plan['transitionContract']['stages'] and mode in ('dispatch', 'observe'), 'Unknown R2 action')
    e = plan['transitionContract']['stages'][stage]
    require(e['effect'] not in ('azure-deallocate', 'azure-size') and
            (mode == 'observe' or e['effect'] not in ('canonical-startup', 'converge')), 'Wrong transport route')
    return dict(plan=plan, stage=stage, mode=mode, settlements=settlements or {})


def settlement_projection(settled):
    """Bounded remote reconciliation envelope. Original full receipts stay local."""
    result = {}
    for key, resolution in settled.items():
        proof = resolution['proof']; observed = proof['observation']
        # Remote consumers need original process/events, not repeated full inventories.
        projected = {f: copy.deepcopy(v) for f, v in proof.items() if f not in ('observation', 'observationSha256')}
        projected['observation'] = {f: copy.deepcopy(observed[f]) for f in ('worker', 'request', 'remoteStartup') if f in observed}
        projected['originalObservationSha256'] = sha(observed)
        result[key] = dict(key=key, intentSha256=resolution['intentSha256'], originalSettlementSha256=sha(resolution), proof=projected)
    return result


def authorise_transport(ctx, commit):
    """Direct transport calls cannot bypass the controller's durable original intent."""
    plan, stage, mode = ctx['plan'], ctx['stage'], ctx['mode']
    require(ctx == context(plan, stage, mode, ctx['settlements']), 'Exact transport context required')
    state, effects, settled = I['history']()
    require(state and state['sourceCommit'] == commit and state['planSha256'] == sha(plan), 'Active source/plan fence absent')
    e = plan['transitionContract']['stages'][stage]
    if mode == 'dispatch':
        require(stage in effects and stage not in settled and effects[stage]['kind'] == 'remote-worker'
                and effects[stage]['requestSha256'] == sha(e) and set(effects) - set(settled) == {stage}
                and ctx['settlements'] == settled, 'Exact original unresolved dispatch intent/settled history absent')
    else:
        require(stage in effects or e['effect'] == 'converge' and all(k in settled and settled[k]['proof']['outcome'] == 'applied' for k in e['predecessors']), 'Read observer has no original effect/applied convergence prerequisite')


def render_context(ctx, commit):
    plan, stage, mode = ctx['plan'], ctx['stage'], ctx['mode']
    validate(plan, approved=True)
    require(re.fullmatch('[a-f0-9]{40}', commit), 'Exact source commit required')
    require(ctx == context(plan, stage, mode, ctx['settlements']), 'Unexpected transport context')
    return render_validated_context(ctx, commit, effects_enabled=EFFECTS_ENABLED)


def render_validated_context(ctx, commit, *, effects_enabled):
    """Pure shared renderer. Each hardcoded route validates its own context first.

    This emits bytes, never dispatches them or changes the legacy authority profile.
    The private transport separately enforces the route's source and original intent.
    """
    plan, stage, mode = ctx['plan'], ctx['stage'], ctx['mode']
    common = (ROOT / 'scripts/smal-compute-capacity-20261108-common.ps1').read_text()
    public = base64.b64encode(json.dumps(plan, sort_keys=True, separators=(',', ':')).encode()).decode()
    prefix = "$ErrorActionPreference='Stop'\n$ComputeCapacityLibraryOnly=$true\n$plan=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + public + "'))|ConvertFrom-Json)\n"
    prefix += "$stage='" + stage + "'\n$effectKey='" + plan['transitionContract']['stages'][stage]['key'] + "'\n$planSha='" + sha(plan) + "'\n$sourceCommit='" + commit + "'\n"
    prefix += '$CapacityEffectsEnabled=' + ('$true' if effects_enabled else '$false') + '\n'
    worker = (prefix + common + '\n' + (ROOT / 'scripts/smal-compute-capacity-20261108-worker.ps1').read_text()).encode()
    helper = ("$ComputeCapacityLibraryOnly=$true\n" + common + '\n' + (ROOT / 'scripts/smal-capacity-startup-interlock.ps1').read_text()).encode()
    settlements = base64.b64encode(json.dumps(settlement_projection(ctx['settlements']), sort_keys=True, separators=(',', ':')).encode()).decode()
    extra = "$mode='" + mode + "'\n$workerSha256='" + hashlib.sha256(worker).hexdigest().upper() + "'\n$workerBase64='" + base64.b64encode(worker).decode() + "'\n"
    extra += "$startupHelperSha256='" + hashlib.sha256(helper).hexdigest().upper() + "'\n$startupHelperBase64='" + base64.b64encode(helper).decode() + "'\n"
    extra += "$settlements=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + settlements + "'))|ConvertFrom-Json)\n"
    if ctx.get('directive') is not None:
        directive = base64.b64encode(json.dumps(ctx['directive'], sort_keys=True, separators=(',', ':')).encode()).decode()
        extra += "$directRecoveryDirective=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + directive + "'))|ConvertFrom-Json)\n"
    return (prefix + extra + common + '\n' + (ROOT / 'scripts/smal-capacity-dispatch-r2.ps1').read_text()).encode()


def health(snapshot, plan, selected=None, proof=None, compensating=False):
    h = snapshot['clusterHealth']
    o = dict(clusterStatic=snapshot['clusterStatic'], devices=h['devices'],
             nodeStates={n['name']: n['state'] for n in h['nodeStates']}, csv=h['csvStates'],
             virtualDisks=h['virtualDiskStates'], jobs=h['activeStorageJobs'],
             requiredPhysicalFreeBytes=plan['admission']['requiredPhysicalFreeBytes'] + plan['admission']['repairReserveBytes'],
             **{f: h[f] for f in ('quorumType', 'witness', 'poolHealth', 'poolOperational', 'physicalFreeBytes', 'unrelatedFailures')})
    require(len(h['nodeStates']) == 3, 'Exactly three distinct node observations required')
    if selected:
        require(proof and proof['planSha256'] == sha(plan) and proof['sourceCommit'] == snapshot['sourceCommit'], 'Original drain source/plan binding differs')
    args = (o, plan['baseline']['clusterStatic'], plan['transitionContract']['deviceOwners'])
    return M['planned'](*args, selected, proof, compensating) if selected else M['strict'](*args)


def verify_snapshot(snapshot, plan, entry, after=False, drain=None, health_required=True, *, expected_source):
    fresh(snapshot)
    require(re.fullmatch('[a-f0-9]{40}', expected_source) and snapshot.get('sourceCommit') == expected_source, 'Snapshot execution source differs')
    profiles = entry['afterProfiles' if after else 'beforeProfiles']
    states = entry['afterStates' if after else 'beforeStates']
    C['verify_snapshot'](snapshot, plan, {n: (v['cpu'], v['memory']) for n, v in profiles.items()},
                         off=[n for n, s in states.items() if s == 'Off'], healthy=False,
                         expanded=entry['hostCpu'] == 64)
    cpu = snapshot['hostCapacity']
    require(cpu['logicalProcessors'] == entry['hostCpu'] and cpu['physicalCores'] == entry['hostCpu'] // 2
            and cpu['memoryBytes'] >= entry['hostMinimumMemoryGiB'] * 1024**3
            and cpu['numa'] and sum(n['logicalProcessors'] for n in cpu['numa']) == entry['hostCpu'], 'Fresh actual host capacity required')
    profile = entry['observeHealth'] if after else entry['health']
    if profile == 'strict' and health_required:
        health(snapshot, plan)
    elif profile == 'maintenance' and health_required:
        health(snapshot, plan, entry['node'], drain, entry['compensating'])
    if profile != 'stopped':
        if entry['node']:
            node_states = {n['name']: n['state'] for n in snapshot['clusterHealth']['nodeStates']}
            require(node_states[entry['node']] == entry['afterClusterState' if after else 'beforeClusterState'], 'Exact selected-node phase/state differs')
        require(set(snapshot['nodeCapacity']) == {n for n, s in states.items() if n in C['NODES'] and s == 'Running'}, 'Actual all-running-node capacity set differs')
        placements = [(n, v) for n, cap in snapshot['nodeCapacity'].items() for v in cap['bridgePlacement']]
        require(len(placements) == 1 and placements[0][1]['id'] == plan['infrastructureVmId']
                and placements[0][1]['state'] == 'Running', 'Exact global infrastructure placement unproved')
        owner = placements[0][0]
        resources = snapshot['clusterHealth']['vmResources']
        require(len(resources) == 1 and resources[0]['vmIds'] == [plan['infrastructureVmId']]
                and resources[0]['ownerNode'] == owner and resources[0]['state'] == 'Online', 'Cluster VmID/actual owner mapping unproved')
        for node, capacity in snapshot['nodeCapacity'].items():
            expected = profiles[node]
            require(capacity['logicalProcessors'] == expected['cpu'] and capacity['memoryBytes'] >= expected['memory'] - 8 * 1024**3
                    and capacity['numa'] and sum(n['logicalProcessors'] for n in capacity['numa']) == expected['cpu'], 'Actual per-node CPU/RAM/NUMA differs')
            require(capacity['freeMemoryBytes'] >= (24 if node == owner else 16) * 1024**3, 'Actual platform/infrastructure memory reserve insufficient')


def transport(plan, stage, mode, key, settled):
    t = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='r2_private_transport')
    receipt_key = 'r2-' + key
    require(len(receipt_key) <= 64, 'Receipt key too long')
    code = t['main']('scripts/smal-capacity-dispatch-r2.ps1', receipt_key,
                     compute_context=context(plan, stage, mode, settled))
    receipt = json.loads((t['OUT'] / ('private-ssh-' + receipt_key + '.json')).read_text())
    require(code == 0 and receipt['status'] == 'complete' and receipt['result']['status'] == 'complete', 'Transport uncertain/incomplete. Original intent retained')
    result = receipt['result']
    if mode == 'observe':
        result['cloud'] = C['get_cloud']()
    return result


def drain_proof(plan, stage, settled):
    node = plan['transitionContract']['stages'][stage]['node']
    if not node:
        return None
    key = 'drain-' + node.lower()
    return settled.get(key, {}).get('proof', {}).get('observation', {}).get('worker', {}).get('drainProof')


def dispatch(plan, stage, admission):
    head = source_guard(plan)
    e = plan['transitionContract']['stages'][stage]
    require(e['effect'] not in ('canonical-startup', 'converge'), 'Use canonical startup or GET convergence')
    # Every fresh admission is separately collected, source/plan-bound and read-only.
    fresh(admission)
    require(admission['mutationPerformed'] is False and admission['sourceCommit'] == head
            and admission['planSha256'] == sha(plan) and admission['stage'] == stage
            and admission['quotaPolicyAndScheduleChecked'] is True and admission['exclusiveParentWriter'] is True,
            'Exact fresh admission/writer/conflict evidence absent')
    _, _, settled = I['idle']()
    cloud = admission['cloud']; fresh(cloud); C['verify_cloud'](cloud, plan)
    expected_size = plan['beforeSize'] if e['hostCpu'] == 32 else plan['targetSize']
    require(cloud['size'] == expected_size, 'Configured model differs')
    snapshot = admission['snapshot']
    verify_snapshot(snapshot, plan, e, drain=drain_proof(plan, stage, settled), expected_source=head)
    # Verify a final read immediately before Azure effects. Guest effects recheck inside worker.
    if e['effect'].startswith('azure-'):
        current = C['get_cloud'](); C['verify_cloud'](current, plan)
        require(current['size'] == plan['beforeSize'] and current['power'] == ('PowerState/running' if stage == 'deallocate' else 'PowerState/deallocated'), 'Azure immediate precondition differs')
        require(admission['allExactGuestsOff'] is True and admission['clusterStopped'] is True, 'Fresh Off/graceful cluster stop absent')
        cloud = current
    else:
        require(cloud['power'] == 'PowerState/running', 'Running outer host required')
    I['begin'](sha(plan), head)
    kind = 'azure' if e['effect'].startswith('azure-') else 'remote-worker'
    intent = I['claim'](e['key'], stage, kind, sha(plan), head, e['predecessors'], sha(e))
    # From here all failure/timeout/crash paths retain the unresolved operation-wide barrier.
    if e['effect'] == 'azure-deallocate':
        C['az'](['vm', 'deallocate', '--ids', C['HOST'], '--subscription', C['SUB'], '--no-wait'])
    elif e['effect'] == 'azure-size':
        C['az'](['rest', '--method', 'patch', '--url', 'https://management.azure.com' + C['HOST'] + '?api-version=2025-04-01',
                 '--headers', 'If-Match=' + cloud['etag'], '--body', json.dumps({'properties': {'hardwareProfile': {'vmSize': plan['targetSize']}}})])
    else:
        transport(plan, stage, 'dispatch', stage, settled)
    return dict(intent=intent, status='unresolved-await-exact-independent-observation', operationCompleted=False)


def settle(plan, stage, observed):
    head = source_guard(plan); fresh(observed)
    e = plan['transitionContract']['stages'][stage]
    _, effects, settled = I['history']()
    require(e['key'] in effects and e['key'] not in settled, 'Original unresolved effect required')
    if e['effect'] != 'canonical-startup':
        require(effects[e['key']]['requestSha256'] == sha(e), 'Original requested transition changed')
    require(observed['mutationPerformed'] is False and observed['sourceCommit'] == head
            and observed['planSha256'] == sha(plan) and observed['key'] == e['key'] and observed['stage'] == stage,
            'Exact independent source/plan/key observation absent')
    require(observed.get('outcome') in ('applied', 'not-applied'), 'Explicit observed outcome required')
    if e['effect'].startswith('azure-'):
        require(observed['outcome'] == 'applied', 'Azure absence is not proof of never-dispatched effect')
        cloud = observed['cloud']; fresh(cloud); C['verify_cloud'](cloud, plan)
        require(cloud['power'] == 'PowerState/deallocated' and cloud['size'] == (plan['targetSize'] if stage == 'host-size' else plan['beforeSize'])
                and observed['azureProvisioningState'] == 'Succeeded' and observed['azureTransitionSettled'] is True, 'Azure transition not independently settled')
    else:
        cloud = observed['cloud']; fresh(cloud); C['verify_cloud'](cloud, plan)
        require(cloud['power'] == 'PowerState/running' and cloud['size'] == (plan['beforeSize'] if e['hostCpu'] == 32 else plan['targetSize']), 'Observed configured host model/power differs')
        require(observed['dispatcherAlive'] is False and observed['workerAlive'] is False and observed['rpcPhase'] == 'returned'
                and observed['workerIdentityVerified'] is True and observed['workerSourceVerified'] is True, 'Exact remote process/RPC/source not settled')
        outcome = observed.get('outcome', 'applied')
        require(outcome in ('applied', 'not-applied'), 'Partial/unknown effects require an independently reviewed exact recovery contract')
        verify_snapshot(observed['snapshot'], plan, e, after=outcome == 'applied', drain=observed.get('worker', {}).get('drainProof') or drain_proof(plan, stage, settled), expected_source=head)
        if e['effect'] == 'cluster-stop':
            require(observed['clusterServices'] == {n: 'Stopped' if outcome == 'applied' else 'Running' for n in C['NODES']}, 'Cluster service outcome not converged')
        if e['effect'] != 'canonical-startup':
            worker = observed['worker']
            require(worker['key'] == e['key'] and worker['stage'] == stage and worker['sourceCommit'] == head
                    and worker['planSha256'] == sha(plan) and (worker['rpcSucceeded'] is True if outcome == 'applied' else worker['rpcInvoked'] is False), 'Original worker/outcome differs')
            ctx = context(plan, stage, 'observe')
            rendered = render_context(ctx, head).decode()
            expected_worker_hash = re.search(r"\$workerSha256='([A-F0-9]{64})'", rendered)[1]
            require(worker['sourceSha256'] == expected_worker_hash, 'Exact deterministic worker source differs')
            request = observed['request']
            require(all(request[f] == worker[f] for f in ('key', 'stage', 'sourceCommit', 'planSha256', 'operationId'))
                    and worker['phase'] == 'returned' and worker['pid'] > 0 and request['pid'] > 0
                    and worker['processStartedUtc'] and request['processStartedUtc'], 'Exact original process/request identity absent')
        else:
            remote = observed['remoteStartup']
            require(outcome == 'applied' and all(remote[f] == observed[f] for f in ('key', 'stage', 'sourceCommit', 'planSha256', 'operationId'))
                    and remote['phase'] == 'returned' and remote['sequence'] > 0 and remote['pid'] > 0
                    and remote['processStartedUtc'], 'Original canonical startup event identity absent')
            helper = render_context(context(plan, stage, 'observe'), head).decode()
            require(remote['helperSha256'] == re.search(r"\$startupHelperSha256='([A-F0-9]{64})'", helper)[1], 'Exact startup helper source differs')
        if e['effect'] == 'complete':
            certificate = observed['remoteCompletion']
            require(all(certificate[f] == observed[f] for f in ('key', 'stage', 'sourceCommit', 'planSha256', 'operationId'))
                    and certificate['snapshot'] == observed['worker']['completionSnapshot'], 'Original remote completion snapshot binding differs')
            verify_snapshot(certificate['snapshot'], plan, e, after=True, expected_source=head)
    proof = dict(atUtc=observed['atUtc'], operationId=I['OPERATION'], planSha256=sha(plan), sourceCommit=head,
                 key=e['key'], stage=stage, identityAndSettingsVerified=True, effectObserved=True,
                 outcome=observed['outcome'], observation=observed, observationSha256=sha(observed))
    for f in ('dispatcherAlive', 'workerAlive', 'rpcPhase', 'workerIdentityVerified', 'workerSourceVerified', 'azureProvisioningState', 'azureTransitionSettled'):
        if f in observed:
            proof[f] = observed[f]
    return I['resolve'](e['key'], proof)


def handover(plan, stage, evidence, plan_path):
    head = source_guard(plan)
    _, _, settled = I['idle']()
    e = plan['transitionContract']['stages'][stage]
    require(e['effect'] == 'canonical-startup', 'Exact canonical stage required')
    require(all(k in settled and settled[k]['proof']['outcome'] == 'applied' for k in e['predecessors']), 'Applied startup prerequisites absent')
    grant_key = stage.replace('comp-start-', 'comp-grant-', 1) if stage.startswith('comp-start-') else ('grant-outer' if stage == 'startup-outer' else 'grant-' + e['node'].lower())
    require(grant_key in settled and settled[grant_key]['proof']['outcome'] == 'applied', 'Original applied remote grant absent')
    fresh(evidence)
    require(evidence['sourceCommit'] == head and evidence['planSha256'] == sha(plan)
            and evidence['stage'] == stage and evidence['mutationPerformed'] is False, 'Exact fresh startup observation absent')
    grant = settled[grant_key]['proof']['observation']['worker']['remoteGrant']
    require(grant['key'] == stage and grant['grantStage'] == grant_key and grant['states'] == e['beforeStates']
            and grant['profiles'] == e['beforeProfiles'] and grant['hostCpu'] == e['hostCpu']
            and grant['startupEntry'] == e, 'Sealed startup stage/profiles/grant differs')
    expected_context = dict(baseline={'clusterStatic': plan['baseline']['clusterStatic']},
                            admission={f: plan['admission'][f] for f in ('requiredPhysicalFreeBytes', 'repairReserveBytes')},
                            deviceOwners=plan['transitionContract']['deviceOwners']) if e['node'] else None
    require(grant['maintenanceContext'] == expected_context, 'Sealed startup maintenance context differs')
    cloud = evidence['cloud']; fresh(cloud); C['verify_cloud'](cloud, plan)
    require(cloud['size'] == plan['targetSize'] and cloud['power'] == ('PowerState/deallocated' if stage == 'startup-outer' else 'PowerState/running'), 'Exact pre-start cloud state differs')
    if stage != 'startup-outer':
        verify_snapshot(evidence['snapshot'], plan, e, drain=drain_proof(plan, stage, settled), expected_source=head)
    else:
        # Never claim actual running E64 capacity/bridge visibility while host is deallocated.
        off = settled[grant_key]['proof']['observation']['snapshot']
        fresh(off)
        verify_snapshot(off, plan, plan['transitionContract']['stages'][grant_key], after=True, expected_source=head)
    return I['prepare_startup'](plan_path, dict(evidence, safeCanonicalStartup=True), grant, stage)


def finish(plan, observation):
    head = source_guard(plan); fresh(observation)
    _, _, settled = I['idle']()
    require('complete' in settled and settled['complete']['proof']['outcome'] == 'applied', 'Original applied completion effect absent')
    e = plan['transitionContract']['stages']['complete']
    require(observation['sourceCommit'] == head and observation['planSha256'] == sha(plan)
            and observation['stage'] == 'complete' and observation['key'] == 'complete'
            and observation['mutationPerformed'] is False, 'Exact final completion observation required')
    verify_snapshot(observation['snapshot'], plan, e, after=True, expected_source=head)
    cloud = observation['cloud']; fresh(cloud); C['verify_cloud'](cloud, plan)
    require(cloud['size'] == plan['targetSize'] and cloud['power'] == 'PowerState/running', 'Final configured model/power differs')
    require(observation['remoteCompletion'] == settled['complete']['proof']['observation']['remoteCompletion'], 'Original remote completion certificate differs')
    proof = dict(atUtc=observation['atUtc'], operationId=I['OPERATION'], sourceCommit=head,
                 planSha256=sha(plan), allHealthyAndOk=True, noActiveStorageJobs=True,
                 identityAndSettingsVerified=True, remoteCompletionObserved=True,
                 observation=observation, observationSha256=sha(observation),
                 completionSettlementSha256=sha(settled['complete']))
    return I['finish'](proof)


def converge(plan, stage, observation):
    head = source_guard(plan)
    e = plan['transitionContract']['stages'][stage]
    require(e['effect'] == 'converge', 'Not a convergence stage')
    fresh(observation)
    require(observation['mutationPerformed'] is False and observation['sourceCommit'] == head and observation['planSha256'] == sha(plan), 'Exact GET convergence observation required')
    require(observation['operationId'] == I['OPERATION'] and observation['stage'] == stage and observation['key'] == stage, 'Exact convergence stage/key absent')
    verify_snapshot(observation['snapshot'], plan, e, after=True, expected_source=head)
    # This certificate has no remote effect and cannot settle an unresolved intent.
    _, effects, settled = I['history']()
    require(all(k in settled for k in e['predecessors']), 'Resume not settled')
    if stage in effects:
        require(stage not in settled and effects[stage]['kind'] == 'read-certificate'
                and effects[stage]['requestSha256'] == sha(e), 'Original convergence certificate differs/already complete')
        require(set(effects) - set(settled) == {stage}, 'Another original effect remains unresolved')
    else:
        I['claim'](stage, stage, 'read-certificate', sha(plan), head, e['predecessors'], sha(e))
    proof = dict(atUtc=observation['atUtc'], operationId=I['OPERATION'], planSha256=sha(plan), sourceCommit=head,
                 stage=stage, key=stage, identityAndSettingsVerified=True, effectObserved=True, outcome='applied',
                 workerAlive=False, dispatcherAlive=False, rpcPhase='returned', workerIdentityVerified=True,
                 workerSourceVerified=True, observation=observation, observationSha256=sha(observation))
    return I['resolve'](stage, proof)


def observe_convergence(plan, stage, read_key):
    """Bounded read-only resync loop. Timeout never admits another node or clears history."""
    head = source_guard(plan)
    e = plan['transitionContract']['stages'][stage]
    require(e['effect'] == 'converge' and re.fullmatch('[a-z0-9-]{1,32}', read_key or ''), 'Exact convergence stage/read key required')
    _, _, settled = I['idle']()
    deadline = time.monotonic() + plan['transitionContract']['convergenceMaximumSeconds']
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        observation = transport(plan, stage, 'observe', read_key + '-' + str(attempt), {})
        fresh(observation)
        verify_snapshot(observation['snapshot'], plan, e, after=True, health_required=False, expected_source=head)
        try:
            health(observation['snapshot'], plan)
            return observation
        except ValueError:
            # Only exact selected-device planned repair may remain pending. Unknown
            # identities/failures raise here, rather than being swallowed until timeout.
            health(observation['snapshot'], plan, e['node'], drain_proof(plan, stage, settled), True)
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(10, remaining))
    raise TimeoutError('Read-only resync convergence limit reached. No next-node admission')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['prepare', 'render', 'dispatch', 'observe', 'observe-convergence', 'settle', 'converge', 'handover', 'finish'])
    p.add_argument('--plan', type=Path, default=OUT / 'plan.sealed.json')
    p.add_argument('--stage'); p.add_argument('--evidence', type=Path); p.add_argument('--read-key')
    p.add_argument('--owner-map', type=Path)
    args = p.parse_args()
    plan = json.loads(args.plan.read_text())
    if args.action == 'prepare':
        require(plan['executionApproval'] is None, 'Do not derive from old approval')
        plan['transitionContract'] = contract(plan, json.loads(args.owner_map.read_text()))
        plan.update(independentReview=None, disruptionHoldReleased=False,
                    runtimeReadiness=dict(trustReferencesVerified=False, catalogueContinuationSettled=False))
        print(json.dumps(plan, indent=2)); return
    if args.action == 'render':
        # Approved rendering requires an exact approval supplied by parent, never generated here.
        print(render_context(context(plan, args.stage, 'dispatch'), '0' * 40).decode()); return
    with Path('/tmp/opencode/smal-localbox-start.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        evidence = json.loads(args.evidence.read_text()) if args.evidence else None
        if args.action == 'dispatch':
            result = dispatch(plan, args.stage, evidence)
        elif args.action == 'settle':
            result = settle(plan, args.stage, evidence)
        elif args.action == 'converge':
            result = converge(plan, args.stage, evidence)
        elif args.action == 'observe':
            source_guard(plan)
            require(re.fullmatch('[a-z0-9-]{1,48}', args.read_key or ''), 'Unique read receipt key required')
            result = transport(plan, args.stage, 'observe', args.read_key, {})
        elif args.action == 'observe-convergence':
            result = observe_convergence(plan, args.stage, args.read_key)
        elif args.action == 'handover':
            result = str(handover(plan, args.stage, evidence, args.plan))
        else:
            result = finish(plan, evidence)
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
