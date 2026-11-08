# Three-node LocalBox change proposal

**Proposed, not approved or applied.** Exact effect list: `three-node-proposal.json`.
This changes the previous two-node topology. No part of the old approval is rewritten.

## Recommendation

- Keep the existing **Standard_E32s_v6**, 256 GiB / 32 vCPUs. It is already an E32.
- Resize NODE1 and NODE2 from 96 GiB / 12 vCPUs to **64 GiB / 8 vCPUs**, preserving
  their VM IDs, OS, data-disk IDs, vTPM/guardian and successful Arc registrations.
- Add **LB-NODE03**, also **64 GiB / 8 vCPUs**, on the same approved OS/solution.
- Leave the 4 GiB / 2-vCPU DC unchanged. Total guest allocations: **196 GiB and
  26 vCPUs**, leaving approximately 60 GiB outside guests. This is sizing arithmetic,
  not measured workload performance or a production HA claim.
- Use **No Witness** (empty service witness type) for three nodes, as permitted by
  the selected ARM reference for cluster sizes other than two. No Cloud Witness
  key, SAS, witness-secret upload or Shared Key enablement. Keep the existing unused
  witness account private and unchanged. No file-share workaround.

## Storage changes and why

The **pre-conversion** Azure sizing snapshot recorded all nine attached disks as
Standard HDD (`Standard_LRS`), not the Premium SSDs described in earlier notes.
Their identities, then-current SKUs and prices are retained in
`three-node-premium-cloud-sizing.json`. The actor or cause of that difference has
not been established. The separately requested nine-disk Premium conversion and
startup reconciliation are recorded in `premium-disk-conversion-reconciled-result.json`.

1. Convert exactly those nine disks to **Premium_LRS**, as explicitly requested,
   preserving disk IDs, encryption, contents and capacities. This includes the 1 TiB OS disk and eight
   256 GiB data disks. No Premium v2, Ultra or shared-disk conversion.
2. Add **one 2 TiB Premium SSD LRS** disk, named
   `LocalBox-Client-Node03-SSD-20261029`, at unused **LUN8**, caching None, retain on
   detach/delete. Verify its exact Azure/Windows identity before formatting **only
   that new blank disk** as GPT/NTFS, 64 KiB allocation units, drive **W:**.
3. Keep the existing eight-member Simple V: pool and its volume unchanged. No pool
   expansion, stripe-column change, reformat, existing-disk shrink or recreation.
4. Move only NODE1's currently blank **SCSI LUN4 / S2D-4.vhdx** from V: to
   `W:\AzureLocalBox\Relocated\LB-NODE01\S2D-4.vhdx`, using Hyper-V's guarded
   per-VHD move. Preserve VHD GUID `45B23F1E-D817-4DE0-A84A-C5F2124F7E30` and guest
   unique ID `600224801E3FB24517D8C5F2124F7E30`. Verify RAW/identity before moving,
   then verify the attachment, GUID and guest ID afterwards. No other VHD moves.
5. Put NODE3's VM/configuration and all five VHDXs on W:. Its OS is **128 GiB** and
   its four data VHDXs are **170 GiB each**. Existing data-disk sizes/counts remain.

Simply appending the third guest on V: would reserve **2,504 GiB** of virtual disks
against approximately **2,032 GiB** of volume capacity. Dynamic expansion is not
permission to overcommit the host filesystem.

| Volume | Maximum attached VHD capacity | Runtime-state allowance | Metadata/recovery allowance | Free-space floor |
|---|---:|---:|---:|---:|
| V: after the single move | 1,526 GiB | 132 GiB | 16 GiB | 200 GiB |
| New W: | 978 GiB | 64 GiB | 16 GiB | 200 GiB |

The W: calculation conservatively deducts 1 GiB for partition/filesystem overhead
before checking the budget. Its actual formatted capacity must pass the same check.
Runtime allowance reserves guest RAM even though current running VMRS files are
small. C: receives no guest files. Each volume must retain its own floor. This is
not a claim that the Simple outer pool gains hardware resiliency.

## Network, credentials and cloud delta

- NODE3 management **10.64.0.13/24**, gateway **10.64.0.1**, AD DNS **10.64.0.10**.
  Confirm address/name availability before assigning it. Same internal LB-Fabric
  switch and LB-NAT, no Azure VNet/route/firewall/PE/DNS-link changes.
