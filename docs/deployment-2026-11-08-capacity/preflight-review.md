# Fresh read-only preflight and unsigned candidate

Date: 2026-11-08. **No host/guest shutdown, resize or start was requested.**
Catalogue disruption hold is released by the parent. Exact final capacity GO remains
pending parent review of this source/candidate. Peer custom-location repair source is
not included in this delivery and no mapping repair was applied.

## Candidate and source

- PR: https://github.com/quintindk/azurelocalbox/pull/1, scoped against the deployed
  `deploy/smal-host-20261027` branch. No merge or force push.
- Deterministic unsigned candidate digest:
  `dcdabe1106f42767ed030908347b3476f1dc94f86eafbf92d4147d37bb4225a5`.
- [Candidate reference](https://github.com/quintindk/azurelocalbox/blob/63036d03fbdb3a3f433a5dfa71de36aa902fbf05/docs/deployment-2026-11-08-capacity/candidate-reference.json) binds the retained local receipts by
  SHA256 and capture-time source revisions. `build_candidate` assembles the exact
  baseline/proposed admission without writing files or approving execution.
- The candidate leaves `maintenanceConflictChecked=false` and `executionApproval=null`.
  It cannot execute. Actual admission/storage/job/power state is refreshed before effects.
  Rendered mutating stages and `plan.sealed.json` remain unmaterialised.

## Actual host and guest inventory

Host observation completed at 09:36:03 SAST. Node inventory completed at 09:37:27.
DC observation completed at 09:37:57. Hardware metadata completed at 09:40:12.
These are dated measurements, not continuously current readings.

| Component | Actual logical processors / cores | RAM GiB | Observed free RAM GiB |
| --- | ---: | ---: | ---: |
| LocalBox-Client | 32 / 16 | 256 approximately | 50.36 |
| LB-NODE01 | 8 / 4 | 64 approximately | 49.53 |
| LB-NODE02 | 8 / 4 | 64 approximately | 57.68 |
| LB-NODE03 | 8 / 4 | 64 approximately | 57.16 |
| LB-DC01 | Configured 2 vCPU, unchanged | Fixed 4 | Not guest-measured by capacity |

Exactly four outer guests are Running. All three HCI profiles are freshly verified fixed
64 GiB / 8 vCPU, Gen2, Secure Boot/vTPM, nested extensions enabled, checkpoints Disabled,
automatic start Nothing and automatic stop ShutDown. All 28 attached VHD GUIDs/paths/
maximum sizes are captured. Existing protector hashes are compared without exporting
protector bytes, keys or credentials. All eleven Azure disks remain Standard_LRS and
the same NIC holds 10.200.16.4 without public IP or forwarding.

**NUMA discriminator:** actual `Get-VMHostNumaNode` has `ProcessorsAvailability`, not
`ProcessorCount`. Its array has 32 entries on the outer host and eight on each HCI node.
`MemoryTotal` is MiB here, matching measured host/node RAM after conversion. The earlier
null CPU field and unconverted memory field remain in original receipts, not overwritten.
The observer/executor now uses the observed array count and MiB-to-byte conversion.
Each machine reports one NUMA node. No NUMA setting was changed.

Node instantaneous CPU samples were 12%, 4% and 34% respectively. NUMA availability
samples vary across processors and are not a sustained performance benchmark. Do not
translate current samples into a guaranteed model latency or exact future platform demand.

## Existing clustered infrastructure VM

The single existing VM is **4 vCPU / fixed 8 GiB**, Gen2, one 100-GiB OS VHD and an
untagged adapter on `ConvergedSwitch(managementcompute)`. Its actual VM ID is
`4c6ca5cc-8c9a-499b-8ffe-c029bbfd3522`. The exact cluster Virtual Machine resource's
`VmID` parameter matches. Its Online group and Running VM are owned by NODE01.

MAC `02EC000B0000` is observed in neighbour tables at **10.64.0.22**. The VHD/configuration
paths are under the existing infrastructure CSV `MocArb` working directory. This proves
the Hyper-V/cluster identity and address correlation, not an independent ARM-appliance
to VM-GUID mapping or Linux Kubernetes readiness.

Preserve its global identity/configuration. A legitimate serial drain can change owning
HCI node and that placement is recorded separately. No forced placement, bridge resize,
recreation, registration or Linux credential/kubeconfig access is part of capacity.

### CPU packing accounts for that VM

| HCI node at this baseline | Conditional maintenance AKS packing | Platform CPU allowance | Platform RAM allowance |
| --- | --- | ---: | ---: |
| NODE01, current infrastructure owner | Replacement 8/32 | 8 logical CPUs: existing VM 4 plus host allowance 4 | 24 GiB including existing VM 8 |
| NODE02 | System 8/32 + control plane 4/8 | 4 logical CPUs | 16 GiB |
| NODE03 | Inference 8/32 + workload 4/16 | 4 logical CPUs | 16 GiB |

This avoids the earlier false packing of twelve AKS vCPUs plus the existing four-vCPU
VM and no HCI host allowance. If infrastructure ownership changes, recompute packing
around its actual owner before AKS admission. These are engineering allowances informed
by inventory, not CPU reservations or measured concurrent performance acceptance.
AKS placement enforcement and CPU performance are later gates. N-1 plus surge remains
unadmitted. Enlarging the outer host alone still provides no extra AKS capacity.

## Storage and runtime-state admission

Fresh cluster view: three Up nodes, Majority/no witness, 24 Healthy members, five Healthy
three-copy Mirror virtual disks, four Online CSVs, no active storage jobs. Same physical
pool 4,055.98 GiB, allocated 1,117.50 GiB, unallocated **2,938.48 GiB**.

| Outer volume | Actual size GiB | Observed free GiB | Maximum attached VHD GiB | Target runtime reserve GiB | Margin after 16-GiB metadata and 200-GiB floor |
| --- | ---: | ---: | ---: | ---: | ---: |
| C: | 1023.89 | 953.89 | 0 | 0 | 807.89 |
| V: | 2031.98 | 1790.33 | 1526 | 260 | **29.98** |
| W: | 2047.98 | 1910.19 | 978 | 128 | 725.98 |
| X: | 4095.98 | 3977.98 | 2040 | 0 | 1839.98 |

Budgets use actual configuration/smart-paging paths and **maximum** VHD sizes, not their
small currently allocated files. All four floors pass this observation. V remains tight
but the requested profiles fit without a storage move, resize or new disk.

The unsigned proposal protects 510 GiB physical S2D repair reserve and another 360 GiB
physical model-cache/headroom projection. These are explicit lab allowances, not a new
allocation or complete AKS disk admission. Exact AKS catalogue OS-disk defaults are still
unavailable. Four 128-GiB boot disks plus one replacement would consume 640 GiB logical
if that assumption is later verified, on top of model backing and overhead. Do not hand
AKS a free-capacity approval derived from CSV free space or these unverified defaults.
No extra S2D capacity is consumed by an outer/HCI CPU/RAM setting alone.

## Network observations, not allocation authority

- All three HCI nodes have the existing External converged switch backed by Teamed-Interface,
  untagged management adapters, management `.11`/`.12`/`.13`, gateway `.1` and DNS `.10`.
- Existing outer Internal LB-Fabric switch, gateway `.1`, WinNAT `10.64.0.0/20`, no static
  NAT mappings, outer private 10.200.16.4 and resolver 10.204.0.4 are captured unchanged.
- DC has no DHCPServer service. AD-zone A records identify DC, three HCI nodes and the
  cluster `.20`. This does not exclude another allocator or manually assigned machine.
- All 81 proposed `.100`–`.180` and ten disabled demo `.200`–`.209` probes completed
  without an echo response. Their neighbour entries have no resolved MAC. Existing DC/
  HCI probes respond. The gateway did not echo and is not labelled down on that basis.
- **No positive address conflict was observed. Unallocated-address ownership is not proved.**
  NETWORK must reconcile its authoritative reservations before allocation. No address,
  route, NAT, VLAN, firewall, DHCP, DNS record or VPN setting was changed.

## Bridge/catalogue diagnosis and next gate

The parent's ARM diagnosis reports bridge Running/Succeeded without repair, while its
09:25:54 Resource Health response says Unavailable and provides no component cause.
The two catalogue operations have now settled with **MissingAzureKubernetesMapping**,
and independent GETs return 404. That establishes a custom-location/operator mapping
gate, not an actual SKU/Kubernetes catalogue or a diagnosed host-capacity failure.

This local inventory shows healthy cluster/storage and the exact Running infrastructure
VM, with no unsafe storage transition observed. It does not diagnose the earlier Arc
connectivity lag. The parent must reconcile whether any residual bridge condition makes
maintenance unsafe and confirm the final exact plan. PLATFORM's additive mapping repair
is source-preparation only, remains separate and must not disrupt this operation.

Before actual effects: final parent GO, current conflict check, plan sealing/rendering,
source guard/tests/push, fresh health/free/power/profile checks and explicit independent
receipt reconciliation. No generic human permission re-request is needed.

## Offline verification and preserved peer work

- **305 tests pass** for the deployed regression suite plus this capacity candidate,
  including **22** new capacity tests and PowerShell parsing/comparator execution.
- A separate complete current discovery passes **335**, including the peer's 30
  untracked custom-location-binding tests. Those peer files are not staged or delivered
  in the capacity commit and are not thereby approved for apply.
- Scoped staged whitespace checks pass. No canonical startup/transport/approval/trust
  file changed. Original inventory timeout and every raw observation receipt remain local.
- SMAL document verification encountered three missing peer NETWORK links to
  `solution/infra/network/delivery-freeze.json` during concurrent source preparation.
  CAPACITY did not create a placeholder or alter those peer documents to mask the failure.
