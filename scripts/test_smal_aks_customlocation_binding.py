"""Synthetic guard tests. No Azure call, model, guest command or Git mutation."""
import copy
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

M = runpy.run_path(str(Path(__file__).with_name("smal-aks-customlocation-binding.py")), run_name="binding_test_module")
# Functions from runpy share the returned function globals, not necessarily M itself.
G = M["prepare"].__globals__
VM, AKS, CL, BRIDGE = (M[k] for k in ["VM_EXT", "AKS_EXT", "CL", "BRIDGE"])


def baseline():
    return {"customLocation": {"id": CL, "type": "Microsoft.ExtendedLocation/customLocations", "name": "cl-localbox-smal-weu-1",
                              "location": "westeurope", "tags": {"preserve": "yes"}, "futureField": {"keep": True},
                              "properties": {"namespace": "default", "hostResourceId": BRIDGE, "authentication": {},
                                             "displayName": "preserve-name", "provisioningState": "Succeeded",
                                             "unknownProperty": {"keep": [1, 2]}, "clusterExtensionIds": [VM]},
                              "systemData": {"createdAt": "2026-10-30", "lastModifiedAt": "2026-10-30"}},
            "extensions": {VM: {"id": VM, "scope": "unchanged"}, AKS: {"id": AKS, "scope": "unchanged"}},
            "enabled": {VM: {"propertiesSha256": "retained-complete-properties-hash", "types": [
                ["microsoft.azurestackhci", t, "2024-01-01"] for t in ["virtualmachineinstances", "storagecontainers", "logicalnetworks"]]}},
            "resourceBindings": [{"id": "existing-vm", "type": "Microsoft.AzureStackHCI/virtualMachineInstances",
                                  "extendedLocation": {"name": CL, "type": "CustomLocation"}}], "etag": None}


def after(plan, enabled=True):
    value = copy.deepcopy(plan["baseline"])
    value["customLocation"]["properties"]["clusterExtensionIds"].append(AKS)
    value["customLocation"]["systemData"]["lastModifiedAt"] = "2026-11-08"
    if enabled:
        value["enabled"][AKS] = {"propertiesSha256": "new", "types": [
            ["microsoft.hybridcontainerservice", t, "2024-01-01"]
            for t in ["skus", "kubernetesversions", "provisionedclusterinstances"]]}
    return value


