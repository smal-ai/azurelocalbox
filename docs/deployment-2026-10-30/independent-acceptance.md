# Azure Local deployment and independent acceptance

## Outcome

**Deployment succeeded. Full platform readiness is not accepted.** Service success
and independent cluster/cloud health are verified, but boot encryption and
recovery/audit-export acceptance remain unresolved. The original Premium-tier drift
is retained below as history; the later human decision accepts Standard_LRS.

### Later approved capacity/tier decision

The human subsequently accepted **Standard_LRS** as the desired lab tier and
withdrew the WorkIQ request, taking the exemption investigation personally. Premium
is therefore no longer the active tier requirement. The original drift evidence
below remains historical and is not rewritten.

The separately approved supported additive expansion completed online and was
independently verified at **15:53 SAST**: Azure data backing **4 → 8 TiB**, S2D
members **12 → 24**, and pool capacity **2,027.99 → 4,055.98 GiB**. Original OS,
data-disk, pool and CSV identities/sizes were preserved. All eleven Azure disks
remain Standard_LRS. See [capacity expansion](capacity-expansion.md).
Boot encryption and audit-delivery/recovery acceptance remain unresolved, so full
platform readiness is still false. Automatic redistribution completion is not claimed.

## Independently verified at 14:53 SAST on 30 October 2026

- Cluster **smal-localbox01** has exactly NODE1–NODE3 **Up**, in **ad.localbox.test**.
- S2D is **Enabled**. All nodes report the same Healthy/OK pool containing exactly
  the twelve approved 170 GiB data-device identities. All three OS identities are excluded.
- Four CSVs are **Online**. Five Express virtual disks are **Healthy**, three-copy
  mirrors. No storage jobs are active. Active infrastructure cluster groups are Online.
  The reserved **Available Storage** group is Offline and is not treated as an active workload.
- Quorum is **Majority**, with no witness resource. The unused witness account remains private.
- The original eight-member outer pool is unchanged and Healthy. Outer C:, V: and W: are Healthy.
- All three Arc identities are Connected, with the expected separate managed identities.
- Resource bridge **smal-localbox01-arcbridge** is **Succeeded / Running**.
- Custom location **cl-localbox-smal-weu-1** is Succeeded and bound to that bridge.
- Vault RBAC, purge protection, 90-day soft deletion and public access Disabled are preserved.
- Both platform storage accounts have public access Disabled and Shared Key false.
- Vault **AuditEvent** export is configured to the dedicated diagnostic account.
- Defender/firewalls and cluster/Hyper-V/Arc services are active on all three nodes.
- The documented post-deployment **ASBuiltInAdmin** name successfully authenticated
  with the existing protected credential. Its RID 500 SID was verified on each node.
  No account/password/baseline was reset or changed by acceptance.

## Readiness blockers

### Boot encryption does not match the requested configuration

Each node's OS volume **C:** reports **FullyDecrypted, 0%, Protection Off**. The
approved settings requested boot-volume encryption and the service reported its
encryption steps Success. Those facts do not override the independent disk state.
No encryption/protector change is applied during diagnosis. Recovery material is
not printed or exported. The read-only diagnostic uses TPM/status metadata and
AD recovery-object metadata only, never recovery-password attributes.

At **15:02 SAST**, the AzureStackBitlockerAgent's own read-only BootVolume query
corroborated Protection Off on all three nodes. All three vTPMs are present, enabled,
activated and ready. Each OS volume has zero protectors. Four AD recovery objects
were observed by metadata only, consistent with encrypted data volumes but not
proof of OS-volume recovery protection. No encryption log files were returned from
the documented log directory. The cause of the omitted boot encryption remains
unresolved; it is not attributed to missing TPM hardware.

### Azure disk tiers were changed after the approved Premium conversion

All ten attached host managed disks now report **Standard_LRS**, including the
added 2 TiB disk. Its original unique ID is unchanged. Earlier Premium conversion
and creation receipts remain valid historical observations and are not rewritten.

Activity Log shows the same non-user application identity issuing successful writes
to all ten disks at approximately **00:57 SAST on 30 October**, after the approved
conversion. The writer's display name/owning automation is not yet resolved. This
is evidence of a later write, not proof of which unattended process or setting
caused it. No disk tier, VM power state, automation schedule or application grant
is modified in response. Restoring tiers without resolving the competing writer
would not prevent recurrence.

A subsequent read-only Resource Graph change-history query confirms
**Premium_LRS → Standard_LRS** transitions for all ten distinct disks. Application
records identify a **PowerShell** client matching the Activity Log application's
ID. The owning job/schedule remains unresolved. The query returned 14 records
(including duplicate/delayed records), with truncation false. This strengthens the
change evidence without claiming ownership of the external automation.

### Audit delivery and recovery ownership are not fully verified

The audit export is configured, but the operator's Azure AD-authenticated blob
metadata read failed. A redacted follow-up confirms missing data-plane permission.
The minimum read-only permission for this check is Blob Data Reader scoped to the
audit container. No new role grant or activation was attempted. The CLI suggests
key authentication as an alternative, but that is explicitly forbidden here and
was not used. Missing read access does not prove delivery failed.
Read-only recovery metadata checks do not constitute an off-host secured recovery
export or an accepted recovery test/owner handover.

## Capacity warning

Observed S2D pool capacity is **2027.99 GiB**, with **1138.50 GiB allocated** and
**889.49 GiB unallocated**. The three thin user volumes advertise **852 GiB** of
logical capacity in total. Their nominal size/CSV free space is not physical capacity.
With three copies, current unallocated physical space represents at most **296.50 GiB**
of additional logical allocation **before repair reserve, metadata and other overhead**.
Do not fill all advertised thin capacity or allocate workloads using CSV free space
alone. No workload, AKS system, model or additional storage purchase is included.

## Evidence and retained failures

- `../deployment-2026-10-29/three-node-cluster-deploy-observation-follow-up-20261030.json`.
- `../deployment-2026-10-27/private-ssh-final-cluster-storage-postdeploy-identity-20261030.json`.
- `../deployment-2026-10-29/three-node-cloud-acceptance-corrected-observer-20261030.json`.
- `../deployment-2026-10-29/three-node-independent-acceptance-assessment-20261030.json`.
- `../deployment-2026-10-29/three-node-disk-and-audit-export-observation-20261030.json`.
- Disk-write activity and selected application-identity metadata observations.
- `../deployment-2026-10-27/private-ssh-boot-encryption-recovery-metadata-20261030.json`.
- `../deployment-2026-10-29/three-node-audit-delivery-redacted-error-20261030.json`.
- `../deployment-2026-10-29/three-node-disk-tier-resource-changes-20261030.json`.

Original validation failures, rejected pre-submit attempts, observation timeouts,
initial cloud null projection and failed Windows observers remain retained. The
acceptance observer's unsupported S2D parameter and historical Administrator login
name were corrected without weakening deployed security or repairing resources.

References:

- [Azure Local built-in account names and lockout](https://learn.microsoft.com/en-us/azure/azure-local/concepts/security-features?view=azloc-2610#local-built-in-user-accounts).
- [Azure Local BitLocker management and recovery](https://learn.microsoft.com/en-us/azure/azure-local/manage/manage-bitlocker?view=azloc-2610).
