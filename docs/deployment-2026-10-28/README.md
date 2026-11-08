# LocalBox bootstrap continuation, 28 October 2026

## Approved three-node change is executing, 29 October

The exact three-node plan is approved. The additional 2 TiB Premium SSD is attached
and verified as W:. NODE1/NODE2 are now 64 GiB / 8 vCPUs with original identities,
bootstrap success and data IDs preserved. The single approved VHD move is verified.
The DC, shared networking, public-access/Shared Key settings and original V: pool
were not changed. NODE3's protected one-shot build completed with task result 0,
cleanup and common credential login verified. All four guests are Running and the
new daily startup includes NODE3's actual VM ID. Its human-auth console is installed,
not invoked. Follow the [NODE3 authentication handoff](../deployment-2026-10-29/node03-authentication-handoff.md).
The cluster is not deployed. See [execution evidence and remaining gates](../deployment-2026-10-29/three-node-execution.md).

## Existing disks converted to Premium SSD, 29 October

The owner's explicit Premium SSD request has been applied to **all nine existing
managed disks**. Their Azure IDs, unique IDs, sizes and encryption metadata were
preserved. The host and the original three guests are running, V: and its existing
pool are healthy, both local bootstrap statuses are Succeeded, and the Arc services
are Running with unchanged Connected cloud identities. Early delayed-auto-start
observations and both earlier CLI/startup observer failures are retained, not
rewritten as successful attempts. See
`../deployment-2026-10-29/premium-disk-conversion-reconciled-result.json`.

At the end of the Premium-only phase, no additional disk, guest resize, NODE3,
witness change or cluster deployment had been applied. The immutable
[three-node proposal](../deployment-2026-10-29/three-node-proposal.md) was subsequently
approved in `../deployment-2026-10-29/three-node-approval.json`. Its storage/resize
effects have since been applied as recorded at the top of this document. It retains
the E32 host, specifies 64 GiB / 8 vCPUs per node, an additional 2 TiB Premium SSD
and a single identified blank VHD move.
That new disk is an additional public retail capacity reference of USD315.60/month,
excluding other applicable charges. Existing nine-disk Premium capacity is
USD535.14/month, not a contract quote or total platform cost.

## Historical two-node deployment stop, 29 October

The final node/storage/AD inspection passed. The two-node deployment was blocked by
the **Cloud Witness authentication design**, not by the private vault. The
witness rejects key-authenticated requests with `KeyBasedAuthenticationNotPermitted`,
and the owner confirmed Shared Key will not be permitted by policy. No enable,
exemption, credential upload, cluster creation or No Witness substitution was
attempted. The approved three-node change now removes that dependency, but NODE3
and service Validate/Deploy remain incomplete. See
[historical evidence](../deployment-2026-10-29/cluster-deployment-status.md) and the
current execution record linked above.

## 29 October: both Arc nodes verified, scoped platform roles applied

Both node bootstrap statuses are independently verified **Succeeded** and both Arc
machines **Connected**, with expected West Europe location and separate inspected
managed identities. NODE2's guarded fresh-auth recovery fixed yesterday's confirmed
machine-write authorisation denial. Seven approved RG/vault role bindings were
applied and read back at 09:18 SAST. The vault remains private. See
[recovery and role evidence](../deployment-2026-10-29/arc-registration-recovery.md).
Do not register either node again or delete historical failure markers. Cluster
Validate/Deploy and full platform acceptance have **not** completed.

## Current progress: private ARM secret path verified

The public-vault assumption has now been tested rather than treated as an absolute
deployment blocker. With PNA **Disabled**, a modern ARM secret-child write succeeded
and authenticated private readback matched the exact harmless marker through
`10.200.17.11`. The owned probe was soft-deleted, not purged. See
`private-vault-flow-probe.json`. No real deployment credential was used as a probe,
no owner ARM token forwarded, no public toggle, tag or exemption.

Initial private metadata access reached Key Vault but returned `ForbiddenByRbac`.
The explicitly approved conditional **Secrets Officer** grant was applied only at
the new vault for the existing deployer, then private authenticated access passed.
The original pre-apply what-if refusal is retained: unchanged `Ignore` resources
and omitted principal-type metadata were reconciled without permitting extra
effects. The actual created assignment's identity/type/scope were read back.

This verifies the ARM secret-publication/private-operator path, not full Azure Local
RP deployment. That later step must be tested with actual Arc managed identities.
Proceed privately. The next human step is the normal device-code/MFA sign-in via
the reviewed [private-console launcher](arc-authentication-handoff.md). Installing
the launcher does not itself register a node, capture authentication output or
resume a recurring job.

