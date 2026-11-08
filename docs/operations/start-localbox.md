# Start LocalBox after the nightly shutdown

## Current operational handover

The cluster is deployed. Current storage is **24 S2D data VHDXs**, eight per node,
with **8 TiB Azure data backing**, and Standard_LRS is the approved lab tier. Older
three-guest, standalone, 12-device and ValidationFailed observations below are
historical, not the current operating baseline.

Other agents on this operator machine should reference this canonical checkout,
not copy the Python script into another repository. Its repository-relative
dependencies, exact approval/receipt bindings, pinned host-key setup and pushed
HEAD checks must remain intact. The command can be called by absolute path:

```bash
python3 -B /home/quintin/play/azurelocalbox/scripts/start-smal-localbox.py
```

When AzureLocalBox is unavailable, inspect whether the existing host/guests are
stopped after the normal shutdown and use this command for startup-only recovery.
Do not interfere with an intentional maintenance window or an active deployment.
If the host and four guests are already Running with healthy heartbeats, investigate
application/network/Arc health rather than redeploying or restarting the cluster.

Incorporate the canonical command and these prerequisites/failure boundaries into
the consuming project's runbook. Do not copy credentials, private keys or Azure
token caches, provision replacement infrastructure, activate PIM automatically,
change nightly shutdown automation or install recurring startup jobs.

Startup success proves host/guest power and heartbeat, not application or full
platform readiness. Boot encryption and audit-delivery/recovery acceptance remain
open. Current technical evidence is in
[independent acceptance](../deployment-2026-10-30/independent-acceptance.md) and
[capacity expansion](../deployment-2026-10-30/capacity-expansion.md).

From `/home/quintin/play/azurelocalbox`:

```bash
python3 -B scripts/start-smal-localbox.py
```

## Prerequisites

- Existing Azure CLI sign-in in the approved tenant/subscription with the required Azure RBAC
  permissions. The owner removed the historical user-object-ID pin on 2026-11-01 to use the
  current personal account. The routine does not assert that account permissions are equivalent;
  Azure enforces each request. Activate existing PIM access manually if needed. No identity switch,
  role activation or grant is performed by this command. Tenant/subscription and exact resource
  checks remain mandatory. Canonical result/uncertainty receipts are retained.
- Existing NetworkManager VPN profile `entlz-san-cert`, with its certificate and
  authentication already configured. The command now connects it when needed.
  A healthy private path is left alone. An Active profile without working private
  routes/resolver reachability is reconnected once. Missing profiles or credentials
  require manual attention, not automatic provisioning.

- Existing pinned SSH key and successful private Bastion setup receipts on this
  operator machine. This is not a portable first-time provisioning tool.
- Startup source must match committed HEAD and be pushed to the current branch.

## Behaviour

1. Checks committed/pushed source, then actual `tun0` routes to the host/resolver
   and TCP53 reachability to the private resolver. If needed, resolves the existing
   named VPN to its UUID and connects it, or disconnects/reconnects that exact active
   profile once. Rechecks the private path and signed-in identity before any Azure
   start. No VPN profile, certificate, route configuration or credential is edited.
2. Starts only `LocalBox-Client` in `rg-localbox-nodes-san-1`. Already Running is
   a no-op. A Starting host is observed without another start request. Stopping,
   deallocating and unexpected states are refused.
3. Waits for host Running and Azure VM agent Ready, bounded by `--host-timeout`
   (default 900 seconds). This does not certify SSH availability.
4. Uses VPN → private Premium Bastion → pinned-key SSH to validate the exact four
   existing guest IDs, then starts the DC first, followed by NODE1, NODE2 and NODE3.
   Already Running guests are left alone. There is no DC service-readiness gate
   between guest starts.
5. Waits for healthy Hyper-V heartbeats from all four guests. Heartbeat means OS
   liveness, not working AD, DNS, PowerShell Direct, Arc or Azure Local readiness.

Safe to run again after a completed run. It does not reboot Running machines,
change automatic-start settings, bypass PIM, alter nightly shutdown automation,
register Arc nodes, delete registration markers or continue bootstrap.

Every invocation retains a distinct receipt under `docs/deployment-2026-10-29/`
and a separate private transport receipt under `docs/deployment-2026-10-27/`.
Failures, interruptions and uncertain timeouts are retained. The command does not
automatically replay remote operations. If it fails, inspect the named receipts
and actual VM state before running it again. Concurrent local invocations are refused.

Historical pre-deployment NODE2 bootstrap recovery reference only. This is **not**
part of daily startup or recovery of the now-deployed cluster. The historical
command performed inspection, not registration:

```bash
python3 -B scripts/register-smal-node-console.py --node LB-NODE02 --inspect
```

## Verification, 29 October 2026

- Regression suite: 177 tests passed, including startup identity, routing, bounded
  waiting, uncertain-effect handling and no-op behaviour tests.
- Two consecutive live runs completed with host Running/agent Ready and all three
  guests Running with healthy heartbeats. Both requested **zero** host/guest starts.
- The combined command's stopped-host path was tested offline, not by deliberately
  shutting down the live environment. Earlier guest-start receipts independently
  record all three guests changing from Off to Running.
- Live receipts: `../deployment-2026-10-29/start-20261029-065230-91ec0efb.json`
  and `../deployment-2026-10-29/start-20261029-065252-f7c03032.json`.

### Real host deallocation and Premium conversion recovery

