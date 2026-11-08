# Private PowerShell access and bootstrap preflight

Date: 2026-10-27. Host: `LocalBox-Client`, `10.200.16.4`.

**Current prerequisite state:** Hyper-V and its PowerShell tools installed at
**12:19:44 SAST**, then rebooted with explicit owner approval. The new guest boot time
is **12:34:09 SAST**. Private administrator SSH/PowerShell and Hyper-V management
were reverified after reboot, with the inspection completed at **12:36:11 SAST**.
The host remains Running and the pending-reboot flag is clear.
Defender real-time protection remains enabled. No disks were formatted, no nested
network was configured and no Azure Local platform resources were deployed.

## Verified administration path

**Authenticated administrative PowerShell execution works through private Bastion.**

The verification at **12:14:36 SAST** returned the expected host, existing
`LocalBox-Client\arcdemo` account, Administrator membership and Windows PowerShell
`5.1.26100.33648`. SSH reported client source `10.202.0.6`, target `10.200.16.4:22`.
The loopback-only local tunnel was closed and its socket disappeared afterwards.

This is PowerShell commands over SSH, not a PowerShell 7 PSRP subsystem or WinRM.
No PowerShell 7 installation is required for this command transport.

Security and scope:

- Quintin explicitly approved read-only Run Command inspection, then a one-off
  Run Command setup for key-only SSH through Bastion. See the two approval JSON files.
- OpenSSH was already installed and running. No SSH software installation occurred.
- Only the existing local administrator is admitted. Password authentication,
  agent forwarding and TCP forwarding are disabled.
- Guest firewall permits the exact SSH executable on TCP 22 only from
  `10.202.0.0/26`. The original broad OpenSSH guest rule is disabled. Shared NSGs,
  firewall policy, routes, DNS, VM public access and role assignments were not changed.
- The dedicated Ed25519 private key stays in
  `~/.local/state/azurelocalbox/ssh/localbox-client_ed25519`, outside Git, owner-only
  `0600` in a `0700` directory. It is not passphrase-encrypted. Protect local state as
  administrator credentials. The key is not copied to the guest or passed as an argument.
- The host PUBLIC key came from authorised Azure Run Command on this exact VM and
  is pinned in the dedicated local `known_hosts`. SSH uses strict verification,
  no password fallback, no SSH agent and no inherited client configuration.
- WinRM listeners, TrustedHosts, CredSSP, Defender settings and RDP were not modified
  by the access setup. Existing WinRM service state was observed, not changed.
- The original SSH configuration and its existing AllowGroups restriction were
  preserved. An owner-created backup remains in `C:\ProgramData\ssh`.

## Reconciled failures

The initial setup rejected an active AllowGroups directive before making guest
changes. Read-only inspection captured its complete configuration hash and confirmed
no setup marker, backup or key file. The revised setup preserves that exact gate.

The next operation configured SSH but failed verification because Windows represents
`10.202.0.0/26` as `10.202.0.0/255.255.255.192`. It stopped sshd rather than silently
restoring password access. Read-only inspection reconciled the pending operation.
Recovery verified exact config/backup/key/rule state and only started the service
and completed its marker. It did not repeat the configuration writes.

The first login observation timed out locally without a retained result. It remains
uncertain, not relabelled successful. A subsequent observation timed out before
authentication. Inspection confirmed the SSH listener and scoped rule but no accepted
connection. Our added service filter was incompatible with the image's `sshd` service
SID type `NONE`. A guarded repair removed only that extra service filter, retaining
the executable, port and Bastion source. The next verification succeeded.

All failure, inspection, recovery and success receipts remain separate. No safety
receipt or marker was deleted to enable a retry.

## Host preflight results

| Check | Observation |
|---|---|
| Nested virtualisation | CPU extension, firmware virtualisation and SLAT flags true |
| Capacity | 32 logical processors, 256 GiB RAM |
| Hyper-V at initial inspection | Available, not installed |
| Data disks | Eight 256 GiB RAW disks, not formatted |
| OS volume | 127 GiB C: partition on 1,024 GiB OS disk, 95 GiB free |
| DNS | Host uses `10.204.0.4`, direct resolver query succeeded |
| NTP | Valid matching response from `time.windows.com`, clock not adjusted |
| Identity endpoint | Entra discovery HEAD returned HTTP 200 |
| Azure management | HTTP 400 response over normal TLS, not authenticated API access |
| Gallery | HEAD returned HTTP 405, not package-download verification |
| Raw GitHub | HTTP 404 for the tested path, not bootstrap-artifact validation |
| Image checksum URLs | Both HEAD responses HTTP 200, no image download/hash verification |
| GitHub releases/assets | DNS works but requests failed before HTTP response |
| Defender | Antivirus and real-time protection enabled |