At **15:26 SAST**, guest checks confirmed all **nine** normal DNS/TLS paths (three
platform endpoints from DC and both nodes). Vault returned unauthenticated `404`,
both Blob roots `400`, all at the expected private IPs. No hostname override or
TLS bypass. This is separate from the authenticated operator/ARM probe above.

The reviewed human console package was installed and hash-verified at **15:25 SAST**,
status `installed-not-invoked`. No node registration has been claimed. The next
required action is the owner's normal device-code/MFA sign-in from a real TTY using
`scripts/register-smal-node-console.py`; output is deliberately not captured by
the agent. See `arc-authentication-handoff.md` for exact commands and interruption
handling. This is not a request for another generic approval or an owner-token
export. Installed/source evidence:
`../deployment-2026-10-27/private-ssh-install-arc-console-20261028.json` and
`../deployment-2026-10-27/private-ssh-guest-platform-private-path-20261028.json`.

## Historical stop: unproven public-vault assumption and enforced policy

**Network completion/wording correction:** Entlz completed the private endpoints
at 14:06 SAST. Their approved connections, owned DNS records and deployment-host
private DNS/TLS are verified. See `platform-network-result.json`. The remaining
question is the Azure-hosted RP/selected ARM secret flow, not missing private
networking. Microsoft's public-access note is explicit, but private-only deployment
failure has not been demonstrated here. Keep the vault private while checking that
specific path, rather than treating the note as proof public access is unavoidable.

**The approved cloud prerequisite deployment succeeded, but its independent
configuration guard stopped further platform apply.** The new vault is public
access **Disabled**, despite the approved template/preview requesting Enabled.
Activity Log proves tenant-root `MCAPSGovDeployPolicies` /
`KeyVault_PublicNetwork_Modify` replaced that field during the deployment.
Microsoft's current deployment-vault guidance requires public access during RP
secret configuration. See
[`deployment-blocker-vault-policy.md`](deployment-blocker-vault-policy.md) and
`platform-policy-conflict-reconciled.json`.

Created/retained: `rg-localbox-platform-weu-1`, `kv-lbox-weu-4766ea`, private
diagnostic/witness Standard LRS accounts, enabled vault AuditEvent export,
90-day scoped audit lifecycle and diagnostic-account CanNotDelete lock. RBAC,
purge protection and 90-day vault recovery were independently verified.
No keys/secrets uploaded, role assignments created, Arc onboarding, S2D, bridge,
custom location or workload started by this deployment.

The original prerequisite receipt retains both Azure `Succeeded` and the wrapper's
failed boundary check. **Do not recreate the services or re-enable public access.**
No exemption/ignore tag, older-API evasion, unapproved perimeter or privilege
activation was attempted. Product/governance compatibility must be resolved before
the irreversible node registration step. Normal host/new-resource charges continue.

Entlz has factual target readiness for the approved three private endpoints and
existing-zone DNS path. Its optional public-host vault FQDN admission is explicitly
held because host public-path necessity is unproven. That private network subtask
does not resolve the public RP path or authorise a policy bypass.

## Continuing toward registration

The reviewed owner decision is now concrete:
[`cloud-apply-proposal.md`](cloud-apply-proposal.md) and its exact JSON effect list.
Quintin answered **Approve staged plan**. The immutable proposal hashes and exact
accepted/excluded effects are recorded in `cloud-apply-approval.json`. This is not
an unrestricted cloud/RBAC/network grant. New resource names were available when checked,
the new platform RG was absent, first-party RP/role IDs were inspected and no
application/role/provider/resource was created by these reads.

Entlz's separate bounded platform network task/execution is
`task_localbox_platform_network_20261028` / `exec_localbox_platform_network_20261028`.
It may prepare now, but private-endpoint apply waits for the underlying platform
vault/storage to exist and coordinator readiness. No new central zone/link outside
the enumerated effect list is assumed. The terminal main task was not reopened.

The next applies are source-gated: exactly one new platform RG, and the approved
local OU/common-node-credential preparation. The latter preserves domain password
policy/expiry, uses no third-party AD module, refuses existing object conflicts,
and commits each node's new credential binding only after its new login is verified.
Existing node-specific encrypted roles are retained as inactive history after
convergence, not overwritten with a common value. Any partial failure is inspected,
never resolved by replaying the whole preparation or deleting AD objects.

