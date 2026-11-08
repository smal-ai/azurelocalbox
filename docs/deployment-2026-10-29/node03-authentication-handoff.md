# NODE3: verified local readiness, human Arc authentication next

## Run from the owner's terminal

From `/home/quintin/play/azurelocalbox`:

```bash
python3 -B scripts/register-smal-node03-console.py
```

- Use a real human TTY. The launcher refuses captured/headless authentication.
- Complete only the official Microsoft device-code/MFA flow shown in that terminal,
  with the approved tenant/account. Do not copy codes or credentials into chat/files.
- The existing Owner PIM role was active at the latest pre-handoff check. Keep it
  active throughout the registration. The launcher checks it but does not activate,
  extend or grant privileges.
- Do **not** register NODE1 or NODE2 again. Both existing Arc identities remain
  Connected after resizing and are unchanged.
- On interruption/reboot/error, preserve the NODE3 marker and inspect, not replay:

  ```bash
  python3 -B scripts/register-smal-node03-console.py --inspect
  ```

## Independently verified at 12:23–12:24 SAST

- All four guests are Running. Each Azure Local node has **64 GiB / 8 vCPUs**,
  expected OS build **26100.33650**, standalone domain role and no S2D pool yet.
- NODE3 VM ID **5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9**, management **10.64.0.13/24**.
  Actual live non-zero MACs match their guest adapter names on all three nodes.
- All twelve approved blank 170 GiB data devices are bound by actual VHD GUID,
  path and guest unique ID. OS disks are explicitly excluded. NODE1's relocated
  device has its original identity. See `three-node-local-identity-bindings.json`.
- The pinned **AzureEdgeBootstrap 1.0.0** command and module hash match on NODE3,
  as well as NODE1/2. Target solution remains **12.2610.1004.41**.
- NODE3 answer-file cleanup, credential rotation and common cluster-only credential
  login passed. No setup-log/answer-file review flags remain. Clock offset was
  about **0.012 seconds**, with no manual clock adjustment.
- All nine node-to-platform private DNS/TLS paths passed: vault **10.200.17.11**,
  diagnostic Blob **10.200.17.9**, unused witness Blob **10.200.17.10**. These are
  transport tests, not managed-identity data-plane acceptance.
- Daily startup includes all four exact VM IDs. Its live no-op run succeeded with
  healthy heartbeats and **zero** start/reboot requests.
- The separate NODE3 console was installed and hash-verified, **installed-not-invoked**.
  No registration, authentication stream capture or owner ARM token forwarding was
  performed by its installer. Script SHA256:
  `1B1A1ECC40A4B83C7CDFB600862A0EB12EFDF7D9614F538509FBC2783CC39A81`.

Before first initialization, NODE3's bootstrap-status endpoint was unavailable
(`EndpointNotFoundException`). This is retained as the pre-registration observation,
not treated as a successful Arc bootstrap or proof of a failed registration.
The supported initializer is invoked only by the human command above.

Proofs:

- `node03-local-completion.json`.
- `../deployment-2026-10-27/private-ssh-three-node-live-before-arc-20261029.json`.
- `start-20261029-102241-6d02b948.json`.
- `node03-arc-console-install-receipt.json`.
- `../deployment-2026-10-27/private-ssh-install-node03-arc-console-20261029.json`.

## After authentication

Independently verify NODE3's actual Arc resource ID, principal ID, region and health.
Only then apply its three approved scoped platform roles and use the exact
three-node **No Witness** configuration for reviewed secret delivery and resource-
creating service **Validate → Deploy**. NODE3's principal ID remains unknown in
the public local binding until that Azure readback. No guessed identity, witness
key, Shared Key enablement, policy exemption or public-access change is authorised.

The cluster, bridge, custom location and full platform acceptance remain incomplete.