class BindingTests(unittest.TestCase):
    def setUp(self):
        self.plan = M["prepare"](baseline())

    def test_minimal_explicit_union(self):
        M["validate_plan"](self.plan)
        self.assertEqual(self.plan["requestBody"], {"properties": {"clusterExtensionIds": [VM, AKS]}})
        self.assertIsNone(self.plan["executionApproval"])

    def test_no_atomic_cas_claim(self):
        self.assertFalse(self.plan["etagContractVerified"])
        self.assertIn("not-atomic", self.plan["concurrency"])

    def test_drop_vm_extension_refused(self):
        self.plan["requestBody"]["properties"]["clusterExtensionIds"] = [AKS]
        self.plan["requestSha256"] = M["sha"](self.plan["requestBody"])
        with self.assertRaises(ValueError): M["validate_plan"](self.plan)

    def test_duplicate_extension_refused(self):
        b = baseline(); b["customLocation"]["properties"]["clusterExtensionIds"] = [VM, VM]
        with self.assertRaises(ValueError): M["prepare"](b)

    def test_unchanged_request_refused(self):
        self.plan["requestBody"]["properties"]["clusterExtensionIds"] = [VM]
        self.plan["requestSha256"] = M["sha"](self.plan["requestBody"])
        with self.assertRaises(ValueError): M["validate_plan"](self.plan)

    def test_already_bound_preparation_refused(self):
        with self.assertRaises(ValueError): M["prepare"](after(self.plan))

    def test_wrong_cl_refused(self):
        b = baseline(); b["customLocation"]["id"] = CL + "-wrong"
        with self.assertRaises(ValueError): M["prepare"](b)

    def test_wrong_bridge_refused(self):
        b = baseline(); b["customLocation"]["properties"]["hostResourceId"] = BRIDGE + "-wrong"
        with self.assertRaises(ValueError): M["prepare"](b)

    def test_unsupported_namespace_refused(self):
        b = baseline(); b["customLocation"]["properties"]["namespace"] = "helm-operator2"
        with self.assertRaises(ValueError): M["prepare"](b)

    def test_auth_value_suppressed(self):
        b = baseline(); b["customLocation"]["properties"]["authentication"] = {"value": "synthetic-secret"}
        with self.assertRaises(ValueError): M["prepare"](b)

    def test_baseline_hash_mismatch_refused(self):
        self.plan["baseline"]["customLocation"]["tags"] = {}
        with self.assertRaises(ValueError): M["validate_plan"](self.plan)

    def test_request_hash_mismatch_refused(self):
        self.plan["requestSha256"] = "wrong"
        with self.assertRaises(ValueError): M["validate_plan"](self.plan)

    def test_extra_request_field_refused(self):
        self.plan["requestBody"]["tags"] = {}
        self.plan["requestSha256"] = M["sha"](self.plan["requestBody"])
        with self.assertRaises(ValueError): M["validate_plan"](self.plan)

    def test_unknown_plan_field_refused(self):
        self.plan["roles"] = ["Owner"]
        with self.assertRaises(ValueError): M["validate_plan"](self.plan)

    def test_success_checks_vm_and_aks_mappings(self):
        self.assertEqual(M["verify_readback"](self.plan, after(self.plan)), "binding-and-required-mappings-verified")

    def test_association_is_not_mapping_success(self):
        self.assertEqual(M["verify_readback"](self.plan, after(self.plan, False)), "binding-applied-aks-mappings-pending")

    def test_incomplete_aks_types_are_pending(self):
        value = after(self.plan); value["enabled"][AKS]["types"].pop()
        self.assertEqual(M["verify_readback"](self.plan, value), "binding-applied-aks-mappings-pending")

    def test_existing_vm_mappings_cannot_drop(self):
        value = after(self.plan); value["enabled"].pop(VM)
        with self.assertRaises(ValueError): M["verify_readback"](self.plan, value)

    def test_existing_vm_bindings_cannot_drop(self):
        value = after(self.plan); value["resourceBindings"] = []
        with self.assertRaises(ValueError): M["verify_readback"](self.plan, value)

    def test_unknown_property_loss_detected(self):
        value = after(self.plan); value["customLocation"]["properties"].pop("unknownProperty")
        with self.assertRaises(ValueError): M["verify_readback"](self.plan, value)

    def test_unknown_top_level_loss_detected(self):
        value = after(self.plan); value["customLocation"].pop("futureField")
        with self.assertRaises(ValueError): M["verify_readback"](self.plan, value)

    def test_tags_preserved(self):
        value = after(self.plan); value["customLocation"]["tags"] = {}
        with self.assertRaises(ValueError): M["verify_readback"](self.plan, value)

    def test_created_identity_metadata_preserved(self):
        value = after(self.plan); value["customLocation"]["systemData"]["createdAt"] = "changed"
        with self.assertRaises(ValueError): M["verify_readback"](self.plan, value)

    def test_extension_settings_preserved(self):
        value = after(self.plan); value["extensions"][AKS]["scope"] = "changed"
        with self.assertRaises(ValueError): M["verify_readback"](self.plan, value)

    def test_unsupported_extension_type_scope_account(self):
        value = {"id": AKS, "properties": {"extensionType": "microsoft.hybridaksoperator",
                 "scope": {"cluster": {"releaseNamespace": "hybridaks-operator-system"}}, "provisioningState": "Succeeded",
                 "configurationSettings": {"Microsoft.CustomLocation.ServiceAccount": "default", "HCIClusterID": M["HCI"]}}}
        M["verify_extension"](AKS, value)
        for key, bad in [("extensionType", "wrong"), ("scope", {"namespace": {"targetNamespace": "default"}})]:
            v = copy.deepcopy(value); v["properties"][key] = bad
            with self.subTest(key=key), self.assertRaises(ValueError): M["verify_extension"](AKS, v)
        value["properties"]["configurationSettings"]["Microsoft.CustomLocation.ServiceAccount"] = "cluster-admin"
        with self.assertRaises(ValueError): M["verify_extension"](AKS, value)

    def approval(self):
        return {"decision": "approve-exact-binding-effect", "planSha256": M["sha"](self.plan),
                "requestSha256": self.plan["requestSha256"],
                "phase": "parent-authorised-pre-resize", "capacityPhaseComplete": False,
                "exclusiveAzureWriter": True, "parentDisruptionHold": True,
                "noActiveOrUncertainHostGuestMutation": True,
                "approvalSource": "explicit-parent-direction-2026-11-08",
                "operatorObjectId": "fab70700-36e8-4cf5-ba5d-86ed49003fcf"}

    def test_parent_approval_and_capacity_boundary(self):
        M["approve"](self.plan, self.approval())
        for field in ["capacityPhaseComplete", "exclusiveAzureWriter", "parentDisruptionHold", "noActiveOrUncertainHostGuestMutation"]:
            a = self.approval(); a[field] = not a[field]
            with self.subTest(field=field), self.assertRaises(ValueError): M["approve"](self.plan, a)

    def test_pre_resize_phase_is_explicit(self):
        a = self.approval(); a["phase"] = "post-resize"
        with self.assertRaises(ValueError): M["approve"](self.plan, a)

    def test_pre_resize_request_digest_must_match(self):
        a = self.approval(); a["requestSha256"] = "wrong"
        with self.assertRaises(ValueError): M["approve"](self.plan, a)

    def test_wrong_approval_hash(self):
        a = self.approval(); a["planSha256"] = "wrong"
        with self.assertRaises(ValueError): M["approve"](self.plan, a)

    def test_immediate_baseline_drift_sends_no_patch(self):
        changed = baseline(); changed["customLocation"]["tags"] = {"other-owner-work": "keep"}
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as tmp:
            with patch.dict(G, {"OUT": Path(tmp), "source_guard": lambda *_: None, "permission": lambda: None,
                                "snapshot": lambda: changed}), patch.dict(G, {"az": unittest.mock.Mock()}) as _:
                with self.assertRaises(ValueError):
                    M["apply"](self.plan, self.approval(), "once", "a" * 40, Path(tmp) / "approval.json")
                G["az"].assert_not_called()

    def test_existing_uncertain_receipt_blocks_write(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as tmp:
            path = Path(tmp) / "aks-customlocation-binding-run-once.json"
            path.write_text(json.dumps({"status": "reconciliation-required-no-retry"}))
            with patch.dict(G, {"OUT": Path(tmp), "source_guard": lambda *_: None, "az": unittest.mock.Mock()}):
                with self.assertRaises(ValueError):
                    M["apply"](self.plan, self.approval(), "once", "a" * 40, Path(tmp) / "approval.json")
                G["az"].assert_not_called()

    def test_reconcile_never_retries_and_retains_failure(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as tmp:
            path = Path(tmp) / "aks-customlocation-binding-run-once.json"
            original = {"key": "once", "planSha256": M["sha"](self.plan), "status": "reconciliation-required-no-retry",
                        "writeResult": "failed-or-uncertain-preserve-do-not-repeat", "observations": []}
            path.write_text(json.dumps(original))
            with patch.dict(G, {"OUT": Path(tmp), "ROOT": Path(tmp), "snapshot": lambda: after(self.plan), "az": unittest.mock.Mock()}):
                M["reconcile"](self.plan, "once")
                G["az"].assert_not_called()
            retained = json.loads(path.read_text())
            self.assertEqual(retained["status"], original["status"])
            self.assertEqual(retained["writeResult"], original["writeResult"])
            self.assertEqual(len(retained["observations"]), 1)

    def test_write_is_one_minimal_patch(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as tmp:
            native = unittest.mock.Mock(return_value={})
            with patch.dict(G, {"OUT": Path(tmp), "ROOT": Path(tmp), "source_guard": lambda *_: None,
                                "permission": lambda: None, "snapshot": lambda: baseline(),
                                "get": lambda *_: baseline()["customLocation"], "az": native}):
                M["apply"](self.plan, self.approval(), "once", "a" * 40, Path(tmp) / "approval.json")
            native.assert_called_once()
            args = native.call_args.args[0]
            self.assertEqual(args[:3], ["rest", "--method", "patch"])
            self.assertEqual(json.loads(args[-1]), self.plan["requestBody"])

    def test_write_failure_retained_and_no_second_patch(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as tmp:
            native = unittest.mock.Mock(side_effect=RuntimeError("synthetic failure"))
            with patch.dict(G, {"OUT": Path(tmp), "ROOT": Path(tmp), "source_guard": lambda *_: None,
                                "permission": lambda: None, "snapshot": lambda: baseline(),
                                "get": lambda *_: baseline()["customLocation"], "az": native}):
                result = M["apply"](self.plan, self.approval(), "once", "a" * 40, Path(tmp) / "approval.json")
                self.assertEqual(result["status"], "reconciliation-required-no-retry")
                with self.assertRaises(ValueError):
                    M["apply"](self.plan, self.approval(), "once", "a" * 40, Path(tmp) / "approval.json")
            native.assert_called_once()

    def test_complete_mapping_properties_hash_retained(self):
        props = {"clusterExtensionId": VM, "extensionType": "microsoft.azstackhci.operator", "future": {"keep": True},
                 "typesMetadata": [{"resourceProviderNamespace": "Microsoft.AzureStackHCI", "resourceType": "virtualmachines/start",
                                    "apiVersion": "2021-07-01-preview"}]}
        projected = M["enabled_projection"]([{"properties": props}])[VM]
        self.assertEqual(projected["propertiesSha256"], M["sha"](props))
        self.assertEqual(projected["allTypesCount"], 1)
        self.assertEqual(projected["types"], [])

    def test_mapping_metadata_reordering_is_not_loss(self):
        props = {"clusterExtensionId": VM, "extensionType": "microsoft.azstackhci.operator",
                 "typesMetadata": [{"resourceProviderNamespace": "Microsoft.AzureStackHCI", "resourceType": t,
                                    "apiVersion": "2024-01-01", "future": {"keep": True}} for t in ["logicalnetworks", "storagecontainers"]]}
        reordered = copy.deepcopy(props); reordered["typesMetadata"].reverse()
        self.assertEqual(M["enabled_projection"]([{"properties": props}]), M["enabled_projection"]([{"properties": reordered}]))

    def test_source_checkpoint_change_refused(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as tmp:
            approval = Path(tmp) / "approval.json"
            with patch.dict(G, {"OUT": Path(tmp), "APPROVAL_PATH": approval}), patch("subprocess.check_output", return_value="b" * 40):
                with self.assertRaises(ValueError): M["source_guard"]("a" * 40, Path(tmp) / "approval.json")

    def test_final_cl_read_drift_refuses_without_write(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as tmp:
            native = unittest.mock.Mock()
            changed = baseline()["customLocation"]; changed["tags"] = {"concurrent": "change"}
            with patch.dict(G, {"OUT": Path(tmp), "ROOT": Path(tmp), "source_guard": lambda *_: None,
                                "permission": lambda: None, "snapshot": lambda: baseline(),
                                "get": lambda *_: changed, "az": native}):
                with self.assertRaises(ValueError):
                    M["apply"](self.plan, self.approval(), "once", "a" * 40, Path(tmp) / "approval.json")
            native.assert_not_called()


if __name__ == "__main__":
    unittest.main()