- Same four vNICs and restricted trunk configuration. Storage A **10.64.4.13/24**
  VLAN711, storage B **10.64.5.13/24** VLAN712. No RDMA or storage gateway.
- Gen2, Secure Boot, vTPM, fixed RAM, nested virtualisation, no checkpoints,
  automatic start Nothing and stop ShutDown. Reuse verified ISO/image terms.
- A separate temporary bootstrap secret/answer file for NODE3, protected in its
  owned image. Remove setup copies and rotate to the existing dedicated
  `cluster-node-admin` secret before registration. No DC/outer credential reuse.
- Record the returned new VM ID and exact new disk GUIDs/guest unique IDs. Do not
  guess them. Preserve original NODE1/NODE2 registration markers and all failures.
- Register NODE3 in West Europe with fresh human device-code/MFA, pinned solution
  **12.2610.1004.41**. No exported owner ARM token or new Entra app/client secret.
- Only after inspecting its actual identity, add its two approved platform RG roles
  and vault-only Secrets User role. Preserve existing roles. Update startup and
  inspection tools to four guests after binding NODE3's actual ID.
- Re-derive the deployment for exactly three nodes. Publish only dedicated local
  admin/LCM credentials, not a witness key. Require exact new S2D device allowlists
  and checked resource effects before service **Validate**, then **Deploy**.

## Costs and interruption

Public USD **disk-capacity** meters for South Africa North, captured from the
official Retail Prices API. Not a contract quote, tax/FX assessment or spending cap.

| Monthly capacity comparison | USD |
|---|---:|
| Pre-conversion nine HDD disks | 176.33 |
| Same nine converted to Premium SSD | 535.14 |
| Additional 2 TiB Premium SSD | 315.60 |
| Proposed total disk capacity | 850.74 |
| **Increase versus current capacity meters** | **674.41** |

Conversion of the existing nine disks was explicitly requested separately. Once
that completes, the **additional** capacity charge for this three-node plan is
the new disk's **USD315.60/month**, not another charge for the conversions.

Other applicable meters are additional. No on-demand bursting or Performance Plus
enablement is requested. Premium SKU is not a measured performance guarantee. Compute
SKU is unchanged. The third Arc node can add Defender and platform charges. The
existing Azure Local core-fee illustration is not a new billing assessment. Keep
mandatory diagnostics/billing reports. Existing vault/PE/unused-witness costs remain.

Disk-type conversion requires an **outer-host shutdown/deallocation/restart**.
Gracefully stop guests first. Existing node resizes also require them to be off.
Check inherited policy and nightly automation without disabling either. Stop on
unexpected configuration, permission or policy effects.

There is **no new external backup/snapshot purchase** in this proposal. Current
DPAPI secrets/guardian material remain host-bound. A failed operation is preserved
for reconciliation, not followed by automatic reset/reinstall/rollback. This remains
an unsupported educational virtual deployment, not production HA.

## Approval boundary

The existing nine-disk Premium conversion is covered by its separate explicit
instruction and conversion receipt, not re-requested here. Approve this exact
topology, **one new 2 TiB Premium SSD**, the
new-disk-only format, the **single identified blank VHD move**, guest/host downtime,
NODE3 temporary secret/bootstrap/authentication boundary and listed cost delta.
Implementation still requires review, tests and commit/push before application.
No unlisted storage move/deletion, policy exemption, Shared Key, public access,
subscription-wide grant, AKS/workload/model or recurring agent job is included.

Fresh unique IDs and final apply previews remain mandatory. No service deployment
is approved against an inferred NODE3 identity or uninspected S2D disks.

## References

- [Azure Local virtual deployment requirements and educational-only status](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-virtual?view=azloc-2610).
- [2610 ARM witness-type reference](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template?view=azloc-2610#arm-template-parameters-reference).
- [Managed disk type conversion and VM restart](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-convert-types).
- [Hyper-V per-VHD Move-VMStorage parameters](https://learn.microsoft.com/en-us/powershell/module/hyper-v/move-vmstorage?view=windowsserver2025-ps).
- Public price response and exact query: `three-node-premium-cloud-sizing.json`.
