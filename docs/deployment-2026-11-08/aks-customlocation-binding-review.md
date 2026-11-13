# AKS custom-location association: exact additive candidate

Prepared 2026-11-08. **The original plan remains a technical candidate. The later
explicit parent approval and pre-resize sequence are recorded separately. No Azure
write was performed, and CAPACITY remains sole canonical Git/guest writer.**

## Evidence and supported mechanism

The existing Azure Local custom location `cl-localbox-smal-weu-1` is Succeeded,
bound to `smal-localbox01-arcbridge` in namespace `default`, with empty authentication,
and contains only `vmss-hci` in `clusterExtensionIds`. The bridge-installed
`hybridaksextension` is Succeeded, currentVersion 7.2.12, stable release train,
type `microsoft.hybridaksoperator`, cluster scope release namespace
`hybridaks-operator-system`, and `Microsoft.CustomLocation.ServiceAccount=default`.
The matching HCIClusterID is `smal-localbox01`'s exact resource ID. Existing VM extension
is `microsoft.azstackhci.operator` 5.22.1, cluster release namespace `helm-operator2`,
and the same service account `default`. Operator release namespace is not a request
to change the custom-location namespace.

The fresh baseline has one enabled-resource-type mapping, VM extension only, containing
240 API/type tuples. Its 2024-01-01 mappings include VM instances and start/stop/restart,
network interfaces, logical networks, storage containers, virtual disks and images.
Three existing storage containers and InfraLNET bind to this exact custom location.
No ARM HCI workload VM binding was found in the paginated inventory at capture.
This is not a claim that the platform's nested bridge VM is absent.

Official Microsoft sources retrieved on 2026-11-08:

