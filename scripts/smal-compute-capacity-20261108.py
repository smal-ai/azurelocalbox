"""Exact-plan staged compute-only operation. No starts except canonical startup.

Offline rendering emits candidate file content as JSON for reviewed patching. It does
not overwrite source, approve itself, commit, push, install tools or dispatch guests.
Transport is the existing unmodified canonical private PowerShell entry point.
"""
import argparse
import base64
import contextlib
import copy
from datetime import datetime, timezone
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/deployment-2026-11-08-capacity"
SUB = "8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea"
TENANT = "c6e67968-af25-4557-ab8b-06b693048d3b"
HOST = f"/subscriptions/{SUB}/resourceGroups/rg-localbox-nodes-san-1/providers/Microsoft.Compute/virtualMachines/LocalBox-Client"
GUESTS = {
    "LB-DC01": "f94c71f1-6854-48b9-a9f1-8238c99366d0",
    "LB-NODE01": "3adff629-2f67-449b-ab32-8a8748c46f34",
    "LB-NODE02": "12a44e0c-cc08-4c4c-a812-fa0b56efdbc3",
    "LB-NODE03": "5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9",
}
NODES = ["LB-NODE01", "LB-NODE02", "LB-NODE03"]
INVENTORY = {"inventory": "scripts/smal-compute-capacity-20261108-common.ps1",
             "inventory-nodes": "scripts/smal-compute-capacity-20261108-nodes.ps1",
             "inventory-dc": "scripts/smal-compute-capacity-20261108-dc.ps1",
             "inventory-topology": "scripts/smal-compute-capacity-20261108-topology.ps1"}
PRIVATE_STAGES = ["inspect", "shutdown", *[s for n in NODES for s in (f"stop-{n}", f"resize-{n}", f"resume-{n}")]]
VM_FIELDS = ("id", "vmId", "location", "identity", "networkProfile", "osProfile", "storageProfile",
             "securityProfile", "tags", "priority", "licenseType", "zones", "availabilitySet",
             "additionalCapabilities", "diagnosticsProfile", "plan", "host", "hostGroup")
DISK_FIELDS = ("id", "uniqueId", "diskSizeGB", "sku", "encryption", "hyperVGeneration",
               "networkAccessPolicy", "publicNetworkAccess", "diskAccessId", "maxShares",
               "burstingEnabled", "performancePlus", "managedBy", "diskIOPSReadWrite", "diskMBpsReadWrite")


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def now():
    return datetime.now(timezone.utc).isoformat()


def fresh(row, age=600):
    stamp = datetime.fromisoformat(row["atUtc"].replace("Z", "+00:00"))
    require(stamp.tzinfo is not None, "Evidence needs timezone")
    seconds = (datetime.now(timezone.utc) - stamp).total_seconds()
    require(0 <= seconds <= age, "Stale or future evidence")


def cloud_projection(vm, disks, nic):
    def stable(value):
        if isinstance(value, dict):
            return {k: stable(v) for k, v in value.items() if k not in ("etag", "provisioningState", "resourceGroup")}
        if isinstance(value, list):
            return [stable(v) for v in value]
        return value
    return stable({"vm": {k: vm.get(k) for k in VM_FIELDS}, "disks": sorted(
        [{k: d.get(k) for k in DISK_FIELDS} for d in disks], key=lambda d: d["id"].lower()),
        "nic": {k: nic.get(k) for k in ("id", "macAddress", "ipConfigurations", "networkSecurityGroup",
                                            "enableIPForwarding", "enableAcceleratedNetworking", "dnsSettings")}})


def verify_cloud(row, plan):
    require(row["projection"] == plan["baseline"]["cloud"], "Cloud identity/settings drift")
    require(row["size"] in (plan["beforeSize"], plan["targetSize"]), "Unexpected outer size")
    require(row["projection"]["vm"]["id"].lower() == HOST.lower(), "Wrong host")
    require(row["projection"]["vm"]["vmId"] == plan["hostVmId"], "Host VM identity drift")
    require(len(row["projection"]["disks"]) == 11, "Exactly eleven disks required")
    require(all(d["sku"]["name"] == "Standard_LRS" for d in row["projection"]["disks"]), "Tier drift")
    configs = row["projection"]["nic"]["ipConfigurations"]
    require(len(configs) == 1 and configs[0]["privateIPAddress"] == plan["privateIp"]
            and not configs[0].get("publicIPAddress"), "Private address/public-IP drift")


