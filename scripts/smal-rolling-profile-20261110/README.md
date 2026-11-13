# Bounded rolling guest continuation

New operation `smal-foundation-profile-20261110-02`, rooted only at
`C:\ProgramData\AzureLocalBox\FoundationProfile-20261110-02`, with a fixed
20:00 SAST execution/read end on 2026-11-10. This factory emits no GO. Parent
owns publication, the actual fresh baseline, plan sealing, transport and execution.

## Exact delta

- Reuse the pinned existing 25-stage plan/preflight and rendered worker/dispatcher.
  The only plan-source substitutions are the operation ID and fixed deadline.
  The old source, old plan and old capsules are neither edited nor reissued.
- Preserve NODE02 → NODE03 → NODE01, 20 CPU/96 GiB, 20/96 and 16/64, no NODE01
  RAM write, E64/64 host logical processors, the existing volume/reserve gates,
  serial original RPC settlement, 300-second proofs, current maintenance,
  survivors, vNUMA bounds and protected infrastructure live return to NODE01.
- Preserve mandatory MOC removal after drain and addition after resume, using
  the installed Moc 1.2.161 `-NodeName` contract and existing membership checks.
  Use the actual accepted `['name']` / `WindowsComputerName` / `MocLocation`
  binding when parent seals the plan. Do not alter native false flags or records.
- Bind `originalOperationReconciliation` to the exact original plan and accepted
  coordinator/cleanup/state receipt hashes in `plan.RECONCILIATION`. Every fresh
  proof must additionally carry `originalReconciliationSha256` equal to the
  coordinator reconciliation hash. Native worker and dispatch also verify the
  immutable reconciliation fields. Dispatch refuses all three prior roots.
- Append a separate exact new-root startup gate. Keep the existing legacy/R2 and
  expired rolling-root gates intact. The new gate uses the existing completion,
  original-worker liveness and profile-drift rules. No expiry-based startup bypass.
- Add `snapshot.guestsRuntime[].memoryAssignedBytes` directly from each exact
  `Get-VM` object's `MemoryAssigned`. This is separate from `guestsStatic`, static
  profile equality and startup memory. It does not assert future AKS admission.
- Derive the new GET-only initial baseline reader from the pinned original reader,
  replacing its embedded common fragment with this exact new common source.
  It rejects all three prior roots plus the new root, requires all guests Running,
  retains start/end read-window checks, and exports the new common-source hash.

The immutable-plan/fresh-proof split and original observe behaviour are unchanged.
Original observe remains possible after this operation's expiry. The new builder
rejects the old operation ID. Use the retained exact old observe capsule and its
original source checkpoint for old observations, never this new factory.
No new dispatcher, retry policy, cleanup, grant, schedule or transport is added.

## Offline use

From the published canonical repository root:

```bash
python3 -B scripts/smal-rolling-profile-20261110/build.py render
python3 -B scripts/smal-rolling-profile-20261110/build.py baseline
python3 -B -m unittest discover -s scripts/smal-rolling-profile-20261110 -p 'test_*.py' -v
```

For this private candidate only, set `SMAL_CANONICAL_ROOT=/home/quintin/play/azurelocalbox`.
Every inherited dependency is SHA-256 checked. `render` includes exact input pins
and an unsealed plan. It does not write or publish anything. `baseline` emits
`scripts/read-smal-rolling-profile-baseline-20261110-02.ps1` as JSON source only.
Publish that exact file and the startup delta before parent performs the one fresh
baseline read. Do not fetch it while implementation/publication is still pending.

Parent should create the new sealed input at
`/tmp/opencode/smal-rolling-execution-20261110-02/plan.json`, using the actual new
baseline receipt, actual retained MOC contract and closed measured guest-only volume
budget `f04d4b7c1d45a5ec1051eea930151fc69de9e38a2b59c459ab6ce9f557a4ad64`.
The unchanged plan's admission structure remains parent's responsibility. This
factory does not manufacture evidence, GO, admission or a sealed plan file.

With `PUBLISHED_CONTINUATION_COMMIT` set by parent to the actual published source
checkpoint, the precise first capsule commands are:

```bash
python3 -B scripts/smal-rolling-profile-20261110/build.py capsule \
  --plan /tmp/opencode/smal-rolling-execution-20261110-02/plan.json \
  --stage drain-LB-NODE02 \
  --source-commit "$PUBLISHED_CONTINUATION_COMMIT" \
  --mode dispatch

python3 -B scripts/smal-rolling-profile-20261110/build.py capsule \
  --plan /tmp/opencode/smal-rolling-execution-20261110-02/plan.json \
  --stage drain-LB-NODE02 \
  --source-commit "$PUBLISHED_CONTINUATION_COMMIT" \
  --mode observe
```

The input file and source checkpoint do not exist merely because these commands
are documented. Parent must produce both. Assembly outputs JSON source, not native
execution. Publish exact generated dispatcher/worker bytes through the existing
source-bound private transport before use. Preserve original worker/plan/request
identity for every subsequent independent observation. Stop on unknown RPC outcomes.

## Focused evidence

`test_continuation.py` reuses the existing six MOC phase fixtures. It also checks
exact 25-stage equality, no inherited GO, reconciliation/expiry/freshness refusal,
retained-root/native guards, GET-reader parsing, actual runtime memory projection,
unsealed capsule refusal, expired observe, startup active/live-worker/drift refusal
and startup installation preserving capsule and baseline bytes. All PowerShell
execution is isolated synthetic fixture code, not native lab validation.