1. [Manage custom locations](https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/custom-locations#update-a-custom-location)
   documents associating additional cluster extensions with an existing custom location.
   Its `update` preserves existing associations, while `patch` replaces the supplied
   extension array. Therefore a direct PATCH must contain the explicit existing-plus-new
   union, not only the new AKS ID. This general mechanism does not require another namespace.
2. [Custom Locations Update REST API](https://learn.microsoft.com/en-us/rest/api/extendedlocation/custom-locations/update?view=rest-extendedlocation-2021-08-15)
   documents PATCH and `properties.clusterExtensionIds`, with omitted properties not
   part of the request. Its example updates association references on an existing resource.
3. [Azure Local Windows node pool guidance for 2508 and earlier](https://learn.microsoft.com/en-us/azure/aks-hybrid-edge/local/hyperconverged/disable-windows-nodepool)
   explicitly describes the Azure Local deployment's custom location as containing both
   `hybridaksextension` and `vmss-hci`. This corroborates combined VM/AKS association,
   but its Windows-feature mutation procedure is version-limited and is not applied here.
4. [Current Windows node pool guidance, 2509 and later](https://learn.microsoft.com/en-us/azure/aks-hybrid-edge/local/hyperconverged/howto-enable-windows-node-pools)
   uses the existing deployment-configured custom location for AKS catalogue queries.
   No Windows-feature setting is changed by this repair.

No retrieved source requires a dedicated replacement AKS custom location for this
association. The minimal supported ARM mechanism is association of the already installed
AKS extension with the existing default-namespace custom location. This is an API-level
repair proposal, not proof that it completes managed-platform/AKS readiness. The existing
operator must independently populate enabled resource types. If it fails, stop and
investigate through the supported platform path rather than reinstalling extensions.

The older `deploy-aks-service-hci` Learn URLs found through search were unavailable
(Spider refusal, then direct English URL 404). Search snippets were not promoted to
current deployment evidence. No VMware-specific extension procedure was substituted.

## Frozen request

Exact target/method/API/body and complete baseline are in
`aks-customlocation-binding-plan.json`. The only changed field is
`properties.clusterExtensionIds`, from the existing singleton to ordered
`[vmss-hci full ID, hybridaksextension full ID]`.

- One allowed Azure write target: the exact existing custom-location resource ID.
- No new custom location, bridge, extension, registration, namespace, credential, role,
  catalogue, network, VM or workload operation.
- Body SHA256: `b98f3852ba486545980a12ddf90b65a46c9d7e07b768d1dbda0ee7173efc1cda`.
- Frozen baseline SHA256: `8bd3a9bc9991c848b8ac68099f98bdd4c11e7fdb6a9a2fd5d63a62819b6c732a`.
- Capture completed `2026-11-08T07:49:16.075562+00:00`, 09:49:16 SAST.

The plan retains the complete public custom-location GET, including absence of tags,
empty authentication, display name, namespace, bridge and systemData. Unknown fields
are not reconstructed from an allowlist. Post-write comparison ignores only the
documented lastModified metadata, provisioning state, association array and ETag.
Any other unknown field loss/change is a failure, not masked by projection.

Enabled-resource-type metadata is read fully and hashed in canonical order. Live
responses reordered the typesMetadata array between reads. Sorting that known list
avoids false order-only drift while retaining every tuple, duplicate, unknown metadata
field and complete mapping-property hash. The selected 2024-01-01 tuples are not a
substitute for the all-types count/hash and complete properties hash.

## Concurrency and validation limitation

The current GET has no body ETag and the verbose header check returned no ETag header.
The documented API does not establish an If-Match/atomic compare-and-swap contract.
**No atomic concurrency protection is claimed.** An invented If-Match header would
not fix that. Before effect, parent must accept this limitation and hold exclusive
Azure-write ownership for this resource through read-back.

The executor additionally uses a local mutex, exact frozen full-baseline comparison,
then one final custom-location GET immediately before the minimal PATCH. Unexpected
associations, changed metadata/settings, wrong scope or an existing receipt stop it.
This cannot eliminate a race with an external writer after the last GET. Minimal PATCH
avoids submitting tags/auth/namespace/host or other properties, and read-back detects
unrequested server-side loss. If exclusive ownership cannot be established, do not apply.

The preview is an offline exact PATCH diff, **not ARM policy what-if or service validation**.
No documented dry-run PATCH endpoint was identified. Replaying a full Azure Local
deployment or PUT template is not a valid minimal validation. The actual PATCH remains
subject to Azure RBAC, policy and platform validation during the separately approved effect.

## Delivery and effect gates

CAPACITY must deliver only these new binding-owned files alongside its own selected files:

- `scripts/smal-aks-customlocation-binding.py`
- `scripts/test_smal_aks_customlocation_binding.py`
- `docs/deployment-2026-11-08/aks-customlocation-binding-plan.json`
- `docs/deployment-2026-11-08/aks-customlocation-binding-review.md`
- `docs/deployment-2026-11-08/aks-customlocation-binding-pre-resize-approval.json`

PLATFORM has not staged, committed, pushed, opened a PR or changed canonical branch.
The script checks exact reviewed source/plan/approval bytes against HEAD, requires the
explicit parent-selected source commit to equal HEAD and the pushed branch HEAD, and
refuses effects until a separate approved public approval file is also in that checkpoint.
Do not commit a guessed approval. Parent must first review this candidate and its digest.

The parent subsequently explicitly reorders this binding repair **before capacity
resize**, while no capacity mutation has been issued and the host/guests remain
Running. This supersedes the initial post-resize sequence without altering the original
baseline, plan or request bytes. The parent approves original plan digest
`fe9aa027abc6b5574f4763cf5dce8ed15606cdd77f2b969f6a6098a4f3a23aef` and the exact request
digest above under the human's explicit all-Azure authority.

The separate pre-resize approval file states `capacityPhaseComplete=false`, phase
`parent-authorised-pre-resize`, `exclusiveAzureWriter=true`, `parentDisruptionHold=true`
and `noActiveOrUncertainHostGuestMutation=true`, with the exact operator and both
digests. This records actual delegated parent approval, not impersonated human
acceptance or a completed resize. Any changed phase, false exclusivity/hold, active or
uncertain host/guest mutation, or invented completed-capacity state fails the gate.

CAPACITY must deliver the revised five-file allowlist and return a verified retained,
pushed source checkpoint through the parent. Parent will then issue precise apply GO
after current preconditions pass. Preparing the approval/source does not authorise
dispatch before that final GO. Parent holds capacity guest/Azure disruption throughout
the binding and later separately authorised catalogue continuation.

Immediately before effect, the existing operator's effective custom-location write
permission and all scoped GET preconditions must pass. No auto-PIM activation. Parent
reports APP Owner access expiry 16:07:20 SAST today. No expiry extension is performed.

## Receipt/reconciliation and independent acceptance

One immutable key creates `aks-customlocation-binding-run-<key>.json` exclusively.
The pending intent is flushed/fsynced before a single PATCH. Updates use atomic local
replacement and directory fsync. Existing/pending/failed/uncertain receipts always block
another PATCH, even if the response was lost. Interrupted/failed responses require the
separate GET-only `reconcile` operation under the original key/plan. Reconciliation
appends an observation and retains original write outcome/status. It never retries.

The submitted write is not called success. Independent reconciliation requires:

1. Exact CL Succeeded with ordered union of both full extension IDs.
2. Unchanged CL ID/location/type/name/host/default namespace/auth/tags/creation metadata,
   including every unknown field except documented transition fields.
3. Both existing extension settings/version/scope/configuration hashes unchanged.
4. Exact existing VM enabled-resource mapping properties and all 240 API/type tuples retained.
5. Exact existing storage/network/VM resource custom-location bindings retained.
6. New AKS enabled-resource-type mapping bound to the exact hybridaks extension, including
   `Microsoft.HybridContainerService/skus`, `kubernetesVersions` and
   `provisionedClusterInstances` at API 2024-01-01.

Association present without those enabled types is `binding-applied-aks-mappings-pending`,
not repaired catalogue readiness. Failed provisioning or preservation drift is a blocker.
If the original association remains, reconciliation records that fact without authorising
another attempt. No automatic wait/poll occurs. AKS owner needs a separately scoped new
catalogue continuation after mapping verification, retaining its original MissingAzureKubernetesMapping refusals.