def validate_plan(plan, approved=False):
    pending = json.loads((OUT / "plan.pending.json").read_text())
    for key, value in pending.items():
        if key not in ("baseline", "admission", "executionApproval"):
            require(plan.get(key) == value, "Unapproved fixed plan field: " + key)
    require(isinstance(plan.get("baseline"), dict), "Live baseline not sealed")
    b = plan["baseline"]
    require(set(b) == {"cloud", "hostStatic", "guestsStatic", "clusterStatic", "volumesStatic"}, "Baseline schema")
    require({g["name"]: g["id"] for g in b["guestsStatic"]} == GUESTS, "Guest identity set")
    for g in b["guestsStatic"]:
        cpu, memory = (2, 4 * 1024**3) if g["name"] == "LB-DC01" else (8, 64 * 1024**3)
        require(g["cpu"] == cpu and g["memory"] == memory and not g["dynamicMemory"], "Original profiles differ")
        if g["name"] in NODES:
            require(g["generation"] == 2 and g["tpm"] is True and g["secureBoot"] == "On"
                    and g["processorSettings"]["nested"] is True, "Original nested Gen2/security profile unproved")
    cluster = b["clusterStatic"]
    require(cluster["name"] == "smal-localbox01" and cluster["poolId"] and cluster["poolSize"] > 0, "Exact deployed pool binding missing")
    require(len(cluster["members"]) == 24 and len({m["id"] for m in cluster["members"]}) == 24
            and all(m["size"] == 170 * 1024**3 for m in cluster["members"]), "Exact 24-device expanded pool required")
    require(len(cluster["virtualDisks"]) == 5 and len({d["id"] for d in cluster["virtualDisks"]}) == 5
            and all(d["copies"] == 3 for d in cluster["virtualDisks"]), "Existing mirror bindings unproved")
    require(len(cluster["csv"]) == 4 and len({c["id"] for c in cluster["csv"]}) == 4, "Exact four CSV identities required")
    require(len(cluster["nestedVms"]) == 1 and cluster["nestedVms"][0]["id"] == plan["infrastructureVmId"],
            "Only exact existing infrastructure VM is admitted")
    verify_cloud({"projection": b["cloud"], "size": plan["beforeSize"]}, plan)
    admission = plan.get("admission")
    require(isinstance(admission, dict), "Measured admission not sealed")
    require(set(admission) == {"repairReserveBytes", "requiredPhysicalFreeBytes", "volumeBudgets", "platformCpuReservePerNode",
                               "platformMemoryReservePerNodeBytes", "placement", "infrastructureVmNode", "maintenanceConflictChecked"}, "Admission schema")
    require(admission["maintenanceConflictChecked"] is True, "Nightly/active operation conflict not reconciled")
    require(admission["repairReserveBytes"] > 0 and admission["requiredPhysicalFreeBytes"] >= 360 * 1024**3,
            "Physical reserve must include cache/headroom and AKS disks")
    require(set(admission["platformCpuReservePerNode"]) == set(NODES), "Per-node CPU reserve required")
    require(set(admission["platformMemoryReservePerNodeBytes"]) == set(NODES), "Per-node RAM reserve required")
    bridge_node = admission["infrastructureVmNode"]
    require(bridge_node in NODES, "Infrastructure owner admission required")
    bridge = cluster["nestedVms"][0]
    require(admission["platformCpuReservePerNode"][bridge_node] >= 4 + bridge["cpu"]
            and admission["platformMemoryReservePerNodeBytes"][bridge_node] >= 16 * 1024**3 + bridge["memory"],
            "Platform reserve must account for existing infrastructure VM as well as HCI host")
    expected_vms = {"controlplane": (4, 8), "system": (8, 32), "workload": (4, 16), "inference": (8, 32), "replacement": (8, 32)}
    require(set(admission["placement"]) == set(expected_vms), "Exact initial plus replacement placement")
    for node in NODES:
        assigned = [v for v, n in admission["placement"].items() if n == node]
        reserve = admission["platformCpuReservePerNode"][node]
        ram = admission["platformMemoryReservePerNodeBytes"][node]
        require(reserve >= 4 and ram > 0, "Meaningful measured platform reserve required")
        require(sum(expected_vms[v][0] for v in assigned) + reserve <= 16, "Per-node maintenance CPU does not fit")
        require(sum(expected_vms[v][1] * 1024**3 for v in assigned) + ram <= 128 * 1024**3, "Per-node maintenance RAM does not fit")
    require(all(n in NODES for n in admission["placement"].values()), "Unknown placement node")
    require(set(admission["volumeBudgets"]) == {"C", "V", "W", "X"}, "All outer volume budgets required")
    for letter, budget in admission["volumeBudgets"].items():
        require(set(budget) == {"maximumVhdBytes", "runtimeBytes", "metadataBytes", "freeFloorBytes"}, "Volume budget schema")
        require(all(isinstance(v, int) and v >= 0 for v in budget.values()) and budget["freeFloorBytes"] >= 200 * 1024**3,
                "Volume reserve missing")
    runtime = {letter: 0 for letter in "CVWX"}; vhd_bytes = dict(runtime)
    vhd_ids = set()
    for g in b["guestsStatic"]:
        target_ram = plan["dcMemoryBytes"] if g["name"] == "LB-DC01" else plan["targetNodeMemoryBytes"]
        for letter in {g["configurationLocation"][0], g["smartPagingLocation"][0]}:
            require(letter in runtime, "Runtime-state path on unadmitted volume")
            runtime[letter] += target_ram
        require(len(g["disks"]) == (1 if g["name"] == "LB-DC01" else 9), "Current exact VHD attachment counts unproved")
        for disk in g["disks"]:
            require(disk["id"] not in vhd_ids, "Duplicate guest VHD identity")
            vhd_ids.add(disk["id"])
            letter = disk["path"][0]
            require(letter in vhd_bytes, "VHD on unadmitted volume")
            vhd_bytes[letter] += disk["size"]
    for letter, budget in admission["volumeBudgets"].items():
        require(budget["runtimeBytes"] >= runtime[letter] and budget["maximumVhdBytes"] >= vhd_bytes[letter],
                "Budget below actual attached VHD/target runtime footprint")
    if approved:
        approval = plan.get("executionApproval")
        unsigned = copy.deepcopy(plan); unsigned["executionApproval"] = None
        require(isinstance(approval, dict) and set(approval) == {"parentGo", "unsignedPlanSha256", "approvedEffects"}, "Exact execution approval missing")
        require(approval["parentGo"] is True and approval["unsignedPlanSha256"] == digest(unsigned), "Exact plan approval digest differs")
        require(approval["approvedEffects"] == ["graceful-shutdown", "outer-size-only", "serial-three-guest-profiles", "canonical-startup"], "Effect set differs")