At **13:42:31 SAST**, approved local cluster preparation succeeded: new protected
parent/cluster OUs, `lboxdeploy` with exactly the three scoped AD ACEs, normal
account expiry, no domain password-policy change and no enforced-GPO bypass.
Both nodes accepted the fresh cluster-only admin secret and verified new logins.
The public per-node credential binding was committed only after each verification,
so subsequent observers do not try obsolete node-specific credentials.

The first one-RG cloud preview wrapper failed JSON decoding before a preview hash
or apply request was recorded. Independent reads confirmed the RG absent and the
stable deployment name absent. The CLI's what-if path needs `--no-pretty-print` for
machine JSON. A separate guarded reconciliation receipt keeps the same Azure
deployment identity, retains the original failed receipt and rechecks absence
before any create. No broad retry or RG overwrite is permitted.

Fresh guest inspection at **13:06 SAST** verified both installed HCI OS builds
`26100.33650`, standalone nodes, zero S2D pools and exactly four RAW 170 GiB data
disks per node. The supported built-in `AzureEdgeBootstrap` module is version
`1.0.0` on both, manifest SHA-256
`70B11110F8483898A5CB3667A92F26315361847437832826C58DE53320746F0F`, with explicit
`TargetSolutionVersion` support. It was inspected, not invoked for registration.
The DC is `26100.32230`, still in Evaluation grace, not yet activation-verified.
Node OS licence status `1` does **not** establish Azure Local service registration
or approve subsequent platform charges.

Subsequent accepted Evaluation activation succeeded. Independent read-only
inspection at **13:24 SAST** found DC licence status `1` (Licensed), 259,199 minutes
of evaluation remaining, no product-key change or paid licence purchase. The first
activation wrapper treated the provider's void return as inconclusive despite
observing status `1`; its original receipt and pending marker are retained. The
void-result interpretation was fixed, and activation was **not repeated**.
See `../deployment-2026-10-27/private-ssh-dc-evaluation-activation-20261028.json` and
`../deployment-2026-10-27/private-ssh-guest-readiness-after-eval-activation-20261028.json`.
Update applicability remains unassessed. No generic Windows Update installation
was attempted on the pinned HCI nodes.

The current upstream template and optional AD helper are pinned and audited in
[`registration-source-review.md`](registration-source-review.md). Neither was
executed. Mixed-release rendered documentation incorrectly exposed the old ARB
app/secret prerequisite. Source monikers exclude it for 2610, so no new Entra app is
proposed. Common node credentials, scoped OU/GPO preparation, deployment-vault
public access, precise RBAC, metered costs and diagnostic exports are explicit
remaining decisions, not assumed by the previous local bootstrap approval.

The single-page scraper again reported above-cap credits, including one parallel
response. All captures are retained in `spider-single-page-budget-observation.json`.
Further Spider calls were stopped. Public GitHub/blob and Retail Prices JSON API
reads were used afterwards. No tool-reported credit figure is a currency invoice.

## Latest verified result, 12:08 SAST

**Approved local guest bootstrap finished successfully at 12:07:07 SAST, task result
`0`, independently observed at 12:08:47 SAST.** See `local-bootstrap-result.json`.
All three guests are running, selected DNS/HTTPS/NTP/NAT checks passed, both nested
Hyper-V services are operational, both node clocks match the host within 0.02
seconds, and all three new-credential logins were verified after cleanup/rotation.
No setup-file/log review flags remain. No manual clock override or cron restart.

**This is local preparation, not Azure Local cluster deployment.** Arc registration,
S2D, resource bridge, custom location and AKS remain undeployed. Guest update and
Evaluation activation checks, versioned AD deployment prerequisites and the exact
cloud plan/remaining approvals are still pending. Current compute charges continue.

The following bullets retain the recovery chain rather than rewriting failed
attempts as successful history.

Cloud prerequisite readback at **12:14 SAST** rechecked the same approved principal
and tenant/subscription and confirmed all 13 provider namespaces named by the
retained permission guide are already **Registered**. No registration was applied.
The first observation's `Microsoft.Insights: not-returned` was a namespace-display
case bug (`microsoft.insights`), not proof of non-registration. The corrected receipt
is `cloud-prerequisite-observation-reconciled-20261028.json`; the first receipt is
retained. Eight inherited policy identities were refreshed. Actual policy effects,
effective required data-plane roles and cloud admission remain unverified.

- The approved storage job is **storage-complete**, task result `0`. Independent
  readback at 09:49 SAST found Healthy NTFS V: at **2,181,825,495,040 bytes**.
  The worker verified the C: boot identity and partition unchanged.