The last two GitHub hosts are absent from Entlz's exact HTTPS list. No firewall-log
correlation was performed, so request failure is not labelled a proven firewall deny.
No WebSocket, nested egress, registry pull or complete platform readiness is claimed.
Findings and the draft nested-range/SNAT review request were sent to Entlz.

## Completed bounded bootstrap stage

The request to continue local bootstrap permits the initial local virtualisation
prerequisite. The committed `prepare-smal-host-hyperv.ps1` installed only the Windows
Hyper-V role and management tools, with `-Restart:$false`, using the verified SSH
transport. It checked the exact host, existing elevated account, virtualisation flags
and Defender state. Its own durable marker blocks an uninspected repeat. Source
`075e04a0b67933385ec92b4e21ba4eb7c11e073e` was committed and pushed before execution.
`private-ssh-hyperv-prerequisite.json` reports both features Installed and
`restartNeeded=Yes`, with the original boot timestamp unchanged at that observation.

This is not approval for nested network ranges, storage-pool creation/formatting,
legacy bootstrap scripts, floating downloads/modules, registration identities,
telemetry choices, Azure Local registration or AKS. The access setup itself did not
authorise a reboot. The subsequent explicit approval and outcome are recorded below.

## Approved reboot and post-reboot verification

Quintin answered **"yes, do that"** to the explicit host reboot and verification
question. `host-hyperv-reboot-approval.json` records that bounded authority.

- Source `ec3c81d7fcb6ddaff86ac8b425c5e3a664e6233f` was committed and pushed before
  the one scoped `az vm restart` action. It returned exit 0 at **12:34:12 SAST**.
  No force flag, stop/deallocation or automatic retry was used.
- Guest boot time changed from `2026-10-27T09:21:23.6797000Z` to
  `2026-10-27T10:34:09.5000000Z`. This establishes the reboot, not only the API response.
- The first pre-reboot read-only inspection failed because VMMS was not yet registered
  while the role installation awaited reboot. The corrected read-only inspection
  confirmed that state before any restart. Both observations are preserved.
- After reboot, the same pinned SSH host key was accepted. The existing administrator
  successfully executed read-only PowerShell through private Bastion, source
  `10.202.0.5` to `10.200.16.4:22`. Tunnel and local listener were closed afterwards.
- Hyper-V and its PowerShell tools are Installed. VMMS and sshd are Running.
  `Get-VMHost` succeeds, reporting **32 logical processors and 256 GiB RAM**. The
  Hyper-V management WMI service is present, with reported HealthState `5`.
- Pending reboot is false, Defender real-time protection is true, the eight data
  disks remain RAW and DNS remains `10.204.0.4`. There are **zero nested VMs, virtual
  switches and NetNat entries**. No nested VM boot test or platform deployment ran.
- Independent Azure readback at **12:36 SAST** confirms VM Running/agent Ready,
  `10.200.16.4`, no public IP, NIC forwarding disabled and all nine disks attached,
  totalling 3,072 GiB. Compute charges remain active.

Receipts: `host-hyperv-restart-action.json`, `private-ssh-pre-reboot-hyperv-check2.json`,
`private-ssh-post-reboot-hyperv-check.json`, `host-hyperv-post-reboot-arm.json` and
`checks-host-reboot.json`. This passes the host-role/reboot/access checks, not Azure
Local cluster readiness. Safe pinned platform dependencies and the reviewed nested
network/identity/telemetry design remain outstanding.

## Usage

Run only an authorised, reviewed PowerShell script committed and pushed on the current
branch. Use a unique receipt name and inspect any existing/uncertain result first.

```bash
python3 -B scripts/smal-private-powershell.py \
  --script scripts/verify-smal-private-powershell.ps1 \
  --receipt your-new-read-only-observation
```

The helper opens a temporary loopback tunnel over the existing VPN/private Bastion,
performs strict key authentication, executes the script and closes the tunnel.
It is a transport, not permission to run arbitrary deployments or expose secrets.

Evidence: `bootstrap-preflight-system.json`, `bootstrap-preflight-network.json`,
`private-ssh-setup-resume1.json`, `private-ssh-firewall-repair.json` and
`private-ssh-login-verification3.json`, `private-ssh-hyperv-prerequisite.json` and
`private-ssh-post-hyperv-login-verification.json`. Original VM apply/readback receipts
are unchanged. The earlier host-success manifest is a historical snapshot at commit
`63aa147`, not a checksum claim for subsequently updated progress documents.
