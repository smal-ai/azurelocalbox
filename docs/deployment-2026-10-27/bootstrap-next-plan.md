# Next bootstrap phase: secure implementation and current image

Date: 2026-10-27. This is a proposed plan, not platform deployment approval.

**Current continuation:** [28 October state and receipts](../deployment-2026-10-28/README.md).
The own-agent cron was explicitly cancelled and remains off. The approved one-shot
storage task has since completed. The historical asynchronous design is retained in
[bootstrap-async-control.md](bootstrap-async-control.md), not an active schedule.

## Progress made

The host reboot, Hyper-V management and pinned-key private Bastion access are verified.
The next host preparation operation expanded **only C:** from **126.89 GiB** to
**1,023.89 GiB**, using the existing approved 1,024 GiB boot disk. Free space is now
**991.75 GiB** immediately after expansion, before ISO staging. No new Azure disk
allocation or reboot occurred.
The eight data-disk sizes and partition styles were unchanged. Defender remains active.

Source `783f637142e47429a779c1cf471090a1be67efba` was committed and pushed before
the expansion. The script refuses an unexpected boot disk, unhealthy/non-NTFS volume,
non-contiguous expansion, existing incomplete operation or any data-disk inventory
change. It does not delete recovery partitions or initialise/format any disk.
See `private-ssh-os-volume-expansion.json`.

The owner-selected current **2610 ISO is now staged and publisher-checksum verified**.
The operation completed at **13:37:31 SAST**, transferring **7,491,864,576 bytes**.
It remains unmounted and unexecuted at:

`C:\ProgramData\AzureLocalBox\Artifacts\2610\AzureLocal24H2.26100.32230.LCM.12.2610.0.3098.x64.en-us.iso`

Source `200670ba2acdac26107627e76cf42644be0a4e59` was committed and pushed before
execution. Exact length, ETag and publisher SHA-256 matched. The data-disk inventory
was unchanged, and the temporary private Bastion tunnel and local socket were closed.
See `private-ssh-stage-2610-image.json` and `checks-2610-image-staging.json`.

## Why the vendor bootstrap cannot simply resume

The first audit covered the repository's top-level scripts. Review of the exact,
hash-verified **Azure.Arc.Jumpstart.LocalBox 1.0.8** module exposed additional nested
side effects. Pinning the package does not remove them:

| Function | Behaviour requiring replacement |
|---|---|
| `GenerateAnswerFile` | Disables all guest firewall profiles and embeds deployment credentials in unattend XML |
| `New-DCVM` | Disables password complexity, sets minimum length zero and weakens account lifecycle |
| `New-AdminCenterVM` | Broad CredSSP delegation and downloaded Chocolatey code through `Invoke-Expression` |
| `Set-FabricNetwork` | Wildcard TrustedHosts and network PowerShell remoting |
| `Set-AzLocalDeployPrereqs` | Unpinned AD prerequisite installation and implicit forwarding of the current ARM token to nested nodes |
| `New-AzLocalNodeVM` | Incomplete repeat guards and automatic guest startup before a reviewed network/security state |

Exact source hash, functions and line numbers are in `module-execution-review.json`.
No module was imported or executed on the new host. These are engineering defects to
replace, not an invitation to approve a blanket security waiver.

## Proposed implementation

1. Use the existing Windows/Hyper-V cmdlets and **PowerShell Direct** from the immediate
   Hyper-V host, with explicit guest credentials, for nested Windows administration.
   Keep guest firewalls enabled. Do not configure wildcard TrustedHosts or CredSSP.
2. Omit optional Admin Center, Chocolatey, desktop customisation and logon automation.
   Do not require GitHub-hosted PowerShell installation merely to run the existing
   host transport. PowerShell 5.1 already supports its current Hyper-V tasks.
3. Keep AD-backed LocalBox compatibility as the initial design for review. A change
   to Key Vault-backed local identity is a separate architecture decision. The
   retrieved overview alone does not establish AKS compatibility for that alternative.
4. Generate separate per-role credentials, never reuse the outer-host administrator
   password as the domain password, and agree encrypted provisioning-secret storage,
   delivery and cleanup before generating guest answer files or registering nodes.
5. Pin every image and dependency, including transitive AD/Arc prerequisites. Use
   normal TLS validation and publisher hashes/signatures where supplied. Never claim
   that a download URL or a filename proves its content, version or service admission.
6. Make each phase inspect existing identities/state, preserve uncertain receipts and
   stop on conflict. No destructive "retry" of storage, VMs, network or registration.

