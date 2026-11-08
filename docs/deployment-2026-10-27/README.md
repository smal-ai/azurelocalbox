# Shared SMAL LocalBox deployment preparation

Date: 2026-10-27. Relay: **REL-287**, intended implementer AzureLocalBox.
Status: **private outer host deployed and running; Azure Local bootstrap not deployed**.
Quintin directly instructed this chat to action the task. This is not a self-dispatched run.

**Asynchronous follow-up:** [control and progress](bootstrap-async-control.md). Native
ten-minute cron is installed/active for bounded offline continuation and progress
checks. Initial background preflight completed blocked. No cluster bootstrap job started.

**Guest progress at 12:36 SAST:** [private PowerShell and bootstrap preflight](private-powershell.md).
Key-only administrative PowerShell through private Bastion is verified. Hyper-V and
management tools are Installed. The approved reboot completed, Hyper-V management
queries succeed, VMMS is Running and the pending-reboot flag is clear.
No nested networking, disk formatting, Azure Local registration/cluster or AKS applied.

**Next-phase progress at 13:37 SAST:** [safe bootstrap implementation plan](bootstrap-next-plan.md).
C: now uses the already-provisioned 1 TiB OS disk, with data disks unchanged. The pinned
vendor module contains further unsafe guest-side operations and will not be executed
unchanged. The owner selected 2610 and accepted its licence/privacy terms for image
staging only. The current ISO is downloaded and publisher-SHA256 verified, not mounted
or executed. Replacement code, remaining dependencies, identity and nested-design work remain.

**Current outcome:** [successful reconciled host retry](host-retry.md). VM Running at
`10.200.16.4`, no public IP, guest agent Ready, nine attached disks/3,072 GiB. Private
Bastion-to-target RDP protocol transport verified; RDP login remains untested.
Compute charges are active. No Azure Local cluster/bridge/AKS or workload was deployed
by this host phase. The historical failure and preparation below remain evidence,
not the current VM state.

**Historical first attempt:** [outer-host deployment attempt](host-deployment.md). The private NIC
was created at `10.200.16.4`, but the VM was rejected because
`Microsoft.Compute/UseStandardSecurityType` was `NotRegistered`. At that point no VM or
disks existed, no VM compute had started and no feature registration/retry had occurred. Earlier preflight
and approval sections below are historical, not a claim that Azure remained unchanged.

**Subsequent approval:** [reconciled retry preparation](host-retry.md). The owner-approved
feature registration now reads Registered. Revised preview creates only the VM and
references the existing NIC without writing it. The original failure is preserved;
actual retry success is established by the separate apply receipt and final readback
linked in the current outcome above.

### Outer-host deployment instruction

Quintin subsequently instructed deployment and confirmed these are personal lab
subscriptions with **no cost-centre tag required**. The private outer-host phase is now
separately authorised; do not make a cost centre or review-date tag a prerequisite or
invent values. This phase does not configure nested ranges or run bootstrap, so those
platform gates are retained rather than falsely marked passed.

ARM validation and what-if of this exact host template succeeded. The preview proposes
only the private VM and NIC creates, with nine implicit managed disks, no existing
resource modifications/deletions and no shared-network or role-assignment changes.
Evidence: [host-validation.json](host-validation.json), [host-what-if.json](host-what-if.json),
[host-prepare.json](host-prepare.json). The deployment helper sends secure parameters on
stdin and redacts secure fields and literal credential values before retaining results.

A fresh VM-local admin credential is generated, not reused from old lab configuration.
Desktop Secret Service was unavailable. The value is retained in an owner-only `0600`
file under `~/.local/state/azurelocalbox/credentials/`, outside Git and tool output.
This is OS-permission protection, not a claim of encrypted keyring storage. No credential
value appears in command arguments, reports or Relay. Do not copy it into chat.

The original preflight decision/gate descriptions below are retained as history; this
explicit host-only instruction supersedes their requirement to wait for full bootstrap
readiness before creating the bare host. No platform/security/network gate is waived.

