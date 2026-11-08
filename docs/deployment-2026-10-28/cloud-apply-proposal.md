# Staged Azure Local cloud apply proposal

**Proposed, not approved or applied.** Exact effect list: `cloud-apply-proposal.json`.
This proposal does not claim that the final derived ARM template or complete
service what-if has passed. Those remain mandatory before the corresponding apply.

## Placement and resource boundary

- Keep the outer VM, disks, existing shared SMAL VNet and private administration
  unchanged in South Africa North.
- Use **West Europe** control plane in new owned RG `rg-localbox-platform-weu-1`.
  The name was absent when inspected. Existing app subscription/tenant/deployer
  remain the already accepted identities, not new service principals.
- Create two Arc machine records, `smal-localbox-01`, required deployment/extension
  resources, resource bridge and `cl-localbox-smal-weu-1`. Use solution
  **12.2610.1004.41**, not a floating upgrade target.
- New dedicated vault `kv-lbox-weu-4766ea`, diagnostics account
  `stlboxdiagweu4766ea`, cloud-witness account `stlboxwitweu4766ea`, Standard LRS.
  Names require final availability/drift checks. No archived RG/resource is reused.
- Propose three private endpoints in the existing private-endpoint subnet for the
  dedicated vault and the two blob endpoints. Entlz remains the network/DNS owner.
  Any assignment to Entlz is limited to these new endpoints, exact DNS records and
  exact hostname admission for the LocalBox source, not a VNet/NSG/route redesign.

## Explicit security and credential changes

1. Generate a fresh **cluster-only** local admin secret, protected by host-bound
   DPAPI, and converge the two node Administrator accounts to it. Verify both new
   logins before any subsequent apply. Do not reuse the DC/outer-host secret or
   print/write clear values to Git, arguments, state or chat.
2. Create new AD parent/cluster OUs
   `OU=SMAL01,OU=AzureLocal,DC=ad,DC=localbox,DC=test` and unique LCM user
   `lboxdeploy`. Use reviewed built-in AD/GPO/ADSI operations instead of importing
   the optional audited helper unchanged. Block inheritance **only on that new
   cluster OU**. No enforced organisational GPO exclusion/filter, domain-wide
   password-policy change or Domain Admin membership. Keep the LCM account under
   normal password expiry and document owner rotation before expiry.
3. Use documented **device-code authentication** for node Arc initialisation.
   Human authentication/MFA is required when prompted. Do not explicitly export
   the owner's existing ARM token to the nodes. No new Entra app/client secret is
   proposed for the modern deployment template.
4. Registration is a distinct, potentially irreversible boundary. Microsoft's
   current guide says undoing this Azure Local Arc registration requires OS
   reinstallation. Registration may update the selected OS and reboot. No blind
   retries or automatic reinstall are permitted.
5. Apply only the listed first-party RP / new node managed-identity roles at the
   **new RG**, and vault data roles at the **new vault**. No Owner/Contributor,
   subscription-wide grants, new operator rights or privilege activation. The
   existing deployer may need vault-only Secrets Officer for the declared secret
   operations after effective permissions are checked. Inspect identities before
   grants and preserve existing equivalent assignments rather than deleting them.

## Deployment-vault public access and secret copies

The current Microsoft private-endpoint deployment guide says to keep the deployment
vault's public endpoint enabled while the portal/RP configure secrets. Accepting
this proposal explicitly permits that on the **new platform vault only** during
deployment. RBAC remains required, no anonymous secret access, 90-day soft-delete
and purge protection remain enabled. This is not permission to change public
access on any existing SMAL application resource.

The new vault stores the platform-required LCM/shared node credentials, witness
credential and recovery material as required by the supported deployment. Base64
is only the platform encoding, not encryption. Values must travel only over the
reviewed secure in-memory/HTTPS path. Exact secret delivery must be completed and
reviewed before any secret upload, not improvised by exporting them into a tool
result. Private DNS must resolve the new vault/blob names through the central
resolver. Public closure after deployment requires successful supported private-path
verification, not an unconditional switch that can break management/servicing.

