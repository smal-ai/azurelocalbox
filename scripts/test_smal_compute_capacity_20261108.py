"""Offline compute-capacity guards. No Azure, guest, credential or model calls."""
import copy
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / "scripts/smal-compute-capacity-20261108.py"), run_name="capacity_test")
G = H["execute"].__globals__
GIB = 1024**3


def fixture():
    p = json.loads((H["OUT"] / "plan.pending.json").read_text())
    guests = []
    for name, identity in sorted(H["GUESTS"].items()):
        letter = "W" if name == "LB-NODE03" else "V"
        disks = [{"id": name + "-os", "path": letter + ":\\" + name + "-os.vhdx", "size": (80 if name == "LB-DC01" else 128) * GIB}]
        if name != "LB-DC01":
            disks += [{"id": name + str(i), "path": "X:\\" + name + str(i) + ".vhdx", "size": 170 * GIB} for i in range(8)]
        guests.append({"name": name, "id": identity, "cpu": 2 if name == "LB-DC01" else 8,
                       "memory": (4 if name == "LB-DC01" else 64) * GIB, "dynamicMemory": False,
                       "generation": 2, "tpm": True, "secureBoot": "On", "processorSettings": {"nested": True},
                       "configurationLocation": letter + ":\\config", "smartPagingLocation": letter + ":\\paging", "disks": disks})
    cloud = {"vm": {"id": H["HOST"], "vmId": p["hostVmId"]},
             "disks": [{"id": "disk" + str(i), "sku": {"name": "Standard_LRS"}} for i in range(11)],
             "nic": {"ipConfigurations": [{"privateIPAddress": "10.200.16.4"}]}}
    cluster = {"name": "smal-localbox01", "poolId": "original-pool", "poolSize": 4056 * GIB,
               "members": [{"id": str(i), "size": 170 * GIB} for i in range(24)],
               "virtualDisks": [{"id": str(i), "copies": 3} for i in range(5)], "csv": [{"id": str(i)} for i in range(4)],
               "nestedVms": [{"id": p["infrastructureVmId"], "cpu": 4, "memory": 8 * GIB}]}
    volumes = [{"letter": letter, "uniqueId": letter, "size": 8192 * GIB} for letter in "CVWX"]
    p["baseline"] = {"cloud": cloud, "hostStatic": {"outerPool": "original"}, "guestsStatic": guests,
                     "clusterStatic": cluster, "volumesStatic": volumes}
    p["admission"] = {"repairReserveBytes": 510 * GIB, "requiredPhysicalFreeBytes": 1800 * GIB,
                      "volumeBudgets": {letter: {"maximumVhdBytes": 5000 * GIB, "runtimeBytes": 388 * GIB,
                                               "metadataBytes": 16 * GIB, "freeFloorBytes": 200 * GIB} for letter in "CVWX"},
                      "platformCpuReservePerNode": {n: 8 if n == "LB-NODE03" else 4 for n in H["NODES"]},
                      "platformMemoryReservePerNodeBytes": {n: (24 if n == "LB-NODE03" else 16) * GIB for n in H["NODES"]},
                      "placement": {"controlplane": "LB-NODE01", "system": "LB-NODE01", "inference": "LB-NODE02",
                                    "workload": "LB-NODE02", "replacement": "LB-NODE03"}, "infrastructureVmNode": "LB-NODE03", "maintenanceConflictChecked": True}
    p["executionApproval"] = {"parentGo": True, "unsignedPlanSha256": H["digest"](p),
                              "approvedEffects": ["graceful-shutdown", "outer-size-only", "serial-three-guest-profiles", "canonical-startup"]}
    snapshot = {"atUtc": H["now"](), "mutationPerformed": False,
                **{k: copy.deepcopy(v) for k, v in p["baseline"].items() if k != "cloud"},
                "states": {n: "Running" for n in H["GUESTS"]},
                "volumes": [{**v, "free": 4000 * GIB, "health": "Healthy"} for v in volumes],
                "hostCapacity": {"logicalProcessors": 64, "physicalCores": 32, "memoryBytes": 512 * GIB,
                                 "freeMemoryBytes": 100 * GIB, "numa": [{"logicalProcessors": 64}]},
                "nodeCapacity": {n: {"logicalProcessors": 16, "memoryBytes": 128 * GIB, "freeMemoryBytes": 100 * GIB,
                                     "numa": [{"logicalProcessors": 16}]} for n in H["NODES"]},
                "clusterHealth": {"allNodesUp": True, "allCsvOnline": True, "allMirrorsHealthy": True, "poolHealthy": True,
                                  "quorumType": "Majority", "witness": None, "activeStorageJobs": [], "physicalFreeBytes": 2938 * GIB}}
    return p, snapshot