### Owner approval update

Quintin subsequently approved the host costs and use of the currently logged-in identity.
Tenant/subscription and principal `82f494a8-b9f5-46fc-b0f7-c70be0572a63` were rechecked.
These two decisions are closed, recorded in [owner-approvals.json](owner-approvals.json).
Use the existing session only for the task's scoped host-RG operations and exact subnet
join. No new or broader grant follows. The initial-preflight pending statements below
are historical for those two inputs, not a request for repeat approval.

Egress/nested design, bootstrap version pins, resource-specific security/governance
admission, secure guest-access bootstrap, cost-centre/review date and operating window
remain separate. No VM is deployed merely to wait while incurring approved-but-idle costs.

Further read-only source checks are in [bootstrap-audit.json](bootstrap-audit.json).
The legacy source enables wildcard TrustedHosts/CredSSP, persists the lab password in
configuration, optionally stores a Winlogon password, rewrites its transcript and adds
broad Defender exclusions. It must not be replayed unchanged under the cost approval.
No current credential value was read and no script/module was installed or executed.

Both published VHD/checksum endpoints respond successfully; HEAD metadata and published
hashes are recorded without downloading either VHD. The official PSGallery metadata lists
LocalBox module **1.0.8** as latest stable. Its 22 KB source package was retrieved solely
for static inspection and its SHA-512 verified against the catalogue. It was not imported
or installed. Availability/hash matching does not attest current image patch level,
service-side deployment support, evaluation licensing or full module compatibility.

Run the read-only local gate check with:

```bash
python3 -B scripts/check-smal-apply.py --offline
```

It currently exits **2**, listing the remaining technical/metadata gates. The approved
cost and matching existing identity are not listed as missing. It never deploys, grants
roles or reads guest credentials. A later live precheck also verifies the exact current
tenant/principal and stops if the host RG has changed, rather than overwriting work.
Gate fields are bookkeeping and do not replace human approval or Azure enforcement.
Nine offline regression tests now pass, including approval-boundary and fail-closed checks.

## Decision

Use the supplied shared SMAL network. Do not replay old `azd` provisioning. Do not create
a VM while bootstrap is known to be blocked and material configuration/cost choices are
unapproved. No Azure resource or permission was created/updated/deleted by this work.
No LocalBox VM exists, so **no LocalBox VM compute was started**.

The host-only candidate is deliberately smaller than a LocalBox platform deployment.
Compilation does not make it deployable approval or establish platform readiness.

## Fresh observations

Sources: [preflight.json](preflight.json), [supplemental.json](supplemental.json),
[policy-definitions.json](policy-definitions.json), [address-overlap.json](address-overlap.json),
[dns-probe.json](dns-probe.json). Commands use explicit ARM subscriptions and the current
owner-authorised CLI sign-in in place. No `.env`, `.envrc`, credential cache, VPN key or
historic environment was read or copied.

