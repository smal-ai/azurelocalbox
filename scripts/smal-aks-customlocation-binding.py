"""Prepare or reconcile one exact additive AKS custom-location association.

Only apply issues a PATCH, after separate exact parent approval and pushed-source
checks. No guest transport, credentials, catalogue PUT, role change or retry.
The ARM API has no verified ETag contract: exclusive writer ownership is required.
"""
import argparse
import copy
from datetime import datetime, timezone
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/deployment-2026-11-08"
SUB = "8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea"
TENANT = "c6e67968-af25-4557-ab8b-06b693048d3b"
SCOPE = f"/subscriptions/{SUB}/resourceGroups/rg-localbox-platform-weu-1"
CL = SCOPE + "/providers/Microsoft.ExtendedLocation/customLocations/cl-localbox-smal-weu-1"
BRIDGE = SCOPE + "/providers/Microsoft.ResourceConnector/appliances/smal-localbox01-arcbridge"
HCI = SCOPE + "/providers/Microsoft.AzureStackHCI/clusters/smal-localbox01"
EXT = BRIDGE + "/providers/Microsoft.KubernetesConfiguration/extensions/"
VM_EXT, AKS_EXT = EXT + "vmss-hci", EXT + "hybridaksextension"
API = "2021-08-15"
PLAN_PATH = OUT / "aks-customlocation-binding-plan.json"
APPROVAL_PATH = OUT / "aks-customlocation-binding-pre-resize-approval.json"
FILES = ["scripts/smal-aks-customlocation-binding.py",
         "scripts/test_smal_aks_customlocation_binding.py",
         "docs/deployment-2026-11-08/aks-customlocation-binding-plan.json",
         "docs/deployment-2026-11-08/aks-customlocation-binding-review.md"]