- Original launch failure, timeout, marker, worker and state backups remain retained.
  The corrected resume used exact-byte-length, SHA-256-verified stdin. Only the two
  exactly identified orphan transport processes were stopped. No storage replay ran.
- Entlz applied the approved `*.microsoft.com` HTTPS rule for `10.200.16.0/24`.
  Host HEAD at 09:51 SAST returned **200**, exact expected **8,152,356,864 bytes**
  and ETag for the approved Evaluation ISO. This proves that specific host request,
  not a download, nested egress or platform readiness.
- Three nested VMs have now been created. Domain readiness, registration,
  resource bridge, custom location, AKS and workloads are **not established** by
  the current observations.
- Relay's main task reads `done`, revision `13`, updated `2026-10-28T05:55:03.338Z`.
  Complete comment traversal contains no closure explanation. This conflicts with
  actual readiness. No cause is inferred and no task was reopened or redispatched.
- The cancelled cron remains off. The storage job has no recurring trigger.
- The approved Evaluation-media one-shot task is **media-downloaded**, task result
  `0`, independently read at 09:56 SAST. Final length is **8,152,356,864 bytes**,
  no partial file remains, and the worker's measured SHA-256 is
  `7B052573BA7894C9924E3E87BA732CCD354D18CB75A883EFA9B900EA125BFD51`.
  No publisher SHA-256 was supplied. The ISO remains unmounted/unexecuted at
  `C:\ProgramData\AzureLocalBox\Bootstrap\eval-media-20261028-01\WindowsServer2025Evaluation.26100.32230.x64.en-us.iso`.
- One observation timed out before SSH authentication. Its failure receipt remains
  intact. Independent Azure readback showed Running/agent Ready and the VPN route
  remained on tun0. A new read-only observation succeeded. The download task was
  neither restarted nor reinstalled.
- Owner subsequently approved the exact local guest proposal and its explicit
  DPAPI/temporary-answer-file secret boundary. Consent is bound to the proposal
  SHA-256 in `deployment-decisions.json`. Do not request the same consent again.
- Local network apply succeeded at **10:13:53 SAST**, independently read at
  **10:14:21 SAST**: Internal switch `LB-Fabric`, ID
  `995f5a7a-d229-4ca0-bb2a-9b34529c6934`, gateway `10.64.0.1/24`, exactly one
  WinNAT object `LB-NAT`, selector `10.64.0.0/20`. Outer `10.200.16.4`, default
  gateway `10.200.16.1` and DNS `10.204.0.4` are unchanged. No external switch,
  Azure network write or NIC-forwarding change. Guest traffic remains untested.
- Initial synchronous input inspection timed out without attached media or DISM
  processes. Only its exact two orphan PowerShell processes were stopped after
  identity/creation-time checks. Separate durable one-shot inspection
  `LocalBox-GuestInputs-20261028-02` now records phases independently of SSH.
  At 10:14 SAST it was still checking the Azure Local ISO hash. Do not equate this
  running phase with image inspection success or rerun it without reconciliation.
- The read-only hash phase was subsequently restarted under its exact guarded
  recovery, retaining the original worker/state/marker. One-MiB sequential reads
  replace the observed small-read pattern. Both ISO checks completed successfully.
  Inspection finished **10:29:16 SAST**, task result `0`, independently read at
  **10:31:50 SAST**, no remaining worker process. Both ISO mounts were released.
- Azure Local WIM index `1`: `ServerAzureStackHCICor`, Server Core, x64, actual
  **10.0.26100.33650**. Evaluation WIM index `1`: `ServerStandardEval`, Server Core,
  x64, actual **10.0.26100.32230**. Both setup executables and EFI bootloaders have
  **Valid Microsoft signatures**. The Evaluation full-file hash remains measured,
  not a publisher-provided checksum.
- Installed Hyper-V, DISM, HgsClient and PowerShell Direct cmdlet availability and
  helper parameter names were inspected on the actual host. Offline tests cover
  exact bundle rendering, source pins, consent hash, metadata selection, new-VHD
  identity guards, synthetic secret/XML handling and no import-time side effects.
  These are not a completed guest boot or domain integration test.
- The image/VM task finished successfully at **11:11:03 SAST**, task result `0`.
  All three OS images and Gen2/Secure Boot/vTPM VM definitions were verified.
  Node data VHDXs are created, not an S2D pool. The provisioning snapshot's zero
  dynamic MACs were captured while the VMs were off, not a live MAC mapping.
- The independently installed local continuation is running. It reconciled that
  exact successful image task, started `LB-DC01` and was waiting for completed
  Windows setup/PowerShell Direct at **11:12:29 SAST**. Its timer heartbeat was
  current. The two nodes remained off until the DC stage completes. No Azure
  registration is included in this job. The cancelled cron remains off.