This replacement is **not yet a complete executable cluster bootstrap**. The module
review closes an implementation blind spot, not the remaining engineering work.

## Image and version decision

The freshly retrieved [release information](https://learn.microsoft.com/en-us/azure/azure-local/release-information-23h2?view=azloc-2610)
states that new deployments use **12.2610.1004.41**. The
[what's-new page](https://learn.microsoft.com/en-us/azure/azure-local/whats-new?view=azloc-2610)
maps release 2610 to OS build **26100.33650**.

The old Jumpstart image label is `AzLocal2604`. Its actual offline OS build and current
service admission have not been verified. No claim is made that the label alone
proves either compatibility or end of support.

Do not substitute the generic `https://aka.ms/hcireleaseimage` alias: a metadata-only
HEAD request currently resolves to a **25398.469 / 2503** ISO, not the proposed 2610
image. No image bytes were downloaded. See `current-os-image-alias-head.json`.

The provider is Registered. Initial read-only catalogue requests failed with Bad
Request. Inspection of the actual service error identified the required
`solution-type=HCI` query parameter, absent from the published Swagger operation's
parameter list. Adding that exact service-specified filter resolved the request.
No role, provider or regional workaround was needed. Original failed reads remain
separate diagnostic receipts.

The authenticated catalogue explicitly maps solution **12.2610.1004.41** to composed
image **12.2610.0.3098**, with a public Microsoft download URL and publisher SHA-256
**`317330754A6DAC6F42C1BE40EB780E0959C6C3F7670B33D94556964CDCBC9E89`**.
Independent HEAD metadata reports **7,491,864,576 bytes**. The filename's OS base
build `26100.32230` is distinct from the release target build `26100.33650`.
Use the service's explicit mapping, not a filename-based compatibility guess.
See `current-os-image-catalogue-hci.json` and `current-os-image-2610-pin.json`.

The [software download guide](https://learn.microsoft.com/en-us/azure/azure-local/deploy/download-23h2-software?view=azloc-2610)
requires licence/privacy acceptance and describes a 60-day trial. Those terms have
now been explicitly accepted by the owner **for the selected ISO download only**.
See `current-2610-image-approval.json`. Platform/guest licensing, cloud resource
costs and required billing/diagnostic export are separate from the existing host-only
cost approval.

**Owner decision:** Azure Local **2610** selected for image staging, with the
educational-lab support boundary acknowledged. **West Europe** remains the candidate
control-plane region, not an approved registration action. Replace unsafe vendor
helpers rather than run 1.0.8 unchanged. The educational-lab boundary is explicit:
Microsoft's [virtual deployment guide](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-virtual?view=azloc-2610)
explicitly states that virtual deployments are for education/demonstration and are
not supported by Microsoft Support. This does not make the nested lab a supported
production platform.

Official content hashes and the selected image/version boundaries are recorded in
`bootstrap-current-source-review.json`.

The committed staging script downloads the exact pinned ISO through normal TLS,
requires the reviewed ETag and byte length, verifies the publisher checksum before
renaming its partial file, protects the artifact directory with Administrator/SYSTEM
ACLs, and preserves failed/incomplete state rather than redownloading blindly.
It does not mount, install, boot or register anything. The successful execution
receipt establishes the completed download and full-file checksum verification,
not an installed OS, offline build inspection or successful service deployment.

## Network and apply boundaries

Entlz's separate read-only review completed on 28 October. It found no overlap in
the inspected estate and identified concrete NAT/DNS corrections. Therefore the draft
`10.64.0.0/20`, `10.65.0.0/16` and `10.66.0.0/24` prefixes remain **unreserved and
unapplied**. The intended outbound model is SNAT to the outer-host private IP, not
advertising un-NATed nested sources through the legacy shared catch-all.

At this document's original 27 October observation, no data disk formatting/pool creation, nested VM/switch/NAT creation, new secret,
registration identity/grant, Azure Local registration, resource bridge, custom location,
AKS, workload or model run was performed. No shared-network change occurred.
The current image pin and full download verification are complete. The next platform
apply still needs the remaining dependency pins and safe replacement code, reviewed
storage and nested-network plan, scoped identity, deployment terms/cost and
mandatory-export acceptance. No further generic "continue" instruction is needed
for that engineering preparation. Material apply decisions remain explicit.

On 28 October, the explicitly approved Simple V: storage phase completed. This does
not complete the still-unimplemented guest/network/domain and cloud deployment phases.
