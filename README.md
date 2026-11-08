# azure-localbox

## Daily startup

Start the existing outer host and all four nested guests (DC plus three nodes) after the nightly shutdown:

```bash
python3 -B scripts/start-smal-localbox.py
```

Requires existing Azure sign-in/PIM access and the private VPN. Safe to rerun after
success. Waits for the host agent and guest heartbeats, without rerunning bootstrap
or changing the shutdown automation. [Startup and recovery details](docs/operations/start-localbox.md).

## Current deployment: shared SMAL landing zone, 2026-10-27

The earlier LocalBox deployment was removed. Use the existing shared
`rg-smal-network-san-1/vnet-smal-san-1/snet-localbox-host` (`10.200.16.0/24`).
Do not reuse the archived spoke/registration IDs below or run the historical
`azd provision` / teardown examples. Legacy preprovision now fails before mutations.

Current work and approval gates: [deployment preparation](docs/deployment-2026-10-27/README.md).
Latest apply outcome: [successful private host retry](docs/deployment-2026-10-27/host-retry.md).
The outer host is running at `10.200.16.4`; compute charges are active. Azure Local
bootstrap/registration, resource bridge and AKS are not deployed by this phase.
Subsequent [guest preparation](docs/deployment-2026-10-27/private-powershell.md) verified
key-only PowerShell over private Bastion and installed Hyper-V. The approved reboot
completed, and Hyper-V management and private PowerShell were reverified afterwards.
The [next bootstrap phase](docs/deployment-2026-10-27/bootstrap-next-plan.md) expanded
C: into the existing 1 TiB OS disk and identified unsafe vendor-module helpers that
must be replaced. The approved current 2610 ISO is downloaded and publisher-checksum
verified, but remains unmounted and unexecuted. No nested platform has been deployed.
[Asynchronous continuation and progress](docs/deployment-2026-10-27/bootstrap-async-control.md)
are configured with a ten-minute follow-up cron. The initial readiness check is blocked
on the remaining safe implementation and design/apply decisions, not a running cluster job.
`infra/bicep/main.smal-host.bicep` is the separately approved **private outer-host phase**,
not an approved Azure Local platform/bootstrap deployment. Host costs and the existing
signed-in deployment identity are approved. Bootstrap, version-specific egress,
nested ranges/routing and platform governance effects remain gated. The template
does not deploy shared networking, bootstrap extensions, RBAC or SMAL workloads.

The remainder records the **historical** deployment design, not current live state.

An [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/)
project that deploys Jumpstart **LocalBox** (nested 2-node Azure Local + Azure Arc
+ AKS Arc) into an **enterprise-vended, firewall-governed Virtual WAN spoke** in
South Africa North, registering the Azure Local instance in West Europe.

