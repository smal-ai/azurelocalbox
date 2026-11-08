# Registration/deployment source review

Status: **static review, not application authority**. No module was imported,
registration initiated, role assigned or cloud resource created by this review.

## Sources and version filtering

- Current Microsoft ARM guide source blob
  `bea0e96c0203a56a0bc89de5affd8b2ea2e0b1e8`, retained under
  `upstream-review/arm-guide-source.json`.
- Current quickstart directory pinned at commit
  `b56eb9051390299afe2d913bf2d10861fef279fd`, exact JSON and parameter sample retained
  under `upstream-review/`. Template SHA-256
  `a95bf9a734cc7433f171a31685193ea053941b24f33111bddc9552ce20195f58`.
- Direct Arc registration guide, 2610 view, captured at
  `/tmp/opencode/localbox-20261028-arc-direct.json`, body SHA-256
  `39326cafc67cc06c8ed9fca1f94f175bd26bd5232b32fb008b003b234541523a`.
- AD preparation guide body SHA-256
  `25f931cc2ef508d4629a673b870ab19daac8c6ac7d9304e6f3c67b6dcc931d7b`.

The rendered ARM article includes release-specific content for multiple releases.
Its ARB application/client-secret include is inside `moniker range="<=azloc-24113"`.
The selected current `create-cluster` template has no `arbDeploymentAppID` or
`arbDeploymentAppSecret` parameters. **Do not create a new Entra application based
on that legacy section.** This corrects the preliminary interpretation of the
rendered page, not a performed Entra operation.

Direct registration supports device-code authentication without providing an
`ArmAccessToken`. Prefer that documented path using the existing approved identity,
with human authentication when requested. Do not copy the owner's existing ARM
token to the nodes implicitly. Pin `TargetSolutionVersion=12.2610.1004.41`, not an
interactive/floating release choice. Registration can update the OS and reboot.
The guide warns that undoing this Azure Local Arc registration requires OS
reinstallation, so this is a distinct owner-approved apply boundary.

## Findings that change the apply proposal

1. Both node local administrator credentials must be identical for deployment.
   Current separate per-node credentials need an explicit, cluster-only convergence
   decision. Never reuse the outer-host or DC credential.
2. `Validate` creates prerequisite resources, identities/roles, secrets and deployment
   settings. It is not a read-only preflight. Ordinary ARM template validation or
   what-if must not be confused with that service deployment mode.
3. The stock template enables public access on the **new deployment vault**. The
   current [private-endpoint guide](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deploy-private-endpoints-no-proxy-no-gateway)
   explicitly says to keep public access enabled during deployment while the
   portal/RP configure secrets. Source blob
   `a90466bf3610a824fde8afbd2ef8362fb6ca12d7` is retained. This must be reconciled with
   inherited policy and explicitly accepted if applicable. It is not permission to
   enable public access on the existing SMAL application vault.
4. The stock template assigns first-party RP and node identities roles at the owned
   RG, including Key Vault Secrets User at RG scope. The proposal must identify each
   principal, role and scope, and narrow vault data access where supported. No
   subscription-wide grants, new operator rights or automatic delete/recreate of
   existing role assignments.
5. Stock witness storage leaves several network/access defaults implicit, vault
   soft-delete configuration contains legacy values, and diagnostic retention uses
   an old API shape. Review policy/current API behaviour and deployment networking
   before deriving an apply template. Do not run this capture unchanged.
6. Stock sample network values are unrelated to this lab. Do not import its RDMA,
   9014-byte MTU, automatic storage IPs, sample prefixes or shared credentials.
   Use management/compute on `MGMT1/MGMT2`, storage on `STORAGEA/STORAGEB`, explicit
   storage prefixes/VLANs, and keep IPv4 gateways off storage adapters. Propose
   management infrastructure pool `10.64.0.20-10.64.0.30` without node/DC/gateway
   overlap. Future AKS/pod/service networks remain a separate decision.

## AD preparation component

PSGallery's latest stable catalogue selected `AsHciADArtifactsPreCreationTool`
version `10.2402` (package endpoint `10.2402.0`). Package SHA-512 matches the gallery
metadata; measured SHA-256 is
`70e34f131ee0d4708dfc608b9fee5ce2d212b0e4746b83fd741e644a809753ac`.
Code/manifests are retained for audit only.

- Exported removal helper disables accidental-deletion protection and recursively
  deletes an OU. **Do not call it.** Its presence is not proof the normal create
  entry point executes deletion.
- Create helper sets the LCM account `PasswordNeverExpires=true`.
- It blocks GPO inheritance on the target OU and adds scoped computer-child,
  read-property and BitLocker recovery-object ACL entries.
- The official guide explicitly permits a custom/manual process instead of this
  optional helper. Use reviewed built-in AD/GPO/ADSI operations rather than import
  the package unchanged. Preserve domain password complexity/lifecycle defaults.
  An isolated cluster OU inheritance block and account lifecycle still need their
  exact reviewed decision. Do not treat it as an Azure Policy exemption or alter
  enforced organisational GPOs silently.

Proposed new OU path: `OU=SMAL01,OU=AzureLocal,DC=ad,DC=localbox,DC=test`, deployment
user `lboxdeploy`. Existing objects must be inspected, never reset or deleted to
make an installation pass.

## Pricing evidence

The live HTML pricing page returned `$-` placeholders for the host fee, so it was
not used as a numeric quote. Official Retail Prices API response is retained as
`upstream-review/azure-local-retail-rates.json`, complete one-page result.

For global public USD consumption, product `Azure Local`, SKU `Standard`, meter
`Standard Monthly Service Fee` is **USD 0.33 per core/day**. If the service assesses
the observed 12 guest-reported cores across the two nodes, the illustration is
**USD 3.96/day**, **USD 118.80 for 30 days**, or **USD 122.76 for 31 days** after any
applicable trial. This is not a contract quote or authoritative billing assessment.
Do not assume fresh trial eligibility, Azure Hybrid Benefit or OEM entitlement.

Existing outer-host costs are separate and already accepted. Vault operations,
diagnostic/witness storage, private endpoints if selected, monitoring/Defender and
traffic can add charges. No optional Windows Server subscription, AKS or workload
licensing is selected by this review.