| Check | Result and limit |
| --- | --- |
| Identity | Expected tenant `c6e67968-af25-4557-ab8b-06b693048d3b`, app subscription `8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea`, Enabled |
| Signed-in principal | Object ID `82f494a8-b9f5-46fc-b0f7-c70be0572a63`. Effective RG/subnet permission reads contain `*`; this is not approval for another identity or broad role grants |
| Host RG | Existing `rg-localbox-nodes-san-1`, SAN, empty, expected SMAL foundation tags, no locks |
| Local platform | No Azure Local cluster, resource bridge, connected Kubernetes or provisioned AKS Arc cluster found by the recorded subscription query. Old October evidence is historical, not reusable health/identity evidence |
| Existing VNet | `rg-smal-network-san-1/vnet-smal-san-1`, `10.200.16.0/22`, DNS `10.204.0.4` |
| Host subnet | `snet-localbox-host`, `10.200.16.0/24`, no observed NIC allocations. PE subnet remains separate and is not a host target |
| Host NSG | Bastion `10.202.0.0/26` to TCP22/3389 only, deny other inbound. Internet outbound deny remains enabled |
| Routing | Existing default route through `10.200.0.132`; no nested routes added |
| SKU / quota | E32s_v6 has no listed subscription restrictions. 32 vCPU, 256 GiB RAM. Regional and Esv6-family usage 0/100. This is not a capacity reservation or allocation guarantee |
| Windows host image | SAN has `MicrosoftWindowsServer:WindowsServer:2025-datacenter-g2:26100.33674.261024`, x64/Gen2. Candidate pins that version, not `latest` |
| Azure Local registration | Provider lists West Europe, not South Africa North, for `clusters`. West Europe is a candidate registration region, not a revived old RG |
| Policy | Eight inherited assignments from `atScope()` at both network and host RG. No exemptions or bypass tags introduced |
| Actual deployment host | `Gerard-EVO-X2`; both SMAL and resolver routes use `tun0`, source `172.16.0.130`; resolver TCP53 reachable. This is an actual route/probe check, not an active-VPN indicator |
| Private DNS | Direct query through `10.204.0.4` resolves `acrentlzsan1.azurecr.io` via its private-link CNAME to `10.200.9.5`. No registry login/image pull/data operation |
| Administration | Existing Bastion Premium, `enablePrivateOnlyBastion=true`, tunnelling enabled, no PIP association. No host exists to test a session/guest login |

Two harmless projection/CLI errors are preserved, not hidden: `az ad` rejects
`--subscription` because Graph is tenant-scoped; the corrected signed-in-user query
succeeded after tenant verification. The Bastion private-mode field is
`enablePrivateOnlyBastion`, not `enablePrivateOnly`; supplemental evidence records the
correct field. Initial nulls were not treated as an access failure or public Bastion.

## IaC candidate and unsafe legacy path

`infra/bicep/main.smal-host.bicep` is **resource-group-scoped** for the existing host RG:

- Creates only a private NIC and `LocalBox-Client` VM, with implicit managed disks.
- References the exact existing shared host subnet. No VNet, subnet, NSG, route, DNS,
  Bastion, public IP, registration RG, platform extension, SMAL PaaS or workload creation.
- E32s_v6, Windows Server 2025 Gen2, pinned marketplace version above. Explicit proposed
  `securityType=Standard` for nested Hyper-V, requiring security/governance acceptance.
- Candidate storage: 1,024 GiB OS plus eight 256 GiB Premium_LRS data disks, total
  3,072 GiB. VM/NIC/disk deletions detach rather than automatically delete data.
- System-assigned identity has **no RBAC grants**. No bootstrap, auto-logon, cluster
  creation, resource bridge, AKS or model installation. IP forwarding stays off.
- Requires owner-approved cost centre, review date, host username, secure password
  and explicit approval marker. No password/default credential or guessed expiry is stored.
- The approval marker is a safety input, **not an access-control or human-approval proof**.
  The caller must enforce exact subscription/RG and reviewed plan before applying.
- Legacy `main.localbox.bicep` still has old defaults, immediate bootstrap, broad platform
  grants and optional Ignore tags. Its historical content is retained, but preprovision
  now exits **before any provider registration, credential prompt, env mutation or Azure call**.

This template does not resolve bootstrap secret delivery, support acceptance, nested
network configuration or full platform lifecycle. Do not silently add those to a host
deployment. Do not use the historical `azd down`/purge commands for rollback.

## Governance effects to resolve before apply

The inherited deny initiative's observed blocked-size arrays do not include E32s_v6.
This is not a full policy-admission pass: ARM validation/what-if and effective assignment
parameters still need review against the final plan.

The inspected `VirtualMachine_GuestExtnforWindowsClient_Deploy` and
`VirtualMachine_ManagedIdentity_Deploy` definitions specifically target
`imagePublisher=MicrosoftWindowsDesktop`, not this candidate's MicrosoftWindowsServer
image. Do not infer their applicability from their names. Other inherited Defender/SQL
on-machines policies, guest extension identities, diagnostic destinations and remediation
effects still need a final resource-specific review. No existing export was removed.