This is a **brownfield** adaptation of upstream
[`microsoft/azure_arc` → `azure_jumpstart_localbox`](https://github.com/microsoft/azure_arc/tree/main/azure_jumpstart_localbox).
Vendored sources and their pinned commits are recorded in
[`docs/vendor/SOURCES.md`](docs/vendor/SOURCES.md).

## Layout

```
azure.yaml                     # azd project (infra-only), points at infra/bicep/main.localbox
infra/
  bicep/
    main.localbox.bicep        # subscription-scoped wrapper (creates 2 RGs, BYO network)
    main.localbox.parameters.json
    network/network.byo.bicep  # references EXISTING LZ spoke subnet, creates nothing
    host/host.bicep            # patched: governed mode (no public IP / no in-spoke bastion)
    mgmt/, network/, host/     # vendored upstream modules (pinned)
    modules/rgRoleAssignment.bicep
  artifacts/PowerShell/        # vendored + patched in-VM automation
  hooks/                       # azd pre/postprovision
docs/vendor/localbox/          # pinned mirror of LocalBox docs (context)
```

## Key design decisions

| Area | Decision |
|---|---|
| Target subscription | `8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea` (quintindekok-app) |
| Client VM + nodes RG | `rg-localbox-nodes-san-1` in **southafricanorth** |
| Azure Local registration RG | `rg-localbox-azlocal-we-1` in **westeurope** (SAN is not a supported Azure Local region) |
| Network | **BYO** — NIC placed in existing LZ spoke `vnet-az-test-wkl-san-1/snet-default` (`10.201.0.0/24`). We create **no** VNet/subnet/NSG/UDR/NAT/Bastion/public IP. |
| VM SKU | `Standard_E32s_v6` (available in SAN) |
| Management | Central LZ Azure Bastion (Standard, IP-based) over **RDP 3389** |
| Bastion NSG rule | `AzureBastionSubnet (10.202.0.0/26) -> 3389` added by the **LZ/connectivity team** on the spoke NSG (not by us) |
| Egress | Spoke forces `0.0.0.0/0 -> SAN Azure Firewall`; the LocalBox allowlist is already in place |
| Teardown | `azd down` destroys both our RGs; the LZ spoke is never touched |
| Foundry Local / GPU | Out of scope (all GPU SKUs are `NotAvailableForSubscription` in SAN) |

### Two-RG / registration behaviour (important)

Upstream LocalBox registers Arc nodes + the Azure Local cluster into a single RG,
and the Arc onboarding RG is **hard-coded to `$env:resourceGroup`** inside the
PSGallery module `Azure.Arc.Jumpstart.LocalBox` (`Set-AzLocalDeployPrereqs`).

Rather than fork that module, the wrapper passes the **westeurope registration RG**
as `-resourceGroup` to `Bootstrap.ps1`, so all in-VM Arc/cluster operations target
`rg-localbox-azlocal-we-1`. The client VM itself is created by Bicep in the SAN
nodes RG. Consequence: LocalBox **progress tags** are written to the westeurope RG
(cosmetic azd UX only); the deployment is unaffected. `New-LocalBoxCluster.ps1` is
patched to resolve the client VM across the subscription for tag propagation.

## Prerequisites

See [`docs/PREREQS.md`](docs/PREREQS.md). Summary:

1. `az login`; select the target subscription (PIM to Owner if required).
2. **No service principal is required.** The deployment runs as the signed-in
   `az`/`azd` user, who must be Owner on the subscription (PIM activate if
   required). `main.localbox.bicep` passes only `spnProviderId` to the templates,
   and every role assignment it creates targets the client VM's system-assigned
   managed identity — not an SP.
3. **Fork hosting for patched in-VM scripts.** Because `artifacts/PowerShell/*` are
   patched, the client VM must download **our** copies. Push the vendored+patched
   `azure_jumpstart_localbox/` tree to a fork of `azure_arc` and set:
   `azd env set JS_GITHUB_ACCOUNT <account>` / `JS_GITHUB_BRANCH <branch>`
   (wired into `templateBaseUrl`). *Until this is done the VM would pull unpatched
   upstream scripts.*
4. The LZ team confirms the spoke/subnet exists and adds the Bastion→3389 NSG rule.

## Deploy

```sh
azd env new localbox-san
azd env set JS_GITHUB_ACCOUNT quintindk
azd env set JS_GITHUB_BRANCH localbox-governed-san
# optional overrides: JS_LOCATION, JS_AZURELOCAL_LOCATION, JS_SPOKE_*, JS_VM_SIZE
azd provision
```

The client VM authenticates to Azure with its **system-assigned managed identity**
(`Connect-AzAccount -Identity`) — no service principal secret is involved anywhere
in the flow. The VM's managed identity is granted the roles it needs by
`host.bicep`; the azd deployment itself runs as the signed-in user.

The in-VM automation continues for ~1–3 hours after `azd provision` returns.

## Teardown

```sh
azd down --purge
```

Removes `rg-localbox-nodes-san-1` and `rg-localbox-azlocal-we-1`. The LZ spoke
(`vnet-az-test-wkl-san-1`) and all connectivity resources are untouched.
