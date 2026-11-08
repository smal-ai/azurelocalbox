# Three-node cluster deployment execution

## Current outcome, 30 October 2026

**Service deployment succeeded. Independent cluster/S2D, bridge and custom-location
checks passed. Full readiness remains false.** Read-only acceptance identified
unencrypted OS volumes and incomplete audit-delivery/recovery acceptance.
The human subsequently accepted Standard_LRS after the documented overnight tier
change. A supported additive expansion now provides 24 S2D devices and 8 TiB Azure
data backing, with existing OS/pool/CSV identities and sizes preserved.
See [independent acceptance and blockers](../deployment-2026-10-30/independent-acceptance.md).
Historical failures, approvals and completed-stage receipts below remain unchanged.

## Verified onboarding and scope

All three local bootstraps are **Succeeded** and all three Arc machines are
**Connected**, region **westeurope**, build **10.0.26100.33650**. NODE3's inspected
managed-identity principal is **bd9a2019-2109-4aba-9f4e-90a1d300325d**.
`three-node-arc-verified.json` and the private post-registration inspection retain
the exact cloud/local identities, live MACs and twelve unchanged RAW data-device IDs.

NODE3's three approved role bindings were applied and independently read back:
two platform roles at `rg-localbox-platform-weu-1`, and Secrets User only at
`kv-lbox-weu-4766ea`. The original seven platform roles and deployer Secrets Officer
were preserved. See `node03-platform-roles-receipt.json` and its checked what-if.

## Corrected cluster name

The original `smal-localbox-01` is 16 characters, violating the pinned template's
15-character cluster-name maximum. This was caught before real credential upload
or cluster creation. The owner selected **Use smal-localbox01**. The correction
is retained separately in `cluster-name-correction-approval.json`; prior approved
proposals are not edited. Only the cluster/Windows name and its two dedicated
secret prefixes change. Region, networking, costs, topology and permissions do not.

Active templates use **smal-localbox01**, three nodes and **No Witness**. Their
derivation now validates default string lengths against the pinned constraints.
The old two-node drafts/failure receipts remain historical and are not executed.

## Stages and safeguards

`scripts/deploy-smal-three-node-cluster.py` runs separate fixed, create-only stages:

1. **secrets**: fresh private node/storage/AD inspection, exact two-secret create
   preview, approved shared node-admin and LCM credential delivery. Only public
   metadata is retained after upload. No witness secret or storage-key read.
2. **prerequisites**: three HCI edge-device resources and the owned cluster shell,
   using existing private vault/storage/network/roles. Inspect the new system-assigned
   cluster identity independently before granting it anything.
3. **cluster-role**: exactly one Secrets User grant to that actual inspected cluster
   principal, only at the dedicated vault. No guessed identity or broader scope.
4. **validate**: one deployment-settings resource, mode Validate. This is a
   resource-creating service action, not read-only template validation.
5. **deploy**: only after positive **reported service validation success** and the
   exact settings-template hash still matching the validated configuration.

ARM deployment acceptance/Succeeded alone is not treated as platform validation.
The reported `validationStatus`/`deploymentStatus` must positively succeed, with
no failed/in-progress reported steps or exceptions. Status records omit raw service
exception/description text because it can contain sensitive diagnostic material.
API status model reference:
[2025-09-15-preview hciCommon.json](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/azurestackhci/resource-manager/Microsoft.AzureStackHCI/StackHCI/preview/2025-09-15-preview/hciCommon.json).

The credential transport is the reviewed one-use **RSA4096-OAEP-SHA256** envelope
from protected host DPAPI storage to the operator process. Its private key uses an
anonymous RAM-backed descriptor. Actual values travel in memory/secure ARM stdin
parameters, never command arguments, plaintext files, chat, source or receipts.
No existing owner ARM token is forwarded. Managed runtimes cannot guarantee erasure
of every transient in-memory string copy. Synthetic crypto interoperability tests
do not alone prove actual service credential acceptance.

Every stage checks exact source/approval hashes, fresh Arc health, all ten approved
platform role bindings, private vault DNS/RBAC/public-access state and current blank
disk/AD prerequisites. Each has a distinct durable receipt/deployment identity.
Failures/timeouts are retained. No automatic replay, rollback, repeated Validate
after deployment failure, licence reset, disk reinitialisation or policy bypass.

No additional generic approval is required for these authorised effects. Unexpected
resource, permission, policy or cost requirements still stop for review. Public
access and Shared Key remain disabled. AKS/workloads/models and recurring jobs are
not included. Full platform readiness stays false until final independent acceptance.

## Before-submission private transport interruption

The first three-node secrets stage passed fresh node/storage/AD inspection and the
exact two-secret create preview, but lost real private connectivity before credential
sealing or ARM submission. Its original receipt remains uncertain, as first recorded.
No sealing transport receipt or secrets ARM deployment existed, and after reconnecting
the existing VPN profile the authenticated active-secret metadata list was empty.

The profile and tun0 route had both reported Active while resolver TCP53 and vault
TCP443 timed out. One reconnect of `entlz-san-cert` restored both probes and normal
private DNS, without profile/credential/Azure network or policy changes. Evidence:
`private-transport-pre-submit-reconciliation.json`.

The dedicated `--resume-unsubmitted-secrets` path requires this exact retained
before-sealing failure, unchanged template hash, no sealing receipt, no existing
deployment and no active/deleted target secret identities. It keeps the original
deployment name and writes a separate reconciliation receipt. This is not permission
to replay an uncertain submitted resource operation or regenerate existing secrets.

## Credentials and prerequisites completed

- The reconciled **two-secret** deployment succeeded at **13:53 SAST**. Both
  dedicated credentials are enabled, only their metadata is retained in receipts,
  and vault public access remained **Disabled**. The actual host credential
  transport used the reviewed RSA4096-OAEP-SHA256 envelope. No witness key was read
  or uploaded. Original pre-submit failure receipts remain unchanged.
- At **14:03 SAST**, ARM creation and independent GETs verified the owned
  **smal-localbox01** cluster shell and all **three HCI edge devices** Succeeded.
- Actual inspected cluster principal:
  **8c44672b-b729-4d3f-ad38-a0ac815ea265**. Its only newly requested role was
  **Key Vault Secrets User**, only at the dedicated vault. That grant and its
  ServicePrincipal type/scope were read back at **14:06 SAST**.
- These completed actions do **not** prove a deployed Windows/S2D cluster, bridge,
  custom location, service credential acceptance or final platform readiness.

The first service **Validate** failed before Environment Checker initialization:
the service requires an unqualified LCM username, while our encoder supplied a
domain-qualified one. No Deploy was submitted. See the
[exact diagnosis, one-secret correction and guarded initial-validation retry](initial-validation-lcm-format-recovery.md).
No Deploy is submitted unless current reported validation and all steps positively pass.
The gateway-echo correction subsequently produced positive service validation on
30 October. The original observer timeout is retained and a separate read-only
success reconciliation records **ValidationSuccess**, with only the inapplicable
alternative Local Identity validation skipped for this AD-backed system. See the
linked recovery record for the exact gate and post-validation domain membership.
Final read-only Windows/storage and cloud-observation scripts are prepared without
credential resets, service restarts, storage repairs or kubeconfig/secret export.

Receipts:

- `three-node-cluster-secrets-after-private-transport-reconciliation.json`.
- `three-node-cluster-prerequisites-receipt.json`.
- `three-node-cluster-cluster-role-receipt.json`.
