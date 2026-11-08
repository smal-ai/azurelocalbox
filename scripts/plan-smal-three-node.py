"""Generate a review-only three-node proposal from captured live sizing evidence.

No Azure command, guest mutation, disk purchase or approval is performed.
"""
import argparse
from decimal import Decimal
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/deployment-2026-10-29'
GIB = 1024**3
CAPTURE = ROOT / 'docs/deployment-2026-10-27/private-ssh-three-node-capacity-20261029.json'
CLOUD = OUT / 'three-node-premium-cloud-sizing.json'


def budget(capacity, vhd_maximum, runtime, metadata=16 * GIB, free_floor=200 * GIB):
    result = {'capacityBytes': capacity, 'attachedVhdMaximumBytes': vhd_maximum, 'runtimeStateAllowanceBytes': runtime,
              'metadataAndRecoveryAllowanceBytes': metadata, 'minimumFreeBytes': free_floor}
    result['uncommittedMarginBytes'] = capacity - vhd_maximum - runtime - metadata - free_floor
    result['fits'] = result['uncommittedMarginBytes'] >= 0
    return result


def build():
    proof = json.loads(CAPTURE.read_text()); cloud = json.loads(CLOUD.read_text())
    if proof.get('status') != 'complete' or cloud.get('status') != 'complete-read-only': raise RuntimeError('Complete live sizing evidence required')
    host = proof['result']; vm = cloud['vm']; disks = cloud['disks']
    if vm['vmSize'] != 'Standard_E32s_v6' or host['logicalProcessors'] != 32: raise RuntimeError('Observed host SKU/CPU differs')
    if set(host['allVmNames']) != {'LB-DC01', 'LB-NODE01', 'LB-NODE02'} or host['thirdNodeNamePresent'] or host['proposedWDrivePresent']:
        raise RuntimeError('Existing guest/W-drive conflict')
    if len(disks) != 9 or any(row['sku'] != 'Standard_LRS' or row['managedBy'].lower() != vm['id'].lower() for row in disks):
        raise RuntimeError('Exact current Standard HDD disk set/ownership differs')
    if sorted(vm['luns']) != list(range(8)): raise RuntimeError('Expected existing LUN allocation differs')
    sizes = sorted(row['diskSizeGB'] for row in disks)
    if sizes != [256] * 8 + [1024]: raise RuntimeError('Observed disk sizes differ')
    v = next(row for row in host['volumes'] if row['letter'] == 'V')
    if v['health'] != 'Healthy' or host['pool']['memberCount'] != 8 or host['virtualDisk']['columns'] != 8 or host['virtualDisk']['resiliency'] != 'Simple':
        raise RuntimeError('Existing V pool differs')
    current_max = sum(disk['virtualSizeBytes'] for guest in host['guests'] for disk in guest['disks'])
    if current_max != 1696 * GIB: raise RuntimeError('Current virtual capacity budget differs')
    node1 = next(guest for guest in host['guests'] if guest['name'] == 'LB-NODE01')
    move = next(disk for disk in node1['disks'] if disk['lun'] == 4)
    if move['diskId'] != '45B23F1E-D817-4DE0-A84A-C5F2124F7E30' or move['virtualSizeBytes'] != 170 * GIB or move['parentPath']:
        raise RuntimeError('Exact proposed relocation differs')
    ram = 3 * 64 * GIB + 4 * GIB; processors = 3 * 8 + 2
    new_max = (128 + 4 * 170) * GIB
    budgets = {'V': budget(v['sizeBytes'], current_max - move['virtualSizeBytes'], (2 * 64 + 4) * GIB),
               'W': budget(2048 * GIB - GIB, new_max + move['virtualSizeBytes'], 64 * GIB)}
    if ram > host['hostMemoryBytes'] - 48 * GIB or processors > host['logicalProcessors'] or not all(row['fits'] for row in budgets.values()):
        raise RuntimeError('Proposed capacity does not fit with declared reserves')

    def price(product, meter):
        matches = [row for row in cloud['pricing']['items'] if row['productName'] == product and row['meterName'] == meter and row['unitOfMeasure'] == '1/Month' and row['currencyCode'] == 'USD']
        if len(matches) != 1: raise RuntimeError('Public retail meter ambiguous or absent')
        return Decimal(str(matches[0]['retailPrice']))

    current = 8 * price('Standard HDD Managed Disks', 'S15 LRS Disk') + price('Standard HDD Managed Disks', 'S30 LRS Disk')
    converted = 8 * price('Premium SSD Managed Disks', 'P15 LRS Disk') + price('Premium SSD Managed Disks', 'P30 LRS Disk')
    extra = price('Premium SSD Managed Disks', 'P40 LRS Disk')
    proposal = {
        'schemaVersion': 1, 'status': 'proposed-not-approved-not-applied', 'ownerApproved': False,
        'scope': 'three-node-policy-compliant-topology-and-explicit-ssd-capacity-change',
        'observedAtUtc': host['atUtc'], 'hostVmId': vm['id'], 'hostSkuBeforeAndAfter': 'Standard_E32s_v6', 'hostResizeRequested': False,
        'sourceEvidenceSha256': {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [CAPTURE, CLOUD]},
        'guestTargetProfiles': [{'name': name, 'memoryGiB': 64, 'vcpus': 8, 'action': 'create' if name == 'LB-NODE03' else 'graceful-stop-resize-and-start-preserve-identity'} for name in ['LB-NODE01', 'LB-NODE02', 'LB-NODE03']],
        'dcChanged': False, 'guestMemoryTotalBytes': ram, 'hostMemoryBytesObserved': host['hostMemoryBytes'], 'hostMemoryOutsideGuestsBytes': host['hostMemoryBytes'] - ram,
        'assignedVcpusTotal': processors, 'hostLogicalProcessorsObserved': 32,
        'diskConversions': [{'id': row['id'], 'sizeGiBUnchanged': row['diskSizeGB'], 'skuBefore': 'Standard_LRS', 'skuAfter': 'Premium_LRS', 'preserveDiskIdentityAndContents': True} for row in sorted(disks, key=lambda x: x['name'])],
        'newDisk': {'name': 'LocalBox-Client-Node03-SSD-20261029', 'sizeGiB': 2048, 'sku': 'Premium_LRS', 'region': 'southafricanorth', 'lun': 8, 'caching': 'None', 'deleteOption': 'Detach', 'driveLetter': 'W', 'fileSystem': 'NTFS', 'allocationUnitBytes': 65536, 'newDiskOnlyFormatting': True, 'joinExistingPool': False},
        'premiumStorageExplicitlyRequested': True,
        'existingNineDiskConversionSeparatelyRequested': True,
        'existingDiskConversionOutcomeReference': 'premium-disk-conversion-reconciled-result.json',
        'premiumStorageHumanInstruction': 'please change the disks to Premium SSD, we need it to be performant.',
        'onDemandBurstingOrPerformancePlusRequested': False,
        'volumeBudgets': budgets,
        'existingVhdRelocation': {'vmName': 'LB-NODE01', 'vmId': node1['vmId'], 'lun': 4, 'diskIdPreserved': move['diskId'],
                                  'guestUniqueIdPreserved': '600224801E3FB24517D8C5F2124F7E30', 'source': move['path'],
                                  'destination': 'W:\\AzureLocalBox\\Relocated\\LB-NODE01\\S2D-4.vhdx', 'requiredGuestPartitionStyleBeforeMove': 'RAW',
                                  'recreateOrShrinkVhd': False, 'existingSourceCopyDeletionOnlyAfterVerifiedMove': True},
        'newNode': {'name': 'LB-NODE03', 'vmId': None, 'bindReturnedVmIdBeforeFurtherActions': True,
                    'root': 'W:\\AzureLocalBox\\Guests\\three-node-20261029-01\\LB-NODE03', 'osDiskGiB': 128, 'dataDisks': 4, 'dataDiskGiB': 170,
                    'generation': 2, 'secureBoot': True, 'vtpm': True, 'nestedVirtualisation': True, 'dynamicMemory': False,
                    'guestTimeIntegrationEnabled': False, 'checkpointType': 'Disabled', 'automaticStartAction': 'Nothing', 'automaticStopAction': 'ShutDown',
                    'managementIp': '10.64.0.13', 'managementPrefixLength': 24, 'gateway': '10.64.0.1', 'dns': ['10.64.0.10'],
                    'adapters': ['MGMT1','MGMT2','STORAGEA','STORAGEB'], 'storageA': '10.64.4.13/24', 'storageB': '10.64.5.13/24', 'storageVlans': [711,712],
                    'reuseExistingInternalSwitchAndNatOnly': True, 'rdmaEnabled': False,
                    'solutionVersion': '12.2610.1004.41', 'osBuild': '26100.33650', 'reuseVerifiedIso': True,
                    'temporaryBootstrapSecretProtectedAnswerFile': True, 'cleanupAndRotateBeforeArcRegistration': True,
                    'finalCredentialRole': 'cluster-node-admin', 'existingDcOrOuterCredentialReused': False, 'domainJoinByPlatformOnly': True},
        'cloudDelta': {'newArcMachine': 'LB-NODE03', 'region': 'westeurope', 'newEntraApp': False, 'existingOwnerArmTokenForwarded': False,
                       'humanDeviceCodeAuthentication': True, 'newNodeRoleBindingsAfterIdentityInspection': [
                           {'role': 'Azure Stack HCI Device Management Role', 'scope': 'rg-localbox-platform-weu-1'},
                           {'role': 'Azure Stack HCI Connected InfraVMs', 'scope': 'rg-localbox-platform-weu-1'},
                           {'role': 'Key Vault Secrets User', 'scope': 'kv-lbox-weu-4766ea only'}],
                       'witnessTypeParameter': 'No Witness', 'serviceWitnessType': '', 'witnessCredentialReadOrUpload': False,
                       'existingWitnessAccountDeleted': False, 'sharedKeyEnabled': False, 'publicAccessEnabled': False,
                       'vaultSecretCountForLocalAndLcmCredentials': 2,
                       'node03DataUniqueIdAllowlist': None, 'requireExactNewDataIdsBeforeS2DApprovalOrServiceDeploy': True},
        'retailDiskCapacityUsdPerMonth': {'before': str(current), 'convertedExistingNine': str(converted), 'additionalDisk': str(extra), 'after': str(converted + extra), 'delta': str(converted + extra - current),
                                          'region': 'southafricanorth', 'currency': 'USD', 'contractQuote': False, 'operationTrafficTaxFxAndOtherPlatformChargesIncluded': False},
        'downtimeAndRecovery': {'gracefulGuestShutdownRequired': True, 'outerHostDeallocationAndRestartRequiredForSkuConversion': True,
                                'preserveExistingVmIdsArcResourcesVhdIdsGuardianAndSecrets': True, 'noAutomaticRollbackOrReplay': True,
                                'newExternalBackupOrSnapshotPurchased': False, 'existingHostBoundRecoveryLimitAcknowledgedAgainBeforeApply': True},
        'unchangedBoundaries': ['no shared Azure network change', 'no existing pool/volume reformat or extension', 'no node reinstall', 'no subscription-wide role grants',
                                'no policy exemption or privilege activation', 'no AKS, workload or model', 'no recurring agent job', 'no change to nightly shutdown automation'],
        'applyGates': ['approve this exact proposal and cost/downtime/credential delta', 'implement and test bounded apply sources, commit and push',
                       'fresh exact identity/capacity and ARM effect preview', 'preserve receipts for disk conversion and restarts', 'new disk exact Azure-to-Windows identity before format',
                       'resize existing nodes without replacing registration', 'verify exact relocated RAW VHD identity and new free-space budgets',
                       'build node03 and clean/rotate bootstrap material', 'human Arc authentication and independent returned identity verification',
                       'bind new guest/Arc/data disk IDs and update startup/inspection/role/template guards', 'review new exact three-node S2D allowlist before resource-creating service Validate/Deploy']
    }
    return proposal