def verify_snapshot(row, plan, profiles, off=(), healthy=True, expanded=False):
    fresh(row, plan["maximumEvidenceAgeSeconds"])
    require(row.get("mutationPerformed") is False, "Read-only evidence required")
    b = plan["baseline"]
    require(row["hostStatic"] == b["hostStatic"], "Outer static storage/settings drift")
    require(row["volumesStatic"] == b["volumesStatic"], "Outer volume identity/size drift")
    static = copy.deepcopy(row["guestsStatic"])
    require({g["name"]: g["id"] for g in static} == GUESTS, "Guest set drift")
    for g in static:
        require((g["cpu"], g["memory"]) == profiles[g["name"]], "Unexpected guest profile")
        old = next(x for x in b["guestsStatic"] if x["name"] == g["name"])
        g["cpu"], g["memory"] = old["cpu"], old["memory"]
    require(static == b["guestsStatic"], "Guest non-profile settings/VHD/vTPM drift")
    require(set(row["states"]) == set(GUESTS), "State set drift")
    for name, state in row["states"].items():
        require(state == ("Off" if name in off else "Running"), "Guest not in required power state")
    volumes = {v["letter"]: v for v in row["volumes"]}
    for letter, budget in plan["admission"]["volumeBudgets"].items():
        v = volumes[letter]
        require(v["health"] == "Healthy" and v["free"] >= budget["freeFloorBytes"], "Outer free-space/health floor")
        require(sum(budget.values()) <= v["size"], "Maximum VHD/runtime-state volume reserve unproved")
    if expanded:
        c = row["hostCapacity"]
        require(c["logicalProcessors"] == 64 and c["physicalCores"] == 32, "Actual SMT topology differs")
        require(c["memoryBytes"] >= 500 * 1024**3 and c["freeMemoryBytes"] >= plan["minimumOuterFreeMemoryBytes"], "Actual outer RAM not admitted")
        require(c["numa"] and sum(n["logicalProcessors"] for n in c["numa"]) == 64, "Actual NUMA topology not proved")
    if healthy:
        require(row["clusterStatic"] == b["clusterStatic"], "Pool/CSV/VD/member identities drift")
        health = row["clusterHealth"]
        require(health["allNodesUp"] and health["allCsvOnline"] and health["allMirrorsHealthy"] and health["poolHealthy"], "Unhealthy cluster")
        require(health["quorumType"] == "Majority" and health["witness"] is None, "Quorum/witness changed")
        require(not health["activeStorageJobs"], "Active storage jobs block maintenance")
        require(health["physicalFreeBytes"] >= plan["admission"]["requiredPhysicalFreeBytes"] + plan["admission"]["repairReserveBytes"], "S2D physical admission failed")
        require(row["nodeCapacity"] and len(row["nodeCapacity"]) == 3, "Actual capacity of all three HCI nodes required")
        if expanded:
            for node, capacity in row["nodeCapacity"].items():
                require(node in NODES and capacity["logicalProcessors"] == 16 and capacity["memoryBytes"] >= 120 * 1024**3,
                        "Actual guest CPU/RAM differs from profile")
                require(capacity["freeMemoryBytes"] >= plan["admission"]["platformMemoryReservePerNodeBytes"][node],
                        "Actual guest available RAM below admitted reserve")
                require(capacity["numa"] and sum(n["logicalProcessors"] for n in capacity["numa"]) == 16,
                        "Actual guest NUMA topology not proved")