- At **11:16:04 SAST**, continuation readback showed a guarded failure at
  `LB-DC01-configure-exact-guest-network`, `RemoteException`, source line `35`,
  task result `1`. Windows setup and the initial PowerShell Direct session passed
  before that call. No forest/rotation/nested-connectivity success is claimed.
  The task stopped itself; DC remains running and nodes remain off. Preserve the
  original attempt and inspect exact guest identity/protection/adapter state before
  any network-only resume. Do not replay images, guest creation or V: formatting.
- Read-only guest inspection at **11:20:02 SAST** confirmed `IMAGE_STATE_COMPLETE`,
  correct DC/MAC identity, active Defender, all profiles enabled, only APIPA/loopback
  IPv4, no default route, standalone domain role `2` and no NTDS service. This does
  not establish which guard failed during the earlier attempt. The prepared
  recovery validates that exact no-network/no-directory state again, preserves
  worker/bundle/helper/state backups and the original marker, and resumes only
  the running DC's network phase. It adds a bounded read-only protection-readiness
  wait without changing Defender or firewall settings. Future failures record only
  known public guard codes or a restricted error identifier, never raw messages.
- The guarded resume succeeded without image/VM recreation. At **11:38:27 SAST**,
  `ad.localbox.test` / `LOCALBOX` existed with Windows Server 2016 forest/domain
  functional levels. DC DNS forwards to `10.204.0.4`; protection remains enabled.
  Domain SRV and normal/TCP private DNS passed, public HTTPS returned `200`, the
  private vault root returned unauthenticated `404` and matched NTP passed.
- Actual DC WinNAT sessions demonstrate `10.64.0.10` translated to `10.200.16.4`
  for central DNS `10.204.0.4:53`, private vault `10.200.17.4:443`, public HTTPS and
  NTP. Historical root-server DNS **attempt** sessions also appear from before
  forwarding was configured; their presence does not establish allowed replies.
- The DC's owned answer file was removed, its bootstrap credential rotated and a
  new-credential login verified. Setup-log inspection found no old-value match.
  No secure-erasure claim. Node 1 has now started and is completing setup/session
  readiness. Node 2 remains off until the preceding node stage completes.
- At **11:45:26 SAST**, node 1 had completed setup, management networking and nested
  Hyper-V verification: 12 logical processors, **6 guest-reported cores**, about
  96 GiB, VMMS running, Defender/firewalls enabled. Domain/private DNS, public/private
  HTTPS, NTP responses and observed source translation passed from that node too.
  This core report is not an authoritative Azure Local billing assessment.
- The continuation then stopped at node 1's answer-file/credential cleanup with
  `IOException`, task result `1`. Its credential rotation is **not confirmed** and
  node 2 remains off. Inspect exact setup-file readability/ownership and account
  state before a cleanup-only resume. Do not replay the forest, images or VMs.
- Node 1's recorded UTC timestamp was two hours behind the host. A matched NTP
  response did not establish clock synchronisation, as already flagged in state.
  Reconcile the actual clock/time service before registration or a domain join.
- At **11:52:35 SAST**, read-only node inspection verified the original bootstrap
  login still works, no answer XML remains in the inspected setup locations, and
  the sampled setup logs are readable and contain no old value. No current lock
  was reproduced, so do not claim a proven historical sharing-violation cause.
  The node clock now matches host UTC, Windows Time is running and its source is
  `time.windows.com,0x8`. No manual adjustment was made by the inspection.
- The prepared cleanup-only continuation preserves the successful DC and node 1
  state, skips their creation/boot/network/role phases, and only finishes node 1
  cleanup/rotation before proceeding to node 2. Shared read handles tolerate active
  setup-log writers. Unreadable/unclean files remain explicit review gates, never a
  clean-result claim. Both nodes also get a bounded read-only UTC/source check.
- At **12:01:48 SAST**, the cleanup-only resume had retained the DC proof, finished
  node 1 cleanup/rotation and verified its new-credential login. There were no
  unreadable setup files or remaining answer-file/log review flags. Its existing
  answer file was already removed during the previous attempt, so the resumed
  removal count correctly remains `0`, not another fabricated deletion.
- Node 1's clock/source check passed, observed offset about **-0.015 seconds**,
  Windows Time running with `time.windows.com,0x8`, no manual clock change. Its
  repeated selected transport and source-translation checks passed. Node 2 is now
  running and completing initial setup/PowerShell Direct readiness. Azure Local
  registration/deployment remains excluded, not silently queued.

