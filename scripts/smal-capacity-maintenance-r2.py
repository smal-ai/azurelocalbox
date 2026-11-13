"""Scoped S2D maintenance admission. Warning alone is never an allowance.

Strict normal health gates and selected-node planned degradation are separate. Resuming
the selected node is an effect, not a resync-success claim. Nothing here mutates Windows.
"""
def require(condition, message):
    if not condition: raise ValueError(message)


DEVICE_MAINTENANCE = {"OK", "In Maintenance Mode", "InMaintenanceMode", "Starting Maintenance Mode", "StartingMaintenanceMode", "Lost Communication", "LostCommunication"}
VOLUME_MAINTENANCE = {"OK", "Degraded", "Incomplete", "InService", "In Service"}


def identities(observation, baseline, owners):
    require(observation["clusterStatic"] == baseline["clusterStatic"], "Cluster/pool/CSV/VD/member/global infrastructure identities differ")
    devices = observation["devices"]
    require(len(devices) == 24 and len({d["id"] for d in devices}) == 24, "Exactly 24 distinct devices required")
    require({d["id"] for d in devices} == set(owners), "Device set differs from sealed owner map")
    require(all(d["owner"] == owners[d["id"]] for d in devices), "Per-device ownership differs")
    require(all(sum(n == owner for owner in owners.values()) == 8 for n in ("LB-NODE01", "LB-NODE02", "LB-NODE03")), "Eight devices per exact node required")
    require(observation["quorumType"] == "Majority" and observation["witness"] is None, "Quorum/witness drift")
    require(len(observation["csv"]) == 4 and all(v["state"] == "Online" and v["accessible"] is True for v in observation["csv"]), "All exact CSVs must remain online and accessible")
    require(observation["physicalFreeBytes"] >= observation["requiredPhysicalFreeBytes"], "Physical reserve violated")
    require(observation["unrelatedFailures"] == [], "Unrelated storage/service/cluster failure")


def strict(observation, baseline, owners):
    identities(observation, baseline, owners)
    require(observation["nodeStates"] == {n: "Up" for n in ("LB-NODE01", "LB-NODE02", "LB-NODE03")}, "All nodes Up required")
    require(observation["poolHealth"] == "Healthy" and observation["poolOperational"] == ["OK"], "Pool must be Healthy/OK")
    require(all(d["health"] == "Healthy" and d["operational"] == ["OK"] and not d["maintenance"] for d in observation["devices"]), "All devices Healthy/OK and out of maintenance required")
    require(all(v["health"] == "Healthy" and v["operational"] == ["OK"] for v in observation["virtualDisks"]), "All mirrors Healthy/OK required")
    require(not observation["jobs"], "Resync/repair jobs must finish before next node")
    return "healthy-converged"


def planned(observation, baseline, owners, selected, drain_proof, compensating=False):
    identities(observation, baseline, owners)
    require(selected in set(owners.values()), "Exact selected node required")
    require(drain_proof.get("selectedNode") == selected and drain_proof.get("rpcReturned") is True
            and drain_proof.get("eightDevicesMaintenanceVerified") is True
            and set(drain_proof.get("deviceIds", [])) == {d for d, n in owners.items() if n == selected},
            "Original settled drain/eight-device maintenance proof required")
    survivors = {n: s for n, s in observation["nodeStates"].items() if n != selected}
    require(len(survivors) == 2 and all(s == "Up" for s in survivors.values()), "Exactly two healthy Up survivors required")
    require(observation["nodeStates"][selected] in ("Paused", "Down", "Up"), "Unexpected selected node transition")
    require(observation["poolHealth"] in ("Healthy", "Warning") and set(observation["poolOperational"]) <= {"OK", "Degraded", "Incomplete", "InService", "In Service"}, "Unrelated pool failure")
    for device in observation["devices"]:
        if device["owner"] != selected:
            require(device["health"] == "Healthy" and device["operational"] == ["OK"] and not device["maintenance"], "Surviving-node device degradation is not planned maintenance")
        else:
            require(device["health"] in ("Healthy", "Warning") and device["operational"] and set(device["operational"]) <= DEVICE_MAINTENANCE,
                    "Selected device has an unrelated or unknown failure")
            require(device["maintenance"] or set(device["operational"]) <= {"OK", "Lost Communication", "LostCommunication"}, "Unproved selected maintenance state")
    require(all(v["health"] in ("Healthy", "Warning") and v["operational"] and set(v["operational"]) <= VOLUME_MAINTENANCE for v in observation["virtualDisks"]), "Mirror fault outside exact planned-maintenance profile")
    if observation["jobs"]:
        require(compensating, "No active jobs admitted before taking/resizing a node offline")
        virtual_ids = {v["id"] for v in baseline["clusterStatic"]["virtualDisks"]}
        require(all(j["name"] == "Repair" and j["poolId"] == baseline["clusterStatic"]["poolId"]
                    and j["affectedVirtualDiskIds"] and set(j["affectedVirtualDiskIds"]) <= virtual_ids
                    and j["affectedDeviceIds"] and set(j["affectedDeviceIds"]) <= {d for d, n in owners.items() if n == selected}
                    for j in observation["jobs"]), "Unrelated/unassociated repair job is not a compensation allowance")
    return "selected-node-maintenance-admitted"


def convergence(observation, baseline, owners, selected, drain_proof):
    try:
        return strict(observation, baseline, owners)
    except ValueError:
        # This is only a GET observation. Pending never admits another mutation/node outage.
        planned(observation, baseline, owners, selected, drain_proof, compensating=True)
        return "pending-selected-node-resync"
