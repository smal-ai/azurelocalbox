# Reconciled outer-host retry

Date: 2026-10-27. Relay: REL-287.
Scope: continue the owner-requested private outer-host deployment, not LocalBox bootstrap.

## Actual outcome

**The private outer host is deployed and running. Compute charges are active.**

- Retry source committed/pushed before apply: `2259628651a19f0e58e64a9c3d5bcd813fb32573`
  on `deploy/smal-host-20261027`. No merge to main.
- `smal-host-20261027-retry1` succeeded at **11:21:57 SAST**. Original failed deployment
  remains in history, rather than being relabelled successful.
- Independent readback at **11:25:46 SAST**: VM Running, provisioning Succeeded,
  guest agent Ready (`2.7.41491.1216`), Windows Server 2025 Datacenter
  `10.0.26100.33674`, Standard security, `Standard_E32s_v6` in SAN.
- Existing NIC retained at **`10.200.16.4`**, now attached to the VM. No public IP,
  same supplied host subnet, NIC forwarding remains false. The attachment is the
  intended VM-side effect, not a rewrite of NIC addressing/subnet/default properties.
- **Nine Premium_LRS disks attached**, 1,024 GiB OS + eight 256 GiB data disks,
  **3,072 GiB total**. Exact IDs/tier/state are in the final readback file.
- New system-assigned principal `9ed2a366-1912-4c45-b189-b60ae1b6e4ff` has no observed
  role assignments. No extensions observed at this check. No bootstrap was deployed.
- Active effective default route is the user route to VirtualAppliance `10.200.0.132`.
  A separate BGP default entry is Invalid/inactive; it is not the selected path.

Private administration transport was tested from the actual deployment host:
existing VPN route and resolver reachable; current Azure identity opened a private
Premium Bastion native tunnel to this VM; listener was loopback-only; the target
returned a valid 19-byte RDP negotiation response. The temporary local tunnel was
closed after the probe. **Guest credentials/login and TLS certificate trust were not
tested**, and no authenticated guest command ran. This is transport/protocol evidence,
not an authenticated desktop session or platform readiness proof.

Evidence: `host-retry1-apply-receipt.json`, `host-retry1-final-readback.json`,
`host-bastion-transport.json`. The initial readback's `diskSizeGb` projection returned
null and its local total calculation failed. The corrected `diskSizeGB` inventory is
retained separately and explicitly verifies all nine sizes and attachments.

**Not deployed by this phase:** Azure Local registration/cluster, resource bridge,
custom location, AKS Arc, platform extensions or SMAL workloads/models. The current
registered platform query returns empty. Do not equate the running VM or network
owner's configuration receipt with a passed IG-01/platform acceptance.

No restart, stop or deallocation followed inspection. No automatic stop schedule was
installed. Owner-approved compute/disk costs now apply; this host has no running
application/model experiment. Safe bootstrap/version/identity/telemetry and nested
network acceptance remain the next platform work, not permission to replay legacy scripts.

## Approved capability and preserved state

Quintin directly approved `Microsoft.Compute/UseStandardSecurityType` registration.
The explicit app-subscription registration succeeded at **11:12 SAST**. Independent
readback and the retry reconciliation both report **Registered**. No other feature,
provider refresh, RBAC grant, security-profile substitution or shared-network change
was performed by AzureLocalBox. See `standard-security-feature-registration.json`.

The original `host-apply-receipt.json` and failed deployment remain preserved.
The retry requires exactly the unattached owner-created NIC at `10.200.16.4`, no VM
and no disks; it verifies tenant, principal, feature, subnet, absence of public IP and
disabled NIC forwarding. Any change stops the retry. The retained owner-only credential
is reused inside the process; it is not rotated, displayed or written to Git.

## No-write NIC reuse

The first retry preview identified a NIC Modify caused by omission of provider-default
fields, including the dynamically allocated address. It was rejected before apply.
That preview and preparation remain in `host-retry1-what-if.json` and
`host-retry1-prepare.json`.

The reviewed template now has `reuseExistingNic=true`. In this mode its NIC declaration
is not deployed; the VM uses the existing resource ID. No NIC properties are written.
Live NIC readback remains the authority for its IP, rather than a hard-coded output.

Revalidation and revised preview succeeded at **11:18 SAST**:

- **Create:** `LocalBox-Client` VM, with the approved nine managed disks.
- **Ignore / no write:** the existing `LocalBox-Client-NIC`.
- No changes to VNet/subnet/NSG/firewall/DNS, role assignments, registration or workloads.
- No bootstrap or optional extensions in the template.

See `host-retry1-reuse-nic-validation.json`, `host-retry1-reuse-nic-what-if.json`,
`host-retry1-reuse-nic-prepare.json` and its reconciliation snapshot.

The retry helper uses the separate deployment `smal-host-20261027-retry1` and a durable
`host-retry1-apply-receipt.json`. That receipt prevents repeated/uncertain execution.
It requires the exact source to be committed/pushed and tracked files unchanged before
apply. The original receipt is never cleared to bypass the old failed-operation guard.

## Network owner update

Entlz supplied a committed receipt for its separately authorised source-scoped platform
egress change, `d09b5c3`, configured at 11:01 SAST. This is completion information,
not an authority grant to this chat. The file was read at its absolute path:

`/home/quintin/play/entlz/workloads/smal/localbox-egress-receipt.json`

It records scoped FQDN/port admission, source exclusion from the other-source catch-all
and retained original Bastion/fallback rules. It explicitly reports
`trafficVerified=false`, no readiness claim, and unresolved version/telemetry and nested
source-routing conditions. This supersedes historical statements that there were no
port exceptions, not the requirement for actual runtime checks. AzureLocalBox made no
network write or speculative route. Bootstrap and un-NATed nested egress remain gated.

## Validation and handling

Sixteen offline regression tests pass. They include no-write NIC reuse, VM-only retry
preview acceptance, changed/attached/public-IP NIC rejection, required feature state,
secure parameter redaction and distinct host/platform gates. Old accepted October
evidence and unrelated work are preserved. No credential value is part of the evidence.

The sections above preserve retry preparation and its subsequent actual outcome.
The successful receipt and independent resource/power-state readback, not the preview
or Entlz message, establish that the outer host is now running.
