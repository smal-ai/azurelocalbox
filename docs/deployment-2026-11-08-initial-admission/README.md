# Read-only initial AKS base inputs

This observer supports the initial A4 + D8 + D8 candidate, 20 CPU / 72 GiB and a
100-GiB RWO cache. It does not admit a deployment or change infrastructure.

- The existing SMAL operator is bound additively in [operator-binding.json](operator-binding.json).
  The October owner approval and original identity-mismatch receipt remain unchanged.
- New observer names alone use that exact tenant/subscription/principal/read-only binding,
  fresh effective VM/NIC/Bastion permissions and the fixed 2026-11-08T22:00:00Z cutoff.
  Existing transport callers and legacy principal pins are unchanged.
- Each part uses committed, pushed source through the existing pinned-key private Bastion
  transport. The 90-second guest command limit and uncertainty/replay handling are unchanged.
- Node parts reuse `New-ComputeSession` from the committed common library and verify the
  expected node and RID 500 inside the guest. The library's broader observers are not called.

## Fixed parts

| Source | Scope |
| --- | --- |
| `read-smal-initial-host-20261108.ps1` | Four exact configured guest profiles, outer capacity, IPv4/routes, OS route selection to `.100`/`.180`, NAT selectors, current SSH22 peer addresses and outer volume bytes |
| `read-smal-initial-storage-20261108.ps1` | NODE01 VD footprint/provisioning/copies, native CSV partitions, verified VD-to-disk-to-partition-to-volume and tier interfaces |
| `read-smal-initial-discovery-20261108.ps1` | NODE01 loaded getter signatures and installed vendor module/hash/signature metadata only |
| `read-smal-initial-routes-20261108.ps1` | Three return-route selections to protected `.1`, three gateway echo checks and three own-FQDN DNS checks against configured `.10` |

Join the route part's literal `.1` to the host's measured selected source before claiming
return-path coverage. Neither routes, neighbours nor DNS absence prove IP ownership.
MOC discovery does not invoke a getter, import a module or establish image/controller state.
No API socket, scan, catalogue refresh, bridge SSH or credential-service operation is present.

Example, only in the accepted read-only execution and after independent source review:

```bash
AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no python3 -B scripts/smal-private-powershell.py \
  --script scripts/read-smal-initial-host-20261108.ps1 \
  --receipt initial-host-20261108-01
```

Each receipt name is immutable. Inspect partial, failed or timed-out receipts rather than
automatically repeating them. An outer transport `complete` is not enough: inspect the
guest status and each query's counts, completeness, errors and capture interval.

Native byte fields remain integers or unavailable. Thin logical capacity is not physical
headroom. Storage interface metadata is not permission or build-specific support to resize.
The underlying S2D capacity VHDs, all existing disks, Infrastructure CSV and identities stay
unchanged. The SMAL coordinator owns placement, reservations, SSH source policy and admission.
