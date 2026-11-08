import json
from pathlib import Path
import runpy
import unittest

ROOT = Path(__file__).resolve().parents[1]
MAP = runpy.run_path(str(ROOT / 'scripts/map-smal-nvme-disks.py'), run_name='nvme_test')['correlate']


def fixture():
    guest = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-nvme-inventory-started-20261028.json').read_text())['result']
    vm = '/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/LocalBox-Client'
    arm = {'id': vm, 'controller': 'NVMe', 'osDisk': 'os',
           'dataDisks': [{'id': f'data-{i}', 'lun': i} for i in range(8)]}
    return arm, guest


class NvmeTests(unittest.TestCase):
    def test_namespace_offset_and_physical_identity(self):
        result = MAP(*fixture())
        self.assertEqual(len(result['disks']), 8)
        self.assertEqual(result['disks'][0]['lun'], 0)
        self.assertEqual(result['disks'][0]['namespaceId'], 1)
        self.assertTrue(result['bootDiskExcluded'])
        self.assertFalse(result['resourceActionsPerformed'])

    def test_reordering_guest_records_does_not_change_selection(self):
        arm, guest = fixture()
        expected = MAP(arm, guest)
        guest['disks'].reverse()
        guest['physicalDisks'].reverse()
        self.assertEqual(expected, MAP(arm, guest))

    def test_identity_state_and_namespace_conflicts_fail_closed(self):
        for field, value in [('partitionStyle', 'GPT'), ('isBoot', True), ('readOnly', True),
                             ('offline', True), ('uniqueId', ''), ('serialNumber', 'changed')]:
            arm, guest = fixture()
            guest['disks'][1][field] = value
            with self.assertRaises((ValueError, KeyError)): MAP(arm, guest)
        arm, guest = fixture()
        guest['disks'][2]['win32']['scsiLogicalUnit'] = 1
        with self.assertRaises(ValueError): MAP(arm, guest)

    def test_no_guessing_other_controller_or_unpoolable_physical_disk(self):
        arm, guest = fixture()
        arm['controller'] = 'SCSI'
        with self.assertRaises(ValueError): MAP(arm, guest)
        arm, guest = fixture()
        guest['physicalDisks'][0]['canPool'] = False
        with self.assertRaises(ValueError): MAP(arm, guest)
