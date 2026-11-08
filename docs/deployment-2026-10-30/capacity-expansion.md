# Approved additive data-capacity expansion

## Human decisions

- Keep **Standard_LRS**. This supersedes Premium as the active desired tier for
  this lab, without rewriting the earlier conversion/drift evidence.
- The human will investigate exemption options. WorkIQ and policy/automation
  changes are excluded from this operation.
- Target doubled **data capacity**, excluding every OS disk. Coordinated downtime
  is permitted if necessary, but it is not a requirement to interrupt a healthy cluster.
- After the supported alternative and cost were explained, the human selected
  **Approve supported addition**. Exact plan and approval: `capacity-expansion-plan.json`
  and `capacity-expansion-approval.json`.

## Why add rather than resize

Microsoft explicitly does not support host-level virtual disk size changes for an
S2D guest cluster. Existing VHDXs must retain their size and characteristics. The
documented expansion method is to add same-sized virtual disks to each node.

Accordingly, this operation will not resize the existing twelve pooled VHDXs or
the outer eight-member Simple pool. It adds capacity without rebuilding either pool.

| Layer | Before | Approved target |
| --- | --- | --- |
| Azure data backing | Eight 256 GiB disks plus one 2 TiB disk: 4 TiB | Add one 4 TiB Standard_LRS disk: 8 TiB total |
| Outer host data volume | Existing V: and W: | Add independent X:, GPT/NTFS, 64 KiB allocation units |
| Guest S2D devices | Four 170 GiB VHDXs per node | Add four 170 GiB matching dynamic VHDXs per node |
| Total raw S2D devices | 12 / 2,040 GiB | 24 / 4,080 GiB, less pool metadata/reserves |
| OS disks | Host, DC and three node OS disks | Unchanged |
| Existing CSV/virtual disks | Four CSVs / five Express virtual disks | Original identities, sizes and three-copy mirrors preserved |

The new managed disk is **LocalBox-Client-Capacity-20261030**, South Africa North,
4,096 GiB, at free Azure LUN **9**. It uses caching None and retention Detach/default
Detach. Public disk access is Disabled, network access DenyAll. It never joins the
outer pool. Only this admitted blank new disk may be initialised/partitioned/formatted.
No additional managed disks, new nodes, workloads, models or AKS systems are included.

Each node receives only new SCSI data slots **5–8** and new files under
`X:\AzureLocalBox\CapacityExpansion-20261030-01\<node>\S2D-5..8.vhdx`.
The existing boot/data VHD GUIDs, paths, sizes and attachments are checked before
and after. New VHDs clone the existing data-VHD sector/block characteristics and
are bound to their actual returned GUIDs and derived guest unique IDs.

## Cost and performance

The inspected Azure Retail Prices API gives **USD 192.10/month** for the added
South Africa North **S50 LRS Disk** capacity. This is a public capacity-only reference,
not a contract quote. Transactions, tax and other applicable charges are excluded.
Standard HDD is retained by explicit instruction. Adding capacity is not a promise
of SSD performance or doubled throughput.

## Stages and failure boundaries

`scripts/smal-capacity-expansion.py` has separate create-only receipt stages:

1. **prepare**: source/approval, current Azure identity, exact ten Standard disks,
   VM/LUN limit, all original guest/VHD identities, healthy idle 12-device cluster,
   outer pool/volume identities and before-attachment Windows device set.
2. **create**: actual ARM what-if admits only the one approved empty private disk.
3. **attach**: inspect that disk's actual unique ID, compare the exact requested
   attachment diff and attach it only at free LUN 9. Preserve every old VM/disk field.
4. **format**: require same host boot epoch, precisely one new 4 TiB RAW non-OS
   Windows/physical device, unchanged old device sets and no partitions. Format only
   that new device. Preserve C:, V:, W: and both existing pools.
5. **add-vhds**: create twelve distinct owned new files, record their identities,
   and hot-attach only to the exact three running VMs/free SCSI slots. Never resize,
   reset, format or recreate a guest pooled disk. S2D performs its normal auto-claim.
6. **verify**: independent reads must show exactly the original twelve plus the
   twelve returned new device IDs, same S2D pool and approximately doubled pool
   capacity, all three nodes Up, all CSVs Online, unchanged original virtual-disk
   IDs/sizes and healthy three-copy mirrors. Verify 8 TiB Azure data backing and
   unchanged OS/old managed disks separately.

Every mutation requires committed/pushed source and exact approved plan hash.
Existing/uncertain receipts or host markers are not removed. There is no blind
replay, destructive rollback, disk reset, cluster redeployment, policy bypass,
role activation/grant or automatic automation/schedule change. Failure to auto-claim
the exact drives stops for inspection, not reformatting.

S2D may start automatic optimization after drive addition. Readiness reports must
distinguish capacity admission from completed redistribution. No active jobs in one
early observation does not prove that automatic optimization has finished.

The pre-existing boot-encryption and recovery/audit-delivery gaps remain separate
and are not silently waived by this capacity operation.

## Applied stages and retained interruption

