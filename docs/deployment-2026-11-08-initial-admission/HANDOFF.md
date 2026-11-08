# Initial AKS base handoff

**Measured HCI profiles remain 8 vCPU / fixed 64 GiB on all three guests.** The outer
host is E64s_v6, Running. This is a partial read-only handoff, **not initial workload
admission** and not evidence that the attributed 16/128 guest enlargement completed.
No resize, restart, storage expansion, catalogue operation or network change occurred.

[Evidence manifest](evidence-manifest.json) binds eight sanitised projections to their
original private receipts. Remoting metadata is removed from published projections.
Original failures, the October identity approval, the earlier mismatch receipt and
REL-333's history/stash remain unchanged.

## Current host and configured guests

Host ARM capture: **17:16 SAST**. Outer PowerShell capture: **17:24–17:25 SAST**.
Source for the new parts: `e49c11aad1753defb1b7cd2c903267b9b69edeec`.

- Original Azure VM UUID: `627c8b3f-0a90-41cb-b707-12ba9d9ddad4`.
- Private address: `10.200.16.4`, public-IP reference null, security type Standard.
- Guest-observed host capacity: 64 logical processors, **549,750,304,768 RAM bytes**.
- All eleven managed disks remain `Standard_LRS`. IDs, unique IDs and `diskSizeGB`
  equal the authoritative pre-resize managed-disk baseline. NIC ID and VM UUID match.
  This comparison uses disk resources, not resize-nullified attachment annotations.

| Guest | Exact Hyper-V UUID | State | vCPU | Fixed / assigned RAM bytes |
| --- | --- | --- | --- | --- |
| LB-DC01 | `f94c71f1-6854-48b9-a9f1-8238c99366d0` | Running | 2 | 4,294,967,296 |
| LB-NODE01 | `3adff629-2f67-449b-ab32-8a8748c46f34` | Running | 8 | 68,719,476,736 |
| LB-NODE02 | `12a44e0c-cc08-4c4c-a812-fa0b56efdbc3` | Running | 8 | 68,719,476,736 |
| LB-NODE03 | `5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9` | Running | 8 | 68,719,476,736 |

Dynamic memory is disabled on all four. Nested extensions are enabled on the HCI
guests. All heartbeats report `OkApplicationsUnknown`. The earlier **16:36–16:37 SAST**
guest OS capture independently reports eight logical processors and 68,718,317,568
physical RAM bytes per HCI guest. The small RAM difference is between assigned and
guest-observed values, not evidence of a 128-GiB profile.

The existing infrastructure VM `4c6ca5cc-8c9a-499b-8ffe-c029bbfd3522` was Running on
NODE01 in that baseline, 4 CPU / fixed 8 GiB, MAC `02EC000B0000`, reported `.22` and `.21`.
Its existing 100-GiB OS VHD remains on `Infrastructure_1`. It is **not** evidence for
the selected AKS package's OS-disk maximum. Infrastructure CSV remains platform-reserved.

## Native storage baseline and current limitation

The complete **16:36–16:37 SAST** source-bound baseline is retained, not relabelled as
a later fresh read. All three cluster nodes were Up, 24 capacity devices Healthy,
five three-copy mirrors Healthy, four CSVs Online and no active storage jobs returned.
Cluster/Hyper-V/Arc services were Running. This is not a fresh ARM Arc Connected claim.

Pool `{923c0194-3ed4-449a-ae14-0f62861e0ec8}`:

| Native field | Integer bytes |
| --- | ---: |
| Size | 4,355,071,672,320 |
| AllocatedSize | 1,199,906,488,320 |
| Derived unallocated | 3,155,165,184,000 |
| Each of 24 capacity devices | 182,536,110,080 |

| CSV path | Native Size bytes | Native free bytes |
| --- | ---: | ---: |
| `C:\ClusterStorage\Infrastructure_1` | 270,515,830,784 | 225,401,851,904 |
| `C:\ClusterStorage\UserStorage_1` | 304,875,569,152 | 285,591,822,336 |
| `C:\ClusterStorage\UserStorage_2` | 304,875,569,152 | 301,216,014,336 |
| `C:\ClusterStorage\UserStorage_3` | 304,875,569,152 | 301,216,014,336 |

The baseline includes five actual VD IDs/sizes/copy counts. **Current FootprintOnPool,
ProvisioningType, native VD-to-volume associations, tier layout, active jobs and
committed/image-staging reservations could not be refreshed.** Both the first attempt
and one inspected serial follow-up failed at `New-PSSession`, before storage queries.
The source error is `PSDirectException` at rendered line 88 on the serial follow-up.
No further retry or transport workaround was attempted.

The **17:16 SAST** ARM GET returned all three UserStorage containers, Succeeded, bound
to the existing custom location. Their paths map by directory containment to the three
named CSV paths above. Container `availableSizeMB` values are 272384 / 287232 / 287232,
with `containerSizeMB=290713` each. These provider MB fields are **not native byte
measurements**. Eligible per-package OS/image paths and provider placement/count limits
are not established by this path mapping.

## Network observations

At **17:25 SAST**, both outer OS route selections to proposed `.100` and `.180` choose:

- Source `10.64.0.1/24`, interface 4, `vEthernet (LB-Fabric)`.
- Route `10.64.0.0/24`, next hop `0.0.0.0`, metric 256.
- `LB-NAT` remains Active with internal prefix `10.64.0.0/20`.
- Zero static NAT mappings returned. No NAT sessions were read.
- Current outer SSH22 peer selector returned `10.202.0.5`, the Bastion-side source.

