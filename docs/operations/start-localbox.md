# SMAL LocalBox operations moved to `smal-ai-infra`

Date: 2026-11-16.

The canonical SMAL LocalBox startup, private Bastion/SSH PowerShell transport, platform/MOC
inspection and repair, capacity, disk-performance and dedicated SMB file-service tooling moved
into the canonical SMAL repository (`smal-ai/smal-project`) under `solution/infra/localbox/`.

## Canonical location and commands

Run from `/home/quintin/play/smal-ai-infra`:

```bash
python3 -B solution/infra/localbox/scripts/start-smal-localbox.py
python3 -B solution/infra/localbox/scripts/smal-platform.py inspect --timeout 600
python3 -B solution/infra/localbox/scripts/smal-platform.py inspect-performance --timeout 300
```

Read `/home/quintin/play/smal-ai-infra/solution/infra/localbox/README.md` for full operating
and diagnostic instructions. Do not recreate duplicate copies in `azurelocalbox`.

## Retained scope in `azurelocalbox`

This repository retains the outer-host and initial brownfield Jumpstart LocalBox Bicep
templates (`infra/bicep/`) and historical deployment/bootstrap records (`docs/deployment-*/`).

```bash
BICEP_CLI="$HOME/.azure/bin/bicep" python3 -B scripts/canonical_ci.py
git diff --check
```
