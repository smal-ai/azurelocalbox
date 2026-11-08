# R2 capacity preparation and reconciliation

**Source candidate only. No capacity effect, startup, approval or publication.**
Date: 8 November 2026. Branch: `feat/localbox-capacity-r2-20261108`.
Starting main: `42408eda6f96943f47d4ef46e46f1d32fbf09e3d`.

## Release boundary

- `scripts/smal-capacity-r2.py` has `EFFECTS_ENABLED = False`. Operational source
  validation refuses before provider calls or intent creation. Rendered dispatcher
  and worker source also refuse effects. No CLI flag or plan GO overrides this.
- Production `plan.pending.json` remains unsigned, with null baseline, admission
  and `executionApproval`. No production sealed plan, handover, intent or worker
  exists from this preparation. Unit tests use temporary synthetic sealed fixtures.
- Activation requires a separate reviewed source change, exact committed and pushed
  source, independently reviewed source-file map, fresh inventory-bound parent GO,
  settled catalogue continuation and explicit release of the disruption hold.
- The old inline executor, stage renderer, generated mutation stages, direct worker
  transport and legacy cloud receipt relabelling are refused. Original receipts stay
  intact. Do not execute the old untested partials to bypass a new prerequisite.

## Exact scope and admission

APP subscription `8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea`, tenant
`c6e67968-af25-4557-ab8b-06b693048d3b`. Only existing `LocalBox-Client` in
`rg-localbox-nodes-san-1`, `southafricanorth`, private `10.200.16.4`, immutable VM ID
`627c8b3f-0a90-41cb-b707-12ba9d9ddad4` is admitted.

- E32s_v6 32/256 to E64s_v6 64/512 only. Actual E64 is 64 logical processors and
  32 physical cores, not a model-field capacity claim.
- Exact three HCI guests change only fixed startup RAM 64 to 128 GiB and CPU 8 to 16.
  The DC stays 2/4. Four guest IDs, 28 VHD identities/paths/attachments, eleven
  Standard_LRS disks with 8 TiB data backing, NIC/IP/security, protector hashes,
  credentials, automatic power policies and shutdown schedule are preserved.
- Existing infrastructure VM `4c6ca5cc-8c9a-499b-8ffe-c029bbfd3522` stays 4 CPU/8 GiB,
  MAC `02EC000B0000`, historical address `10.64.0.22`. Its global configuration is
  compared unchanged. Live cluster VmID and actual owner must agree. Legitimate
  migration among the three nodes is allowed, not recreation or a guessed restart.
- Before every effect, source/plan-bound actual observations must be no more than
  600 seconds old. Worker preflight re-reads local identities, CPU/RAM/NUMA, outer
  volume budgets, exact node capacity and storage. Unknown/missing fields fail closed.
  Every snapshot, including strict and stopped/cloud-stage evidence, must also carry
  the current execution source commit. An outer admission stamp cannot substitute
  for the snapshot's own source binding.
- Windows NUMA `ProcessorsAvailability` is counted. `MemoryTotal` is MiB and
  `FreePhysicalMemory` is KiB. Storage sizes/free values are bytes. Native operational
  enums are captured as arrays of strings, not converted into reassuring booleans.
- Initial AKS is 24 CPU/88 GiB, maintenance 32/120. Platform and the infrastructure
  VM need per-node allowances. N-1 plus surge is not admitted. Historical physical
  free space 2,938.48 GiB and V: margin 29.98 GiB are not fresh admission.
- No role, policy exemption, public access, disk, GPU, tier or schedule change is
  included. Boot encryption, audit delivery and independently verified recovery
  remain open. The cost delta reference is USD 4.288 per running hour.

## Transition and compensation contracts

The offline contract builder creates exact stages, keys, before/after profiles,
power states, selected cluster-node states and applied prerequisites. A normal
transition cannot consume a `not-applied` prerequisite under an after-profile
assumption. The complete normal route is mocked in tests, not run against the lab.

1. Request `Stop-Cluster -Force -Wait 0`, then independently observe all three
   ClusSvc services Stopped. Stop each exact HCI guest separately and DC last,
   observing and settling each request before the next. No forceful VM stop.
2. Persist and settle a remote startup grant with all exact guests Off. Request
   outer deallocation, independently observe stable Deallocated, then request the
   size-only update with the inspected ETag. Settle that separately.
3. Consume the exact canonical outer-start handover. While deallocated, use only
   the fresh sealed stopped-mode guest proof. Do not claim unseen bridge placement
   or actual running E64 capacity. Canonical startup and its subsequent observer
   must corroborate the target model, actual CPU/RAM and preserved identities.
