# Direct-human full-outage resize

Source-only candidate based on `ef978b66b9fb3d62cf32995990b8f4c6325841c3`.
Branch: `feat/localbox-direct-resize-20261108`. No Relay execution, task, message or
parent authority is used. The original R2 route stays `EFFECTS_ENABLED=False`.
Its original delivery manifest remains unchanged historical evidence.

## Fixed hardware and authority

Only the existing APP `LocalBox-Client`, immutable VM ID
`627c8b3f-0a90-41cb-b707-12ba9d9ddad4`, changes E32s_v6 to E64s_v6. Three exact HCI
guests change 8/64 to 16/128. DC stays 2/4. All four IDs, 28 VHD attachments/IDs/paths,
eleven Standard_LRS disks, 8 TiB data backing, private IP `10.200.16.4`, network,
security, TPM/protector/credential bindings and power/schedule properties are preserved.
No disk, GPU, role, exemption, public access, credential or model change is included.
The observed guest policies are automaticStart=Nothing and automaticStop=ShutDown.
These are enforced preservation prerequisites, not settings this route changes.

The route requires an actual `directHumanApproval` quoting the human instruction,
binding the exact unsigned plan digest and effect set. `technicalReview` separately
binds the reviewed code map. It does not call either record `parentGo` or generate one.
The pending plan contains null approval, baseline and review fields. Committed+pushed
origin/code/plan/map equality remains mandatory. No dirty-source or CLI approval bypass.

The root's 10:19:47Z host and 10:23:13Z node reads are retained evidence, not fresh
execution preconditions. The four root-owned receipts are excluded from this source
delivery. Actual reads must be renewed within 600 seconds after source publication.
Kubernetes catalogue remains **Pending**. Root must explicitly assess hardware
quiescence and disclose the interruptible control-plane operation. No refresh, replay,
catalogue success, AKS capacity or patch selection is inferred.

## One graceful full outage

1. Fresh strict all-node health, exact resources and no jobs.
2. One `Stop-Cluster -Force -Wait 0` intent. Independently observe all three ClusSvc
   Stopped and exactly one infrastructure VM in its frozen policy-bound state:
   **Saved for OfflineAction=1**, or **Off for OfflineAction=2** with enabled shutdown
   integration. Missing, Running, Paused or policy-mismatched state blocks. No guessed
   individual stop/start or saved-state discard is permitted.
3. Gracefully stop each exact HCI guest, then DC last. Each request gets its own
   immutable intent, native process/RPC observation and independently verified Off
   settlement. Never `Stop-VM -Force` or `-TurnOff`.
4. While all four guests are Off and the E32 host remains Running, set memory and CPU
   on each HCI guest as six separately settled effects. No guest may start with the
   resulting 388 GiB profiles on the 256 GiB host.
5. Create and settle the exact target-profile/all-Off startup grant. Deallocate the
   original outer VM once, settle, then PATCH only hardwareProfile.vmSize with the
   inspected ETag and independently settle the E64 model change.
6. Canonical startup consumes its exact one-use handover. Before any guest start it
   verifies actual 64 logical CPUs, 32 cores, at least 500 GiB physical RAM, NUMA,
   preserved private identity and enough available RAM for remaining Off guests plus
   a 64 GiB host floor. It rechecks before each Start-VM. A model label is insufficient.
7. Independently observe all four target profiles, three Up nodes, 24 Healthy/OK
   devices, four accessible Online CSVs, five Healthy three-copy mirrors, no jobs and
   the global infrastructure VM restored by cluster lifecycle. Final completion has
   its own durable source/process/snapshot certificate and settlement.

The whole-cluster route checks all 24 device IDs, sizes and Healthy/OK states without
the expensive physical-owner scan required for serial node maintenance. No device
ownership is inferred. The initial over-budget read remains retained as a timeout.