| Guest | VM ID | Memory | vCPU | State at 12:08 SAST |
|---|---|---:|---:|---|
| `LB-DC01` | `f94c71f1-6854-48b9-a9f1-8238c99366d0` | 4 GiB | 2 | Running, domain/DNS and selected transport checks passed |
| `LB-NODE01` | `3adff629-2f67-449b-ab32-8a8748c46f34` | 96 GiB | 12 | Running, selected checks/cleanup/clock/new login passed |
| `LB-NODE02` | `12a44e0c-cc08-4c4c-a812-fa0b56efdbc3` | 96 GiB | 12 | Running, selected checks/cleanup/clock/new login passed |

Current receipts:

- `../deployment-2026-10-27/private-ssh-storage-worker-recovery-framed-20261028.json`
- `../deployment-2026-10-27/private-ssh-storage-job-progress-20261028-02.json`
- `../deployment-2026-10-27/private-ssh-eval-media-access-post-wildcard-20261028.json`
- `../deployment-2026-10-27/private-ssh-eval-media-job-start-20261028.json`
- `../deployment-2026-10-27/private-ssh-eval-media-job-final-observation-20261028.json`
- `../deployment-2026-10-27/private-ssh-local-network-apply-20261028.json`
- `../deployment-2026-10-27/private-ssh-local-network-readback-20261028.json`
- `../deployment-2026-10-27/private-ssh-guest-input-inspection-complete-20261028.json`
- `../deployment-2026-10-27/private-ssh-guest-cmdlet-inventory-reconciled-20261028.json`
- `../deployment-2026-10-27/private-ssh-guest-image-job-progress-20261028-05.json`
- `../deployment-2026-10-27/private-ssh-guest-bootstrap-job-start-20261028.json`
- `../deployment-2026-10-27/private-ssh-guest-bootstrap-job-progress-20261028-02.json`
- `../deployment-2026-10-27/private-ssh-guest-bootstrap-job-progress-20261028-03.json`
- `../deployment-2026-10-27/private-ssh-guest-bootstrap-network-failure-inspection-20261028.json`
- `../deployment-2026-10-27/private-ssh-guest-bootstrap-network-recovery-20261028.json`
- `../deployment-2026-10-27/private-ssh-guest-bootstrap-network-recovery-progress-20261028-03.json`
- `../deployment-2026-10-27/private-ssh-guest-bootstrap-network-recovery-progress-20261028-04.json`
- `../deployment-2026-10-27/private-ssh-node01-cleanup-failure-inspection-20261028.json`
- `../deployment-2026-10-27/private-ssh-node01-cleanup-recovery-20261028.json`
- `../deployment-2026-10-27/private-ssh-node-cleanup-recovery-progress-20261028-01.json`
- `../deployment-2026-10-27/private-ssh-node-cleanup-recovery-progress-20261028-03.json`

## Verified starting state and recovery

The following starting-state inventory predates the completed storage job.

- Relay has no active execution/obligations in this chat. The old ten-minute cron
  is cancelled at revision 2 and is not being restarted.
- The deployment host's VPN profile claimed Active but had no resolver tunnel route.
  One reconnect of the existing `entlz-san-cert` profile restored actual `tun0`
  routing and TCP 53 reachability to `10.204.0.4`. No profile/key changes occurred.
- The Azure VM was deallocated overnight by principal
  `da847d8c-ee71-44de-b462-6775e7d649a7`, successful at `2026-10-27T22:48:16Z`.
  That caller's governance/operating purpose was not inferred from its ID.
- The first start attempt was denied with `AuthorizationFailed`. Original failure
  and independent deallocated readback were retained. Quintin then reported
  **Approved access restored**. One reconciled start succeeded. No role activation,
  role assignment or shutdown-control change was made by the agent.
- Private Bastion key-only administration was freshly verified after startup.
  VMMS and Defender are active, no nested VM/switch/NAT or LocalBox task exists at
  that observation, and the 2610 ISO remains unattached.

Receipts: `host-start-action.json`, `host-start-after-access-restored.json`, and
`../deployment-2026-10-27/private-ssh-nvme-inventory-started-20261028.json`.

## Exact NVMe disk identities

The host uses NVMe, not SCSI. The
[official remote NVMe FAQ](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-remote-faqs)
documents Windows `SCSILogicalUnit = Azure LUN + 1` for the observed
`Virtual_Disk NVMe Premium` model. The captured single-controller profile has data
namespaces 1–8 corresponding to Azure LUNs 0–7.