def original_profiles():
    return {n: (2, 4 * 1024**3) if n == "LB-DC01" else (8, 64 * 1024**3) for n in GUESTS}


def build_candidate(host_receipt, nodes_receipt):
    """Assemble an unsigned plan from complete source-bound reads. Never approve/write."""
    require(host_receipt.get("status") == nodes_receipt.get("status") == "complete", "Incomplete inventory receipts")
    require(host_receipt.get("stage") == "inventory" and nodes_receipt.get("stage") == "inventory-nodes", "Wrong inventory roles")
    host = host_receipt["private"]["result"]["snapshot"]
    data = nodes_receipt["private"]["result"]
    require(data.get("status") == "complete" and data.get("mutationPerformed") is False, "Not read-only node observation")
    fresh(host); fresh(data)
    nodes = data["nodes"]; require(set(nodes) == set(NODES), "Exact all-node inventory required")
    c = nodes["LB-NODE01"]["cluster"]
    def text(v):
        return v.get("Value") if isinstance(v, dict) else v
    require(c["health"] == "Healthy" and not c["jobs"] and c["quorumType"] == "Majority" and c["witness"] is None,
            "Cluster health/jobs/quorum block candidate")
    require({n["Name"]: text(n["State"]) for n in c["nodes"]} == {n: "Up" for n in NODES}, "Not all nodes Up")
    require(all(v["health"] == "Healthy" for v in c["virtualDisks"]) and all(v["state"] == "Online" for v in c["csv"]), "Unhealthy mirrors/CSVs")
    nested = sorted([v for node in nodes.values() for v in node["nestedVms"]], key=lambda v: v["id"])
    require(len(nested) == 1 and nested[0]["id"] == "4c6ca5cc-8c9a-499b-8ffe-c029bbfd3522", "Exact existing infrastructure VM required")
    bridge_owner = next(n for n, v in nodes.items() if v["nestedVms"])
    vm_resources = c["vmResources"]
    require(len(vm_resources) == 1 and vm_resources[0]["ownerNode"] == bridge_owner
            and vm_resources[0]["state"] == "Online" and len(vm_resources[0]["vmIdentity"]) == 1
            and vm_resources[0]["vmIdentity"][0]["Value"].lower() == nested[0]["id"], "Cluster ownership/VM identity mapping unproved")
    plan = json.loads((OUT / "plan.pending.json").read_text())
    plan["baseline"] = {"cloud": host_receipt["cloudBefore"]["projection"], "hostStatic": host["hostStatic"],
        "guestsStatic": host["guestsStatic"], "volumesStatic": host["volumesStatic"],
        "clusterStatic": {"name": c["name"], "poolId": c["poolId"], "poolSize": c["poolSize"],
            "members": [{k: m[k] for k in ("id", "size")} for m in c["members"]],
            "virtualDisks": [{k: v[k] for k in ("id", "size", "copies", "resiliency")} for v in c["virtualDisks"]],
            "csv": [{"name": v["name"], "id": v["id"], "volumes": [{k: w[k] for k in ("path", "size")} for w in v["volumes"]]} for v in c["csv"]],
            "nestedVms": nested}}
    volumes = {l: {"maximumVhdBytes": 0, "runtimeBytes": 0, "metadataBytes": 16 * 1024**3, "freeFloorBytes": 200 * 1024**3} for l in "CVWX"}
    for g in host["guestsStatic"]:
        for disk in g["disks"]: volumes[disk["path"][0]]["maximumVhdBytes"] += disk["size"]
        for letter in {g["configurationLocation"][0], g["smartPagingLocation"][0]}:
            volumes[letter]["runtimeBytes"] += (4 if g["name"] == "LB-DC01" else 128) * 1024**3
    others = [n for n in NODES if n != bridge_owner]
    plan["admission"] = {"repairReserveBytes": 510 * 1024**3, "requiredPhysicalFreeBytes": 360 * 1024**3,
        "volumeBudgets": volumes, "platformCpuReservePerNode": {n: 4 + (nested[0]["cpu"] if n == bridge_owner else 0) for n in NODES},
        "platformMemoryReservePerNodeBytes": {n: 16 * 1024**3 + (nested[0]["memory"] if n == bridge_owner else 0) for n in NODES},
        "placement": {"controlplane": others[0], "system": others[0], "workload": others[1], "inference": others[1], "replacement": bridge_owner},
        "infrastructureVmNode": bridge_owner,
        "maintenanceConflictChecked": False}
    # Operation conflict and parent GO stay false/null. These are not inferred from healthy storage.
    return plan


