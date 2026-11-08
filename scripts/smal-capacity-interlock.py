"""Create-only operation history shared by capacity and canonical startup.

No process liveness heuristic, transport exit or elapsed time settles an intent.
Crash between intent fsync and dispatch is deliberately unresolved. All filesystem
writes belong to the new repository. Historical receipt roots are read-only.
"""
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import runpy

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-11-08-capacity'
LOCK = Path('/tmp/opencode/smal-capacity-state.lock')
LEGACY = Path('/home/quintin/play/azurelocalbox/docs/deployment-2026-11-08-capacity')
OPERATION = 'smal-compute-capacity-20261108-01'
SCRIPTS = Path(__file__).resolve().parent


def approved_plan(plan):
    if plan.get('route') == 'direct-full-outage-v1':
        controller = runpy.run_path(str(SCRIPTS / 'smal-capacity-direct.py'), run_name='direct_handover_authority')
        controller['validate'](plan, approved=True)
    else:
        require(plan.get('route') is None and isinstance(plan.get('executionApproval'), dict)
                and plan['executionApproval'].get('parentGo') is True, 'Exact legacy sealed GO absent')


def sha(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def fresh(proof):
    stamp = datetime.fromisoformat(proof['atUtc'].replace('Z', '+00:00'))
    require(stamp.tzinfo is not None, 'Timezone required')
    require(0 <= (datetime.now(timezone.utc) - stamp).total_seconds() <= 600, 'Expired/future evidence')


def read(path):
    require(path.is_file() and not path.is_symlink(), 'Missing or symlink history: ' + path.name)
    require(path.stat().st_uid == os.getuid(), 'History owner differs')
    return json.loads(path.read_text())


def write_new(path, value):
    require(path.parent.resolve() == OUT.resolve(), 'Write outside operation history')
    require(not OUT.is_symlink() and OUT.stat().st_uid == os.getuid(), 'Unsafe history directory')
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, sort_keys=True, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    fd = os.open(OUT, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


@contextmanager
def locked():
    fd = os.open(LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'r+') as lock:
        require(os.fstat(lock.fileno()).st_uid == os.getuid() and
                stat.S_IMODE(os.fstat(lock.fileno()).st_mode) == 0o600, 'Unsafe mutex owner/mode')
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def legacy_guard():
    require(LEGACY.is_dir() and not LEGACY.is_symlink(), 'Original receipt root missing. No empty-history assumption')
    require(not (LEGACY / 'operation-r2.json').exists() and not list(LEGACY.glob('intent-r2-*.json')), 'Original-root R2 history requires explicit migration reconciliation')
    for root in {OUT, LEGACY}:
        for path in root.glob('operation-*.json'):
            if path.name == 'operation-r2.json':
                continue
            row = read(path)
            if row.get('mutationRequested') is True and row.get('status') != 'complete':
                resolution = root / ('resolution-' + path.name)
                r = read(resolution) if resolution.exists() else {}
                require(r.get('originalSha256') == sha(row) and r.get('status') == 'complete'
                        and r.get('mutationPerformed') is False, 'Unresolved original effect: ' + path.name)
        require(not (root / 'interlock-r2.json').exists(), 'Partial R2 index requires explicit migration review')


def history():
    legacy_guard()
    anchor = OUT / 'operation-r2.json'
    intents = {p.name: read(p) for p in OUT.glob('intent-r2-*.json')}
    if not anchor.exists():
        require(not intents and not list(OUT.glob('settlement-r2-*.json'))
                and not list(OUT.glob('startup-handover-r2-*.json'))
                and not (OUT / 'completion-r2.json').exists(), 'Orphan R2 history')
        return None, {}, {}
    state = read(anchor)
    require(state['operationId'] == OPERATION and state['ownerUid'] == os.getuid()
            and state['root'] == str(ROOT.resolve()), 'Operation writer/root fence differs')
    effects, settlements = {}, {}
    for name, intent in intents.items():
        require(name == 'intent-r2-' + intent['key'] + '.json' and intent['key'] not in effects,
                'Intent filename/key differs')
        for field in ('operationId', 'planSha256', 'sourceCommit', 'ownerUid', 'root'):
            require(intent[field] == state[field], 'Intent scope/source/writer differs')
        effects[intent['key']] = intent
    for path in OUT.glob('settlement-r2-*.json'):
        resolution = read(path)
        key = resolution['key']
        require(key in effects and path.name == 'settlement-r2-' + key + '.json', 'Orphan settlement')
        require(resolution['intentSha256'] == sha(effects[key]), 'Original intent changed')
        validate_resolution(effects[key], resolution['proof'])
        settlements[key] = resolution
    for intent in effects.values():
        require(all(k in settlements and sha(settlements[k]) == h for k, h in intent['predecessorHashes'].items()), 'Original predecessor history changed')
    return state, effects, settlements


def idle():
    state, effects, settled = history()
    require(set(effects) == set(settled), 'Operation-wide unresolved effect. Reconcile original key, never replay')
    return state, effects, settled


def begin(plan_sha, source_commit):
    require(re.fullmatch('[a-f0-9]{64}', plan_sha) and re.fullmatch('[a-f0-9]{40}', source_commit), 'Exact source/digest required')
    with locked():
        state, _, _ = history()
        if state:
            require(state['planSha256'] == plan_sha and state['sourceCommit'] == source_commit, 'Existing operation differs')
            return state
        state = dict(operationId=OPERATION, planSha256=plan_sha, sourceCommit=source_commit,
                     ownerUid=os.getuid(), root=str(ROOT.resolve()))
        write_new(OUT / 'operation-r2.json', state)
        return state


def claim(key, stage, kind, plan_sha, source_commit, predecessors, request_sha):
    require(re.fullmatch('[a-z0-9][a-z0-9-]{0,47}', key) and kind in ('remote-worker', 'azure', 'canonical-startup', 'read-certificate'), 'Invalid key/kind')
    with locked():
        state, effects, settled = idle()
        require(state and not (OUT / 'completion-r2.json').exists(), 'Active operation absent')
        require(state['planSha256'] == plan_sha and state['sourceCommit'] == source_commit, 'Source/plan fence differs')
        require(key not in effects and not any(e['stage'] == stage for e in effects.values()), 'Stage/key already requested')
        require(not any(read(p)['key'] not in effects for p in OUT.glob('startup-handover-r2-*.json')), 'Outstanding canonical handover fences new effects')
        require(set(predecessors) <= set(settled) and all(settled[k]['proof']['outcome'] == 'applied' for k in predecessors), 'Applied prerequisite missing')
        intent = dict(state, key=key, stage=stage, kind=kind, requestSha256=request_sha,
                      predecessorHashes={k: sha(settled[k]) for k in predecessors},
                      atUtc=datetime.now(timezone.utc).isoformat())
        write_new(OUT / ('intent-r2-' + key + '.json'), intent)
        return intent


def validate_resolution(intent, proof):
    for field in ('operationId', 'planSha256', 'sourceCommit', 'stage', 'key'):
        require(proof[field] == intent[field], 'Settlement binding differs')
    require(proof['identityAndSettingsVerified'] is True and proof['effectObserved'] is True
            and proof['outcome'] in ('applied', 'not-applied'), 'Exact observed effect required')
    require(proof['observationSha256'] == sha(proof['observation']), 'Observation changed')
    if intent['kind'] in ('remote-worker', 'canonical-startup'):
        require(proof['workerAlive'] is False and proof['dispatcherAlive'] is False
                and proof['rpcPhase'] == 'returned' and proof['workerIdentityVerified'] is True
                and proof['workerSourceVerified'] is True, 'Exact process/source/RPC settlement missing')
    elif intent['kind'] == 'azure':
        require(proof['azureTransitionSettled'] is True and proof['azureProvisioningState'] == 'Succeeded', 'Azure transition unresolved')


def resolve(key, proof):
    fresh(proof)
    with locked():
        state, effects, settled = history()
        require(key in effects and key not in settled, 'Original unresolved key required')
        intent = effects[key]
        validate_resolution(intent, proof)
        resolution = dict(key=key, intentSha256=sha(intent), proof=proof)
        write_new(OUT / ('settlement-r2-' + key + '.json'), resolution)
        return resolution


def prepare_startup(plan_path, proof, remote_grant, key):
    fresh(proof)
    with locked():
        state, _, settled = idle()
        _, effects, _ = history()
        require(not any(read(p)['key'] not in effects for p in OUT.glob('startup-handover-r2-*.json')), 'Existing unconsumed startup handover')
        require(state and proof['planSha256'] == state['planSha256'] and proof['safeCanonicalStartup'] is True, 'Live startup preconditions absent')
        plan_path = Path(plan_path)
        require(plan_path.parent.resolve() == OUT.resolve(), 'Exact owned sealed plan required')
        plan = read(plan_path)
        require(sha(plan) == state['planSha256'], 'Exact sealed plan digest absent')
        approved_plan(plan)
        require(remote_grant['key'] == key and remote_grant['planSha256'] == state['planSha256']
                and remote_grant['sourceCommit'] == state['sourceCommit'], 'Remote grant binding differs')
        handover = dict(state, key=key, planFile=plan_path.name, proof=proof, remoteGrant=remote_grant,
                        settlementHashes={k: sha(v) for k, v in settled.items()})
        path = OUT / ('startup-handover-r2-' + key + '.json')
        write_new(path, handover)
        return path


def authorise_startup(handover_path=None, expected_source=None):
    # Called while canonical startup owns the shared outer process mutex, before VPN/start.
    with locked():
        state, effects, settled = idle()
        if state is None:
            require(handover_path is None, 'No active handover')
            return None
        if (OUT / 'completion-r2.json').exists():
            complete = read(OUT / 'completion-r2.json')
            require(complete['planSha256'] == state['planSha256'] and complete['settlementHashes'] == {k: sha(v) for k, v in settled.items()}, 'Completion/history differs')
            require('complete' in settled and settled['complete']['proof']['outcome'] == 'applied'
                    and complete['completionSettlementSha256'] == sha(settled['complete'])
                    and complete['observationSha256'] == sha(complete['observation'])
                    and complete['observation']['remoteCompletion'] == settled['complete']['proof']['observation']['remoteCompletion'], 'Unbound completion certificate')
            require(handover_path is None, 'Completed operation needs no handover')
            return None
        require(handover_path is not None and state['sourceCommit'] == expected_source, 'Exact explicit startup handover/source required')
        path = Path(handover_path)
        require(path.parent.resolve() == OUT.resolve(), 'Handover outside history')
        handover = read(path)
        require(all(handover[f] == state[f] for f in state), 'Handover writer/source/plan differs')
        fresh(handover['proof'])
        require(handover['settlementHashes'] == {k: sha(v) for k, v in settled.items()}, 'Handover history changed')
        plan = read(OUT / handover['planFile'])
        require(sha(plan) == state['planSha256'], 'Sealed plan changed')
        approved_plan(plan)
        key = handover['key']
        require(re.fullmatch('[a-z0-9][a-z0-9-]{0,47}', key) and key not in effects, 'Handover consumed/invalid')
        intent = dict(state, key=key, stage=key, kind='canonical-startup', requestSha256=sha(handover),
                      predecessorHashes=handover['settlementHashes'], atUtc=datetime.now(timezone.utc).isoformat())
        write_new(OUT / ('intent-r2-' + key + '.json'), intent)
        return dict(key=key, handover=handover, intent=intent)


def finish(proof):
    fresh(proof)
    with locked():
        state, _, settled = idle()
        require(state and proof['planSha256'] == state['planSha256'] and proof['allHealthyAndOk'] is True
                and proof['noActiveStorageJobs'] is True and proof['identityAndSettingsVerified'] is True
                and proof['remoteCompletionObserved'] is True, 'Exact remote completion/full convergence absent')
        require(proof['operationId'] == state['operationId'] and proof['sourceCommit'] == state['sourceCommit']
                and 'complete' in settled and settled['complete']['proof']['outcome'] == 'applied'
                and proof['completionSettlementSha256'] == sha(settled['complete'])
                and proof['observationSha256'] == sha(proof['observation'])
                and proof['observation']['remoteCompletion'] == settled['complete']['proof']['observation']['remoteCompletion'], 'Unbound completion proof refused')
        write_new(OUT / 'completion-r2.json', dict(proof, settlementHashes={k: sha(v) for k, v in settled.items()}))
