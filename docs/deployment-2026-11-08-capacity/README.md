# Existing AzureLocalBox compute-capacity operation

Date: 2026-11-08. **Prepared source, not applied capacity.**

The owner approves E64s_v6 and exactly three existing HCI guests at fixed 128 GiB /
16 vCPU, leaving the DC at 4 GiB / 2 vCPU. All eleven Standard_LRS disks, NIC, private
path, credentials, registrations and power policies remain unchanged. Public Windows
compute delta is USD 4.288 per running hour, not a contract quote. No GPU, disk purchase,
tier change, automation change, replacement VM or bridge repair belongs to this operation.

The parent separately approves scoped source commit/push/PR. The PLATFORM mutex is
released. **Actual disruption still waits for the parent's final inventory-bound GO.**
No deployment or source-delivery instruction is an implicit approval of a null baseline.

## Current inherited facts and limits

PLATFORM's settled receipts at deployed source `7a949dc` establish four Running guests,
three Up HCI nodes, 24 healthy S2D members, healthy three-copy mirrors, four Online CSVs,
and no active storage jobs. They remain historical, not fresh operation preconditions.

- Pool ID `{923c0194-3ed4-449a-ae14-0f62861e0ec8}`. Physical pool 4,055.98 GiB,
  allocated 1,117.50 GiB, unallocated 2,938.48 GiB at that observation.
- Existing infrastructure VM `4c6ca5cc-8c9a-499b-8ffe-c029bbfd3522`, 8 GiB, was Running
  on NODE01. Admit this exact global VM identity/configuration. Drain may move it between
  HCI nodes. Record placement separately and never recreate it or admit unknown VMs.
- V: 2,031.98 GiB, free 1,791.58 GiB. Historical 1,526 GiB maximum VHDs + 260 GiB
  target runtime reserve + 16 GiB metadata + 200 GiB floor leaves only 29.98 GiB margin.
- E64 exposes 64 logical processors / 32 SMT cores. Four outer guests total 50 logical
  processors / 388 GiB. Normal AKS is 24/88, maintenance is 32/120. Per-node placement
  and actual platform reserve remain necessary. Two HCI nodes cannot sustain N-1 plus
  32-vCPU maintenance without consuming all their CPU before platform work.
- Arc nodes are Connected but the bridge remains Offline/Succeeded. PLATFORM owns
  read-only ARM diagnosis while CAPACITY owns guests. The concrete cause and whether it
  makes maintenance unsafe must be reconciled before disruption. No full readiness claim.
- Boot encryption and audit/recovery acceptance remain unresolved. Standard HDD is the
  explicitly accepted lab tier, not compliance with the virtual guide's SSD prerequisite.

Source facts: canonical `docs/deployment-2026-10-27/private-ssh-readiness-platform-20261108-final.json`,
`private-ssh-readiness-platform-20261108-host-capacity.json`, and
`docs/deployment-2026-10-29/arc-readiness-20261108-070726-7d0b722a.json`.
These foreign receipts are referenced, not included in this scoped source commit.

Sizing/source discussion is maintained separately in SMAL at
`solution/infra/deployments/2026-11-08-aks-foundry/capacity/recommendation.md`.

## New files and boundaries

- `scripts/smal-compute-capacity-20261108.py`: GET-only cloud inventory, exact plan and
  preservation guards, canonical transport invocation, individually claimed effect
  receipts, minimal ETag-bound size PATCH and explicit read-only cloud reconciliation.
- `scripts/smal-compute-capacity-20261108-common.ps1`: direct invocation is read-only
  host inventory. Separate `...-nodes.ps1` and `...-dc.ps1` collect bounded node/cluster
  and DC/network facts. Uses existing node ASBuiltInAdmin / RID 500 and existing DC domain RID 500
  credentials, with no fallback, reset, export, installation or borrowed credential.
- `scripts/smal-compute-capacity-20261108-stage.ps1`: a source template, not a dispatchable
  standalone operation. Rendered stages embed the exact approved public plan/digest.
- `scripts/test_smal_compute_capacity_20261108.py`: offline identity, approval, capacity,
  per-node placement, storage, Off-state, uncertainty and PowerShell comparator/parser tests.
- `plan.pending.json`: pinned fixed effects with null baseline/admission/GO. It cannot resize.

Canonical startup/private transport, old approvals, trust files and historical unsafe
resize/move routines are unchanged. The current transport accepts new committed PS1 files
without changing its signature or credentials. All reviewed source must match pushed HEAD.
Startup can operate on the dedicated pushed branch. A PR merge is not needed for its
existing exact-source guard, and no merge is authorised.

## Observe, seal, review, then dispatch

Run offline tests first:

```bash
python3 -B -m unittest discover -s scripts -p 'test_smal_compute_capacity_20261108.py' -v
git diff --check
```

Only after this source is committed/pushed and the parent mutex handover is active:

```bash
AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no python3 -B scripts/smal-compute-capacity-20261108.py cloud-read
```

For `inventory`, `inventory-nodes` and `inventory-dc`, supply the canonical pending plan's deterministic JSON digest printed by
the Python `digest` helper, an immutable receipt key and `--mutex-handover`. `inventory`
does not need execution approval and invokes only the direct read-only common observer.
The observer never connects or reconnects VPN. Its canonical transport retains the
existing pinned SSH/private Bastion path and 90-second bound. A timeout is retained as
failed observation, not a reason to increase bounds or replay guest effects.

The combined observations capture all four VM profiles, attachments/GUIDs, vTPM protector hashes,
processor/memory/NUMA settings, all-node capacity, cluster/pool/CSV/VD identity and health,
existing infrastructure VM configuration and placement, IPv4/routes/neighbours/DNS/NAT,
DC DNS/DHCP metadata and bounded address echo observations. No raw protector/secret is
returned. MAC/IPv4/runtime placement information is operational evidence, not credentials.

