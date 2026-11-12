# Operate the existing SMAL lab

## Start after the nightly shutdown

```bash
python3 -B /home/quintin/play/azurelocalbox/scripts/start-smal-localbox.py
```

This command restores the existing private VPN connection when required, starts the
configured outer host, then starts the four existing guests. Running machines are no-ops.
It checks guest identity, power state and heartbeat. The cluster-wide operation mutex
prevents overlap with an active platform operation.

Use the existing Azure CLI sign-in and `entlz-san-cert` VPN profile. Azure RBAC checks the
current caller's permissions. Private SSH uses the existing owner-only key and pinned host
key. An unavailable credential, failed permission check or changed host key needs repair
at that dependency.

## Inspect or repair MOC membership

The reusable source is `scripts/smal-platform.ps1`. Its `Action` parameter is `Inspect` or
`RepairMoc`. Supply `ConfigurationBase64` from the public `config/smal-platform.json`.
Pass the resulting public parameter object to:

```bash
python3 -B scripts/smal-private-powershell.py \
  --script scripts/smal-platform.ps1 \
  --parameters /path/to/public-parameters.json \
  --timeout 900
```

Inspection reads current HCI nodes, MOC membership, S2D/CSV health and actual CPU/memory
allocation. Repair adds a missing MOC member from a surviving peer. Existing members are
no-ops. It records an intent before the request and verifies membership after the return.
An unresolved intent requires a current-state read before another request.

Initial workload deployment uses actual available capacity. Historical resize plans,
per-attempt approval hashes and expired capture windows are not current-state requirements.

## Canonical source and state

Maintain these operational files:

- `config/smal-platform.json`
- `scripts/start-smal-localbox.py`
- `scripts/start-smal-existing-guests.ps1`
- `scripts/smal-platform.ps1`
- `scripts/smal-platform.py`
- `scripts/smal-private-powershell.py`
- `config/smal-capacity.json` and `scripts/smal-capacity.py` / `.ps1`
- `config/smal-disk-performance.json` and `scripts/smal-disk-performance.py` / `.ps1`
- `config/smal-files.json` and `scripts/smal-files.py` / `.ps1`
- `scripts/test_smal_canonical.py`

The capacity commands inspect or continue the exact existing NODE03 operation and the
selected 32-GiB user-volume expansion. Disk-performance commands reconcile the approved
two-disk Premium SSD conversion and its controlled shutdown/restart. Completed operations
are observed rather than repeated. Read current state before any new maintenance action.

The file-service commands operate only `smal-smb01` and its dedicated evidence/workflow
disks, shares and accounts. Use read-only inspection for an installed service:

```bash
python3 -B scripts/smal-capacity.py inspect
python3 -B scripts/smal-files.py guest-inspect
```

The installed SMB CSI driver is `smb.csi.akshci.com`. Both workload-node probes verified
encrypted SMB 3.1.1 and authenticated write/read access. The Windows evaluation licence is
time-limited. Protected service credentials and BitLocker recovery material are runtime state.

Receipts live in `~/.local/state/azurelocalbox/receipts/`. Each records the executed source
hash, invocation ID, result and observation times. Current source can run from the working
tree under the operator's instruction. A Git publication or a new dated copy is not a
runtime dependency.

Existing guest-helper and credential-store paths are durable bindings in configuration.
Their historical date suffixes identify real existing directories and have no expiry
semantics. The scripts use elapsed-time bounds rather than fixed calendar cut-offs.

## Verification

```bash
BICEP_CLI="$HOME/.azure/bin/bicep" python3 -B scripts/canonical_ci.py
git diff --check
```

The repository's separate `Offline canonical operations` CI job runs source/credential
exclusions, Python/JSON and PowerShell syntax checks, pinned Bicep compilation and mocked
startup, disk and file-service regressions. It has read-only repository permission and no
Azure login or native deployment step. Live lab acceptance remains a separate operation.

Startup heartbeat, cluster health and workload readiness are separate checks. Retain the
normal shutdown schedule and read an uncertain command's actual result before retrying it.