4. For each node: strict health, drain, observe/settle exact selected-node maintenance,
   graceful stop, observe Off, memory-only effect, CPU-only effect, startup grant,
   canonical start, compensating Resume, then bounded read-only full convergence.
   Every remote/control effect has its own durable intent and settlement.
5. Full Healthy/OK, accessible exact CSVs and no storage jobs are required before
   another node. Completion is a separate remote control effect with its exact
   snapshot, process and source certificate, followed by bound local final settlement.

Known-state compensation branches exist after settled drain, stop, memory and CPU.
They preserve that last settled profile, restore only through canonical startup
when Off, Resume the selected paused node, then observe strict convergence. They do
not revert CPU/RAM, resize the outer host or authorise the normal next node.
The sealed `compensating` predicate applies consistently before compensation grant,
canonical pre-start and Resume in Python and PowerShell. Exact associated selected-node
Repair can therefore be active while returning that stopped node to service. Forward
memory/CPU and ordinary forward grant admission still reject active jobs.

Selected maintenance admits only the sealed eight-device owner set with two Up,
Healthy/OK surviving nodes, exact pool/mirror/CSV identities, accessible CSVs and no
unrelated failure. Drain settlement requires all eight devices fully **In Maintenance
Mode**, not merely Starting Maintenance. Resume can precede mirror convergence.
Known Repair jobs must bind to the exact pool and admitted mirrors, with nonempty
device associations confined to the selected eight. Missing pool, mirror or device
associations are unknown and fail closed. No fabricated owners or repair-job inference
is allowed. Unknown job/failure types remain blockers.

### Storage maintenance semantics remain a release blocker

