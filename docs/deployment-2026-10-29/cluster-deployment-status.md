# Cluster deployment: blocked by two-node witness authentication

## Superseding decision

The owner approved the hash-bound three-node plan. The added Premium disk, new-only
W: format, existing node resizes and single VHD relocation have completed. NODE3's
one-shot local build and cleanup/login checks have passed. Its human-auth console
is installed, not invoked. This removes the **design requirement** for
the two-node Cloud Witness, not the policy constraint. Shared Key remains disabled.
See [current three-node execution](three-node-execution.md). This document retains
the original two-node blocker, not a claim that the three-node cluster has deployed.

## Verified inputs

Final private inspection at **09:26 SAST on 29 October 2026** verified both standalone
nodes on build `26100.33650`, successful Arc bootstrap, Defender enabled and four
live approved vNICs per node. The exact four RAW 170 GiB data-device unique IDs per
node match the approved allowlists. Host VHD paths, VHD GUID-derived guest serials
and SCSI LUNs were cross-checked, not inferred from capacity or enumeration order.
The OS disks were separately identified and excluded. No storage pool exists in
either node. The dedicated OU and enabled LCM account retain normal password expiry.

Proof: `../deployment-2026-10-27/private-ssh-cluster-inputs-20261029.json`.

## Confirmed blocker, not a public-access requirement

- `stlboxwitweu4766ea` has `allowSharedKeyAccess=false` and
  `publicNetworkAccess=Disabled`.
- A read-only signed container-list request returned
  **KeyBasedAuthenticationNotPermitted**. Raw account keys/CLI diagnostics were not
  exported. No blob/container write occurred.
- The owner explicitly stated **“shared key will not be allowed by policy”**. No
  attempt was made to enable it, weaken policy or request an exemption. The exact
  inherited deny assignment was not independently identified, nor is one needed
  to respect that instruction.
- The selected 2610 connected ARM deployment guide says `witnessType` **must be
  Cloud for a two-node cluster**. The pinned template supports Cloud and No Witness,
  not a file-share deployment option.
- Windows Cloud Witness uses an access-key-derived SAS. Shared Key disabling also
  rejects that key-authorised authentication. An Entra/RBAC role assignment alone
  does not replace the authentication in this selected deployment path.

Sources:

- [Azure Local 2610 ARM deployment parameter reference](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template?view=azloc-2610#arm-template-parameters-reference).
- [Windows Cloud Witness configuration and account-key-derived SAS](https://learn.microsoft.com/en-us/windows-server/failover-clustering/deploy-quorum-witness?pivots=cloud-witness).
- [Shared Key prohibition also denies service/account SAS, but not user-delegation SAS](https://learn.microsoft.com/en-us/azure/storage/common/shared-key-authorization-prevent#understand-how-disallowing-shared-key-affects-sas-tokens).

A user-delegation SAS is not interchangeable with the storage access key expected
by the selected Cloud Witness workflow. No supported keyless Cloud Witness option
was established for this selected deployment. Do not treat all SAS types as equivalent.

File-share witnesses exist in Windows Failover Clustering and are documented for
some Azure Local disconnected/rack-aware scenarios. That is not evidence that the
selected connected two-node ARM workflow accepts them. No `FileShare` enum value,
post-deployment witness replacement or No Witness workaround has been invented.

## Work prepared, not applied

`scripts/derive-smal-cluster-templates.py` derives three bounded templates from the
hash-pinned reviewed quickstart: secret children, cluster/edge prerequisite objects,
and deployment settings. Existing vault/storage/network/role resources are not
reapplied, and no public-access setting is introduced.

`scripts/deploy-smal-cluster.py` prepares staged what-if/apply/readback boundaries.
It **refuses all stages before credential sealing or resource creation** while the
witness policy constraint remains unresolved. It has no Shared Key enable command,
policy exemption path, or automatic failed-operation replay. It is not a successful
deployment receipt and is not offered as a runnable bypass.

The prepared credential path uses a one-use RSA4096-OAEP-SHA256 envelope from the
host-bound DPAPI secrets to the operator process, then secure ARM stdin parameters.
The RSA private key uses an anonymous RAM-backed descriptor, not a filesystem file.
The existing owner ARM token is never forwarded to the host. Clear values are not
written to files/arguments/logs. Normal managed runtimes do not guarantee erasure of
every transient string copy. Only a **synthetic cross-runtime crypto round-trip**
was tested. Actual platform credentials were not sealed or published by this attempt.

## Next decision

The current approved **two-node Cloud Witness** design cannot proceed with this
authentication constraint. Policy-compliant options need a reviewed design change:

1. A three-node topology, for which the selected ARM reference permits an empty
   witness type. This needs a new memory, disk-capacity, VM and bootstrap plan.
   A third node is not assumed to fit the existing approved allocations.
2. A Microsoft-confirmed supported alternative witness/deployment workflow for the
   selected release. Do not equate generic Windows support with Azure Local cloud
   deployment support or switch to disconnected operations implicitly.

No additional VM, file share, domain permission, account configuration, service
Validate resource or cluster/storage deployment was created as a workaround.

## Fail-closed execution verified

At **09:35 SAST**, the prepared `secrets` stage refused to proceed at its witness
preflight, before sealing credentials, requesting what-if, or submitting an ARM
deployment. Receipt: `cluster-secrets-receipt.json`. A subsequent independent
resource list contained no Azure Local cluster/edge/deployment-settings resource,
and the vault's active secret-name list remained empty. The owned RG also contains
an MDE extension on NODE1 and two Event Grid system topics associated with the
storage accounts. This cluster stage did not request those resources and did not
change or delete them.

The regression suite passed **191 tests**, including exact VHD/guest disk mapping,
policy refusal, bounded effect previews and synthetic RSA-OAEP interoperability.
Consequential source and the retained blocker/evidence are committed and pushed.
