"""Direct-human, single-full-outage E32 -> E64 preparation/execution route.

No parentGo, catalogue success, source approval or human approval is manufactured.
Effects require an exact committed/pushed plan, real direct-human authority and an
independent technical source review. Read, render and execution are separate routes.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import runpy
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-11-08-capacity'
ROUTE = 'direct-full-outage-v1'
PENDING = OUT / 'plan.direct.pending.json'
SEALED = OUT / 'plan.direct.sealed.json'
R = runpy.run_path(str(ROOT / 'scripts/smal-capacity-r2.py'), run_name='direct_shared_pure_helpers')
C, I, M = R['C'], R['I'], R['M']
sha, require, fresh = C['digest'], C['require'], C['fresh']
EFFECTS = ['whole-cluster-graceful-stop', 'four-exact-graceful-guest-stops',
           'six-offline-profile-effects', 'outer-deallocate-size-only', 'guarded-canonical-startup']
FILES = sorted(set(R['FILES'] + ['scripts/smal-capacity-direct.py', 'scripts/test_smal_capacity_direct.py',
                               'docs/deployment-2026-11-08-capacity/plan.direct.pending.json',
                               'docs/deployment-2026-11-08-capacity/direct-full-outage.md']))


def contract(plan):
    profiles = {n: dict(cpu=c, memory=m) for n, (c, m) in C['original_profiles']().items()}
    states = {n: 'Running' for n in C['GUESTS']}
    stages = {}; previous = None; boundaries = []

    def add(name, effect, health='stopped', cpu=32, guest=None, change=None, target_cpu=None, target_memory=None):
        nonlocal previous
        before_profiles, before_states = copy.deepcopy(profiles), dict(states)
        if change: change()
        stages[name] = dict(key=name, effect=effect, node=None, guest=guest, health=health,
                            observeHealth='stopped' if effect == 'cluster-stop' else health,
                            compensating=False, hostCpu=cpu, hostMinimumMemoryGiB=250 if cpu == 32 else 500,
                            beforeProfiles=before_profiles, afterProfiles=copy.deepcopy(profiles),
                            beforeStates=before_states, afterStates=dict(states),
                            predecessors=[] if previous is None else [previous], startupKey=None,
                            targetCpu=target_cpu, targetMemoryBytes=target_memory, recovery=False)
        previous = name

    add('direct-cluster-stop', 'cluster-stop', 'strict')
    for n in [*C['NODES'], 'LB-DC01']:
        add('direct-off-' + n.lower(), 'guest-stop', guest=n, change=lambda n=n: states.update({n: 'Off'}))
    boundaries.append(previous)
    for n in C['NODES']:
        tag = n.lower()
        add('direct-memory-' + tag, 'memory', guest=n, target_memory=128 * 1024**3,
            change=lambda n=n: profiles[n].update(memory=128 * 1024**3)); boundaries.append(previous)
        add('direct-cpu-' + tag, 'cpu', guest=n, target_cpu=16,
            change=lambda n=n: profiles[n].update(cpu=16)); boundaries.append(previous)
    add('direct-grant', 'startup-grant')
    stages['direct-grant'].update(startupKey='direct-startup', startupHostCpu=64)
    add('direct-deallocate', 'azure-deallocate')
    add('direct-host-size', 'azure-size')
    add('direct-startup', 'canonical-startup', cpu=64, change=lambda: states.update({n: 'Running' for n in states}))
    stages['direct-startup']['observeHealth'] = 'strict'
    add('direct-converge', 'converge', 'strict', 64)
    add('complete', 'complete', 'strict', 64)
    normal = copy.deepcopy(stages)
    # Explicit offline restoration only. No automatic fallback, host downsize or E32 start.
    for index, boundary in enumerate(boundaries):
        profiles = copy.deepcopy(normal[boundary]['afterProfiles']); states = dict(normal[boundary]['afterStates']); previous = boundary
        for number, n in enumerate(C['NODES'], 1):
            for field, effect, target in [('memory', 'memory', 64 * 1024**3), ('cpu', 'cpu', 8)]:
                if profiles[n][field] == target: continue
                name = f'restore-{index}-{number}-{field}'
                add(name, effect, guest=n, target_cpu=target if field == 'cpu' else None,
                    target_memory=target if field == 'memory' else None,
                    change=lambda n=n, field=field, target=target: profiles[n].update({field: target}))
                stages[name]['recovery'] = True
    return dict(version=2, route=ROUTE, stages=stages, transportTimeoutSeconds=90,
                convergenceMaximumSeconds=600, deviceOwners=plan.get('deviceOwners') or {},
                recovery='separately-directed-offline-original-profiles-only')


def fixed_scope(plan):
    pending = json.loads((OUT / 'plan.pending.json').read_text())
    for field, value in pending.items():
        if field not in ('baseline', 'admission', 'executionApproval'):
            require(plan.get(field) == value, 'Direct fixed hardware scope differs: ' + field)
    require(plan.get('route') == ROUTE and plan.get('executionApproval') is None, 'Direct route cannot adopt legacy parentGo')


def infrastructure_policy(cluster, vm_id):
    policies = cluster.get('vmLifecyclePolicies')
    require(isinstance(policies, list) and len(policies) == 1, 'Exactly one frozen cluster VM OfflineAction policy required')
    policy = policies[0]
    require(policy.get('vmIds') == [vm_id], 'OfflineAction must bind the exact infrastructure VmID')
    resource_id = policy.get('resourceId')
    require(isinstance(resource_id, str) and re.fullmatch('[a-fA-F0-9-]{36}', resource_id) is not None, 'Stable cluster VM resource ID required')
    require(str(uuid.UUID(resource_id)) == resource_id.lower(), 'Invalid cluster VM resource ID')
    action = policy.get('offlineAction')
    require(type(action) is int and action in (1, 2), 'Missing/unknown/forced OfflineAction rejected before disruption')
    nested = cluster.get('nestedVms')
    require(isinstance(nested, list) and len(nested) == 1 and nested[0].get('id') == vm_id
            and type(nested[0].get('shutdownIntegrationEnabled')) is bool, 'Exact nested VM shutdown integration setting required')
    require(action == 1 or nested[0]['shutdownIntegrationEnabled'] is True, 'OfflineAction=2 requires enabled guest shutdown integration')
    return policy, 'Saved' if action == 1 else 'Off', nested[0]['shutdownIntegrationEnabled']


def validate(plan, approved=False):
    fixed_scope(plan)
    if approved: C['validate_plan'](plan, approved=False)
    require(isinstance(plan.get('baseline'), dict) and isinstance(plan.get('admission'), dict), 'Actual direct baseline/admission required')
    require(plan['transitionContract'] == contract(plan), 'Exact full-outage transition contract differs')
    bridge = plan['baseline']['clusterStatic']['nestedVms'][0]
    infrastructure_policy(plan['baseline']['clusterStatic'], plan['infrastructureVmId'])
    require(bridge['cpu'] == 4 and bridge['memory'] == 8 * 1024**3
            and len(bridge['adapters']) == 1 and bridge['adapters'][0]['mac'].upper() == '02EC000B0000', 'Exact infrastructure VM profile/MAC missing')
    require(all(g.get('automaticStart') == 'Nothing' and g.get('automaticStop') == 'ShutDown' for g in plan['baseline']['guestsStatic']), 'Preserved no-autostart/graceful-stop policies required; never change them to bypass the OOM guard')
    require(len(plan['deviceOwners']) == 24 and all(list(plan['deviceOwners'].values()).count(n) == 8 for n in C['NODES']), 'Exact device ownership missing')
    if approved:
        approval = plan.get('directHumanApproval'); unsigned = copy.deepcopy(plan); unsigned['directHumanApproval'] = None
        require(isinstance(approval, dict) and set(approval) == {'quotedRequest', 'unsignedPlanSha256', 'approvedEffects', 'authorityProfile'}, 'Actual direct-human approval required')
        require(approval['quotedRequest'] == "make the changes, I'm the boss here"
                and approval['authorityProfile'] == 'direct-human-full-outage'
                and approval['unsignedPlanSha256'] == sha(unsigned) and approval['approvedEffects'] == EFFECTS, 'Exact direct-human instruction/plan/effects binding differs')
        review = plan.get('technicalReview')
        require(isinstance(review, dict) and review['decision'] == 'accept-direct-full-outage-source-and-plan'
                and review['reviewer'] != 'implementation-worker' and re.fullmatch('[a-f0-9]{64}', review['sourceFileMapSha256']), 'Independent technical review required, not fabricated parent authority')
        q = plan['quiescence']
        require(q == dict(catalogueState='Pending', catalogueRefreshReplay=False,
                          interruptibleControlPlaneOperationDisclosed=True, exclusiveHardwareWriter=True,
                          nightlyScheduleConflictChecked=True, clusterLifecycleResourceQuiescenceConfirmed=True),
                'Root must disclose Pending catalogue and explicitly confirm actual hardware quiescence')


def source_guard(plan, read_only=False):
    if read_only: fixed_scope(plan)
    else: validate(plan, approved=True)
    refs = runpy.run_path(str(ROOT / 'scripts/smal-localbox-references.py')); refs['verify_origin']()
    files = FILES + ([] if read_only else [str(SEALED.relative_to(ROOT))])
    source_map = {}
    for name in files:
        path = ROOT / name; data = path.read_bytes()
        require(not path.is_symlink() and data == subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT), 'Direct source/plan differs from committed HEAD: ' + name)
        if name in FILES: source_map[name] = hashlib.sha256(data).hexdigest()
    if not read_only:
        require(plan == json.loads(SEALED.read_text()) and sha(source_map) == plan['technicalReview']['sourceFileMapSha256'], 'Exact sealed direct plan/reviewed source map differs')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip()
    remote = subprocess.check_output(['git', 'ls-remote', '--heads', 'origin', 'refs/heads/' + branch], cwd=ROOT, text=True).split()
    require(remote and remote[0] == head, 'Exact direct source must be pushed')
    return head


def entry(plan, stage):
    require(stage in plan['transitionContract']['stages'], 'Unknown direct stage')
    return plan['transitionContract']['stages'][stage]


def verify_snapshot(s, plan, e, head, after=False, strict=True, capacity_refusal=False):
    fresh(s); require(s.get('sourceCommit') == head, 'Direct snapshot source differs')
    profiles = e['afterProfiles' if after else 'beforeProfiles']; states = e['afterStates' if after else 'beforeStates']
    C['verify_snapshot'](s, plan, {n: (v['cpu'], v['memory']) for n, v in profiles.items()},
                         off=[n for n, state in states.items() if state == 'Off'], healthy=False,
                         expanded=e['hostCpu'] == 64 and not capacity_refusal)
    cap = s['hostCapacity']
    allowed_cpu = (32, 64) if capacity_refusal or e['recovery'] else (e['hostCpu'],)
    require(cap['logicalProcessors'] in allowed_cpu and cap['physicalCores'] == cap['logicalProcessors'] // 2
            and cap['memoryBytes'] >= (250 if cap['logicalProcessors'] == 32 else 500) * 1024**3
            and cap['numa'] and sum(n['logicalProcessors'] for n in cap['numa']) == cap['logicalProcessors'], 'Actual direct host CPU/RAM/NUMA differs')
    health_profile = e['observeHealth'] if after else e['health']
    if health_profile == 'strict' and strict:
        policy, _, _ = infrastructure_policy(s['clusterStatic'], plan['infrastructureVmId'])
        require(policy == plan['baseline']['clusterStatic']['vmLifecyclePolicies'][0], 'Cluster VM resource/OfflineAction policy drift')
        R['health'](s, plan)
        require(set(s['nodeCapacity']) == set(C['NODES']), 'All three actual node capacities required')
        for n, c in s['nodeCapacity'].items():
            require(c['logicalProcessors'] == profiles[n]['cpu'] and c['memoryBytes'] >= profiles[n]['memory'] - 8 * 1024**3, 'Actual direct guest CPU/RAM differs')
        placement = [(n, v) for n, c in s['nodeCapacity'].items() for v in c['bridgePlacement']]
        require(len(placement) == 1 and placement[0][1]['id'] == plan['infrastructureVmId'] and placement[0][1]['state'] == 'Running', 'Infrastructure VM must be restored by cluster lifecycle')
        for n, c in s['nodeCapacity'].items():
            require(c['numa'] and sum(v['logicalProcessors'] for v in c['numa']) == profiles[n]['cpu']
                    and c['freeMemoryBytes'] >= (24 if n == placement[0][0] else 16) * 1024**3, 'Actual per-node NUMA/platform/infrastructure reserve unproved')
        resources = s['clusterHealth']['vmResources']
        require(len(resources) == 1 and resources[0]['vmIds'] == [plan['infrastructureVmId']] and resources[0]['ownerNode'] == placement[0][0] and resources[0]['state'] == 'Online', 'Exact restored cluster VmID/owner binding required')
        require(resources[0]['id'] == policy['resourceId'], 'Restored cluster VM resource ID changed')
    elif health_profile == 'stopped':
        require(s['clusterStatic'] is None and s['clusterHealth'] is None and s['nodeCapacity'] == {}, 'Stopped mode must explicitly report cluster/bridge unseen')


def recovery_authority(plan, e, head, directive):
    require(e['recovery'] and isinstance(directive, dict) and directive.get('authorityProfile') == 'direct-human-offline-original-profile-restoration'
            and isinstance(directive.get('quotedRequest'), str) and directive['quotedRequest'].strip()
            and directive['planSha256'] == sha(plan) and directive['sourceCommit'] == head
            and directive['stage'] == e['key'] and directive['approvedEffects'] == ['restore-original-profile-while-all-four-guests-off'], 'Separate exact direct-human offline restoration directive required')
    fresh(directive)


def context(plan, stage, mode, settlements=None, directive=None):
    require(mode in ('snapshot', 'dispatch', 'observe'), 'Unknown direct mode')
    if mode == 'snapshot': fixed_scope(plan)
    else: validate(plan, approved=True)
    p = copy.deepcopy(plan)
    if p.get('transitionContract') is None: p['transitionContract'] = contract(p)
    e = entry(p, stage)
    require(e['effect'] not in ('azure-deallocate', 'azure-size'), 'Azure observation is the explicit GET-only controller route, not guest transport')
    require(mode == 'snapshot' and stage == 'direct-cluster-stop' or
            mode == 'observe' or e['effect'] not in ('azure-deallocate', 'azure-size', 'canonical-startup', 'converge'), 'Wrong direct transport route')
    return dict(plan=p, stage=stage, mode=mode, settlements=settlements or {}, directive=directive)


def authorise_transport(ctx, head):
    plan, stage, mode = ctx['plan'], ctx['stage'], ctx['mode']; e = entry(plan, stage)
    require(ctx == context(plan, stage, mode, ctx['settlements'], ctx['directive']), 'Direct transport context differs')
    if mode == 'snapshot': return
    state, effects, settled = I['history']()
    require(state and state['planSha256'] == sha(plan) and state['sourceCommit'] == head, 'Original direct operation source fence absent')
    if mode == 'dispatch':
        require(stage in effects and stage not in settled and effects[stage]['requestSha256'] == sha(e)
                and set(effects) - set(settled) == {stage} and ctx['settlements'] == settled, 'Original direct unresolved intent required before dispatch')
        if e['recovery']: recovery_authority(plan, e, head, ctx['directive'])
    else: require(stage in effects or e['effect'] == 'converge', 'No original direct effect for observation')


def render_context(ctx, head):
    require(ctx == context(ctx['plan'], ctx['stage'], ctx['mode'], ctx['settlements'], ctx['directive']), 'Direct renderer context differs')
    return R['render_validated_context'](ctx, head, effects_enabled=ctx['mode'] != 'snapshot')


def preview(plan, stage):
    validate(plan, approved=False); entry(plan, stage)
    ctx = dict(plan=plan, stage=stage, mode='dispatch', settlements={}, directive=None)
    return R['render_validated_context'](ctx, '0' * 40, effects_enabled=False)


def transport(plan, stage, mode, key, settled=None, directive=None):
    t = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='direct_transport')
    name = 'direct-' + key; require(re.fullmatch('[a-z0-9-]{1,64}', name), 'Immutable direct read/transport key required')
    code = t['main']('scripts/smal-capacity-dispatch-r2.ps1', name, compute_context=context(plan, stage, mode, settled, directive))
    receipt = json.loads((t['OUT'] / ('private-ssh-' + name + '.json')).read_text())
    require(code == 0 and receipt['status'] == 'complete' and receipt['result']['status'] == 'complete', 'Direct transport uncertain/incomplete; original barrier retained')
    result = receipt['result']; result['cloud'] = C['get_cloud']()
    return result


def dispatch(plan, stage, evidence, directive=None):
    head = source_guard(plan); e = entry(plan, stage)
    require(e['effect'] not in ('canonical-startup', 'converge'), 'Use exact canonical handover/GET convergence')
    fresh(evidence)
    require(evidence['mutationPerformed'] is False and evidence['sourceCommit'] == head and evidence['planSha256'] == sha(plan)
            and evidence['stage'] == stage and evidence['exclusiveHardwareWriter'] is True
            and evidence['quotaPolicyAndScheduleChecked'] is True, 'Fresh direct stage/source/writer/quota/policy/schedule evidence absent')
    _, _, settled = I['idle']()
    cloud = evidence['cloud']; fresh(cloud); C['verify_cloud'](cloud, plan)
    verify_snapshot(evidence['snapshot'], plan, e, head)
    if e['recovery']: recovery_authority(plan, e, head, directive)
    else: require(cloud['size'] == (plan['beforeSize'] if e['hostCpu'] == 32 else plan['targetSize']), 'Direct configured model differs')
    if e['effect'].startswith('azure-'):
        require(settled['direct-off-lb-dc01']['proof']['outcome'] == 'applied', 'Original all-guest shutdown not settled')
        cloud = C['get_cloud'](); C['verify_cloud'](cloud, plan)
        require(cloud['size'] == plan['beforeSize'] and cloud['power'] == ('PowerState/running' if e['effect'] == 'azure-deallocate' else 'PowerState/deallocated'), 'Immediate direct Azure precondition differs')
    else: require(cloud['power'] == 'PowerState/running', 'Offline guest inspection/resize requires existing Running host')
    I['begin'](sha(plan), head)
    intent = I['claim'](stage, stage, 'azure' if e['effect'].startswith('azure-') else 'remote-worker', sha(plan), head, e['predecessors'], sha(e))
    if e['effect'] == 'azure-deallocate': C['az'](['vm', 'deallocate', '--ids', C['HOST'], '--subscription', C['SUB'], '--no-wait'])
    elif e['effect'] == 'azure-size':
        C['az'](['rest', '--method', 'patch', '--url', 'https://management.azure.com' + C['HOST'] + '?api-version=2025-04-01',
                 '--headers', 'If-Match=' + cloud['etag'], '--body', json.dumps({'properties': {'hardwareProfile': {'vmSize': plan['targetSize']}}})])
    else: transport(plan, stage, 'dispatch', stage, settled, directive)
    return dict(intent=intent, status='unresolved-independent-observation-required')


def settle(plan, stage, o):
    head = source_guard(plan); e = entry(plan, stage); fresh(o)
    _, effects, settled = I['history']()
    require(stage in effects and stage not in settled and all(o[f] == v for f, v in dict(operationId=I['OPERATION'], sourceCommit=head, planSha256=sha(plan), stage=stage, key=stage).items())
            and o['mutationPerformed'] is False and o['outcome'] in ('applied', 'not-applied'), 'Original direct independent observation required')
    if e['effect'] != 'canonical-startup':
        require(effects[stage]['requestSha256'] == sha(e), 'Original direct requested transition differs')
    cloud = o['cloud']; fresh(cloud); C['verify_cloud'](cloud, plan)
    if e['effect'].startswith('azure-'):
        require(o['outcome'] == 'applied' and cloud['power'] == 'PowerState/deallocated' and cloud['size'] == (plan['targetSize'] if e['effect'] == 'azure-size' else plan['beforeSize'])
                and o['azureProvisioningState'] == 'Succeeded' and o['azureTransitionSettled'] is True, 'Original Azure effect not independently settled')
    else:
        require(all(o[f] is False for f in ('workerAlive', 'dispatcherAlive')) and o['rpcPhase'] == 'returned'
                and o['workerIdentityVerified'] is True and o['workerSourceVerified'] is True and cloud['power'] == 'PowerState/running', 'Original direct process/source/RPC unproved')
        if not e['recovery']:
            require(cloud['size'] == (plan['beforeSize'] if e['hostCpu'] == 32 else plan['targetSize']), 'Observed direct stage model differs')
        refusal = e['effect'] == 'canonical-startup' and o['outcome'] == 'not-applied'
        verify_snapshot(o['snapshot'], plan, e, head, after=o['outcome'] == 'applied', capacity_refusal=refusal)
        text = render_context(context(plan, stage, 'observe'), head).decode()
        if e['effect'] == 'canonical-startup':
            w = o['remoteStartup']
            require(w['key'] == stage and w['sourceCommit'] == head and w['planSha256'] == sha(plan) and w['phase'] == 'returned'
                    and w['helperSha256'] == re.search(r"\$startupHelperSha256='([A-F0-9]{64})'", text)[1], 'Exact direct startup process/event differs')
            if refusal: require(w['guestRpcInvoked'] is False and w['refusal'] == 'capacity-refused-before-guests', 'Only proved no-guest-RPC capacity refusal can settle not-applied')
        else:
            w = o['worker']; request = o['request']
            require(w['sourceSha256'] == re.search(r"\$workerSha256='([A-F0-9]{64})'", text)[1]
                    and all(w[f] == request[f] == o[f] for f in ('operationId', 'sourceCommit', 'planSha256', 'stage', 'key'))
                    and w['phase'] == 'returned' and w['pid'] > 0 and request['pid'] > 0
                    and (w['rpcSucceeded'] is True if o['outcome'] == 'applied' else w['rpcInvoked'] is False), 'Exact original direct worker/request/outcome differs')
            if e['effect'] == 'cluster-stop' and o['outcome'] == 'applied':
                _, expected_state, shutdown_enabled = infrastructure_policy(plan['baseline']['clusterStatic'], plan['infrastructureVmId'])
                require(o['clusterServices'] == {n: 'Stopped' for n in C['NODES']}
                        and o['clusterLifecycleVms'] == [dict(id=plan['infrastructureVmId'], state=expected_state, cpu=4, memory=8 * 1024**3,
                                                             shutdownIntegrationEnabled=shutdown_enabled)], 'Whole cluster stop must preserve the exact policy-bound nested VM state')
            if e['effect'] == 'complete':
                require(o['remoteCompletion']['snapshot'] == w['completionSnapshot'], 'Original direct completion snapshot differs')
                verify_snapshot(o['remoteCompletion']['snapshot'], plan, e, head, after=True)
    proof = dict(atUtc=o['atUtc'], operationId=I['OPERATION'], sourceCommit=head, planSha256=sha(plan), key=stage, stage=stage,
                 identityAndSettingsVerified=True, effectObserved=True, outcome=o['outcome'], observation=o, observationSha256=sha(o))
    for f in ('workerAlive', 'dispatcherAlive', 'rpcPhase', 'workerIdentityVerified', 'workerSourceVerified', 'azureProvisioningState', 'azureTransitionSettled'):
        if f in o: proof[f] = o[f]
    return I['resolve'](stage, proof)


def observe(plan, stage, key):
    head = source_guard(plan); e = entry(plan, stage)
    require(re.fullmatch('[a-z0-9-]{1,48}', key or ''), 'Unique direct observation key required')
    _, effects, settled = I['history']()
    require(stage in effects or e['effect'] == 'converge' and all(k in settled for k in e['predecessors']), 'Original direct effect/convergence prerequisite required')
    if e['effect'].startswith('azure-'):
        cloud = C['get_cloud'](); C['verify_cloud'](cloud, plan)
        expected_size = plan['targetSize'] if e['effect'] == 'azure-size' else plan['beforeSize']
        terminal = cloud['power'] == 'PowerState/deallocated' and cloud['size'] == expected_size and cloud.get('provisioningState') == 'Succeeded'
        return dict(atUtc=cloud['atUtc'], operationId=I['OPERATION'], sourceCommit=head, planSha256=sha(plan), stage=stage, key=stage,
                    observationKey=key, mutationPerformed=False, outcome='applied' if terminal else 'unknown', cloud=cloud,
                    azureProvisioningState=cloud.get('provisioningState'), azureTransitionSettled=terminal)
    return transport(plan, stage, 'observe', key)


def handover(plan, evidence):
    head = source_guard(plan); e = entry(plan, 'direct-startup'); fresh(evidence)
    _, _, settled = I['idle']()
    require(all(k in settled and settled[k]['proof']['outcome'] == 'applied' for k in e['predecessors']), 'Applied direct E64 model change required')
    require(evidence['sourceCommit'] == head and evidence['planSha256'] == sha(plan) and evidence['mutationPerformed'] is False, 'Fresh source-bound direct handover evidence required')
    cloud = evidence['cloud']; fresh(cloud); C['verify_cloud'](cloud, plan)
    require(cloud['size'] == plan['targetSize'] and cloud['power'] == 'PowerState/deallocated', 'No direct guest startup before E64 model and stable deallocation')
    grant = settled['direct-grant']['proof']['observation']['worker']['remoteGrant']
    require(grant['startupEntry'] == e and grant['profiles'] == e['beforeProfiles'] and grant['states'] == e['beforeStates'], 'Exact target-profile/all-Off grant required')
    grant_snapshot = settled['direct-grant']['proof']['observation']['snapshot']; fresh(grant_snapshot)
    verify_snapshot(grant_snapshot, plan, entry(plan, 'direct-grant'), head, after=True)
    require(grant['guests'] == grant_snapshot['guestsStatic'] and grant['hostStatic'] == grant_snapshot['hostStatic']
            and grant['volumesStatic'] == grant_snapshot['volumesStatic']
            and grant['capacityGuard'] == dict(hostCpu=64, physicalCores=32, minimumMemoryBytes=500 * 1024**3, minimumFreeMemoryBytes=64 * 1024**3), 'Original full identity/runtime guard grant differs')
    return I['prepare_startup'](SEALED, dict(evidence, safeCanonicalStartup=True), grant, 'direct-startup')


def converge(plan, o):
    head = source_guard(plan); e = entry(plan, 'direct-converge'); fresh(o)
    verify_snapshot(o['snapshot'], plan, e, head, after=True)
    require(o['key'] == o['stage'] == e['key'] and o['sourceCommit'] == head and o['planSha256'] == sha(plan) and o['mutationPerformed'] is False, 'Exact direct GET convergence evidence required')
    I['claim'](e['key'], e['key'], 'read-certificate', sha(plan), head, e['predecessors'], sha(e))
    return I['resolve'](e['key'], dict(atUtc=o['atUtc'], operationId=I['OPERATION'], sourceCommit=head, planSha256=sha(plan), stage=e['key'], key=e['key'],
                                    identityAndSettingsVerified=True, effectObserved=True, outcome='applied', observation=o, observationSha256=sha(o)))


def finish(plan, o):
    head = source_guard(plan); fresh(o); _, _, settled = I['idle']()
    verify_snapshot(o['snapshot'], plan, entry(plan, 'complete'), head, after=True)
    fresh(o['cloud']); C['verify_cloud'](o['cloud'], plan)
    require(o['key'] == o['stage'] == 'complete' and o['sourceCommit'] == head and o['planSha256'] == sha(plan)
            and o['cloud']['power'] == 'PowerState/running' and o['cloud']['size'] == plan['targetSize']
            and o['mutationPerformed'] is False, 'Exact final direct identity/model/source observation required')
    require(settled['complete']['proof']['outcome'] == 'applied' and o['remoteCompletion'] == settled['complete']['proof']['observation']['remoteCompletion'], 'Original direct completion settlement required')
    return I['finish'](dict(atUtc=o['atUtc'], operationId=I['OPERATION'], sourceCommit=head, planSha256=sha(plan),
                          allHealthyAndOk=True, noActiveStorageJobs=True, identityAndSettingsVerified=True, remoteCompletionObserved=True,
                          observation=o, observationSha256=sha(o), completionSettlementSha256=sha(settled['complete'])))


def prepare(observation):
    """Fresh read-only data -> unsigned candidate, stdout only. No approval inference."""
    fresh(observation); s = observation['snapshot']; fresh(s)
    require(observation['mutationPerformed'] is False and s['sourceCommit'] == observation['sourceCommit'], 'Actual source-bound read-only snapshot required')
    plan = json.loads(PENDING.read_text())
    plan['baseline'] = dict(cloud=observation['cloud']['projection'], **{f: s[f] for f in ('hostStatic', 'guestsStatic', 'clusterStatic', 'volumesStatic')})
    infrastructure_policy(plan['baseline']['clusterStatic'], plan['infrastructureVmId'])
    plan['deviceOwners'] = {d['id']: d['owner'] for d in s['clusterHealth']['devices']}
    placements = [(n,v) for n,c in s['nodeCapacity'].items() for v in c['bridgePlacement']]
    require(len(placements) == 1 and placements[0][1]['id'] == plan['infrastructureVmId'], 'Exact infrastructure owner required')
    owner = placements[0][0]; others = [n for n in C['NODES'] if n != owner]
    budgets = {letter: dict(maximumVhdBytes=0, runtimeBytes=0, metadataBytes=16 * 1024**3, freeFloorBytes=200 * 1024**3) for letter in 'CVWX'}
    for guest in s['guestsStatic']:
        for disk in guest['disks']: budgets[disk['path'][0]]['maximumVhdBytes'] += disk['size']
        for letter in {guest['configurationLocation'][0], guest['smartPagingLocation'][0]}:
            budgets[letter]['runtimeBytes'] += (4 if guest['name'] == 'LB-DC01' else 128) * 1024**3
    plan['admission'] = dict(repairReserveBytes=510 * 1024**3, requiredPhysicalFreeBytes=360 * 1024**3,
        volumeBudgets=budgets, platformCpuReservePerNode={n: 8 if n == owner else 4 for n in C['NODES']},
        platformMemoryReservePerNodeBytes={n: (24 if n == owner else 16) * 1024**3 for n in C['NODES']},
        placement=dict(controlplane=others[0], system=others[0], workload=others[1], inference=others[1], replacement=owner),
        infrastructureVmNode=owner, maintenanceConflictChecked=False)
    plan['transitionContract'] = contract(plan)
    C['verify_cloud'](observation['cloud'], plan)
    verify_snapshot(s, plan, entry(plan, 'direct-cluster-stop'), observation['sourceCommit'])
    require(plan['directHumanApproval'] is None and plan['technicalReview'] is None, 'Preparation must stay unsigned')
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'preview', 'render', 'read', 'dispatch', 'observe', 'settle', 'handover', 'converge', 'finish'])
    parser.add_argument('--plan', type=Path, default=SEALED); parser.add_argument('--stage'); parser.add_argument('--key')
    parser.add_argument('--evidence', type=Path); parser.add_argument('--recovery-directive', type=Path)
    args = parser.parse_args()
    if args.action == 'prepare': print(json.dumps(prepare(json.loads(args.evidence.read_text())), indent=2)); return
    plan = json.loads((PENDING if args.action == 'read' else args.plan).read_text())
    if args.action == 'preview': print(preview(plan, args.stage).decode()); return
    if args.action == 'render': print(render_context(context(plan, args.stage, 'dispatch'), '0' * 40).decode()); return
    # Same local mutex as canonical startup. No Relay state or agent messaging exists here.
    with Path('/tmp/opencode/smal-localbox-start.lock').open('a') as lock:
        import fcntl
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        evidence = json.loads(args.evidence.read_text()) if args.evidence else None
        if args.action == 'read': source_guard(plan, read_only=True); result = transport(plan, 'direct-cluster-stop', 'snapshot', args.key)
        elif args.action == 'dispatch': result = dispatch(plan, args.stage, evidence, json.loads(args.recovery_directive.read_text()) if args.recovery_directive else None)
        elif args.action == 'observe': result = observe(plan, args.stage, args.key)
        elif args.action == 'settle': result = settle(plan, args.stage, evidence)
        elif args.action == 'handover': result = str(handover(plan, evidence))
        elif args.action == 'converge': result = converge(plan, evidence)
        else: result = finish(plan, evidence)
        print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