The exact pre-attachment baseline passed, including all three nodes Up, healthy
idle 12-device pool, original VHD IDs and 64-disk Azure VM SKU limit. The approved
4 TiB disk was created, attached at LUN 9, and only its admitted RAW device was
formatted as X:. Its immutable Azure unique ID is
**db6882f9-8c4a-4923-b1a3-6b73dbbb9109**. Existing managed-disk sizes/SKUs,
attachments, outer pool and C:/V:/W: identities were preserved. No shutdown was needed.

The VHD stage stopped at its first new file while converting DiskIdentifier to
guest unique-ID bytes. The runtime returned the identifier as a string, while the
code called ToByteArray without first parsing a Guid. The original journal records
zero bound/attached new VHDs and the one pending first-file path. No guest attachment
command had been reached. The failure receipt/host marker are retained.

Before a corrected continuation, the dedicated read-only interruption inspector
must prove exactly one small, dynamic, unattached owned new VHD with the intended
size/geometry, the unchanged original five attachments per node, and the original
healthy 12-device S2D pool. Its returned GUID and file hash must be retained. No
file or failure marker may be deleted or blindly recreated.

The read-only inspection verified exactly one **4 MiB**, unattached, dynamic
170 GiB VHD, GUID **2346EBF2-6D1B-48B4-85DB-090E25B7E955**, with matching sector/block
geometry. All fifteen original VHD attachments/identities and the healthy 12-device
S2D pool are unchanged. The new file's SHA256 is retained in the inspection receipt.

The corrected encoder explicitly parses the returned identifier as a Guid before
byte conversion. `add-vhds --resume-first-vhd-binding` permits only this one admitted
file, requiring the committed failure/admission evidence and a live matching file
hash/GUID. It reuses that file without recreation, creates the remaining eleven
files, and proceeds under a **separate** marker/state/receipt. The old failure and
marker stay intact. Other existing files or any prior guest attachment block this
specific recovery. Unit tests execute the string-Guid conversion with PowerShell
and compare it with the independently derived guest unique ID.

## Attachment completed; independent reads must converge

The guarded continuation completed all twelve attachments, four per node, preserving
the first admitted file's original GUID. All original VHD paths/GUIDs/sizes and
the final nine-disk running topology per node were independently checked.

The first sequential post-addition read caught normal automatic pooling in progress:
NODE1 reported 12 members, NODE2 21, and NODE3 24. All reported members were Healthy,
and the final node already reported doubled pool capacity. This is not sufficient
for acceptance because the three snapshots do not yet agree. The early failed
verification receipt remains intact and no mutation is replayed.

`scripts/observe-smal-capacity-growth.py` performs only read-only observations until
all three nodes report the exact approved 24-member pool and doubled capacity,
unchanged original virtual-disk IDs/sizes and Online CSVs. It separately verifies
preserved C:/V:/W:, the exact new X: identity/reserve, 8 TiB Azure data backing and
all eleven managed disks Standard_LRS. Completed AddPhysicalDisk records are not
mislabelled as active jobs or proof of completed automatic optimization.

## Completed and independently verified

At **15:53 SAST on 30 October 2026**, the read-only convergence observation passed:

- Azure backing data capacity is **8,192 GiB**, up from **4,096 GiB**.
- All **eleven** attached managed disks are **Standard_LRS**. Original ten disk
  identities, sizes and ownership remain unchanged.
- Each node has **eight 170 GiB S2D devices**. All three views agree on exactly
  **24 Healthy members**, comprising the original twelve plus the twelve newly
  bound guest IDs, in the **same S2D pool**.
- Pool capacity is **4,055.98 GiB**, up from **2,027.99 GiB**.
- All three nodes remain Up, four CSVs Online, original five virtual-disk GUIDs
  and sizes unchanged, with healthy three-copy mirrors and no witness.
- All original host/guest OS disk sizes, C:/V:/W: identities and the eight-member
  outer pool are preserved. The exact new X: volume is Healthy with **4,094.70 GiB**
  free at the observation. Dynamic VHD maximum capacity remains bounded below X:.
- No storage jobs were active at that read. Automatic optimization may still
  start later; redistribution completion has not been claimed.
- No host/guest shutdown, cluster redeployment, policy/automation change, new
  role grant, secret reset or workload deployment was performed.

Post-expansion cloud reads also verified the three Arc identities Connected,
resource bridge Running, custom location Succeeded/bound, service Deploy still
Success, vault public access Disabled and storage public access Disabled/Shared
Key false. The pre-existing boot-encryption and recovery/audit-delivery gaps remain.

Evidence:

- `capacity-expansion-converged-observation-20261030.json`.
- `../deployment-2026-10-27/private-ssh-capacity-convergence-20261030-0.json`.
- `../deployment-2026-10-29/three-node-cloud-after-capacity-20261030.json`.
- All individual prepare/create/attach/format/add-VHD receipts, the retained
  encoder interruption/admission records and the early non-converged snapshot.

## References

- [S2D in a guest cluster: unsupported host-level size changes and adding capacity](https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/storage-spaces-direct-in-vm).
- [S2D adding drives and automatic pooling/optimization](https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/add-nodes#adding-drives).
- [Azure managed disk expansion and guest volume considerations](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/expand-disks).
- Azure retail API query URL and exact reference retained in the plan JSON.