`map-smal-nvme-disks.py` verifies that correlation and exact agreement between
Storage/Win32/PhysicalDisk unique IDs, serials, sizes and poolability. It rejects
boot/system/non-RAW/offline/read-only disks, ambiguous identities and other controller
profiles. Windows disk numbers are recorded for diagnostics, never the selection key.
The resulting eight identities are in `nvme-data-disk-map.json`.

## Explicit local decisions

Quintin selected **Simple 2 TiB (Recommended)**, approved the bounded Entlz network
review delegation and accepted current Windows Server 2025 Evaluation media/terms
for management/domain infrastructure. See `deployment-decisions.json`. These
decisions do not approve new cloud-role grants, cloud costs or unreviewed shared
network changes. The OS disk is excluded from storage formatting.

## Real asynchronous storage phase

The committed worker/installer/readback scripts implement only the approved storage
phase. They do not claim to implement or complete the remaining cluster bootstrap.

- One Windows task: `LocalBox-Storage-20261028-01`, SYSTEM, no stored password,
  no recurring or logon/startup trigger, no automatic retry, IgnoreNew overlap policy.
- State: `C:\ProgramData\AzureLocalBox\Bootstrap\storage-20261028-01\state.json`.
- Independent .NET timer heartbeat: `heartbeat.json`, every 15 seconds while executing.
- Sanitised phase events: `events.jsonl`. No transcript rewriting or secret logging.
- Installer checks source/manifest hashes, preserves existing tasks/directories and
  refuses policy bypass. Administrator/SYSTEM ACLs protect the owned run directory.
- Worker checks actual Azure VM resource ID through metadata, exact private IP,
  Defender, all eight NVMe/physical identities and current RAW/poolable state before
  any mutation. It excludes the C: boot disk and requires V: and owned pool/VD names
  to be absent.
- Only those eight physical disks are supplied to the new Simple pool. The worker
  creates its own fixed virtual disk and initialises/formats only that returned disk,
  never a wildcard disk set. Final checks bind pool membership, V: NTFS health/size
  and unchanged C: partition/boot identity.
- Every mutating phase has a durable pre-operation checkpoint. A started marker and
  mutex fence repeated execution. A failure is **inspect-before-resume**, not an
  invitation to delete the marker or replay formatting.

The installer ACK is not storage success. Use the actual worker/readback receipt to
establish the result:

```bash
python3 -B scripts/smal-private-powershell.py \
  --script scripts/read-smal-storage-job.ps1 \
  --receipt your-new-storage-observation
```

No nested VM creation, network application, ISO mounting/execution, domain secret
generation or cloud registration belongs to this storage-only job.

## Network and media review

The separately assigned read-only Entlz review completed. Its report/evidence hashes
match the returned result. It found no overlap in the inspected estate, but explicitly
retained candidate/unreserved status and required concrete routing/NAT/DNS corrections.
See `network-review-receipt.json` and the linked report. No permission to apply the
old draft is inferred from that review.

The official Evaluation Center currently links a January 2026 Windows Server 2025 ISO
and an older 2024 VHDX. Prefer the newer ISO, not the old VHDX. The evaluation is 180
days and requires online activation in the first 10 days. Metadata is retained in
`windows-server-eval-metadata.json`; no publisher SHA-256 was supplied by that page.
Do not mislabel a measured/first-seen hash as a publisher checksum.

`start-smal-eval-media-job.ps1` and `smal-eval-media-worker.ps1` implement the approved
**download-only** continuation. The installer refuses an existing job, requires exact
committed/pushed source and explicit recorded media/terms approval, deploys to an
Administrator/SYSTEM-only directory, and starts one SYSTEM task with no trigger/retry.
The worker checks host/IMDS identity, Defender, free space and exact manifest hash,
uses normal TLS and `If-Match`, rejects redirects and ETag/length drift, and retains
partial bytes and the original marker on failure. State records progress every 15
seconds while bytes arrive. A blocked read can make this older, so also inspect task
state and file length rather than treating it as an independent heartbeat.

On success the file stays in the owned job directory, **unmounted and unexecuted**.
Its measured SHA-256 is provenance, not publisher authentication. No guest answer
file, credential, domain, VM or cloud registration is created by this task.

```bash
python3 -B scripts/smal-private-powershell.py \
  --script scripts/read-smal-eval-media-job.ps1 \
  --receipt your-new-eval-media-observation
```

The link-extraction tool unexpectedly traversed beyond the requested page despite the
budget cap. That path was stopped, its reported credits retained in
`spider-links-budget-incident.json`, and the user informed. A subsequent single-page
HTML read resolved the exact links without another crawl. No user secrets were sent.

