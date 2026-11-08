# Asynchronous bootstrap preparation and follow-up

## Current outcome

**Current correction:** the recurring follow-up was cancelled by Quintin and the node
confirmed revision 2. Relay's former conflicted occurrence was subsequently disposed
of through the recovery work. It is not being resumed or replaced. The installation
details below are historical. See [28 October continuation](../deployment-2026-10-28/README.md)
for the separately approved local storage job. Full cluster deployment is not complete.

Quintin explicitly requested asynchronous work, progress checks and a cron follow-up.
That authorises the asynchronous preparation and follow-up, not execution of the
known-unsafe vendor scripts or silent approval of unreviewed resource changes.

- Native Relay schedule: `smal-localbox-bootstrap-followup-20261027`, revision **1**.
- Cron: **`*/10 * * * *`**, timezone **`Africa/Johannesburg`**.
- Independent local schedule readback: **active**, first reported firing **14:10 SAST**.
- Expiry: **28 October 2026 at 14:00 SAST**, bounding unattended follow-up to 24 hours.
  No automatic extension or replacement schedule is authorised.
- The schedule can perform one bounded offline engineering milestone per run and
  inspect progress. It must not launch unreviewed host/cluster mutations, replay
  failed/uncertain operations or report host/image success as platform readiness.

`bootstrap-followup-schedule.json` records installation/readback evidence. A CLI help
probe was refused by the current human-source check. No immediate native execution
was dispatched through that route and no alternate credentials were used. The direct
own-agent schedule API succeeded, and local installation was independently verified.

## Initial asynchronous check

Source `dfb977f` was committed and pushed before launching:

```bash
python3 -B scripts/check-smal-bootstrap-readiness.py --run-id readiness-20261027-01
```

It ran in the background as shell job `sh_17d3ec172001og0fdxgWxW74kf` and completed at
**14:03:47 SAST**. All three recorded prerequisite checks passed: host Hyper-V/private
access, OS-volume expansion and current ISO staging. It correctly returned **blocked**
for the missing safe implementation, remaining dependency pins and unaccepted storage,
network, guest-secret, registration-identity and cloud-cost/export decisions.

This initial check reads existing evidence only. It does not claim a fresh guest
inspection, an active guest bootstrap process or any deployment progress percentage.
The immutable run receipt remains `bootstrap-async-run-readiness-20261027-01.json`.
The progress checkpoint is mutable, with transition history retained separately.

## Check progress

```bash
python3 -m json.tool docs/deployment-2026-10-27/bootstrap-async-progress.json
tail -n 10 docs/deployment-2026-10-27/bootstrap-async-history.jsonl
```

The checkpoint contains status, phase, last check, blockers, fingerprint, evidence,
next action and exact job/execution IDs where known. `clusterDeploymentStarted=false`
and `activeGuestBootstrapJob=null` are intentional. Native executions must record their
actual IDs from `relay_work_read`, not invent them or reuse the local preflight PID.

The observer uses an exclusive OS lock, preserves per-run receipts, atomically updates
JSON checkpoints and appends sanitised history. It never invokes a shell, imports the
vendor module or applies infrastructure. A future status of `ready-for-human-scope-review`
still cannot authorise execution by itself.

## Concrete offline continuation milestones

The follow-up agent must advance engineering rather than repeat the same blocker
summary indefinitely. Start from the next pending milestone and stay within the
exact native execution grant. Preserve unrelated work and commit/push consequential
source before any future application.

1. **Execution-plan validator.** Implement pure validation for an exact proposed
   nested-network/storage manifest. Reject missing approval evidence, overlapping
   prefixes, default-route changes and non-exact disk identities. Unit tests use
   fixtures, not host changes. A validated draft is not address reservation or approval.
   **Completed by the first scheduled occurrence:** [validator report](bootstrap-plan-validator.md).
   The actual draft remains blocked, with guest IDs/LUNs and apply receipts deliberately absent.
2. **Safe PowerShell Direct helpers.** Prepare side-effect-free module import and
   explicit guest-credential/VM-ID interfaces. Keep guest firewalls enabled, avoid
   TrustedHosts/CredSSP and never reuse or log the outer administrator credential.
   Mock or statically test guest operations without creating or starting VMs.
3. **Remaining dependency lock/review.** Freeze necessary AD/Arc dependencies and
   transitive sources. Exclude optional UI/Chocolatey/GitHub installer machinery.
   No floating installs, package execution or new registration identity by assumption.
4. **Durable guest orchestrator source/tests.** Prepare single-instance phase execution,
   exact source hashes, heartbeat/checkpoints, secret-safe logs, durable pre-apply
   receipts and inspect-before-resume behaviour. Keep all unapproved apply phases
   disabled. Do not install/start this guest job until the exact reviewed plan and
   material apply decisions are authorised.

Do not mark the complete safe bootstrap implementation ready merely because the first
validator/helper is written. Guest-secret delivery/lifetime, storage formatting,
nested ranges/SNAT/DNS, region/identity/scopes, platform costs and mandatory exports
remain explicit apply decisions. Peer-message delivery is not network acceptance.

## Reporting and stop conditions

- Report material phase changes, new blockers and terminal outcomes, not every tick.
- Deduplicate human questions and task updates by blocker fingerprint.
- Follow `relay-work`, check cancellation, and use asynchronous questions for human
  decisions. Do not assume permission to mutate a different task or administer
  executions/schedules outside the exact accepted worker grant.
- Never create overlapping jobs or automatically retry a failed/uncertain mutation.
- A stale heartbeat, broken VPN/SSH authentication or inaccessible progress source is
  a blocker, not permission to broaden access or switch administration paths.
- Do not mark the overall platform task complete from this preparation.