def render(plan):
    validate_plan(plan, approved=True)
    return render_files(plan, PRIVATE_STAGES)


def render_files(plan, stages):
    common = (ROOT / "scripts/smal-compute-capacity-20261108-common.ps1").read_text()
    worker = (ROOT / "scripts/smal-compute-capacity-20261108-stage.ps1").read_text()
    public = base64.b64encode(json.dumps(plan, sort_keys=True, separators=(",", ":")).encode()).decode()
    return {"scripts/smal-compute-capacity-20261108-" + stage.lower() + ".ps1":
            "$ErrorActionPreference='Stop'\n$ComputeCapacityLibraryOnly=$true\n$plan=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + public
            + "')) | ConvertFrom-Json)\n$stage='" + stage + "'\n$planSha='" + digest(plan) + "'\n" + common + "\n" + worker
            for stage in stages}


def source_guard(plan, inventory=False):
    names = ["scripts/smal-compute-capacity-20261108.py", "scripts/smal-compute-capacity-20261108-common.ps1",
             "scripts/smal-compute-capacity-20261108-stage.ps1", "scripts/test_smal_compute_capacity_20261108.py",
             "docs/deployment-2026-11-08-capacity/plan.pending.json",
             "scripts/smal-private-powershell.py", "scripts/start-smal-localbox.py", "scripts/start-smal-existing-guests.ps1"]
    names.extend(INVENTORY.values())
    if inventory:
        require(plan == json.loads((OUT / "plan.pending.json").read_text()), "Inventory must use exact pending fixed plan")
        rendered = {}
    else:
        names.append("docs/deployment-2026-11-08-capacity/plan.sealed.json")
        rendered = render(plan)
    for name, text in rendered.items():
        require((ROOT / name).read_text() == text, "Generated stage/source differs")
    for name in [*names, *rendered]:
        require((ROOT / name).read_bytes() == subprocess.check_output(["git", "show", "HEAD:" + name], cwd=ROOT), "Source differs from HEAD")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    branch = subprocess.check_output(["git", "branch", "--show-current"], cwd=ROOT, text=True).strip()
    remote = subprocess.check_output(["git", "ls-remote", "--heads", "origin", "refs/heads/" + branch], cwd=ROOT, text=True).split()
    require(remote and remote[0] == head, "Exact source must be pushed")
    return head


