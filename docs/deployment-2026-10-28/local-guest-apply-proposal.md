# Local guest bootstrap proposal

**Proposed, not approved or applied.** This closes the local topology and secret
choices only. Azure registration, platform deployment and their costs/exports are
separate gates. The remaining executable guest/domain implementation is unfinished.

## Proposed local resources

Use the existing host, V: and the two approved media files. No new Azure resources,
disk purchases, shared-network changes, role grants or public administration.

| Guest | Purpose | Memory | vCPU | OS VHDX | Data VHDX |
|---|---|---:|---:|---:|---|
| `LB-DC01` | Windows Server 2025 Evaluation, AD DS and DNS | 4 GiB | 2 | 80 GiB | None |
| `LB-NODE01` | Selected Azure Local 2610 image | 96 GiB | 12 | 128 GiB | Four × 170 GiB |
| `LB-NODE02` | Selected Azure Local 2610 image | 96 GiB | 12 | 128 GiB | Four × 170 GiB |

- Generation 2 guests, Secure Boot and local-guardian vTPM. Preserve guardian keys.
- Fixed guest memory, no automatic checkpoints or automatic reboot-time bootstrap.
- Expose nested virtualisation only to the two Azure Local nodes. Disable their
  Hyper-V time-synchronisation integration service as required by the virtual guide.
- All VHDX and configuration files on V:. Maximum virtual disk capacity is
  1,696 GiB, excluding metadata. V: is about 2,032 GiB. Retain at least 200 GiB free
  and stop allocation below that floor. Dynamic disks do not allocate their maximum
  immediately, so initial free space does not prove capacity for future growth.
- Guest memory totals 196 GiB, leaving 60 GiB outside these three guests. Assigned
  virtual processors total 26 against the observed 32 host logical processors.
  These are arithmetic budgets, not measured workload capacity or an HA claim.
- No optional management hypervisor, router, Admin Center, Chocolatey, SDN
  controller, BGP, AKS or workload. The two Azure Local nodes remain a proposed
  two-node system, not an already registered cluster.

## Exact initial local network

One owned **Internal** Hyper-V switch, `LB-Fabric`. It is not bound to the Azure
adapter. No external switch, MAC spoofing on the outer Azure NIC, shared route,
Azure NIC forwarding or replacement outer default route.

| Endpoint | IPv4 | Default gateway | DNS |
|---|---|---|---|
| Host `vEthernet (LB-Fabric)` | `10.64.0.1/24` | None | Keep existing outer DNS unchanged |
| `LB-DC01` | `10.64.0.10/24` | `10.64.0.1` | Its authoritative AD DNS |
| `LB-NODE01` management | `10.64.0.11/24` | `10.64.0.1` | `10.64.0.10` |
| `LB-NODE02` management | `10.64.0.12/24` | `10.64.0.1` | `10.64.0.10` |

- One WinNAT object, `LB-NAT`, internal prefix `10.64.0.0/20`. It must translate
  **every off-lab flow**, including private endpoints and UDP/TCP DNS, to the actual
  outer NIC address. Verify that address is still `10.200.16.4` before application.
  Dynamic Azure allocation is not silently changed to Static.
- Inspect existing HNS, container and WinNAT configuration before creation. Any
  existing NAT, prefix collision or unexpected owned-name object blocks application.
- Four node vNICs attached to the internal fabric: two management/compute and two
  storage. Permit MAC spoofing/teaming only on these nested-node adapters. Identify
  guest adapters by their exact Hyper-V MACs, not enumeration order.
- Candidate storage VLANs `711` and `712`, prefixes `10.64.4.0/24` and
  `10.64.5.0/24`. Storage adapters get **no gateway or DNS registration**. The final
  Network ATC intent/IP assignment must be inspected before applying static storage
  addresses, so the bootstrap does not fight Network ATC automatic addressing.
- Management is untagged. Limit nested trunks to required VLANs rather than the
  sample guide's whole `0-1000` range. The DC uses an untagged management adapter.
- Initial host attachment is management only. No router is needed between initial
  management clients. Do not configure unused provider/transit/internal subnet
  labels simply because the legacy module had them.