**Absence of echo/ARP/DNS/DHCP entries is not proof that an address is unallocated.**
Proposed `.100`–`.179`, API `.180` and disabled demo `.200`–`.209` must be reconciled with
NETWORK's authoritative reservation/ownership inventory before network allocation.
This observer allocates or repairs nothing. The actual switch/VLAN0 evidence is handed
to NETWORK and AKS, not promoted into a network-ready claim by CAPACITY.

Seal `plan.sealed.json` only from source-bound, complete fresh observations:

1. Baseline: exact cloud VM/disk/NIC projection, host pools/switch/NAT, four guests'
   non-profile settings and VHDs, cluster/pool/member/VD/CSV/bridge identities and volumes.
2. Admission: measured per-node platform CPU/RAM reserves, initial-plus-replacement packing,
   explicit S2D repair reserve and required physical free space including all AKS VM disks,
   images, model cache and overhead. The 360-GiB minimum guard is **not** full admission.
3. Per-volume budgets must cover actual maximum attached VHD sizes and target RAM at
   both configuration/runtime and smart-paging paths. Keep at least 200 GiB free floor.
4. Reconcile active jobs, maintenance/nightly conflicts and the bridge Offline diagnosis.
   Unhealthy or active storage blocks entry. Do not waive the gate to make resize succeed.
5. Parent approves the exact unsigned JSON digest. The executor validates `parentGo`,
   `unsignedPlanSha256` and the fixed effect list. Never create an approval on its own.
6. Render candidate stage content through the Python helper, materialise by reviewed patch,
   parse/test, commit/push only owned source/plan/sanitised evidence, update the existing PR.
   No source generation overwrites files automatically.

## Stages after final GO

Each invocation requires `--expected-plan-sha256`, a new immutable `--key` and the parent
mutex handover. The startup lock is held only during this executor and released before
canonical startup. Every mutating stage stores pending intent before requesting effects.

1. `shutdown`: exact healthy baseline, graceful `Stop-Cluster`, independently verify all
   cluster services and existing nested VMs stopped, then exact HCI guests and DC last.
   No force turn-off, Saved-state admission or blanket VM shutdown.
2. `deallocate`: requires the complete fresh plan/source-bound shutdown receipt and all
   four Off observations. One Azure request, no automatic retry.
3. `reconcile-cloud`: GET-only confirms Deallocated, binds a create-only resolution to the
   unchanged original receipt hash. Original history is retained.
4. `host-size`: requires reconciled deallocation, Off evidence and exact cloud preservation.
   PATCH only `hardwareProfile.vmSize`, with inspected ETag. No VM replacement or full-model PUT.
5. `reconcile-cloud`: confirms E64 configured while Deallocated and unchanged projections.
   This is not actual running CPU/RAM proof.
6. Invoke only `python3 -B scripts/start-smal-localbox.py`, unchanged, to restore host/guests.
7. Serial NODE01, NODE02, NODE03: `stop-<name>` drains and proves Off, `resize-<name>` changes
   only startup RAM and processor count, canonical startup restores it, `resume-<name>`
   restores cluster participation and requires healthy convergence before the next node.
8. `verify`: actual 64 logical / 32 core outer topology and NUMA, actual three 16/128
   HCI capacities, all settings/identities, storage health/free/reserves and packing.
   Canonical Arc readiness is separate. Hand measured admission to AKS before creation.

Strict storage-health gates also apply during a one-node outage. If the platform reports
degradation or starts repair jobs, stop and inspect. Do not relax them, attempt another
node outage, or force a resize. Canonical restoration and any changed recovery direction
must be explicitly reconciled through the parent.

## Failure and rollback

Original receipts/host markers are never deleted. Repeating a receipt key or an existing
host stage is refused. Read-only `inspect` captures state after a guest failure. A partial
128-GiB/8-vCPU profile cannot be silently adopted or replayed. Parent-directed exact
reconciliation/recovery source is required before further guest mutation. No automatic
rollback or remote repair is implemented.

Before an outer E32 rollback, restore any enlarged guests to original fixed 8/64 profiles
under an exact recovery plan. Three 128-GiB nodes cannot boot on a 256-GiB outer host.
Recheck SKU/quota/IP allocation in either direction. VM configured size after failure is
not actual allocation proof. Preserve host-bound DPAPI/guardian material and the original
OS disk, and never mistake preservation for an independently tested off-host backup.

## Evidence qualifications

Offline checks prove guard/parser behaviour, not Windows cmdlet compatibility or live
cluster correctness. Live observer fields must be inspected before plan sealing. Any
missing CPU/NUMA property, unproved topology, unknown guest/bridge resource, service or
authentication error is a concrete blocker. Do not infer or fabricate the missing values.

### First observer timeout retained

Source `817096d` attempted one GET-only cloud plus full guest inventory at 09:31 SAST.
The canonical 90-second private command timed out after successful authentication.
`docs/deployment-2026-10-27/private-ssh-compute-inventory-20261108-01.json` records the
timeout, closed tunnel/socket and no returned guest result. The local
`operation-inventory-20261108-01.json` records no mutation request and retains the cloud
projection. Both originals remain untouched. No guest effects were present in that direct
observer source. Its outcome is not a completed inventory or a licence to extend bounds.

The source repair splits host, node/cluster and DC/network reads into distinct commands,
each still subject to the unchanged canonical transport timeout. New immutable receipt
keys distinguish later observations. Do not replay the original failed request or mistake
a repaired read-only observer for permission to disrupt the catalogue initialisation.
