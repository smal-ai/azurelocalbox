# Deployment blocker: product vault prerequisite versus inherited policy

## Superseded blanket blocker: actual private ARM flow passed

Subsequent controlled testing succeeded with `publicNetworkAccess=Disabled` at
every boundary: ARM created one non-credential secret child, and an authenticated
private read returned its exact marker through `10.200.17.11`. Only that owned
probe was soft-deleted, without purge. `private-vault-flow-probe.json` contains the
receipt. The required operator data role was the previously approved vault-only
Secrets Officer assignment, not a network opening or broad grant.

The policy rewrite below remains a confirmed fact. It is **not a blanket block on
the tested ARM secret-publication path**. Continue privately and verify actual
Azure Local RP/node-identity operations in the service validation step. Full
platform success is not inferred from this probe. See `arc-authentication-handoff.md`.

## Clarification after network completion

Entlz completed the three private endpoints at **14:06 SAST**, with successful
private DNS/TLS from the deployment host. Vault resolves to `10.200.17.11`, diagnostic
Blob `.9`, witness Blob `.10`. Source report/receipt hashes were independently
matched. See `platform-network-result.json`. This work is done, not still pending.

The public-access requirement below is **documented guidance, not a demonstrated
private-only service failure in this deployment**. The earlier categorical wording
was too strong. Confirmed facts are the policy rewrite and the private host path.
Unconfirmed is whether the selected ARM/RP secret-configuration flow can complete
while the vault remains private. Operator/node data-plane access, ARM resource
operations and the Azure-hosted RP's data-plane access must not be conflated.
Private DNS/TLS alone also does not prove RBAC/secret operations. Keep public access
Disabled while that exact caller/operation path is verified. Do not infer either
that public access is technically unavoidable or that RP access is already proven.

The sections below retain the **historical** stop and evidence. The superseding
private-path result above controls the next action, not the earlier blanket stop.

**Original decision:** Arc registration and cluster deployment were stopped. Do not retry the completed
prerequisite deployment or enable public access again.** Local preparation is
complete and the approved owned cloud prerequisite resources exist.

## Proven facts

- `localbox-platform-rg-20261028` succeeded, creating only the owned West Europe RG.
- `localbox-platform-prereqs-20261028` succeeded, creating the dedicated vault,
  diagnostic/witness accounts, audit setting, scoped 90-day blob lifecycle and
  diagnostic-account deletion lock. No secrets, roles, Arc machines or cluster
  were requested by that template.
- The inspected what-if requested the owner-approved new-vault
  `publicNetworkAccess=Enabled`, RBAC, purge protection and 90-day recovery.
- Independent vault readback is **Disabled**, with RBAC/purge protection/90-day
  recovery intact. Both storage accounts are private, anonymous Blob access off,
  TLS1.2. Audit/lifecycle/lock readbacks succeeded.
- Activity Log records **successful Azure Policy modify actions** during the
  deployment. Assignment: `MCAPSGovDeployPolicies` at the tenant-root management
  group. Definition: `KeyVault_PublicNetwork_Modify`, display name
  **SFI-NS2.2.1 Secure PaaS Resources – Key Vaults (excluding NSP configured
  resources)**. It replaces `Microsoft.KeyVault/vaults/publicNetworkAccess` with
  `Disabled`. Event times include `2026-10-28T11:55:53Z` and
  `2026-10-28T11:56:18Z`, deployment correlation
  `9ae4fe56-0173-4759-b352-f971b7030f16`. No exemption IDs were present.
- The current Microsoft Azure Local private-endpoint/no-proxy/no-gateway guide
  says to **keep public access enabled during deployment while portal/RP configure
  vault secrets**. Source blob `a90466bf3610a824fde8afbd2ef8362fb6ca12d7` is retained
  in `upstream-review/private-endpoint-guide-source.json`.

This is a product/governance compatibility conflict, not a missing owner consent
to the listed public-vault effect. That consent was already given, but did not
authorise policy bypass.

## Current safe state

The original prerequisite receipt says `failed-inspect-before-resume` because its
independent boundary check failed. It also retains `deploymentState=Succeeded` and
the actual resource IDs. **Do not interpret the wrapper status as missing services
and create them again.** Policy-state listing was initially empty while Activity
Log already proved modification, so an empty policy-state result is not clearance.

The independent reconciled readback is `platform-policy-conflict-reconciled.json`.
The earlier read-only observation's bad CLI list-envelope query is retained as a
failed observation. No effectful action was retried.

Private Link resource discovery advertises `vault` and both `blob` targets.
Entlz was given these readiness facts for the already approved private PE/DNS
subtask, explicitly with **no vault-public-setting change and no optional public
host FQDN admission**. Existing central vault/Blob zones and resolver links are
reused. This independent private connectivity work is not a resolution of the
RP/public-path requirement or permission to register the nodes.

## Resolution required before irreversible onboarding

The responsible governance/product owners must confirm a Microsoft-supported,
control-compliant deployment-vault configuration. If a perimeter-based or private-
only path is proposed, its actual Azure Local/RP compatibility, new resource/cost
effects and approved network controls must be reviewed before application.
The policy's allowance for `SecuredByPerimeter` is **not** by itself proof that such
a configuration works for this deployment. No perimeter resource was created.

No `SecurityControl=Ignore`, `CostControl=Ignore`, policy exemption, role activation,
older-API evasion, repeated re-enable, public switch on SMAL resources or broad
network rule is permitted by the current approval. Do not silently relax protection
to pass a validator. No automatic reinstall/rollback or resource teardown.

The paused next steps remain Arc device-code onboarding, exact machine-identity
roles, protected platform-secret upload, service Validate/Deploy and final platform
acceptance. Existing host and newly provisioned resources continue their normal
charges. The cancelled recurring agent cron remains off.