- `10.64.10.0/24` (future platform API/node/VIP), `10.64.11.0/24` (future VMs),
  `10.65.0.0/16` (future pods) and `10.66.0.0/24` (future services) remain unused.
  Their exact pools, host VLAN interfaces/routes and node-then-host pod SNAT need
  a separate platform plan. No AKS/CNI deployment or route advertisement follows.
- This allocation needs owner confirmation for reservations outside the estate
  Entlz inspected. That review found no observed overlap but reserved nothing.

## Domain and secret lifecycle

- Proposed forest `ad.localbox.test`, NetBIOS `LOCALBOX`, authoritative DNS on
  `LB-DC01`. Guest clients use the DC, never central DNS as an alternate AD resolver.
- DC forwards non-authoritative names to `10.204.0.4` over host SNAT. No competing
  Azure private zones, central forwarding rule or VPN DNS change. Ordinary nested
  return traffic uses NAT state, not the management VPN.
- Create separate random secrets for DC/bootstrap, each node's local administrator,
  directory recovery and the deployment account. Do not reuse the outer-host secret.
  Retain password complexity and normal guest firewall profiles.
- Proposed retention: Windows DPAPI **LocalMachine** encryption, files accessible
  only to SYSTEM and local Administrators on this host. This protects stored bytes,
  not against a compromised host administrator. No encrypted external escrow is
  configured. Host loss can make these secrets unrecoverable.
- Host processes decrypt only when needed and pass `PSCredential` objects through
  PowerShell Direct. Never print secrets, forward ARM tokens to guests implicitly,
  or put credentials in Git, command arguments, state, transcripts or task actions.
- Unattended OS installation needs a temporary answer file containing the bootstrap
  credential in the guest image. Base64 is **not encryption**. If approved, keep this
  within the protected guest image only, remove setup answer-file copies after
  confirmed setup, rotate the bootstrap credential and verify removal before
  registration. Do not claim secure erasure of old virtual-disk blocks.
- If this temporary-secret boundary or host-bound DPAPI recovery limit is rejected,
  use owner-entered initial guest credentials and an owner-managed secret escrow
  instead. Do not invent a Key Vault subscription/grant as the alternative.

## Execution and acceptance gates

1. Owner accepts the topology/address allocation, local resource budgets, mounting
   and installing the selected media, guest reboots, domain creation and the exact
   secret boundary above. Existing media-download approval alone is insufficient.
2. Complete and test the safe image/guest/domain implementation, pin its inputs,
   inspect OS image metadata and signatures, commit and push before application.
   The evaluation ISO has no publisher SHA-256, only normal HTTPS/ETag/length and a
   measured hash. Do not describe that as publisher checksum verification.
3. Use durable one-shot host phases, exact resource/VM IDs, guarded checkpoints and
   independent readbacks. Preserve partial/uncertain operations. Never replay
   storage formatting or delete unrelated VMs, switches, files or markers.
4. Prove guest PowerShell Direct, nested Hyper-V, AD/SRV records, UDP/TCP forward
   resolution, permitted public TLS and translated private endpoint transport.
   A TCP connection is not authenticated PaaS access. No image/data operations
   without their separately approved identities.
5. Present the cloud deployment plan: exact supported registration region, existing
   deployer scopes, unique deployment vault and any gateway names, required
   extensions, mandatory billing/diagnostic export and costs. No broad grants,
   exemptions, implicit platform spending or optional AKS approval.

## References and limits

- [Azure Local virtual deployment guide](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-virtual?view=azloc-2610),
  retained source body SHA-256
  `c41222188470a39b99d8538cdac98e34834bc94eb30c8d56f691f84abdc2b660`.
  Supports internal NAT, PowerShell Direct, Gen2/vTPM, nested virtualisation and
  two/four adapter lab examples. It does not certify this unfinished topology.
- Entlz [factual review](network-review-receipt.json), including one WinNAT prefix,
  all off-lab source translation and domain DNS corrections.
- Microsoft virtual deployments are educational demonstrations, **not supported
  production deployments**. User acceptance of that boundary is already recorded.

This proposal is not an executable deployment plan or a claim that the engineering
work is complete. It narrows the next material owner decisions without requesting
the already-approved host costs, storage formatting or media terms again.