def az(args, timeout=90):
    env = dict(os.environ, AZURE_EXTENSION_USE_DYNAMIC_INSTALL="no")
    p = subprocess.run(["az", *args, "--only-show-errors", "-o", "json"], env=env, text=True, capture_output=True, timeout=timeout)
    require(p.returncode == 0, "Azure request failed. Inspect receipt, no automatic retry")
    return json.loads(p.stdout) if p.stdout.strip() else None


def get_cloud():
    account = az(["account", "show", "--subscription", SUB])
    require(account["id"] == SUB and account["tenantId"] == TENANT and account["state"] == "Enabled", "Wrong subscription/tenant")
    vm = az(["rest", "--method", "get", "--url", "https://management.azure.com" + HOST + "?api-version=2025-04-01"])
    disk_ids = [vm["properties"]["storageProfile"]["osDisk"]["managedDisk"]["id"],
                *[d["managedDisk"]["id"] for d in vm["properties"]["storageProfile"]["dataDisks"]]]
    disks = [az(["disk", "show", "--ids", d, "--subscription", SUB]) for d in disk_ids]
    nic_ids = vm["properties"]["networkProfile"]["networkInterfaces"]
    require(len(nic_ids) == 1, "Exact single NIC required")
    nic = az(["network", "nic", "show", "--ids", nic_ids[0]["id"], "--subscription", SUB])
    flat = {**vm, **vm["properties"]}; flat.pop("properties")
    iv = az(["vm", "get-instance-view", "--ids", HOST, "--subscription", SUB])
    powers = [s["code"] for s in iv.get("instanceView", {}).get("statuses", []) if s["code"].startswith("PowerState/")]
    require(len(powers) == 1, "Ambiguous/missing host power state")
    return {"atUtc": now(), "projection": cloud_projection(flat, disks, nic), "size": flat["hardwareProfile"]["vmSize"],
            "power": powers[0], "etag": vm["etag"]}


def private(stage, key):
    transport = runpy.run_path(str(ROOT / "scripts/smal-private-powershell.py"), run_name="compute_capacity_transport")
    name = "compute-" + key
    require(len(name) <= 64, "Receipt key too long")
    with contextlib.redirect_stdout(io.StringIO()):
        script = INVENTORY[stage] if stage in INVENTORY else "scripts/smal-compute-capacity-20261108-" + stage.lower() + ".ps1"
        code = transport["main"](script, name)
    path = transport["OUT"] / ("private-ssh-" + name + ".json")
    proof = json.loads(path.read_text())
    require(code == 0 and proof.get("status") == "complete", "Transport incomplete or uncertain, inspect exact receipt")
    result = proof["result"]
    require(result.get("status") == "complete", "Guest stage failed, inspect exact receipt")
    return {"path": str(path.relative_to(ROOT)), "result": result}