SMAL's IoT Connections export decision to McapsGovernance in West US 2 remains its
separate gate, not permission for this task to deploy IoT Hub. Broader telemetry boundary
claims cannot be made from private NICs or private endpoints.

## Network and platform-version review

[network-request.json](network-request.json) is a draft sent to Entlz for review, not a
firewall-rule change or reservation. Candidate nested ranges are `10.64.0.0/20` for
infrastructure, `10.65.0.0/16` for pods and `10.66.0.0/24` for services. The infrastructure
subdivision is included in the draft. Read-only VNet/hub inventories across all three
subscriptions plus local LAN/Docker/VPN ranges show **no observed overlaps**. Other
nested/externally connected networks, future reservations and peer ownership review
remain outstanding. None of these ranges is allocated or configured by this work.

Proposed direction: nested outbound SNAT to the eventual outer private IP, nested
administration from the authenticated outer host through Bastion, private AKS API
when/if AKS is approved. No assumption of VPN-to-host ingress, advertised pod/service
CIDRs, static hub routes or NIC forwarding. The exact platform profile must establish
guest routing, source translation, forwarding, DNS forwarding and return paths.

Version gates remain explicit:

- Existing vendored deployment source is pinned to `027b9554b2534af190271bd7443d8556da745d3e`
  plus repository patches. Legacy image pin `AzLocal2604` and floating PowerShell modules
  are **not a newly verified supported version set**. No old images or stale fork branch
  will be downloaded merely because they worked previously.
- Select/pin the actual Azure Local image build, matching module/Arc/bridge versions,
  immutable patched bootstrap source and registration region. Verify support, asset
  availability and checksums before proposing bootstrap. Optional AKS Arc version,
  private API and workload identity are separate platform-design choices.
- **An exact egress allowlist is not yet available.** Its source IP, final versions and
  artefact sources are unresolved. Keep the NSG deny. Entlz owns all reviewed changes.
  The draft intentionally has no authorised destination rules. General HTTP80/HTTPS443
  guidance is not an Any-to-Any allowlist.

Official sources retrieved on 2026-10-27 with Spider:

