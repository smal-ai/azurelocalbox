# Offline execution-plan validator milestone

The first scheduled engineering milestone is complete: a **pure network/storage
plan validator**, not an executable cluster bootstrap or an approval mechanism.

Execution: `occurrence_bbe0e9ccab4a3537fb6b2b84e624a5124526c9fced3145445452b83987ffca9f`.
Run: `run_a1de2fa4b131a604498ecdad6cb78c35eb2cf2015871aba97990cd791ecf08c9`.

## Interface and guarantees

```bash
python3 -B scripts/validate-smal-bootstrap-plan.py \
  --plan docs/deployment-2026-10-27/bootstrap-execution-plan.draft.json \
  --inventory docs/deployment-2026-10-27/bootstrap-inventory.draft.json \
  --approvals docs/deployment-2026-10-27/bootstrap-approvals.draft.json
```

Exit **2** is the expected result for the current incomplete draft. Exit **0** means
only `valid-for-independent-review`. Every result explicitly returns
`automaticApplyPermitted=false`, `resourceActionsPerformed=false`,
`approvalReferencesAuthenticated=false` and `liveInventoryVerified=false`.

The program uses only the Python standard library. It reads the three supplied
documents and writes JSON to stdout. It has no subprocess, network/discovery,
credential, resource-application or retry path.

Checks include:

- Strict document keys/types, canonical IPv4 CIDRs, duplicate JSON-key and non-finite
  number rejection. Nested allocations must use RFC1918 space.
- Separate aggregate allocations and leaf subnets, containment, leaf overlap and
  overlap against the supplied connected estate. The known VPN is checked even when
  omitted from the supplied inventory. Two `/25` VPN routes are correctly combined.
- Exact existing host/subnet/IP and central resolver. Only the proposed outbound
  SNAT model is accepted for review. Default-route changes, NIC forwarding, shared
  network writes and nested route advertisement are rejected.
- Exactly eight owned, attached, 256 GiB data disks with explicit guest unique IDs,
  LUNs, RAW state and non-boot/non-system status. Wildcards, ambiguous/missing identity,
  duplicates, path traversal, changed attachment and mismatched inventory are rejected.
- Separate storage/network receipt structures bound to canonical SHA-256 digests of
  **both** plan and inventory. Missing, stale, agent-labelled or duplicate/incomplete
  receipt scopes are rejected. Local receipt strings cannot authenticate a human
  decision. Actual native references and execution authority still need independent
  verification before any future application.

## Current draft is deliberately blocked

The draft prefixes come from `network-request.json`. Connected ranges come from the
historical `address-overlap.json` discovery. Azure disk IDs, attachment and sizes come
from `host-hyperv-post-reboot-arm.json`. No live discovery was performed this run.

The recorded evidence does **not** bind Windows guest unique disk IDs and LUNs to the
exact Azure managed-disk IDs. The older guest disk-number/RAW observations alone do
not establish that cross-layer mapping. Those fields, and guest boot/system/partition
state tied to each Azure disk identity, remain **null**, not guessed from disk numbers
or filenames. Estate review remains incomplete and the approvals receipt list is empty.

The proposed `Simple`/NTFS/V: storage profile and `formatRequested=true` describe a
review proposal, **not approved formatting**. No disk was touched. No addresses were
reserved, advertised or applied.

`bootstrap-plan-validation.json` records the expected blocked result and exact input
and validator source hashes. Its six rejection categories identify missing estate
review, independent storage/network decisions and exact guest/LUN/data-disk evidence.

## Verification and next milestone

**17 validator tests pass. All 60 LocalBox regression tests pass.** Coverage includes
valid-but-review-only fixtures, approval binding, partial estate evidence, overlap,
VPN omission, CIDR/type confusion, route/forwarding changes, boot/system/non-RAW disks,
duplicate/mismatched IDs and LUNs, traversal and malformed JSON. Fixture approval
documents are explicitly synthetic and never grant authority.

Next bounded offline milestone: side-effect-free PowerShell Direct helper source and
mocked/static tests. Do not generate guest credentials, import the vendor module,
mount/execute the ISO, format disks, create/start guests or modify any host/network
while preparing those helpers. Full bootstrap readiness and material apply decisions
remain blocked.
