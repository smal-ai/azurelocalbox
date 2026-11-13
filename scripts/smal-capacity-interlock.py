"""Durable capacity/startup interlock. Local locks alone never settle remote effects.

Intent and resolution files are create-only and fsynced. The mutable index is an atomic
projection of that history, not an approval flag. All callers share the existing startup
mutex externally and this index mutex internally. No Azure/guest call occurs here.
"""
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/deployment-2026-11-08-capacity"
STATE = OUT / "interlock-r2.json"
LOCK = Path("/tmp/opencode/smal-capacity-state.lock")
OPERATION = "smal-compute-capacity-20261108-01"


def sha(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def fresh(proof):
    stamp = datetime.fromisoformat(proof["atUtc"].replace("Z", "+00:00"))
    require(stamp.tzinfo is not None, "Timezone required")
    age = (datetime.now(timezone.utc) - stamp).total_seconds()
    require(0 <= age <= 600, "Settlement/handover evidence expired or future")


def write_new(path, value):
    require(not path.is_symlink(), "Symlink receipt refused")
    path.parent.mkdir(exist_ok=True)
    with path.open("x") as stream:
        json.dump(value, stream, sort_keys=True, indent=2); stream.write("\n")
        stream.flush(); os.fsync(stream.fileno())
    fd = os.open(path.parent, os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)


def write_index(value):
    require(not STATE.is_symlink(), "Symlink index refused")
    temp = STATE.with_name(STATE.name + "." + uuid.uuid4().hex)
    write_new(temp, value)
    os.replace(temp, STATE)
    fd = os.open(STATE.parent, os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)


@contextmanager
def locked():
    with LOCK.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def read_index():
    if not STATE.exists(): return None
    require(not STATE.is_symlink(), "Symlink index refused")
    state = json.loads(STATE.read_text())
    require(state.get("schemaVersion") == 2 and state.get("operationId") == OPERATION
            and state.get("ownerUid") == os.getuid(), "Interlock identity/owner differs")
    return state


def legacy_unresolved():
    result = []
    for path in OUT.glob("operation-*.json"):
        row = json.loads(path.read_text())
        if row.get("mutationRequested") is True and row.get("status") != "complete":
            # Legacy cloud resolutions are checked against immutable original content.
            resolution = OUT / ("resolution-" + path.name)
            settled = False
            if resolution.exists():
                r = json.loads(resolution.read_text())
                settled = r.get("status") == "complete" and r.get("originalSha256") == sha(row) and r.get("mutationPerformed") is False
            if not settled: result.append(path.name)
    return result


def verify_history(state):
    require(not legacy_unresolved(), "Legacy unresolved capacity intent blocks all mutations/startup")
    # Scan intent files too: interruption between fsync(intent) and index rename cannot hide work.
    intents = list(OUT.glob("intent-r2-*.json"))
    actual = {}
    for path in intents:
        intent = json.loads(path.read_text())
        require(intent.get("operationId") == state["operationId"] and intent.get("planSha256") == state["planSha256"], "Intent scope/plan mismatch")
        actual[intent["key"]] = path.name
    require(actual == {k: v["intent"] for k, v in state["effects"].items()}, "Unindexed durable intent blocks continuation")
    for key, effect in state["effects"].items():
        intent = json.loads((OUT / effect["intent"]).read_text())
        require(sha(intent) == effect["intentSha256"], "Original intent changed")
        if effect.get("resolution"):
            resolution = json.loads((OUT / effect["resolution"]).read_text())
            require(resolution["intentSha256"] == effect["intentSha256"] and sha(resolution) == effect["resolutionSha256"], "Resolution changed")
    if not state["active"]:
        path = OUT / "completion-r2.json"
        require(path.exists() and state.get("completionSha256"), "Inactive flag without final completion proof")
        completion = json.loads(path.read_text())
        require(sha(completion) == state["completionSha256"] and completion.get("planSha256") == state["planSha256"]
                and completion.get("allHealthyAndOk") is True and completion.get("noActiveStorageJobs") is True,
                "Final completion certificate differs")
    return state


def idle(state):
    verify_history(state)
    require(all(e.get("resolution") for e in state["effects"].values()), "Operation-wide unresolved effect blocks new mutation/startup")


def begin(plan_sha, source_commit):
    require(re.fullmatch(r"[a-f0-9]{64}", plan_sha) and re.fullmatch(r"[a-f0-9]{40}", source_commit), "Exact plan/source digest required")
    with locked():
        require(not legacy_unresolved(), "Legacy unresolved effect")
        state = read_index()
        if state:
            require(state["planSha256"] == plan_sha and state["sourceCommit"] == source_commit and state["active"], "Existing operation/source differs")
            verify_history(state); return state
        require(not list(OUT.glob("intent-r2-*.json")), "Orphan durable intents require inspection")
        state = {"schemaVersion": 2, "operationId": OPERATION, "ownerUid": os.getuid(), "owner": "CAPACITY",
                 "planSha256": plan_sha, "sourceCommit": source_commit, "active": True, "revision": 1,
                 "effects": {}, "handover": None}
        OUT.mkdir(exist_ok=True); write_index(state); return state


def claim(key, stage, kind, plan_sha, source_commit):
    require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,47}", key), "Immutable key invalid")
    require(kind in ("remote-worker", "azure", "canonical-startup"), "Unknown effect kind")
    with locked():
        state = read_index(); require(state and state["active"], "Active operation absent")
        require(state["planSha256"] == plan_sha and state["sourceCommit"] == source_commit, "Plan/source changed during operation")
        idle(state)
        require(not state["handover"], "Outstanding startup handover blocks mutation")
        require(key not in state["effects"] and not any(e["stage"] == stage for e in state["effects"].values()), "Original stage/key already claimed, do not replay")
        intent = {"operationId": OPERATION, "planSha256": plan_sha, "sourceCommit": source_commit,
                  "owner": state["owner"], "ownerUid": state["ownerUid"], "key": key, "stage": stage, "kind": kind,
                  "atUtc": datetime.now(timezone.utc).isoformat(), "status": "unresolved"}
        path = OUT / ("intent-r2-" + key + ".json")
        write_new(path, intent)
        state["effects"][key] = {"stage": stage, "kind": kind, "intent": path.name, "intentSha256": sha(intent)}
        state["revision"] += 1; write_index(state)
        return intent