Later on 29 October, the existing disks were converted to Premium SSD while the
host was deallocated. The startup command requested a host start, then initially
refused a transient missing Azure PowerState during its observer loop. The original
receipt is retained. The observer now waits within its existing bound when a
previously accepted start briefly lacks PowerState. Missing state at the initial
decision point still refuses a start request.

After independent Running readback, a reconciled startup left the Running host
alone and started all three existing guests from Off to Running with healthy
heartbeats. V: and both Arc identities/bootstrap statuses were subsequently verified.
Arc services are configured for **delayed automatic start**. Early Stopped readings
are not a reason to register again or change their startup configuration.

Reconciled startup receipt:
`../deployment-2026-10-29/start-20261029-080708-7389325a.json`.
Final conversion/recovery evidence:
`../deployment-2026-10-29/premium-disk-conversion-reconciled-result.json`.

### Four-guest binding after NODE3 local completion

The current startup source includes NODE3's returned VM ID
`5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9`. It is bound to the committed successful local
build/cleanup/login receipt, not inferred from its name. Historical three-guest
receipts above remain unchanged. The command now targets the DC and all three
Azure Local guests. NODE3's Arc authentication remains a separate human step.

The four-guest source passed a live no-op run at **12:22 SAST**, with all four
heartbeats healthy and no VM start/reboot requests. Receipt:
`../deployment-2026-10-29/start-20261029-102241-6d02b948.json`.

## Automatic VPN connection, 30 October 2026

The same daily command now manages connection of the **existing** `entlz-san-cert`
profile. No extra command or scheduled job is required tomorrow morning.

- Healthy tunnel routes and reachable resolver: leave the VPN alone.
- Missing private path and inactive profile: connect the existing profile by UUID.
- Active profile with broken routes or resolver path: reconnect it once by UUID.
- Recheck actual host/resolver routes through tun0 and resolver TCP53 afterwards.
- If connection or verification fails, stop before any Azure VM start.
- Never create/edit a profile, certificate, credential or route configuration.
- Never repeat an uncertain connection command automatically. Failure receipts
  retain whether connect/disconnect was requested without raw authentication output.

Morning startup initially stopped because NetworkManager reported the VPN Active
without tun0 routes. After reconnecting the existing profile, the host was started
and the DC plus NODE1–NODE3 changed from Off to Running with healthy heartbeats.
Read-only checks subsequently verified all three Arc identities Connected, all
three bootstrap statuses Succeeded, exact twelve approved RAW data disks, healthy
outer volumes, private platform DNS/TLS paths, expected AD/OU/account expiry and
the retained gateway echo rule. Initial post-boot Arc disconnection and NODE1's
bootstrap endpoint read error cleared on follow-up without service changes.

Evidence: `../deployment-2026-10-29/daily-health-verified-20261030.json` and its
fingerprinted source receipts. The failed pre-start VPN receipt remains intact.
At that morning observation the cluster still reported the previous ValidationFailed
state. Those health checks did not resubmit Validate/Deploy or retest deployment
write permission. Deployment succeeded later that day, as recorded above.

Verification: **239 regression tests passed**, including disconnected-profile,
stale-active-profile, missing-profile, bounded failure and healthy-path VPN cases.
The updated source also passed a live no-op run at **07:47 SAST**: private path
verified, no VPN reconnect, no host/guest start requests, all four heartbeats healthy.
The automatic connect/reconnect branches were tested offline, not by deliberately
interrupting the restored live tunnel. Live receipt:
`../deployment-2026-10-29/start-20261030-054709-2b4f739f.json`.

## After additive capacity expansion

The same daily startup still starts the **same four guests**, with no topology or
startup command change. The deployed cluster now has **24** approved S2D data VHDXs,
eight per node, and the host has an additional independent **X:** data volume.
Standard_LRS is the current human-approved tier. Original 12-device and Premium
receipts are historical baselines, not current-state requirements.

Use the [approved capacity manifest and independent result](../deployment-2026-10-30/capacity-expansion.md)
for post-start storage checks. Do not apply the original standalone/pre-deployment
12-device acceptance gate to the deployed, expanded cluster. Startup itself only
restores the original VM identities and checks heartbeats; it never resets accounts,
re-registers Arc, recreates storage or runs cluster deployment.

## Separate post-start Arc readiness test

Guest heartbeats do not establish Arc readiness. The existing cloud observer has an Arc-only,
read-only mode for the deployed three-node identities, resource bridge and custom location:

```bash
python3 -B /home/quintin/play/azurelocalbox/scripts/inspect-smal-three-node-cloud-health.py --arc-readiness
```

It requires all three exact Arc managed identities to report Connected/Succeeded, the exact
bridge to report Running/Succeeded, and the custom location to be Succeeded/bound to that bridge
in its existing namespace. The existing tenant/subscription and committed/pushed-source checks
remain. It does not pin the old human user ID, inspect guest secrets, issue registration/repair
commands or read kubeconfig. The original full-cloud observation mode remains unchanged.

The default wait is bounded at 600 seconds to allow reported post-boot convergence. Use
`--wait-seconds 0` for a single observation. Identity/binding drift, failed provisioning or read
permission errors stop the test. Non-ready states time out as pending, never as success. A unique
canonical result receipt is retained; do not create a duplicate SMAL journal or restart nodes
merely to make Arc reconnect. Success establishes only these reported cloud states/bindings,
not full cluster, application, workload-extension or security acceptance. Boot encryption and
audit-delivery/recovery gates remain separate.
