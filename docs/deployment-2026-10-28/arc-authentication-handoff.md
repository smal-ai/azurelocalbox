# Arc registration: human device-code sign-in

This is the already approved authentication step, not another request for broad
permission. The current Microsoft device-code flow requires the owner's sign-in
and MFA. Do not substitute an exported existing ARM token, service-principal secret
or stored browser credentials.

## Private vault gate now tested

`private-vault-flow-probe.json` records a successful modern ARM
`Microsoft.KeyVault/vaults/secrets` creation and an authenticated private data-plane
read of the exact harmless marker. Normal DNS was `10.200.17.11`; public access
remained **Disabled before, during and after**. Only this owned non-credential probe
was soft-deleted after ID/value-hash and single-version checks. Nothing was purged.

This disproves the assumed blanket need to open the vault for ARM secret creation.
It does not prove the full Azure Local RP/managed-identity deployment. The real
service Validate step must verify that later. Keep the vault private and reference
it as an existing resource, rather than reapplying a public-access setting.

## Run from the owner's terminal on this deployment host

After the reviewed console package is installed, from `/home/quintin/play/azurelocalbox`:

```bash
python3 -B scripts/register-smal-node-console.py --node LB-NODE01
python3 -B scripts/register-smal-node-console.py --node LB-NODE02
```

- Use a normal **human TTY**, not a captured/headless tool. The launcher refuses
  headless execution and never captures the SSH authentication console streams.
- It reuses VPN → private Premium Bastion → pinned-key SSH → exact VM-ID PowerShell
  Direct. No public IP, alternate transport, password/agent forwarding or TrustedHosts.
- Authenticate only through the official Microsoft browser flow shown in that
  terminal, using the existing approved account in tenant
  `c6e67968-af25-4557-ab8b-06b693048d3b`.
- Do not paste authentication codes, passwords or token output into chat, Git or a
  file. No transcript/console logging is installed by these scripts.
- Target subscription `8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea`, RG
  `rg-localbox-platform-weu-1`, region `westeurope`, solution
  **12.2610.1004.41** are fixed. No explicit `ArmAccessToken` is provided.

The host-side reviewed script is under
`C:\ProgramData\AzureLocalBox\Bootstrap\arc-console-20261028-01\Register-LocalBoxNode.ps1`.
Its source/approval hashes are checked by the installed package and launcher.
Guest credentials remain in host-bound DPAPI storage and are not passed as process
arguments or exported to the terminal.

## Interruption or reboot

Registration can update the OS and reboot. A marker prevents accidental replay.
Do not delete it or automatically retry registration. Inspect the service status:

```bash
python3 -B scripts/register-smal-node-console.py --node LB-NODE01 --inspect
python3 -B scripts/register-smal-node-console.py --node LB-NODE02 --inspect
```

Any documented post-update continuation must first be reconciled against actual
bootstrap/ARM state. No automatic reinstall is allowed. Final machine IDs/identity,
region, target solution and health must be independently read from Azure after
authentication. A console return is not final cluster/platform acceptance.