The [Microsoft maintenance procedure](https://learn.microsoft.com/en-us/previous-versions/azure/azure-local/manage/maintain-servers)
explicitly documents automatic disk maintenance on pause/drain and automatic exit on
Resume for Azure Stack HCI 21H2/Windows Server 2022. It documents separate storage
maintenance commands for older releases. The current URL redirected to this
previous-version article. Those statements do **not** establish behaviour for this
lab's exact current guest OS/build.

The [Windows Server 2025 Suspend-ClusterNode reference](https://learn.microsoft.com/en-us/powershell/module/failoverclusters/suspend-clusternode?view=windowsserver2025-ps)
documents role drain and `-Wait`, but does not itself guarantee disk maintenance.
The candidate uses `-Drain -Wait` to wait for that existing drain RPC, then requires
eight actual devices fully InMaintenanceMode. No storage enable/disable command,
ForceDrain, extra mutating phase or fallback is added. If the deployed version does
not enter that state, drain cannot settle and the original barrier remains held.
Supported behaviour for the exact guest build, or a separately reviewed/sealed
one-effect storage maintenance design, is an **unimplemented operational prerequisite**.
No live validation is performed in this preparation.

The [Microsoft Stop-Cluster documentation](https://learn.microsoft.com/en-us/powershell/module/failoverclusters/stop-cluster?view=windowsserver2025-ps)
states that `-Force` suppresses confirmation and `-Wait 0` initiates without waiting.
It does not prove convergence. Neither `-Force` nor `-TurnOff` is added to `Stop-VM`.
The canonical capacity transport default remains **90 seconds**. Existing special
startup/observer limits are unchanged, not increased to hide unresolved effects.

## Durable barriers and exact reconcilers

- Local history is create-only and fsynced. `operation-r2.json` fences repository
  root, owner UID, source commit and plan digest. `intent-r2-KEY.json` is durable
  before dispatch. There is no mutable index that can hide an unindexed intent.
- All capacity and canonical handover entry points share the startup mutex and the
  internal history lock. An unresolved effect blocks every new key. An unconsumed
  handover fences capacity and becomes an unresolved startup intent when consumed.
- A detached remote worker has one effect, immutable request/launch records and
  sequential fsynced phase events under the shared remote mutex. Losing SSH does
   not terminate, settle or authorise a repeat of that worker.
- All R2 immutable PowerShell JSON writers use the same explicit depth-40 serialiser,
  structural depth/type check, warning-as-error behaviour and 2 MiB byte cap. They
  serialise before creating a file. Deep/oversized/unsupported records fail, not
  silently stringify into truncated certificates. Tests execute the actual completion,
  worker-event, startup-event and dispatcher-request writers against nested synthetic
  hashtables and read their full JSON back from temporary files.
- Remote settlement verifies exact key/stage/operation, source file hash, PID plus
  process start time, original dispatcher request, original event, returned RPC,
  successful effect or proved no-RPC refusal, and live expected identities/profiles.
  Reused/dead PIDs are only liveness observations. A missing event or unknown phase
  is unresolved. An exception after RPC entry remains conservatively uncertain.
  UTC process identity compares both ISO strings and DateTime values produced by
  PowerShell JSON parsing. DateTime string coercion cannot falsely declare the
  still-live original process absent. Operation ID is checked on both request and
  operation anchor before worker effects.
- Subsequent dispatch/startup re-reads the original remote request, worker file and
  event and compares them to the independently validated local settlement. Returned
  phase alone cannot bypass absent settlement. Startup binds the exact fresh remote
  grant and full guest/VHD/TPM/NIC profiles before each serial VM start.
  The remote settlement envelope contains original process/events and receipt hashes,
  not repeated full inventories. Full original receipts remain local. Direct transport
  dispatch also requires the controller's exact already-durable unresolved intent.
- Convergence performs bounded GET-only observations. Unknown identity/configuration
  failures fail immediately. Only the selected known maintenance profile may remain
  pending. Timeout creates no next-node certificate or mutation permission.
- `complete`/`finish` reject bare booleans, unbound snapshots and lone completion
  markers. The final local certificate binds the original completion settlement,
  remote certificate, full fresh identity/health snapshot and complete settled history.

There is no marker clear, stale-PID reset, automatic replay, process kill, credential
fallback or automatic rollback. Unknown/partial RPC outcomes, missing durable remote
history, interrupted grant consumption and expired unconsumed handovers need a
separately directed exact reconciliation/recovery procedure. This candidate refuses
them rather than inventing a safe state. It does not provide an operational recovery
tool for every corruption, crash or partial native failure.

## Migration, provenance and current blockers

- Preparation source `0038592100cbaa9c82e3b3352a6ac7920b9c81bd` entered new main via
  `ae1671d8c14207d988d32c4aff5a41155abab6f8`. The old source checkpoint is
  `f28ff52bfc31a3b2da7fbdc0d2f4c8c7b56a46c5`. All nine specified partial hashes
  matched before selective review. Their original bytes remain untouched.
- `smal-aks-binding-history.py` extracts read-only preservation logic from committed
  f28ff52 source. `binding-history.json` is sanitised historical metadata. The applied
  binding key and original receipt hash remain references. No PATCH executor or old
  binding approval is imported. All 240 old tuples/properties and four bindings must
  survive alongside the 60 AKS tuples. No binding replay is provided.
- `runtime-references.json` binds only four named public receipts at the old root.
  It also pins origin `https://github.com/smal-ai/azurelocalbox`. Matching branch SHA
  on a different configured repository is refused. References and their source must
  be committed unchanged and the exact reviewed branch must be pushed before use.
- Local metadata inspection found the existing SSH directory 0700 and key/trust
  paths 0600, owner UID 1000, not symlinks. Private key contents were not read.
  Existing known-hosts bytes matched the original pinned public-host-key receipt.
  This does not verify current login, protected guest credential bindings, host ACLs,
  remote helper installation or current operational readiness. Nothing was copied.
- The catalogue continuation result SHA256 is
  `1832d3d359d530aaf7d04145250eeed0de6df8a85a7b7a9236418f0ad284cc01`.
  Kubernetes remains Pending after one 900-second request. Local caller settlement
  is not Azure effect settlement. No retry/refresh is performed. Native SKU fields
  are `MemoryGB`/`GPUs`, with no per-SKU OS/disk defaults. No patch or current-image
  capacity is selected from Pending entries.

`delivery-manifest.json` contains changed-file and guarded-runtime source maps. It
excludes itself from both hashes, so there is no self-referential digest. The manifest
is provenance, not approval. Independent review, publication, fresh actual guest/storage
evidence after release, runtime prerequisites, catalogue settlement, exact GO and all
remaining security/recovery acceptance belong to the parent and future operators.

## Offline verification

```bash
python3 -B -m unittest discover -s scripts -p 'test_smal_capacity_r2*.py'
python3 -B -m unittest discover -s scripts -p 'test_smal_*.py'
git diff --check
```

Tests cover mocked full startup/transition/compensation/convergence/completion routes,
applied versus proven-not-applied predecessors, timeout/crash barriers, real local
file-lock races, one-use handovers, exact source/event/process fencing, realistic native
storage fields, legitimate infrastructure migration and pure PowerShell guard parity.
PowerShell is used only for parsing and synthetic pure guards. Canonical Python main
is tested only with all provider/transport boundaries mocked, a temporary lock and
temporary receipts. No live startup, worker, Azure command, SSH or protected credential
helper is executed.