The earlier complete node records show `.11/.12/.13` on `/24`, External
`ConvergedSwitch(managementcompute)`, untagged management VLAN0, link Up, default gateway
`.1` and DNS `.10`. Their route tables include on-link `10.64.0.0/24`.
**Fresh Find-NetRoute return selections and six gateway/DNS probes are unavailable:**
the first route capture and one serial follow-up failed at initial NODE01 PowerShell
Direct session creation, before probes. No socket was opened to the uncreated API.

Actual diagnostic origin is this Linux operator workspace through the existing private
Bastion SSH transport to the outer host, then PowerShell Direct to guests when available.
This does not establish future AKS get-logs/lifecycle SSH origins or an exhaustive extra
caller list. SMAL must select and source-bind `approvedSshSourceCidrs`.

Protect `.1`, `.10–.13`, `.20–.30` and InfraLNET `.21/.22–.23` as instructed. Proposed
SMAL `.100–.179` and API `.180` were **not reserved by this handoff**. Neither negative
ARP/DHCP, route data nor absent ARM NICs clear native address ownership.

## Getter/image interface gap

The successful **17:24–17:25 SAST** NODE01 metadata capture returned zero already-loaded
matching MOC/AKS getters and zero matching loaded vendor modules. Installed metadata:

| Module | Version | Manifest signature | Actual relevant exported getter names |
| --- | --- | --- | --- |
| Moc | 1.2.161 | Valid | `Get-MocGalleryImage`, `Get-MocMacPool`, `Get-MocNetworkInterface`, `Get-MocVipPool`, `Get-MocVirtualMachine`, `Get-MocVirtualNetwork` |
| ArcHci | 2.0.19 | Valid | None in the selected filter |

Exact manifest paths/hashes are in [getter-discovery.json](observations/getter-discovery.json).
Exported names from an unloaded module are **not callable signatures or native traversal**.
No module was loaded. Manifest/initialisation source checks and actual fixed getter
parameter sets would be needed before the permitted read-only module-load proposal.
Current PowerShell Direct failure prevents that follow-up through canonical source.

Therefore complete MOC pool/allocation/reservation/registered-VM/vNIC ownership,
selected CBLMariner 1.34.4 image identity/state, native OS maximum bytes and any exclusive
image/create lock remain **unavailable**, not empty or absent. No bridge SSH, Kubernetes
context, credential-service request, catalogue refresh or image download was used.
Original catalogue Pending/correlation history is unchanged and did not block these reads.

The cloud Arc refresh also has an exact local interface gap: `az connectedmachine`
is not recognised with dynamic extension installation disabled. The original failed
query is retained. No extension was installed and no fresh Arc Connected result is claimed.

## Logical remedy bounds, not permission or a ready proposal

The independently reviewed Microsoft [logical-volume procedure](https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/manage-volumes)
distinguishes non-tiered VD resize from tier resize, then Basic partition/filesystem
extension and verification. It expressly prohibits resizing underlying virtualised S2D
capacity devices and requires room for the new physical footprint. The two reviewed
general pages do **not** establish this build's Thin expansion allocation guarantee.

No current supported placement/count bound or ready-to-apply logical expansion can be
returned without refreshed Thin/footprint/tier/association data and a source-bound native
OS maximum. A co-located engineering scenario of 200-GiB maximum OS + 100-GiB cache +
20-GiB logical margin needs 320 GiB free. Against the dated CSV2/3 free-byte measurement,
that is at least **42,381,369,344 additional logical bytes**, before alignment/metadata.
This is conditional arithmetic, **not** an asserted native OS default, per-VM CSV knob,
physical-allocation requirement or expansion proposal. The documented 200 **GB** default
still needs exact-byte/build applicability. Infrastructure CSV, pool, capacity VHDs,
eleven disks/HDD tier, identities and existing reservations must remain preserved.

## Delivery and decisions

- New operator scope is additive and restricted to this read-only execution. Fresh
  tenant/subscription/principal and effective VM/NIC/Bastion GET permissions passed.
  Referenced SMAL source hashes were checked: `aks/operator.json`
  `fa85266f2560758670c49f0b38c687e8617dc19e06189a66655dba1eb1898b4e`,
  `platform/aks-binding-result.md`
  `68d2162c1dde7501b47a9f89e187362a4ba1a1ceed43d7d1eb9b934a0e4a5c73`, and
  `solution/infra/foundry/identity-plan.json`
  `b396e6accceceee3d3086b64f2a5a722c9707e7fdaba855e733c3c53ae311fc6`.
  Historical PIM/repair entries are provenance only, not current entitlement or replay GO.
- Independent Sol review found no blocking source control-flow defect. It reran **11
  focused observer tests and 8 existing transport tests**, all passing. These are not
  runtime compatibility, Thin support or readiness proofs.
- Canonical outer SSH is usable. The required guest PowerShell Direct interface currently
  fails before queries. Preserve the exact receipts and obtain supported recovery through
  the platform owner, not alternate credentials/transports or automatic service repair.
- SMAL owns the current 8/64-versus-attributed-16/128 reconciliation, platform CPU/RAM
  headroom, native image/address/storage prerequisites and workload admission.
- This bounded handback ends with measured facts and precise gaps. It does not wait for
  INF0–INF8 completion or revive the administratively closed REL-333 invocation.
