# Approved three-node execution

## NODE3 local build completed, 12:18 SAST

The existing one-shot task exited **0**, state Ready, with the expected worker and
helper hashes. NODE3's local setup, network, nested Hyper-V, clock, answer-file
cleanup and shared cluster-only credential login checks passed. Published actual
VM ID: **5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9**.

`node03-local-completion.json` binds that ID and the five new VHD GUIDs to the
observed guest disk unique IDs. Its nested `vm` section is the **creation-time**
snapshot (Off and zero dynamic MACs before first boot), not a claim about current
power state or live MAC addresses. A separate live inspection must be used for
current state. Daily startup now includes the actual fourth guest.

NODE3 is **not Arc-registered yet**, and the Azure Local cluster is not deployed.
The human-auth console has now been installed and independently verified, status
**installed-not-invoked**, with no authentication output capture. All four live
guest identities/startup and all three nodes' private DNS/TLS paths passed the
12:23 SAST inspection. See [the exact human command and verified handoff](node03-authentication-handoff.md).
No additional approval is requested for that already authorised authentication path.

## Authority and completed effects

The owner's **Approved** answer is bound to the exact proposal JSON/Markdown hashes
in `three-node-approval.json`. The original proposal remains immutable. No Shared
Key, public endpoint, subscription-wide role, policy exemption or recurring agent
job is authorised or performed by these stages.

- One additional **2 TiB Premium_LRS** disk was created and attached at **LUN8**,
  caching None, delete option Detach. Existing nine disks remained Premium and their
  VM attachments were unchanged. Disk export networking is DenyAll/Public Disabled.
- Azure disk unique ID: `eab2d4b3-d41d-44b3-99b4-d6c1c928c97b`.
- Windows new-device unique ID: `eui.977A2C37B7C846F087268B8452F57C01`.
- A protected baseline captured all existing Windows/physical device identities
  before attachment. Exactly one new Windows/physical device appeared. Its raw,
  non-boot/non-system identity, capacity and unchanged host boot epoch were checked
  before formatting **only that new device** as W:.
- W: is healthy NTFS, approximately 2 TiB. C:, V: and the original eight-member
  Simple pool were preserved. No existing volume format/extension was requested.
- NODE1 and NODE2 were gracefully stopped, changed to **64 GiB / 8 vCPUs**, then
  started and verified with their original VM IDs, bootstrap success, working Arc
  services and unchanged four RAW 170 GiB guest data-device IDs each.
- NODE1's exact LUN4 VHD was moved to the approved W: path. Its VHD GUID, file hash,
  attachment and guest unique ID were verified. No data disk was shrunk or recreated.
  The DC was not changed. The host remains **Standard_E32s_v6**.

## Retained interruption and reconciliation

The first post-attachment format transport timed out **before SSH authentication or
command delivery**. The disk/attachment had succeeded, so the original disk apply
receipt truthfully remains failed at the format-dispatch stage. It was not replayed.

A read-only inspection independently showed no format marker/state, no W: volume,
the same host boot epoch, and exactly one new RAW device. Only then was the original
guarded format invoked under a new receipt. No new disk creation or attachment was
repeated. Relevant records:

- `node03-disk-apply-receipt.json`, `node03-disk-what-if.json`.
- `../deployment-2026-10-27/private-ssh-node03-disk-interruption-inspection-20261029.json`.
- `../deployment-2026-10-27/private-ssh-node03-disk-format-reconciled-20261029.json`.
- `three-node-resize-receipt.json`.

## Historical build progress and source pins

The one-shot SYSTEM task **LocalBox-Node03-20261029-01** was installed and started
from reviewed, committed and pushed source. It has **no schedule/reboot trigger**,
no automatic restart policy and no Arc/cloud-deployment invocation.

- Task worker SHA256:
  `DFDA8903EE400DB2453C21EB076D02E5D9D991D1917A1480AA81F457C357E485`.
- Helper bundle SHA256:
  `D1568DE10404A25A5961C4088940C1F7EF18EA8E757ED3D32C3DAD419FE65789`.
- Installer source commit: `4835eb6d2b03b7141365ca9001f3eea64865bd60`.
- Protected worker root:
  `C:\ProgramData\AzureLocalBox\Bootstrap\node03-20261029-01`.
- Planned new guest path:
  `W:\AzureLocalBox\Guests\three-node-20261029-01\LB-NODE03`.

At **12:12 SAST**, an independent read showed the worker **Running**, with a fresh
heartbeat, in **LB-NODE03-expand-windows-image**. No NODE3 VM ID or local-completion
proof had yet been published. The ISO hash/edition/build checks and image partition
creation had passed. A reader interruption did not imply worker failure and no
installation or bootstrap step was restarted. All progress receipts, including
failed private reads, are retained. A second monitor interruption was a pre-auth
SSH connection timeout. The subsequent read again confirmed the unchanged task
and fresh heartbeat. The reader now uses share-delete-capable stable
file handles so observation does not block the worker's atomic state replacement.

The bounded observer can retry its **read-only progress command** after a transport
failure. It never dispatches, restarts or retries the worker/installer. Its cadence
is bounded and slower than the initial monitor. This is not a recurring agent job.

## Execution sequence and remaining gates

Steps 1–4 below are now complete. Step 5 is the remaining human action.

1. Observe the existing task, without reinstalling. Require task exit 0, expected
   source hashes and successful OS/network/nested Hyper-V/clock checks.
2. Verify owned answer-file cleanup, no setup-log secret review flags, shared
   cluster-only credential login and the newly returned VM/VHD/guest disk IDs.
3. Commit the public completion/binding evidence. Update daily startup and final
   inspection tools to the **actual** four-guest topology, not a guessed NODE3 UUID.
4. Install the prepared pinned NODE3 human-auth console **only after completion**.
   Installation/readback have now passed; registration has not been invoked. The
   `register-smal-node03-console.py` launcher refuses headless authentication and
   checks existing active PIM access. Its required installed receipt now exists.
5. Human completes normal device-code/MFA. No existing owner ARM token is forwarded.
   Independently verify NODE3's actual Arc ID/identity before its three scoped roles.
6. Re-derive the exact three-node **No Witness** settings and two platform-credential
   secrets. No witness key read/upload, policy change or public access. Complete
   checked service **Validate → Deploy**, then platform acceptance.

No additional generic approval is required for the listed authorised effects.
Unexpected identity, policy, storage, privilege or cost effects still stop for review.
**Cluster deployment and full platform readiness remain false.**

## Source checks

The regression suite passed **211 tests**, including approval hashes, new-disk
effect limits, exact generated NODE3 helpers, native heartbeat compilation,
read-only observer scope, and headless-authentication refusal. The prepared NODE3
console is guarded by the completed native task's cleanup/login proof. Its installer
cannot be run against a guessed VM UUID or incomplete setup. The installed console
has not invoked registration; that remains the human-terminal action above.