class CapacityTests(unittest.TestCase):
    def setUp(self):
        self.plan, self.snapshot = fixture()

    def test_valid_sealed_plan(self):
        H["validate_plan"](self.plan, approved=True)

    def test_pending_plan_cannot_execute(self):
        with self.assertRaises(ValueError):
            H["validate_plan"](json.loads((H["OUT"] / "plan.pending.json").read_text()), approved=True)

    def test_fixed_scope_changes_rejected(self):
        for key, value in [("targetSize", "Standard_E96s_v6"), ("targetNodeCpu", 20), ("storageTier", "Premium_LRS"),
                           ("subscriptionId", "wrong"), ("guestIds", {})]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                H["validate_plan"]({**self.plan, key: value})

    def test_approval_cannot_survive_plan_revision(self):
        self.plan["admission"]["requiredPhysicalFreeBytes"] += GIB
        with self.assertRaisesRegex(ValueError, "digest"):
            H["validate_plan"](self.plan, approved=True)

    def test_missing_nested_bridge_and_unknown_workload_rejected(self):
        for bridges in ([], [{"id": "unknown"}], self.plan["baseline"]["clusterStatic"]["nestedVms"] * 2):
            self.plan["baseline"]["clusterStatic"]["nestedVms"] = bridges
            with self.assertRaises(ValueError): H["validate_plan"](self.plan)

    def test_runtime_budget_below_target_memory_rejected(self):
        self.plan["admission"]["volumeBudgets"]["V"]["runtimeBytes"] = 132 * GIB
        with self.assertRaisesRegex(ValueError, "runtime"): H["validate_plan"](self.plan)

    def test_maximum_vhd_budget_not_actual_small_file_size(self):
        self.plan["admission"]["volumeBudgets"]["X"]["maximumVhdBytes"] = 100 * GIB
        with self.assertRaisesRegex(ValueError, "VHD"): H["validate_plan"](self.plan)

    def test_cpu_and_ram_placement_must_fit_each_node(self):
        self.plan["admission"]["placement"]["replacement"] = "LB-NODE01"
        with self.assertRaisesRegex(ValueError, "CPU"): H["validate_plan"](self.plan)

    def test_infrastructure_cpu_cannot_be_omitted_from_reserve(self):
        self.plan["admission"]["platformCpuReservePerNode"]["LB-NODE03"] = 4
        with self.assertRaisesRegex(ValueError, "infrastructure VM"): H["validate_plan"](self.plan)

    def test_numa_uses_observed_property_and_mib_conversion(self):
        for name in ("common", "nodes"):
            source = (ROOT / ("scripts/smal-compute-capacity-20261108-" + name + ".ps1")).read_text()
            self.assertIn("@($_.ProcessorsAvailability).Count", source)
            self.assertIn("[long]$_.MemoryTotal * 1MB", source)
            self.assertNotIn("logicalProcessors = $_.ProcessorCount", source)

    def test_healthy_snapshot_and_bridge_preserved(self):
        H["verify_snapshot"](self.snapshot, self.plan, H["original_profiles"](), expanded=True)

    def test_each_storage_gate_blocks(self):
        for field, value in [("allNodesUp", False), ("poolHealthy", False), ("allCsvOnline", False),
                             ("allMirrorsHealthy", False), ("activeStorageJobs", [{"state": "Running"}]),
                             ("physicalFreeBytes", 1), ("witness", "unexpected")]:
            s = copy.deepcopy(self.snapshot); s["clusterHealth"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                H["verify_snapshot"](s, self.plan, H["original_profiles"]())

    def test_off_is_not_saved_or_paused(self):
        for state in ("Running", "Saved", "Paused", "Stopping"):
            s = copy.deepcopy(self.snapshot); s["states"]["LB-NODE01"] = state
            with self.subTest(state=state), self.assertRaises(ValueError):
                H["verify_snapshot"](s, self.plan, H["original_profiles"](), off=("LB-NODE01",), healthy=False)

    def test_nonprofile_configuration_drift_rejected(self):
        self.snapshot["guestsStatic"][1]["processorSettings"]["nested"] = False
        with self.assertRaisesRegex(ValueError, "non-profile"):
            H["verify_snapshot"](self.snapshot, self.plan, H["original_profiles"]())

    def test_vhd_identity_drift_rejected(self):
        self.snapshot["guestsStatic"][1]["disks"][0]["id"] = "replacement"
        with self.assertRaises(ValueError): H["verify_snapshot"](self.snapshot, self.plan, H["original_profiles"]())

    def test_stale_snapshot_rejected(self):
        self.snapshot["atUtc"] = "2026-01-01T00:00:00Z"
        with self.assertRaisesRegex(ValueError, "Stale"): H["verify_snapshot"](self.snapshot, self.plan, H["original_profiles"]())

    def test_actual_smt_numa_not_catalogue_model(self):
        for field, value in [("logicalProcessors", 32), ("physicalCores", 64), ("numa", []), ("freeMemoryBytes", 1)]:
            s = copy.deepcopy(self.snapshot); s["hostCapacity"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                H["verify_snapshot"](s, self.plan, H["original_profiles"](), expanded=True)

    def test_disk_nic_ip_and_vm_identity_drift_rejected(self):
        for field in ("disk", "nic", "vm"):
            row = {"projection": copy.deepcopy(self.plan["baseline"]["cloud"]), "size": self.plan["beforeSize"]}
            if field == "disk": row["projection"]["disks"][0]["sku"]["name"] = "Premium_LRS"
            if field == "nic": row["projection"]["nic"]["ipConfigurations"][0]["privateIPAddress"] = "10.200.16.5"
            if field == "vm": row["projection"]["vm"]["vmId"] = "new-vm"
            with self.subTest(field=field), self.assertRaises(ValueError): H["verify_cloud"](row, self.plan)

    def test_receipt_replay_refused_before_cloud_or_transport(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as d:
            out = Path(d); (out / "operation-fixed.json").write_text("{}")
            azure = Mock(); transport = Mock()
            with patch.dict(G, OUT=out, source_guard=Mock(return_value="commit"), validate_plan=Mock(), get_cloud=azure, private=transport):
                with self.assertRaisesRegex(ValueError, "receipt"):
                    H["execute"]("shutdown", "fixed", self.plan, H["digest"](self.plan))
            azure.assert_not_called(); transport.assert_not_called()

    def test_uncertain_guest_effect_retains_pending_receipt_and_never_retries(self):
        row = {"projection": self.plan["baseline"]["cloud"], "size": self.plan["beforeSize"], "power": "PowerState/running"}
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as d:
            transport = Mock(side_effect=subprocess.TimeoutExpired("approved-transport", 90))
            with patch.dict(G, OUT=Path(d), source_guard=Mock(return_value="commit"), validate_plan=Mock(), get_cloud=Mock(return_value=row), private=transport):
                with self.assertRaises(subprocess.TimeoutExpired):
                    H["execute"]("shutdown", "fixed", self.plan, H["digest"](self.plan))
            receipt = json.loads((Path(d) / "operation-fixed.json").read_text())
            self.assertEqual(receipt["status"], "uncertain-inspect-before-continuation")
            self.assertTrue(receipt["mutationRequested"]); self.assertEqual(transport.call_count, 1)

    def test_generated_stage_digest_and_scope(self):
        files = H["render"](self.plan)
        self.assertEqual(len(files), 11)
        for text in files.values():
            self.assertIn(H["digest"](self.plan), text)
            self.assertIn("$ComputeCapacityLibraryOnly=$true", text)
            for forbidden in ("Start-VM ", "Remove-VM ", "Move-VMStorage", "Resize-VHD", "Format-Volume", "Clear-Disk", "-TurnOff"):
                self.assertNotIn(forbidden, text)

    def test_powershell_parse_and_recursive_preservation_comparator(self):
        common = ROOT / "scripts/smal-compute-capacity-20261108-common.ps1"
        stage = ROOT / "scripts/smal-compute-capacity-20261108-stage.ps1"
        command = "$ComputeCapacityLibraryOnly=$true;. '" + str(common) + "';"
        command += "Assert-ComputeEqual @{a=@(@{id='same';size=128})} ('{\"a\":[{\"id\":\"same\",\"size\":128}]}'|ConvertFrom-Json) 'equal';"
        command += "$rejected=$false;try{Assert-ComputeEqual @{id='new'} @{id='old'} 'drift'}catch{$rejected=$true};if(-not $rejected){exit 1};"
        files = [common, stage, ROOT / 'scripts/smal-compute-capacity-20261108-nodes.ps1', ROOT / 'scripts/smal-compute-capacity-20261108-dc.ps1', ROOT / 'scripts/smal-compute-capacity-20261108-topology.ps1']
        command += "foreach($f in @(" + ','.join("'" + str(f) + "'" for f in files) + ")){$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$t,[ref]$e);if($e.Count){exit 2}}"
        result = subprocess.run(["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
