"""Pure Azure/Windows NVMe identity correlation. Never selects disks by order/size.

Microsoft's remote NVMe FAQ documents SCSILogicalUnit = Azure LUN + 1 for the
Virtual_Disk NVMe Premium model. This initial profile requires one controller.
"""
REFERENCE = 'https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-remote-faqs'


def correlate(arm, guest):
    if arm.get('controller') != 'NVMe' or guest.get('inspectionReadOnly') is not True:
        raise ValueError('Expected explicit NVMe and read-only inventory')
    if guest.get('computer') != 'LocalBox-Client' or len(arm.get('dataDisks', [])) != 8:
        raise ValueError('Unexpected host or Azure data-disk count')
    if len({d['id'].casefold() for d in arm['dataDisks']}) != 8:
        raise ValueError('Azure managed-disk identities must be unique')
    data = [d for d in guest['disks'] if d['isBoot'] is False and d['isSystem'] is False]
    if len(data) != 8 or len({d['uniqueId'].casefold() for d in data}) != 8:
        raise ValueError('Exactly eight uniquely identified guest data disks required')
    controllers = {(d['win32']['scsiPort'], d['win32']['scsiBus'], d['win32']['scsiTargetId']) for d in data}
    if len(controllers) != 1:
        raise ValueError('Multi-controller profile requires separate reviewed mapping')
    by_lun = {}
    for disk in data:
        win32 = disk['win32']
        if (disk['busType'] != 'NVMe' or win32['model'].casefold() != 'virtual_disk nvme premium'
                or type(win32['scsiLogicalUnit']) is not int or win32['scsiLogicalUnit'] < 1
                or win32['index'] != disk['number'] or disk['partitionStyle'] != 'RAW'
                or disk['offline'] is not False or disk['readOnly'] is not False
                or disk['sizeBytes'] != 256 * 1024**3 or not disk['uniqueId']
                or disk['serialNumber'] != win32['serialNumber']):
            raise ValueError('Guest identity does not satisfy the reviewed NVMe data profile')
        lun = win32['scsiLogicalUnit'] - 1
        if lun in by_lun:
            raise ValueError('Ambiguous NVMe namespace/LUN')
        physical = [p for p in guest['physicalDisks'] if p['uniqueId'] == disk['uniqueId']
                    and p['serialNumber'] == disk['serialNumber'] and p['sizeBytes'] == disk['sizeBytes']]
        if len(physical) != 1 or physical[0]['canPool'] is not True or physical[0]['busType'] != 'NVMe':
            raise ValueError('Storage/PhysicalDisk identity is not unique and poolable')
        by_lun[lun] = disk
    result = []
    if {d['lun'] for d in arm['dataDisks']} != set(range(8)) or set(by_lun) != set(range(8)):
        raise ValueError('Azure LUNs and guest namespaces are not the exact expected set')
    for azure in sorted(arm['dataDisks'], key=lambda d: d['lun']):
        disk = by_lun[azure['lun']]
        if azure['id'] == arm['osDisk']:
            raise ValueError('OS disk cannot be selected')
        result.append({'resourceId': azure['id'], 'lun': azure['lun'],
                       'guestUniqueId': disk['uniqueId'], 'serialNumber': disk['serialNumber'],
                       'namespaceId': disk['win32']['scsiLogicalUnit'], 'sizeBytes': disk['sizeBytes'],
                       'observedDiskNumberNotSelectionKey': disk['number']})
    return {'method': 'documented-NVMe-namespace-equals-Azure-LUN-plus-one',
            'reference': REFERENCE, 'vmResourceId': arm['id'], 'disks': result,
            'bootDiskExcluded': True, 'resourceActionsPerformed': False}
