# Outer-host deployment attempt

Date: 2026-10-27. Relay: REL-287.
Outcome: **partially applied, VM creation rejected; no VM compute started**.

## Applied scope and source

The owner approved host costs, use of the current sign-in, omission of cost-centre
metadata for these personal lab subscriptions, and proceeding with deployment. The
separate private outer-host phase creates no bootstrap, role assignments, shared
network controls, registration, AKS or SMAL workloads. Platform egress/nested gates
remain unchanged. No cost-centre or review-date tag was invented.

Reviewed source was committed and pushed **before** Azure application:

- Branch: `deploy/smal-host-20261027`.
- Source commit: `74168e5f98da08466be870134617040ae378c64c`.
- Template: `infra/bicep/main.smal-host.bicep`.
- Azure deployment: `rg-localbox-nodes-san-1/smal-host-20261027`.
- Apply began `2026-10-27T10:46:52+02:00`, failed by `10:48:02+02:00`.

ARM validation and what-if both succeeded. Preview showed only the VM and NIC creates,
with nine implicit disks specified, no existing resource modifications/deletions and no
shared-network/role changes. **Validation did not catch the feature-registration gate.**
Do not present that validation as successful VM creation or platform readiness.

## Exact failure and reconciled Azure state

Azure returned `DeploymentFailed` / `BadRequest`:

> The value 'Standard' is not available for property 'securityType' until the feature
> Microsoft.Compute/UseStandardSecurityType is registered on subscription
> '8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea'. Please register the feature and retry.

The subscription feature was independently read back as **`NotRegistered`**.
Azure's error references the [Trusted Launch FAQ](https://aka.ms/TrustedLaunch-FAQ).
No feature/provider registration, security-profile substitution or automatic retry ran.
The apply receipt prevents blind repetition. No deletion/teardown followed the failure.

Read-only reconciliation of the original deployment and resource group found:

| Resource | Current result |
| --- | --- |
| `LocalBox-Client-NIC` | Created successfully, unattached, private `10.200.16.4` |
| NIC subnet | Exact supplied `vnet-smal-san-1/snet-localbox-host` |
| Public IP | None |
| `LocalBox-Client` | Not created, instance-view request returns ResourceNotFound |
| Managed disks in host RG | None |
| Shared controls / RBAC / platform bootstrap | Not changed or created by this template |

The NIC is retained for reconciliation/reuse, not deleted or recreated by assumption.
There is **no VM power state** because no VM exists, and no LocalBox VM compute was
started. Other pre-existing shared service charges remain unrelated.

## Credential handling

A fresh VM-local admin credential for `arcdemo` was generated. Desktop Secret Service
was unavailable, so it is retained only in:

`~/.local/state/azurelocalbox/credentials/smal-host-20261027.json`

The directory is owner-only and the file is owner-owned `0600`, outside the repository.
This is permission protection, not encrypted keyring storage. Do not copy its contents
into chat/Relay. It is not an old lab credential, Azure token or new Entra identity.
No VM account was actually created because the VM resource failed.

Secure parameters passed to Azure on stdin through `@/dev/stdin`, never in command
arguments or a repository parameter file. Output was redacted before retaining evidence.
The actual generated value was checked against every staged file entirely inside the
local process. No value was printed or committed. Retain the protected state for a
reviewed retry rather than silently generating a different credential.

## Next approval and retry boundary

Ask the owner to authorise registering **`Microsoft.Compute/UseStandardSecurityType`**
in the app subscription, then revalidate/preview and retry the VM creation using the
existing private NIC. That is a subscription-scope capability change outside the
previous host-RG apply. Do not register it or change to Trusted Launch implicitly.
If the approved feature workflow requires additional provider refresh, disclose and
handle that in the bounded approved registration scope, not as a blanket provider change.

After any approval, first confirm feature state, unchanged NIC/subnet/ownership, no
unexpected VM/disks and the exact reviewed source. The original helper stops on an
existing apply receipt/nonempty host RG; use an explicitly reviewed reconciled retry,
not deletion of the safety marker or re-running a failed command blindly.

Host boot and private Bastion/guest checks follow only after VM creation succeeds.
LocalBox bootstrap still requires safe pinned source and Entlz-approved egress and
nested addressing/routing. A private VM is not Azure Local or SMAL readiness.

## Evidence and checks

- `host-validation.json`, `host-what-if.json`, `host-prepare.json`.
- `host-apply-receipt.json`: redacted original apply result and source commit.
- `host-failure-reconciliation.json`: deployment operations, resource inventory,
  NIC/IP/subnet, missing VM, empty disk list and feature state.
- Added a direct feature-state preflight because ARM validation/what-if missed it.
- Source/runner regression tests cover redaction, rejecting shared-network preview
  changes, separate host/platform gates and the feature requirement. Existing October
  evidence and unrelated work remain untouched.
