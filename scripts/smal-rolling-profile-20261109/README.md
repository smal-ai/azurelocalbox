# Exact rolling guest profile

Source-only MOC-maintenance delta to rolling-profile v2. This is new source requiring
independent review, not inherited v2 acceptance, native GO or current admission.

## Compatibility boundary

- `plan.py` now defines 25 serial stages, adding MOC removal after each drain and MOC
  addition after each resume. Each has one original stage/key/worker and exact membership
  readback. The operation ID/root remain unchanged because the 19-stage plan never ran.
- Targets remain
  NODE02 20 CPU/96 GiB, NODE03 20/96, NODE01 16/64, infrastructure return, completion.
  NODE01 has no memory write. The outer host remains E64.
- `build.py` verifies all four original v2 render hashes before applying this delta,
  then verifies the new output hashes. It still only assembles offline JSON/source.
- `moc-contract.ps1` provides exact installed-command qualification and MOC membership
  reads through the existing credential/session helper. It does not contain mutations.
  Worker MOC effects invoke only the officially documented `-NodeName` binding.
- Existing R2 common/worker/stage and maintenance sources stay unchanged. Their pinned
  protected WIP is required input, including the worker even if it is not yet tracked.
  Parent must preserve and publish those exact dependencies, not replace them with HEAD.
- `scripts/start-smal-existing-guests.ps1` receives only the accepted profile interlock.
  The renderer accepts its exact before or installed bytes and produces identical output.
- The common fragment and startup output remain byte-identical to v2. R1 immutable
  operation/worker identity, R2 current infrastructure placement, R3 actual Paused/eight
  maintained devices and the original returned/dead unknown-RPC refusal are retained.
  Graceful stop additionally rechecks actual MOC exclusion before the current snapshot.

Historical accepted v2 manifest:
`c83e62314dc5fedeea63c9c96e1e2eeadb66f567b833e0a5b1d8e21fb667d917`.
The [current official maintenance procedure](https://learn.microsoft.com/en-us/azure/azure-local/manage/suspend-resume-cluster-maintenance?view=azloc-2610)
requires MOC removal/re-inclusion. No explicit storage Enable/Disable effect is added.

## Offline interface

From the canonical repository root:

```bash
python3 -B scripts/smal-rolling-profile-20261109/build.py render
python3 -B scripts/smal-rolling-profile-20261109/build.py qualifier
python3 -B -m unittest discover -s scripts/smal-rolling-profile-20261109 -p 'test_*.py' -v
```

`render` prints JSON containing the four proposed rendered sources, their canonical
input pins and an unsealed plan. It installs nothing. `capsule --plan PATH --stage STAGE
--source-commit HASH --mode dispatch|observe` prints the existing capsule result as JSON.
Dispatch assembly requires the unchanged sealed operation plus fresh stage proof.
The plan's original approval and expiry remain immutable. The new proposal is bounded
by 15:20 SAST on 10 November 2026, but its GO is false and expiry remains null.
The GET qualifier and baseline reader still end at 15:00 SAST.

`qualifier` emits the fixed GET-only `scripts/read-smal-rolling-moc-contract.ps1` source.
Parent publishes it before any native read. It checks only the installed Get-MocNode,
Remove-MocPhysicalNode and New-MocPhysicalNode contracts on the three known machines.
The observed module is Moc 1.2.161, file SHA-256
`b9dbda4ab8c0ce6c77d8fa219a153983114afc859f5bb10689f6f3cf71025b7f`.
Parameter-name comparisons follow PowerShell's case-insensitive binding, while the
recorded parameter spellings and signature hashes remain unchanged. No absent
Get-MocPhysicalNode command or invented alternative is used.

Retained installed declarations support exactly `Get-MocNode -location MocLocation
-timeoutSeconds 20`. The qualifier verifies those declared bindings before invoking it
once on Running NODE02. NODE03/01 collect installed metadata only. This avoids repeated
data reads. No membership API/auth-readiness claim is made for those two observers.
Every future effect still requires a successful fresh read from its Running observer.

Actual typed list/array results use the already-qualified bounded Items rules. Strings
and dictionary keys never become nodes. Returned name/ID/type/path spellings are kept
in a bounded safe management projection. Raw JSON-compatible returned data is retained
create-only under a node-local diagnostic directory with the existing protected bootstrap
ACL, capped at one MiB with explicit incomplete-capture status. No raw vendor data or
credential value is exported. A capture failure does not discard the safe projection.
Vendor streams are retained privately as a separate diagnostic with explicit truncation
metadata. They are never parsed into nodes or exported as raw text.

The result deliberately does not guess whether `name`, `NodeName` or another property
identifies the Windows machine. Unknown shape/identity blocks CUD but returns useful
projection/capture metadata. After inspecting actual evidence, parent binds
`mocContract.membershipIdentity` with the exact observed `fieldPath`, `semantics` set to
`WindowsComputerName`, `location` set to `MocLocation`, and the actual evidence SHA-256.
Set `mocContract.nodes` to the actual installed-binding rows and `initialMembership` to
NODE02's actual returned observation. `moc_contract_preflight` derives initial membership
from those recorded fields without changing native values. It requires exactly the three
known names and preserves provider IDs. Case-only Windows name matching requires that
explicit semantics binding. FQDN stripping, GUID translation and guessed fields refuse.

Fresh phase proof must bind actual `mocMembers`, `mocContractQualified`, and
the exact `previousStage` with `previousEffectIndependentlySettled=true`. It must still
satisfy every existing health, profile, volume, permission and 300-second freshness gate.
`resume` and `moc-add` use selected return-to-service context, not a destructive outage's
current-maintenance condition. MOC addition requires an independently observed Up node
and checks that state again natively. Full convergence is still required before the
next drain. Adding MOC membership never pretends that storage has converged.

MOC/Suspend RPC return is recorded durably before post-read. A post-read failure retains
that known return separately from the failed read and still awaits original independent
observation. It does not settle the effect or permit replay. A genuinely unknown RPC
still blocks in the original dispatcher. Resolve the original source-bound observe
result and obtain fresh next-stage proof, never rewrite the worker or reuse its key.

Parent owns publication and the existing source-bound private PowerShell transport.
Publish exact generated capsule bytes under `scripts/` before that transport can accept
them. Retain the original capsule/source/plan/request and independent-proof envelope.
An original observe call uses its original source checkpoint and identical worker bytes,
including after expiry. Earlier legacy/R2/v1 attempts keep their own retained observe
capsules. This builder cannot turn them into v4 operations or clear retained roots.

Every effect still needs independent original-operation settlement before continuation.
Unknown RPC outcomes block. No replay, expiry renewal, marker cleanup, force-stop
fallback, credential path, schedule change or general dispatcher is added.

Checks are offline Python and isolated PowerShell guard fixtures only. Windows
PowerShell 5.1 bindings, actual placement/maintenance and native execution remain untested.
