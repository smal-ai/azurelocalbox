# Cloud deployment gates after local preparation

**No Azure Local registration or cloud deployment is authorised by the local guest
approval. No platform readiness acceptance is claimed.** The current one-shot local
jobs stop at that boundary, even when their selected local checks pass.

Do not ask again for the approved host identity/costs, Simple V: layout, selected
media terms, local topology/address allocation, guest reboots/domain or explicit
temporary-secret/DPAPI boundary. These decisions are recorded and source-hash-bound.

## Facts now established

- Outer compute remains in South Africa North and the existing shared SMAL subnet.
- Fresh provider metadata advertises **West Europe** for both Azure Local clusters
  and resource bridge appliances, not South Africa North. Both providers are already
  Registered. See `control-plane-metadata-observation.json`. Provider advertising
  is not solution-specific admission, a region approval or a reason to use the
  returned future/preview API versions automatically.
- Selected Azure Local image WIM really contains `10.0.26100.33650`, matching the
  selected solution `12.2610.1004.41`. The supported educational-lab boundary remains
  explicit. A two-node virtual deployment on one outer VM is not production HA.
- Nested storage VHDXs are blank devices, not a deployed S2D pool or storage class.
  No AKS API, OIDC issuer, workload identity, image pull, model or GPU exists from
  this work. Local CPU/memory/NAT observations must not be relabelled inference
  readiness or authenticated PaaS access.

## Required exact plan, not a blanket approval request

1. Reconcile actual local job results, guest versions/protection, new-credential
   login and answer-file cleanup, logs needing review, DC/SRV/forwarder behaviour,
   nested Hyper-V and translated DNS/private/public flows. Inspect guest update
   applicability, Evaluation activation and actual clock synchronisation separately.
   Resume only exact failed/uncertain phases, never reformat V: or reinstall guests.
2. Resolve and pin the supported 2610 AD prerequisite/deployment components. The
   forest alone is not the Azure Local OU/deployment-account preparation. Do not
   execute the unsafe Jumpstart helpers or silently domain-join the nodes before
   the versioned deployment workflow requires it.
3. Confirm the registration/control-plane region, exact LocalBox-owned Azure RGs,
   names and resource set: Arc machines, Azure Local cluster/deployment settings,
   required extensions, bridge, custom location and unique deployment vault. A
   source-region list is not a request to create them. Do not repurpose the SMAL
   private application vault or revive archived West Europe resources.
4. Specify the actual onboarding authentication flow and resource scopes using
   existing approved sign-in where supported. No implicit forwarding of an owner
   ARM token to guests, token in process arguments/files/logs, new Entra principal,
   privilege activation or broad RBAC grants. Any necessary additional scoped
   identity/role effect requires its own explicit reviewed decision.
5. Price that exact resource set using current official pricing and actual assessed
   core information. Host costs are already accepted, platform charges are not.
   Document trials and their automatic end-of-trial billing, vault/diagnostic and
   any mandatory Defender/monitoring charges. Do not invent a quote from vCPU count.
   The retained [official billing guide](https://learn.microsoft.com/en-us/azure/azure-local/concepts/billing?view=azloc-2610)
   describes physical-core reporting and refers to current pricing. It is not a
   current monetary quote or spending approval.
6. Refresh inherited policy at parent scopes, mandatory billing/diagnostic exports
   and their destinations/retention. Obtain specific owner acceptance and resolve
   any policy conflict with its responsible owner. No exemptions, bypass tags or
   removal of required exports.
   The freshly retained [official permission guide](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-arc-register-server-permissions?view=azloc-2610)
   also names a diagnostic storage account, vault audit logging and Key Vault
   **data-plane** roles. An existing broad control-plane role is not proof of
   secret data access. Inspect actual effective permissions and the exact required
   resource set, not just role display names. Its provider/role examples were read,
   not executed. See `cloud-permissions-source-review.json`.
7. Give Entlz the selected actual vault and any required gateway hostnames, plus
   version-specific endpoint deltas. Existing source-scoped `*.microsoft.com`
   admission does not cover every Azure namespace. No implicit firewall mutation,
   TLS inspection workaround, public SMAL data-access switch or Arc Private Link
   Scope. Retain private service resolution and no nested route advertisements.
8. Complete the platform topology: actual Network ATC storage addressing without
   old defaults, bridge IP pool, custom location and any approved future VM/AKS
   network. Current node trunks deliberately allow only native management and
   storage VLANs. No AKS VLAN/pool or host route is configured yet. If AKS is chosen,
   define private API access, node/VIP exclusions, CNI node-then-host pod SNAT,
   service CIDR, OIDC and workload identity before application.
9. Commit/push the exact reviewed deployment source, inspect full validation/what-if
   and indirect service effects, obtain the remaining specific decisions, then
   register/deploy once and independently verify actual service results.

The final handover still requires cluster/bridge/custom-location IDs and health,
capacity/storage behaviour, optional AKS facts, ownership/recovery commands and an
honest passed/failed/pending checklist. A completed local OS/domain bootstrap alone
cannot satisfy that handover.