EXPECTED_EXT = {
    VM_EXT: ("microsoft.azstackhci.operator", "helm-operator2"),
    AKS_EXT: ("microsoft.hybridaksoperator", "hybridaks-operator-system"),
}
BOUND_TYPES = {"virtualmachines", "virtualmachineinstances", "networkinterfaces",
               "virtualharddisks", "storagecontainers", "logicalnetworks",
               "galleryimages", "marketplacegalleryimages", "virtualnetworks",
               "networksecuritygroups"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def now():
    return datetime.now(timezone.utc).isoformat()


def persist(path, record, create=False):
    if create:
        with path.open("x") as stream:
            stream.write(json.dumps(record, indent=2) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
    else:
        temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
        with temporary.open("x") as stream:
            stream.write(json.dumps(record, indent=2) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def az(args, timeout=90):
    p = subprocess.run(["az", *args, "--only-show-errors", "-o", "json"],
                       capture_output=True, text=True, timeout=timeout,
                       env=dict(os.environ, AZURE_EXTENSION_USE_DYNAMIC_INSTALL="no"))
    if p.returncode:
        # Never export raw CLI output or retry an external effect.
        raise RuntimeError("Azure request failed; inspect retained receipt, no automatic retry")
    return json.loads(p.stdout) if p.stdout.strip() else None


def get(rid, api):
    require(rid.lower().startswith(f"/subscriptions/{SUB}/".lower()), "Read outside APP scope")
    return az(["rest", "--method", "get", "--url", "https://management.azure.com" + rid + "?api-version=" + api])


def rows(rid, api):
    data = get(rid, api)
    result = []
    while True:
        require(isinstance(data.get("value"), list), "Unexpected listing shape")
        result.extend(data["value"])
        url = data.get("nextLink")
        if not url:
            return result
        require(url.startswith("https://management.azure.com/subscriptions/" + SUB + "/"), "Unsafe pagination scope")
        data = az(["rest", "--method", "get", "--url", url])


def verify_cl(resource, extensions):
    require(resource.get("id", "").lower() == CL.lower(), "Wrong custom location")
    require(resource.get("type", "").lower() == "microsoft.extendedlocation/customlocations", "Wrong resource type")
    require(resource.get("location") == "westeurope", "Wrong custom-location region")
    p = resource["properties"]
    require(p.get("hostResourceId", "").lower() == BRIDGE.lower(), "Wrong bridge binding")
    require(p.get("namespace") == "default", "Unsupported namespace")
    require(p.get("provisioningState") == "Succeeded", "Custom location not Succeeded")
    require(p.get("authentication") == {}, "Unexpected authentication; never read/export bootstrap credentials")
    require(p.get("clusterExtensionIds") == extensions, "Extension binding differs, duplicate or reordered")
    require(len(set(x.lower() for x in extensions)) == len(extensions), "Duplicate extension binding")


def verify_extension(rid, value):
    kind, namespace = EXPECTED_EXT[rid]
    require(value.get("id", "").lower() == rid.lower(), "Wrong extension identity")
    p = value["properties"]
    require(p.get("extensionType", "").lower() == kind, "Unsupported extension type")
    require(p.get("provisioningState") == "Succeeded", "Extension not Succeeded")
    require(p.get("scope") == {"cluster": {"releaseNamespace": namespace}}, "Unsupported extension scope")
    require(p.get("configurationSettings", {}).get("Microsoft.CustomLocation.ServiceAccount") == "default",
            "Unsupported custom-location service account")
    if rid == AKS_EXT:
        require(p["configurationSettings"].get("HCIClusterID", "").lower() == HCI.lower(), "Wrong HCI cluster")
    return {"id": value["id"], "extensionType": p["extensionType"], "scope": p["scope"],
            "provisioningState": p["provisioningState"], "currentVersion": p.get("currentVersion"),
            "version": p.get("version"), "releaseTrain": p.get("releaseTrain"),
            "serviceAccount": p["configurationSettings"]["Microsoft.CustomLocation.ServiceAccount"],
            "configurationSha256": sha(p["configurationSettings"])}


def enabled_projection(values):
    result = {}
    for r in values:
        p = r["properties"]
        extension = p["clusterExtensionId"]
        require(extension in EXPECTED_EXT, "Unexpected enabled extension/role")
        require(p["extensionType"].lower() == EXPECTED_EXT[extension][0], "Enabled extension type mismatch")
        require(extension not in result, "Duplicate enabled mapping")
        types = sorted([[t["resourceProviderNamespace"].lower(), t["resourceType"].lower(), t["apiVersion"]]
                        for t in p["typesMetadata"]])
        stable = copy.deepcopy(p)
        stable["typesMetadata"] = sorted(p["typesMetadata"], key=lambda t: json.dumps(t, sort_keys=True))
        result[extension] = {"propertiesSha256": sha(stable), "allTypesSha256": sha(types), "allTypesCount": len(types),
                             "types": [t for t in types if t[2] == "2024-01-01"]}
    return result


def preservation(resource):
    # Ignore only documented server-managed transition fields, retaining unknowns.
    result = copy.deepcopy(resource)
    result["properties"].pop("clusterExtensionIds", None)
    result["properties"].pop("provisioningState", None)
    result.pop("etag", None)
    for k in ("lastModifiedAt", "lastModifiedBy", "lastModifiedByType"):
        result.get("systemData", {}).pop(k, None)
    return result


def snapshot():
    account = az(["account", "show", "--subscription", SUB, "--query", "{id:id,tenantId:tenantId,state:state}"])
    require(account == {"id": SUB, "tenantId": TENANT, "state": "Enabled"}, "Wrong Azure account scope")
    cl = get(CL, API)
    # Auth value is prohibited. This lab baseline is explicitly empty.
    require(cl.get("properties", {}).get("authentication") == {}, "Unexpected auth; snapshot suppressed")
    bridge = get(BRIDGE, "2022-10-27")
    require(bridge.get("id", "").lower() == BRIDGE.lower(), "Wrong resource bridge")
    require(bridge["properties"]["provisioningState"] == "Succeeded" and bridge["properties"]["status"] == "Running",
            "Bridge not Running/Succeeded")
    extensions = {}
    for rid in EXPECTED_EXT:
        value = get(rid, "2023-05-01")
        extensions[rid] = verify_extension(rid, value)
    enabled = enabled_projection(rows(CL + "/enabledResourceTypes", API))
    bindings = []
    # Full pagination, then exact HCI-resource reads. Never fetch credentials/actions.
    for r in rows(f"/subscriptions/{SUB}/resources", "2021-04-01"):
        typ = r.get("type", "").lower()
        if not typ.startswith("microsoft.azurestackhci/") or typ.split("/")[1] not in BOUND_TYPES:
            continue
        if not r["id"].lower().startswith(SCOPE.lower() + "/") and r.get("extendedLocation", {}).get("name", "").lower() != CL.lower():
            continue  # Never inspect an unrelated HCI environment.
        value = get(r["id"], "2024-01-01")
        location = value.get("extendedLocation", {})
        if location.get("name", "").lower() == CL.lower():
            bindings.append({"id": value["id"], "type": value["type"], "extendedLocation": location})
    return {"customLocation": cl, "extensions": extensions, "enabled": enabled,
            "resourceBindings": sorted(bindings, key=lambda r: r["id"].lower()),
            "etag": cl.get("etag")}


def prepare(baseline):
    verify_cl(baseline["customLocation"], [VM_EXT])
    require(set(baseline["enabled"]) == {VM_EXT}, "Expected VM-only baseline mapping")
    vm_types = baseline["enabled"][VM_EXT]["types"]
    for typ in ("virtualmachineinstances", "storagecontainers", "logicalnetworks"):
        require(["microsoft.azurestackhci", typ, "2024-01-01"] in vm_types, "Required existing VM mapping absent")
    body = {"properties": {"clusterExtensionIds": [VM_EXT, AKS_EXT]}}
    return {"schemaVersion": 1, "preparedAtUtc": now(), "status": "technical-candidate-not-effect-approval",
            "customLocationId": CL, "bridgeId": BRIDGE, "apiVersion": API,
            "method": "PATCH", "requestBody": body, "requestSha256": sha(body),
            "baseline": baseline, "baselineSha256": sha(baseline),
            "writeAllowlist": [CL], "changedFields": ["properties.clusterExtensionIds"],
            "concurrency": "exclusive-parent-Azure-writer-plus-immediate-baseline-GET-not-atomic-CAS",
            "etagContractVerified": False, "executionApproval": None}


def validate_plan(plan):
    require(set(plan) == {"schemaVersion", "preparedAtUtc", "status", "customLocationId", "bridgeId", "apiVersion",
                          "method", "requestBody", "requestSha256", "baseline", "baselineSha256", "writeAllowlist",
                          "changedFields", "concurrency", "etagContractVerified", "executionApproval"}, "Unexpected plan fields")
    require(plan["schemaVersion"] == 1 and plan["status"] == "technical-candidate-not-effect-approval", "Wrong plan status")
    require(plan["customLocationId"] == CL and plan["bridgeId"] == BRIDGE, "Plan target drift")
    require(plan["method"] == "PATCH" and plan["apiVersion"] == API, "Unsupported method/API")
    require(plan["writeAllowlist"] == [CL] and plan["changedFields"] == ["properties.clusterExtensionIds"], "Scope broadening")
    require(plan["requestBody"] == {"properties": {"clusterExtensionIds": [VM_EXT, AKS_EXT]}}, "Drop existing extension or request drift")
    require(plan["requestSha256"] == sha(plan["requestBody"]), "Request hash mismatch")
    require(plan["baselineSha256"] == sha(plan["baseline"]), "Baseline hash mismatch")
    verify_cl(plan["baseline"]["customLocation"], [VM_EXT])
    require(set(plan["baseline"]["enabled"]) == {VM_EXT}, "Wrong baseline mapping")
    require(plan["executionApproval"] is None, "Plan is not a human approval")
    require(not plan["etagContractVerified"], "Unverified concurrency claim")
    require(plan["concurrency"] == "exclusive-parent-Azure-writer-plus-immediate-baseline-GET-not-atomic-CAS", "Concurrency contract changed")


def verify_readback(plan, current):
    validate_plan(plan)
    verify_cl(current["customLocation"], [VM_EXT, AKS_EXT])
    old = plan["baseline"]
    require(preservation(current["customLocation"]) == preservation(old["customLocation"]), "Preserved/unknown custom-location field drift")
    require(current["resourceBindings"] == old["resourceBindings"], "Existing HCI resource/VM bindings changed")
    require(current["extensions"] == old["extensions"], "Extension settings/version changed outside request")
    require(current["enabled"].get(VM_EXT) == old["enabled"][VM_EXT], "Existing enabled VM mappings changed")
    aks = current["enabled"].get(AKS_EXT)
    if not aks:
        return "binding-applied-aks-mappings-pending"
    for typ in ("skus", "kubernetesversions", "provisionedclusterinstances"):
        if ["microsoft.hybridcontainerservice", typ, "2024-01-01"] not in aks["types"]:
            return "binding-applied-aks-mappings-pending"
    return "binding-and-required-mappings-verified"


def source_guard(expected, approval_path):
    require(re.fullmatch(r"[a-f0-9]{40}", expected) is not None, "Exact source commit required")
    require(approval_path == APPROVAL_PATH and not approval_path.is_symlink(), "Exact reviewed pre-resize approval file required")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    require(head == expected, "Source checkpoint changed")
    for name in [*FILES, str(approval_path.relative_to(ROOT))]:
        require((ROOT / name).read_bytes() == subprocess.check_output(["git", "show", "HEAD:" + name], cwd=ROOT), "Uncommitted source/plan/approval")
    branch = subprocess.check_output(["git", "branch", "--show-current"], cwd=ROOT, text=True).strip()
    remote = subprocess.check_output(["git", "ls-remote", "--heads", "origin", "refs/heads/" + branch], cwd=ROOT, text=True).split()
    require(remote and remote[0] == expected, "Exact source checkpoint not pushed")


def approve(plan, approval):
    require(approval == {"decision": "approve-exact-binding-effect", "planSha256": sha(plan),
                        "requestSha256": plan["requestSha256"],
                        "phase": "parent-authorised-pre-resize", "capacityPhaseComplete": False,
                        "exclusiveAzureWriter": True, "parentDisruptionHold": True,
                        "noActiveOrUncertainHostGuestMutation": True,
                        "approvalSource": "explicit-parent-direction-2026-11-08",
                        "operatorObjectId": "fab70700-36e8-4cf5-ba5d-86ed49003fcf"},
            "Exact parent pre-resize approval/exclusive ownership/disruption hold absent")


def permission():
    oid = az(["ad", "signed-in-user", "show", "--query", "id"])
    require(oid == "fab70700-36e8-4cf5-ba5d-86ed49003fcf", "Operator changed; no identity switch")
    action = "microsoft.extendedlocation/customlocations/write"
    perms = rows(CL + "/providers/Microsoft.Authorization/permissions", "2022-04-01")
    require(any(any(fnmatch.fnmatchcase(action, a.lower()) for a in p.get("actions", []))
                and not any(fnmatch.fnmatchcase(action, a.lower()) for a in p.get("notActions", [])) for p in perms),
            "Existing custom-location write permission unavailable; human PIM may be needed")


def apply(plan, approval, key, expected_source, approval_path):
    validate_plan(plan)
    approve(plan, approval)
    source_guard(expected_source, approval_path)
    require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", key) is not None, "Invalid immutable receipt key")
    path = OUT / ("aks-customlocation-binding-run-" + key + ".json")
    require(not path.exists(), "Existing or uncertain receipt: reconcile, never retry PATCH")
    permission()
    before = snapshot()
    require(before == plan["baseline"], "Immediate baseline differs; no unchanged/mismatched replay")
    require(get(CL, API) == plan["baseline"]["customLocation"], "Final pre-PATCH custom-location drift")
    record = {"schemaVersion": 1, "key": key, "planSha256": sha(plan), "sourceCommit": expected_source,
              "beganAtUtc": now(), "status": "pending-before-one-patch", "writeAttempted": True,
              "requestSha256": plan["requestSha256"], "observations": []}
    persist(path, record, create=True)
    try:
        az(["rest", "--method", "patch", "--url", "https://management.azure.com" + CL + "?api-version=" + API,
            "--body", json.dumps(plan["requestBody"], separators=(",", ":"))])
        record["writeResult"] = "response-returned"
        record["status"] = "submitted-readback-required"
    except (RuntimeError, subprocess.TimeoutExpired, OSError, ValueError):
        record["writeResult"] = "failed-or-uncertain-preserve-do-not-repeat"
        record["status"] = "reconciliation-required-no-retry"
    record["finishedAtUtc"] = now()
    persist(path, record)
    return {"receipt": str(path.relative_to(ROOT)), "status": record["status"]}


def reconcile(plan, key):
    validate_plan(plan)
    require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", key) is not None, "Invalid receipt key")
    path = OUT / ("aks-customlocation-binding-run-" + key + ".json")
    require(path.is_file() and not path.is_symlink(), "Original receipt required")
    record = json.loads(path.read_text())
    require(record["key"] == key and record["planSha256"] == sha(plan), "Original identity/plan mismatch")
    current = snapshot()
    state = "original-binding-present-no-write-retry-authorised"
    if current["customLocation"]["properties"]["clusterExtensionIds"] != [VM_EXT]:
        state = verify_readback(plan, current)
    else:
        require(current == plan["baseline"], "Unrelated baseline drift during reconciliation")
    record["observations"].append({"atUtc": now(), "snapshotSha256": sha(current), "state": state})
    # Retain writeStatus and original failure evidence. GET reconciliation never PATCHes.
    record["reconciliationState"] = state
    persist(path, record)
    return {"receipt": str(path.relative_to(ROOT)), "state": state}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["prepare", "preview", "apply", "reconcile"])
    parser.add_argument("--key")
    parser.add_argument("--approval-file", type=Path)
    parser.add_argument("--expected-source-commit")
    args = parser.parse_args()
    # Local lock serialises this executor only. Parent must hold wider Azure writer scope.
    with Path("/tmp/opencode/smal-aks-customlocation-binding.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.operation == "prepare":
            result = prepare(snapshot())  # stdout only. Use reviewed patch to freeze it.
        else:
            plan = json.loads(PLAN_PATH.read_text())
            validate_plan(plan)
            if args.operation == "preview":
                result = {"planSha256": sha(plan), "requestSha256": plan["requestSha256"],
                          "allowlist": plan["writeAllowlist"], "body": plan["requestBody"],
                          "azureMutationPerformed": False, "previewKind": "offline-exact-PATCH-not-ARM-what-if"}
            elif args.operation == "apply":
                require(args.approval_file is not None, "Separate approval file required")
                result = apply(plan, json.loads(args.approval_file.read_text()), args.key,
                               args.expected_source_commit, args.approval_file)
            else:
                result = reconcile(plan, args.key)
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