def claim(path, row):
    with path.open("x") as stream:
        json.dump(row, stream, indent=2); stream.write("\n")


def completed(stage, plan_sha):
    rows = []
    for path in OUT.glob("operation-*.json"):
        r = json.loads(path.read_text())
        if r.get("stage") == stage and r.get("planSha256") == plan_sha:
            resolution_path = OUT / ("resolution-" + path.name)
            if resolution_path.exists():
                resolution = json.loads(resolution_path.read_text())
                require(resolution.get("originalSha256") == digest(r) and resolution.get("status") == "complete"
                        and resolution.get("planSha256") == plan_sha and resolution.get("mutationPerformed") is False,
                        "Resolution/original receipt mismatch")
                r = {**r, "status": "complete"}
            rows.append(r)
    require(len(rows) == 1 and rows[0].get("status") == "complete", "Prerequisite incomplete/uncertain: " + stage)
    return rows[0]


def execute(stage, key, plan, expected_sha, evidence=None):
    if stage not in INVENTORY:
        validate_plan(plan, approved=True)
    require(expected_sha == digest(plan), "Parent reviewed plan differs")
    require(key and all(c in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in key) and len(key) <= 48, "Immutable key invalid")
    head = source_guard(plan, inventory=stage in INVENTORY)
    OUT.mkdir(exist_ok=True)
    path = OUT / ("operation-" + key + ".json")
    require(not path.exists(), "Existing/uncertain receipt. Inspect, do not replay")
    row = {"atUtc": now(), "stage": stage, "planSha256": digest(plan), "sourceCommit": head,
           "status": "preflight", "mutationRequested": False}
    claim(path, row)
    try:
        cloud = get_cloud(); row["cloudBefore"] = cloud
        if stage not in INVENTORY:
            verify_cloud(cloud, plan)
        else:
            require(cloud["projection"]["vm"]["id"].lower() == HOST.lower()
                    and cloud["projection"]["vm"]["vmId"] == plan["hostVmId"], "Inventory host identity differs")
        if stage in (*INVENTORY, "inspect", "verify"):
            require(cloud["power"] == "PowerState/running", "Inspection requires existing Running host")
            row["private"] = private(stage if stage in INVENTORY else "inspect", key)
            if stage == "verify":
                profiles = original_profiles()
                profiles.update({n: (16, 128 * 1024**3) for n in NODES})
                require(cloud["size"] == plan["targetSize"], "Final configured host size differs")
                verify_snapshot(row["private"]["result"]["snapshot"], plan, profiles, expanded=True)
            row["status"] = "complete"
        elif stage in PRIVATE_STAGES:
            require(cloud["power"] == "PowerState/running", "Guest action requires Running outer host")
            if stage != "shutdown":
                require(cloud["size"] == plan["targetSize"], "Guest maintenance requires enlarged outer model")
                if stage == "stop-LB-NODE01":
                    completed("host-size", digest(plan))
                elif stage.startswith("stop-"):
                    previous = NODES[NODES.index(stage[5:]) - 1]
                    completed("resume-" + previous, digest(plan))
                elif stage.startswith("resize-"):
                    completed("stop-" + stage[7:], digest(plan))
                elif stage.startswith("resume-"):
                    completed("resize-" + stage[7:], digest(plan))
            row["mutationRequested"] = True; row["status"] = "pending-effect"
            path.write_text(json.dumps(row, indent=2) + "\n")
            row["private"] = private(stage, key); row["status"] = "complete"
        elif stage in ("deallocate", "host-size"):
            if stage == "host-size":
                completed("deallocate", digest(plan))
            require(evidence is not None and evidence.get("status") == "complete" and evidence.get("stage") == "shutdown"
                    and evidence.get("sourceCommit") == head and evidence.get("planSha256") == digest(plan),
                    "Completed source/plan-bound shutdown receipt required")
            evidence = evidence["private"]["result"]["snapshot"]
            verify_snapshot(evidence, plan, original_profiles(), off=GUESTS, healthy=False)
            require(evidence.get("clusterStopped") is True, "Cluster graceful stop not proved")
            require(cloud["size"] == plan["beforeSize"], "Unexpected pre-resize outer profile")
            require(cloud["power"] == ("PowerState/running" if stage == "deallocate" else "PowerState/deallocated"), "Host state differs")
            row["mutationRequested"] = True; row["status"] = "pending-effect"
            path.write_text(json.dumps(row, indent=2) + "\n")
            if stage == "deallocate":
                az(["vm", "deallocate", "--ids", HOST, "--subscription", SUB, "--no-wait"])
            else:
                az(["rest", "--method", "patch", "--url", "https://management.azure.com" + HOST + "?api-version=2025-04-01",
                    "--headers", "If-Match=" + cloud["etag"], "--body", json.dumps({"properties": {"hardwareProfile": {"vmSize": plan["targetSize"]}}})])
            row["status"] = "awaiting-independent-readback"
        else:
            raise ValueError("Unknown stage. Startup belongs to canonical routine, not this executor")
    except Exception as error:
        row["status"] = "uncertain-inspect-before-continuation" if row["mutationRequested"] else "blocked"
        row["errorType"] = type(error).__name__
        raise
    finally:
        row["finishedAtUtc"] = now(); path.write_text(json.dumps(row, indent=2) + "\n")
    return row


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=["render", "cloud-read", *INVENTORY, "reconcile-cloud", *PRIVATE_STAGES, "verify", "deallocate", "host-size"])
    p.add_argument("--plan", type=Path, default=OUT / "plan.sealed.json")
    p.add_argument("--key"); p.add_argument("--expected-plan-sha256"); p.add_argument("--off-evidence", type=Path)
    p.add_argument("--receipt", type=Path, help="Exact original cloud effect receipt for read-only reconciliation")
    p.add_argument("--mutex-handover", action="store_true", help="Parent must explicitly confirm settled PLATFORM operation")
    args = p.parse_args()
    if args.action == "cloud-read":
        print(json.dumps(get_cloud(), indent=2)); return
    plan = json.loads((OUT / "plan.pending.json").read_text()) if args.action in INVENTORY else json.loads(args.plan.read_text())
    if args.action == "render":
        print(json.dumps(render(plan), indent=2)); return
    require(args.mutex_handover, "Parent PLATFORM mutex handover not acknowledged")
    # Shares the existing startup lock. Never hold it while canonical startup runs.
    with Path("/tmp/opencode/smal-localbox-start.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action == "reconcile-cloud":
            validate_plan(plan, approved=True); head = source_guard(plan)
            require(args.expected_plan_sha256 == digest(plan), "Reviewed plan differs")
            require(args.receipt and args.receipt.parent.resolve() == OUT.resolve(), "Exact owned receipt required")
            original = json.loads(args.receipt.read_text())
            require(original.get("stage") in ("deallocate", "host-size") and original.get("planSha256") == digest(plan)
                    and original.get("sourceCommit") == head and original.get("mutationRequested") is True, "Not a bound cloud effect receipt")
            observed = get_cloud(); verify_cloud(observed, plan)
            require(observed["power"] == "PowerState/deallocated", "Deallocation not independently observed")
            required_size = plan["targetSize"] if original["stage"] == "host-size" else plan["beforeSize"]
            require(observed["size"] == required_size, "Requested size not observed")
            resolution = {"atUtc": now(), "originalReceipt": args.receipt.name, "originalSha256": digest(original),
                          "stage": original["stage"], "planSha256": digest(plan), "status": "complete", "observed": observed,
                          "mutationPerformed": False, "actualRunningCapacityVerified": False}
            target = OUT / ("resolution-" + args.receipt.name)
            claim(target, resolution)
            print(json.dumps(resolution, indent=2)); return
        proof = json.loads(args.off_evidence.read_text()) if args.off_evidence else None
        print(json.dumps(execute(args.action, args.key, plan, args.expected_plan_sha256, proof), indent=2))


if __name__ == "__main__":
    main()