No serial drain, Resume, storage maintenance enable/disable, storage-tier change or
automatic schedule change is part of this route. The
[Stop-Cluster reference](https://learn.microsoft.com/en-us/powershell/module/failoverclusters/stop-cluster?view=windowsserver2025-ps)
documents stopping Cluster service on every node and all clustered services/applications,
`-Force` confirmation suppression, and `-Wait 0` request/observe separation. The
[Stop-VM reference](https://learn.microsoft.com/en-us/powershell/module/hyper-v/stop-vm?view=windowsserver2025-ps)
documents guest-OS shutdown as the ordinary operation, distinguishes forced shutdown
and power-off data-loss semantics, and provides no reason to add those switches here. The
[storage maintenance procedure](https://learn.microsoft.com/en-us/previous-versions/azure/azure-local/manage/maintain-servers)
documents strict Healthy/OK checks and waiting for all storage repair before further
maintenance. Its single-node automatic-maintenance assumption is not used here.
### Four outer guests versus one nested infrastructure VM

The four resized/outer guests (three HCI plus DC) must be **Off**, never Saved, before
any profile change or outer deallocation. The internal infrastructure VM stays 4 CPU/
8 GiB and is not resized. Its saved state is valid under the unchanged cluster Save
policy. That state does not imply storage health, accessible CSVs or safe partial-node
maintenance. Whole-cluster stop and all-four-outer-guests-Off proofs remain separate.

The [OfflineAction property reference](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/mscs/virtual-machines-offlineaction)
documents 1 (default) as Save, 2 as guest OS shutdown, 0 as TurnOff and 3 as forced
shutdown. The [Windows Server 2025 Move-ClusterVirtualMachineRole reference](https://learn.microsoft.com/en-us/powershell/module/failoverclusters/move-clustervirtualmachinerole?view=windowsserver2025-ps)
also describes Save (1) in quick migration. No default is inferred when metadata is
missing. Read-only Get-ClusterParameter captures OfflineAction bound to the exact
VmID and stable cluster resource ID. Get-VMIntegrationService captures the nested VM's
shutdown Enabled setting. Reads expose unsupported/unknown values so root can report
them. Prepare, validate and initial dispatch reject missing/unknown policy, forced 0/3,
or shutdown policy 2 without enabled shutdown integration **before any stop intent**.
No persistent policy write or unsupported next-offline control API is used.

Baseline and final clusterStatic preserve the same resource ID/VmID/OfflineAction and
nested integration setting. Final acceptance still requires that exact global VM
Running and its original cluster VM resource Online, restored by cluster lifecycle.
Saved-to-Running is lifecycle resume of preserved state, not an individual guessed
restart. Failure to restore is a concrete blocker, not authority to recreate the VM,
discard its saved state, force shutdown or change integration/power policies.

## Durable failure and restoration boundaries

The vetted shared immutable ledger, remote worker/event/request identity, UTC PID/start
comparison, depth-40/2 MiB JSON writers, source/plan/writer fences and 90-second transport
remain. Unknown or timed-out effects block every new key and canonical startup. Closing
SSH, a stale PID, model-only readback or marker reset does not settle an operation.

A proved capacity refusal before any guest RPC records a consumed handover and exact
remote phase. Root may independently reconcile that known no-guest outcome while all
four guests remain Off. Partial/unknown guest RPC is never treated as that refusal.
Allocation failure leaves guests Off. There is no automatic downsize or unsafe autostart.

`restore-*` branches restore only original 8/64 guest profiles, separately and while all
four guests are Off, after original effects are fully settled. Each needs a separate,
fresh, exact direct-human restoration directive bound to the original plan/source/key.
The main hardware instruction does not manufacture that directive. No host downsize or
E32 startup is included in restoration. A target-profile grant cannot be reused after
restoring profiles. Unknown startup effects must first be explicitly reconciled.

## Offline checks and operator handoff

`read` is a guarded read-only snapshot route. `prepare` turns fresh source-bound reads
into an unsigned stdout candidate. `preview` renders a disabled unsigned technical
candidate without manufacturing approval. Root must record actual quiescence, human authority
and independent review and publish the exact sealed direct plan before `dispatch`.
`observe` uses fresh native original request/worker hashes, PID/start/phase plus full
snapshot and cloud model readback. `settle`, `handover`, `converge` and `finish` validate
exact original evidence and do not blindly replay anything. The private/canonical
transport selects only the hardcoded R2 or direct route, never an arbitrary module path.
Azure deallocation/size observation is an explicit GET-only controller path, not a
guest worker lookup. No mutable Azure request is issued by an observer.

No operational command was run by the implementation worker. Root owns live effects.
Boot encryption, audit delivery and independently verified recovery remain open.
Initial AKS 24/88 and maintenance 32/120 are engineering allocations, not demonstrated
current image/workload capacity. N-1 plus surge is not admitted.