The remaining local guest/network/credential implementation and exact registration
scope/cost/export decisions still need completion before a full deployment claim.

The [owner-approved local guest proposal](local-guest-apply-proposal.md) defines the
proposed two-node/DC resource budget, initial single-switch management topology,
one NAT selector, domain DNS and temporary-secret/DPAPI boundary. Its original
proposed wording is retained byte-for-byte to preserve the consent hash. The
local network is now applied. Guest/domain orchestration is still unfinished.
Future AKS/pod/service networks remain unused.

## Bounded image and VM phase

`start-smal-guest-image-job.ps1` packages a three-library bundle from exact pushed
source. It refuses an existing attempt and requires recorded guest/secret consent
and the completed media inspection. `smal-guest-image-worker.ps1` checks live
identity, network, volume health/free-space budget and source integrity before
creating anything. It creates a new protected guest root on V: and per-role
host-bound DPAPI secrets, applies only the selected WIM indices to **newly created
VHDX files**, and formats only disks returned by its own VHD attachment. BCDBoot's
explicit `/s` targets only each new virtual EFI partition.

The worker checks the media hashes again with buffered reads, uses read-only ISO
mounts, preserves partial state/objects on failure, and creates the selected three
Gen2/Secure Boot/vTPM VMs with automatic starts/checkpoints disabled. The two nodes
get their four 170 GiB data VHDXs. This bounded phase deliberately leaves all three
guests **OFF**. Guest boot, PowerShell Direct configuration, AD/DNS, answer-file
cleanup/rotation and registration gates remain distinct. Do not claim a ready
domain or Azure Local cluster from image/VM creation.

```bash
python3 -B scripts/smal-private-powershell.py \
  --script scripts/read-smal-guest-image-job.ps1 \
  --receipt your-new-guest-image-observation
```

## Local boot and domain continuation

`start-smal-guest-bootstrap-job.ps1` installs a second bounded one-shot job, not a
cron or another model execution. It waits for the **exact pinned image worker** to
finish successfully with the three VMs off. A failed/stopped/drifted dependency
blocks guest boot. It never reinstalls or restarts the image task.

The continuation is limited to the approved local work:

- Start only the recorded VM IDs after security and host-memory admission checks.
- Wait for completed Windows setup and use immediate-host PowerShell Direct with
  per-guest credentials. Authentication failures stop rather than repeatedly
  testing a credential until an account locks.
- Bind guest NIC names to exact Hyper-V MACs, apply the accepted management
  addresses/DNS and leave storage adapters without a gateway or DNS registration.
- Create the new AD forest with Windows Server 2016 functional levels, normal
  password policy, AD DNS forwarding only to `10.204.0.4` and the selected DC time
  peer. Reboot only that new DC as required, then verify changed boot identity.
- Verify/install nested Hyper-V on the two nodes and perform required guest-only
  reboots. Nodes remain **standalone**, not domain-joined ahead of the versioned
  Azure Local deployment workflow.
- Test domain SRV, normal/TCP private DNS, public/private HTTPS HEAD and matched NTP
  responses from each guest. Capture actual WinNAT source-session evidence. These
  checks do not prove authenticated PaaS access, clock synchronisation, WebSockets,
  image pulls, AKS or platform readiness.
- Remove only answer-file copies attributable to this run/value, rotate the initial
  credential and prove a new credential login. Inspect setup logs for the old value
  without rewriting history. Any match remains a review gate even after rotation.
- Record task/phase state, append-only public events and an independent 15-second
  timer heartbeat. Failures retain markers/objects for inspection, not blind replay.

**It never registers an Azure resource, forwards an ARM token, creates Azure roles,
joins the nodes to AD, deploys AKS or starts a workload.** The result can be local
configuration complete with checks still pending. Even a clean selected-check
result leaves `clusterBootstrapComplete=false` and is not cloud deployment approval.
Guest update applicability and Evaluation activation are not verified by this
continuation. A pinned OS image/version is not an up-to-date security/activation claim.

The remaining [cloud deployment gates](cloud-deployment-next-gates.md) are separate
from the approved local work. Fresh provider metadata advertises West Europe for
both HCI clusters and bridge appliances, not South Africa North. This does not
select a region, API version, identity flow, cost or export policy by implication.

```bash
python3 -B scripts/smal-private-powershell.py \
  --script scripts/read-smal-guest-bootstrap-job.ps1 \
  --receipt your-new-local-bootstrap-observation
```