def resolve(key, proof):
    """Caller validates live expected identity/settings/effect before this durable barrier."""
    fresh(proof)
    with locked():
        state = read_index(); require(state and state["active"], "Operation absent")
        verify_history(state)
        effect = state["effects"].get(key); require(effect and not effect.get("resolution"), "Original unresolved key required")
        require(proof.get("operationId") == OPERATION and proof.get("planSha256") == state["planSha256"]
                and proof.get("sourceCommit") == state["sourceCommit"] and proof.get("stage") == effect["stage"]
                and proof.get("identityAndSettingsVerified") is True and proof.get("effectObserved") is True,
                "Exact original live settlement proof required")
        if effect["kind"] == "remote-worker":
            require(proof.get("workerAlive") is False and proof.get("rpcPhase") == "returned"
                    and proof.get("workerIdentityVerified") is True and proof.get("workerSourceVerified") is True,
                    "Remote process/RPC not proved settled; closing SSH is insufficient")
        if effect["kind"] == "azure":
            require(proof.get("azureProvisioningState") == "Succeeded" and proof.get("azureTransitionSettled") is True, "Azure effect not settled")
        if effect["kind"] == "canonical-startup":
            require(proof.get("privateCommandExited") is True and proof.get("allExactGuestsRunning") is True
                    and proof.get("remoteStartupPhase") == "returned" and proof.get("workerAlive") is False,
                    "Canonical startup remote process/RPC not settled")
        require(proof.get("outcome") in ("applied", "not-applied", "partial-known"), "Unknown outcome cannot release barrier")
        resolution = {"operationId": OPERATION, "key": key, "intentSha256": effect["intentSha256"], "proof": proof}
        path = OUT / ("settlement-r2-" + key + ".json")
        write_new(path, resolution)
        effect["resolution"] = path.name; effect["resolutionSha256"] = sha(resolution)
        effect["outcome"] = proof["outcome"]
        state["revision"] += 1; write_index(state)
        return resolution