**Stop if policy prohibits the required configuration.** This proposal grants no
policy exemptions or bypass tags. A temporary public vault endpoint must not be
substituted silently for a required private path or left open without acceptance.

## Local topology and storage effects

- Management infrastructure pool **10.64.0.20–10.64.0.30**, `/24`, gateway
  `10.64.0.1`, authoritative DNS `10.64.0.10`. Existing DC/node/gateway IPs excluded.
- Management/compute intent on `MGMT1/MGMT2`. Non-RDMA virtual adapters, normal MTU,
  no stock sample RoCE/9014-byte override.
- Storage A VLAN711: node1 `10.64.4.11/24`, node2 `.12`.
  Storage B VLAN712: node1 `10.64.5.11/24`, node2 `.12`.
  No storage gateways, automatic storage addressing off. API field names were
  checked against the selected deployment-settings schema.
- Azure Local may consume/format **only the four independently identified blank
  170 GiB data VHDXs per node** for S2D. Verify exact current unique IDs and host
  VHD backing before apply. Never reformat the outer V: pool or node OS disks.
- Keep one outer WinNAT prefix and all off-lab translation, outer IP forwarding
  off, no nested route advertisements. Verify the actual bridge/infrastructure
  traffic and return paths after creation.
- Keep the recommended security profile, BitLocker, signing, application control
  and protection. Stop on unsupported virtual-profile requirements instead of
  silently disabling controls. This remains an unsupported educational virtual lab,
  not production HA or GPU/inference acceptance.

## Costs and required exports

- Existing outer-host costs are already accepted and excluded from this decision.
- Official global L1 retail meter: **USD0.33/core/day**. At the observed 12
  guest-reported cores, illustration **USD3.96/day / USD118.80 per 30 days** after
  any applicable trial. Actual service core assessment, agreement, FX and tax can
  differ. No new-trial or Hybrid Benefit eligibility is assumed.
- The subscription already has **Defender for Servers Standard P2**, no remaining
  trial, with agentless scanning enabled. Preserve it. New Arc machines can add
  Defender charges. Public legacy P2 reference meter is USD0.02/node/hour, while
  current retail data also exposes newer workload-unit meters, so this is not a
  final offer-specific quote.
- Private Link Standard global reference is **USD0.01/endpoint/hour**, three
  endpoints **USD21.60 per 30 days**, plus processed data. Vault operations,
  diagnostic/witness storage, monitoring ingestion, traffic and tax are additional.
  These are metered charges, **not a hard spending cap**. Do not enable the optional
  paid Windows Server guest subscription or any new Defender plan.
- Preserve mandatory billing/core reports, streaming/episodic platform diagnostics
  and vault audit logs. Propose EU diagnostic location for West Europe and 90-day
  diagnostic retention, subject to inherited requirements. No telemetry suppression
  or deletion of required exports. This explicitly introduces cloud copies of
  machine/health/log/recovery information and deployment credentials.

## Staging and stop conditions

1. Reconcile local readiness and activate the already accepted DC Evaluation licence
   separately without purchasing or changing a product key. Assess update
   applicability, not generic WUA patch installation on Azure Local nodes.
2. Record owner decisions on this exact proposal. Complete/review consequential
   code, secret handling and network requirements, then commit/push before applies.
3. Apply only the bounded local preparation, new RG/prerequisites and node Arc
   initialisation. User completes normal authentication when requested.
4. Use the resulting exact machine/identity IDs to derive and review the service
   `Validate` preview. **It creates cloud resources**. Reject unexpected resources,
   roles, public exposure, policy effects or costs rather than treating approval as
   a general waiver. No tag-based exemptions or deletion/recreation of old roles.
5. Reconcile successful validation before `Deploy`. Preserve all failures and
   uncertain receipts. Do not replay `Validate` on a failed deployment to reset
   service state, licences or storage. Independently inspect final IDs/health.

No AKS, workload, inference model, GPU fallback, shared-network redesign, recurring
agent job or cron resumption is included. Later unlisted requirements stop for
review rather than expand this proposal automatically.