def markdown(p):
    costs = p['retailDiskCapacityUsdPerMonth']
    return f"""# Three-node LocalBox change proposal

**Proposed, not approved or applied.** Exact effect list: `three-node-proposal.json`.
This changes the previous two-node topology. No part of the old approval is rewritten.

## Recommendation

- Keep the existing **Standard_E32s_v6**, 256 GiB / 32 vCPUs. It is already an E32.
- Resize NODE1 and NODE2 from 96 GiB / 12 vCPUs to **64 GiB / 8 vCPUs**, preserving
  their VM IDs, OS, data-disk IDs, vTPM/guardian and successful Arc registrations.
- Add **LB-NODE03**, also **64 GiB / 8 vCPUs**, on the same approved OS/solution.
- Leave the 4 GiB / 2-vCPU DC unchanged. Total guest allocations: **196 GiB and
  26 vCPUs**, leaving approximately 60 GiB outside guests. This is sizing arithmetic,
  not measured workload performance or a production HA claim.
- Use **No Witness** (empty service witness type) for three nodes, as permitted by
  the selected ARM reference for cluster sizes other than two. No Cloud Witness
  key, SAS, witness-secret upload or Shared Key enablement. Keep the existing unused
  witness account private and unchanged. No file-share workaround.

## Storage changes and why

The **pre-conversion** Azure sizing snapshot recorded all nine attached disks as
Standard HDD (`Standard_LRS`), not the Premium SSDs described in earlier notes.
Their identities, then-current SKUs and prices are retained in
`three-node-premium-cloud-sizing.json`. The actor or cause of that difference has
not been established. The separately requested nine-disk Premium conversion and
startup reconciliation are recorded in `premium-disk-conversion-reconciled-result.json`.

1. Convert exactly those nine disks to **Premium_LRS**, as explicitly requested,
   preserving disk IDs, encryption, contents and capacities. This includes the 1 TiB OS disk and eight
   256 GiB data disks. No Premium v2, Ultra or shared-disk conversion.
2. Add **one 2 TiB Premium SSD LRS** disk, named
   `LocalBox-Client-Node03-SSD-20261029`, at unused **LUN8**, caching None, retain on
   detach/delete. Verify its exact Azure/Windows identity before formatting **only
   that new blank disk** as GPT/NTFS, 64 KiB allocation units, drive **W:**.
3. Keep the existing eight-member Simple V: pool and its volume unchanged. No pool
   expansion, stripe-column change, reformat, existing-disk shrink or recreation.
4. Move only NODE1's currently blank **SCSI LUN4 / S2D-4.vhdx** from V: to
   `W:\\AzureLocalBox\\Relocated\\LB-NODE01\\S2D-4.vhdx`, using Hyper-V's guarded
   per-VHD move. Preserve VHD GUID `45B23F1E-D817-4DE0-A84A-C5F2124F7E30` and guest
   unique ID `600224801E3FB24517D8C5F2124F7E30`. Verify RAW/identity before moving,
   then verify the attachment, GUID and guest ID afterwards. No other VHD moves.
5. Put NODE3's VM/configuration and all five VHDXs on W:. Its OS is **128 GiB** and
   its four data VHDXs are **170 GiB each**. Existing data-disk sizes/counts remain.

Simply appending the third guest on V: would reserve **2,504 GiB** of virtual disks
against approximately **2,032 GiB** of volume capacity. Dynamic expansion is not
permission to overcommit the host filesystem.

| Volume | Maximum attached VHD capacity | Runtime-state allowance | Metadata/recovery allowance | Free-space floor |
|---|---:|---:|---:|---:|
| V: after the single move | 1,526 GiB | 132 GiB | 16 GiB | 200 GiB |
| New W: | 978 GiB | 64 GiB | 16 GiB | 200 GiB |

The W: calculation conservatively deducts 1 GiB for partition/filesystem overhead
before checking the budget. Its actual formatted capacity must pass the same check.
Runtime allowance reserves guest RAM even though current running VMRS files are
small. C: receives no guest files. Each volume must retain its own floor. This is
not a claim that the Simple outer pool gains hardware resiliency.

## Network, credentials and cloud delta

- NODE3 management **10.64.0.13/24**, gateway **10.64.0.1**, AD DNS **10.64.0.10**.
  Confirm address/name availability before assigning it. Same internal LB-Fabric
  switch and LB-NAT, no Azure VNet/route/firewall/PE/DNS-link changes.
- Same four vNICs and restricted trunk configuration. Storage A **10.64.4.13/24**
  VLAN711, storage B **10.64.5.13/24** VLAN712. No RDMA or storage gateway.
- Gen2, Secure Boot, vTPM, fixed RAM, nested virtualisation, no checkpoints,
  automatic start Nothing and stop ShutDown. Reuse verified ISO/image terms.
- A separate temporary bootstrap secret/answer file for NODE3, protected in its
  owned image. Remove setup copies and rotate to the existing dedicated
  `cluster-node-admin` secret before registration. No DC/outer credential reuse.
- Record the returned new VM ID and exact new disk GUIDs/guest unique IDs. Do not
  guess them. Preserve original NODE1/NODE2 registration markers and all failures.
- Register NODE3 in West Europe with fresh human device-code/MFA, pinned solution
  **12.2610.1004.41**. No exported owner ARM token or new Entra app/client secret.
- Only after inspecting its actual identity, add its two approved platform RG roles
  and vault-only Secrets User role. Preserve existing roles. Update startup and
  inspection tools to four guests after binding NODE3's actual ID.
- Re-derive the deployment for exactly three nodes. Publish only dedicated local
  admin/LCM credentials, not a witness key. Require exact new S2D device allowlists
  and checked resource effects before service **Validate**, then **Deploy**.

## Costs and interruption

Public USD **disk-capacity** meters for South Africa North, captured from the
official Retail Prices API. Not a contract quote, tax/FX assessment or spending cap.

| Monthly capacity comparison | USD |
|---|---:|
| Pre-conversion nine HDD disks | {Decimal(costs['before']):.2f} |
| Same nine converted to Premium SSD | {Decimal(costs['convertedExistingNine']):.2f} |
| Additional 2 TiB Premium SSD | {Decimal(costs['additionalDisk']):.2f} |
| Proposed total disk capacity | {Decimal(costs['after']):.2f} |
| **Increase versus current capacity meters** | **{Decimal(costs['delta']):.2f}** |

Conversion of the existing nine disks was explicitly requested separately. Once
that completes, the **additional** capacity charge for this three-node plan is
the new disk's **USD{Decimal(costs['additionalDisk']):.2f}/month**, not another charge for the conversions.

Other applicable meters are additional. No on-demand bursting or Performance Plus
enablement is requested. Premium SKU is not a measured performance guarantee. Compute
SKU is unchanged. The third Arc node can add Defender and platform charges. The
existing Azure Local core-fee illustration is not a new billing assessment. Keep
mandatory diagnostics/billing reports. Existing vault/PE/unused-witness costs remain.

Disk-type conversion requires an **outer-host shutdown/deallocation/restart**.
Gracefully stop guests first. Existing node resizes also require them to be off.
Check inherited policy and nightly automation without disabling either. Stop on
unexpected configuration, permission or policy effects.

There is **no new external backup/snapshot purchase** in this proposal. Current
DPAPI secrets/guardian material remain host-bound. A failed operation is preserved
for reconciliation, not followed by automatic reset/reinstall/rollback. This remains
an unsupported educational virtual deployment, not production HA.

## Approval boundary

The existing nine-disk Premium conversion is covered by its separate explicit
instruction and conversion receipt, not re-requested here. Approve this exact
topology, **one new 2 TiB Premium SSD**, the
new-disk-only format, the **single identified blank VHD move**, guest/host downtime,
NODE3 temporary secret/bootstrap/authentication boundary and listed cost delta.
Implementation still requires review, tests and commit/push before application.
No unlisted storage move/deletion, policy exemption, Shared Key, public access,
subscription-wide grant, AKS/workload/model or recurring agent job is included.

Fresh unique IDs and final apply previews remain mandatory. No service deployment
is approved against an inferred NODE3 identity or uninspected S2D disks.

## References

- [Azure Local virtual deployment requirements and educational-only status](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-virtual?view=azloc-2610).
- [2610 ARM witness-type reference](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template?view=azloc-2610#arm-template-parameters-reference).
- [Managed disk type conversion and VM restart](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-convert-types).
- [Hyper-V per-VHD Move-VMStorage parameters](https://learn.microsoft.com/en-us/powershell/module/hyper-v/move-vmstorage?view=windowsserver2025-ps).
- Public price response and exact query: `three-node-premium-cloud-sizing.json`.
"""


def main(check=False):
    proposal = build()
    rendered = {'three-node-proposal.json': json.dumps(proposal, indent=2) + '\n', 'three-node-proposal.md': markdown(proposal)}
    for name, contents in rendered.items():
        path = OUT / name
        if check:
            if path.read_text() != contents: raise RuntimeError('Generated proposal differs: ' + name)
        else:
            path.write_text(contents)
        print(str(path.relative_to(ROOT)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    raise SystemExit(main(parser.parse_args().check))