def prepare_startup(plan_path, proof, remote_grant, key):
    """A one-use grant bound to sealed plan, original settled history and live Off profiles."""
    fresh(proof)
    with locked():
        state = read_index(); require(state and state["active"], "Operation absent")
        idle(state); require(not state["handover"], "Existing handover, inspect instead of replacing")
        plan_path = Path(plan_path)
        require(plan_path.parent.resolve() == OUT.resolve() and not plan_path.is_symlink(), "Owned sealed plan required")
        plan = json.loads(plan_path.read_text())
        require(sha(plan) == state["planSha256"] and plan.get("executionApproval", {}).get("parentGo") is True, "Exact sealed plan/GO required")
        require(proof.get("identityAndSettingsVerified") is True and proof.get("safeCanonicalStartup") is True
                and proof.get("planSha256") == state["planSha256"] and proof.get("remoteBarrierSettled") is True,
                "Live startup identity/profile/remote settlement unproved")
        require(remote_grant.get("planSha256") == state["planSha256"] and remote_grant.get("operationId") == OPERATION
                and remote_grant.get("allPriorRemoteEffectsSettled") is True and remote_grant.get("sourceCommit") == state["sourceCommit"],
                "Exact settled remote startup grant required")
        handover = {"operationId": OPERATION, "owner": state["owner"], "ownerUid": state["ownerUid"],
                    "planSha256": state["planSha256"], "sourceCommit": state["sourceCommit"], "planFile": plan_path.name,
                    "revision": state["revision"], "key": key, "remoteGrant": remote_grant, "proof": proof,
                    "settlementHashes": {k: e["resolutionSha256"] for k, e in state["effects"].items()}}
        path = OUT / ("startup-handover-r2-" + key + ".json")
        write_new(path, handover)
        state["handover"] = {"path": path.name, "sha256": sha(handover)}; write_index(state)
        return path


def authorise_startup(handover_path=None, expected_source=None):
    """Normal startup only. Retained R2 preparation is not a release certificate."""
    with locked():
        require(OUT.is_dir() and not OUT.is_symlink(), "Original capacity receipt root missing or symlinked")
        require(not STATE.is_symlink(), "Symlink index refused")
        require(not legacy_unresolved(), "Unresolved legacy capacity effect blocks startup")
        state = read_index()
        histories = ("operation-r2.json", "intent-r2-*.json", "settlement-r2-*.json",
                     "startup-handover-r2-*.json", "completion-r2.json")
        require(state is None and not any(list(OUT.glob(pattern)) for pattern in histories),
                "Retained R2 history requires reviewed source and exact local/remote settlement before startup")
        require(handover_path is None, "No active capacity operation for handover")
        return None


def finish(proof):
    fresh(proof)
    with locked():
        state = read_index(); require(state and state["active"], "Operation absent")
        idle(state); require(not state["handover"], "Outstanding startup handover")
        require(proof.get("planSha256") == state["planSha256"] and proof.get("allHealthyAndOk") is True
                and proof.get("noActiveStorageJobs") is True and proof.get("identityAndSettingsVerified") is True,
                "Final exact capacity/healthy convergence proof missing")
        write_new(OUT / "completion-r2.json", proof)
        state["completionSha256"] = sha(proof)
        state["active"] = False; state["revision"] += 1; write_index(state)