1. [Esv6 series](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/memory-optimized/esv6-series):
   official [source](https://raw.githubusercontent.com/MicrosoftDocs/azure-compute-docs/main/articles/virtual-machines/sizes/memory-optimized/esv6-series.md)
   lists E32s_v6 as 32 vCPU/256 GiB and nested virtualisation Supported. This is not GPU
   capability, a production Azure Local hardware certification or an allocated host test.
2. [Nested virtualisation](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization):
   Azure Local nested deployments are evaluation, not supported production environments.
3. [Azure Local firewall requirements](https://learn.microsoft.com/en-us/azure/azure-local/concepts/firewall-requirements):
   no Arc Private Link Scope or HTTPS inspection; specified Arc names must resolve publicly.
   Private SMAL PaaS endpoints remain private. Resource bridge/Arc/AKS/update endpoint
   sets are additional dependencies, not implied by the three example Arc suffixes.

Retrieval limitation: rendered/source Spider results omitted the consolidated regional
endpoint sections, one links request timed out and one HTML extraction returned only a
doctype. The official GitHub **source API** subsequently recovered the missing catalogue
link and complete source, rather than treating missing extraction as empty requirements.
[egress-regional-source.json](egress-regional-source.json) preserves the public source
with its immutable blob SHA and SHA-256. [egress-review-baseline.json](egress-review-baseline.json)
projects all **82 West Europe endpoint rows**. Its published update is **2025-11-27**,
so this is a dated regional baseline, not a version-matched approved rule set.

Published ports include 80, 443, NTP 123 and a post-deployment AKS endpoint on 8084.
The catalogue contains unique-vault/optional-Arc-gateway placeholders and broad wildcards.
These must not be copied literally into a firewall rule. It also explicitly includes
platform diagnostic/billing endpoints, which need payload/destination governance review.
Do not silently remove required platform endpoints or claim diagnostic boundary conformance.
Exact version-specific network support remains open. Scratch results are under
`/tmp/opencode/localbox-20261027/`.

## Cost proposal, not spend approval

Read-only official [Azure Retail Prices API](https://prices.azure.com/api/retail/prices)
results are in [pricing.json](pricing.json), queried for South Africa North in USD.
Public retail, not an EA/MCA contract, tax or billing-currency quote:

| Proposed item | Public retail benchmark |
| --- | --- |
| Regular E32s_v6 Windows, no assumed Hybrid Benefit | USD 4.287/hour, USD 3,129.51 for 730 running hours |
| Eight P15 LRS 256 GiB disks | 8 × USD 46.31/month = USD 370.48/month |
| One P30 LRS 1,024 GiB OS disk | USD 164.66/month |
| Illustrative host + disks subtotal | **USD 3,664.65** using 730 host hours plus monthly disk rates |

Ignore Spot/Linux rates and separate shared-disk mount meters when costing the proposed
regular Windows/nonshared disks. No Spot eviction or Hybrid Benefit eligibility is assumed.
The subtotal excludes existing shared networking, traffic, monitoring/Defender/governance
charges, staging/witness services, nested platform licensing and all SMAL services. Budget,
expiry/review window, security-profile acceptance and actual contract rates require approval.
No paid host was started and no ongoing paid deployment is implied by these figures.

## Dependency-ordered next steps

1. Owner approves a concrete host shape/cost/security/image, cost centre/review date and
   named deployment principal. Current signed-in object ID above is **not automatically
   selected** as the new platform identity. Approve only RG-scoped resource creation and
   separately scoped subnet join. No self-grant, Owner/UAA/RBAC Administrator or copied secret.
2. AzureLocalBox completes exact platform/bootstrap version pins and Entlz/SMAL accepts
   nested ranges and routing/SNAT/DNS. Entlz reviews an exact source-IP/endpoint/port/proxy
   request and manages the network gate. The host-only template has no bootstrap to race it.
3. Final governance review, ARM validation and complete what-if. Commit/push only the
   reviewed consequential changes before Azure application, preserving earlier evidence.
   No Azure validation/what-if was misrepresented as a deployment in this preparation.
4. Apply only the approved host plan to the exact host RG, read back IDs/IP/disks and verify
   private Bastion + guest access. An idle paid host still needs an agreed operating window.
5. Separately approved platform bootstrap creates the new registration/bridge/custom location.
   Any registration RG is a new approved resource, not resurrected archived WE objects.
   Review platform identity grants and diagnostic paths before this stage.
6. If AKS Arc is approved, create and inspect the real workload cluster, private API,
   workload identity, versions, allocatable resources and CSI/PV/PVC/reclaim behaviour.
   Return passed/failed/pending platform acceptance and named upgrade/recovery ownership.
7. Only then accept SMAL local extensions/workloads. No model run, cloud fallback, registry
   push/pull or data ingestion is authorised by this preparation. Application go-live remains separate.

## Checks and boundaries

- Bicep **0.45.15** installed locally for compilation; no VM/guest software installation.
  Newer compiler availability notice is informational, not a template lint failure.
- New template compiles. Seven offline regression tests pass. They check resource types,
  exact existing host subnet, no PIP/bootstrap/RBAC/bypass tags, secure required inputs,
  image pin, disk retention and the pre-mutation legacy-hook guard.
- No ARM create/deploy, provider registration, role/Entra write, network/DNS change,
  bootstrap/test suite, old credential retrieval, model/workload execution or teardown.
- Existing untracked October evidence remains unrelated and uncommitted. No changes to
  Entlz/SMAL repos. This preparation is not final platform acceptance or a passed IG gate.
- No new VM exists; do not carry the historical “compute charges active” status into
  this new empty deployment. Existing shared service/billing commitments remain separate.
