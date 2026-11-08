"""Offline additive-capacity boundaries. No real disks or guests are changed."""
import copy
import json
from pathlib import Path
import runpy
import subprocess
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]


class CapacityExpansionTests(unittest.TestCase):
    def setUp(self):
        self.h = runpy.run_path(str(ROOT / 'scripts/smal-capacity-expansion.py'),run_name='capacity_test')
        self.plan = self.h['load_plan']()

    def test_exact_approved_addition_doubles_data_not_os_or_existing_disk_sizes(self):
        plan = self.plan
        self.assertEqual(len(plan['existingDisks']),10)
        data_gib = sum(r['sizeGiB'] for r in plan['existingDisks'] if r['id'].lower() != plan['vmBefore']['osId'].lower())
        self.assertEqual(data_gib,4096); self.assertEqual(plan['newDisk']['sizeGiB'],4096)
        self.assertEqual(plan['newDisk']['sku'],'Standard_LRS')
        self.assertEqual(sum(len(n['newDisks']) for n in plan['nodes'].values()),12)
        self.assertTrue(all(d['sizeBytes'] == 170*1024**3 for n in plan['nodes'].values() for d in n['newDisks']))
        self.assertFalse(plan['existingOsDisksOrDiskSizesChanged']); self.assertFalse(plan['csvSizesChanged'])
        self.assertEqual(plan['retailReference']['capacityUsdPerMonth'],192.1)

    def test_cloud_preview_allows_only_the_one_empty_private_standard_disk(self):
        disk = self.plan['newDisk']
        data = {'status':'Succeeded','changes':[{'resourceId':disk['id'],'changeType':'Create','after':{'type':'Microsoft.Compute/disks','location':'southafricanorth',
            'sku':{'name':'Standard_LRS'},'properties':{'diskSizeGB':4096,'creationData':{'createOption':'Empty'},'networkAccessPolicy':'DenyAll','publicNetworkAccess':'Disabled'}}}]}
        self.h['validate_preview'](data,set(),self.plan)
        for key,value in [('diskSizeGB',8192),('publicNetworkAccess','Enabled'),('creationData',{'createOption':'Copy'})]:
            bad = copy.deepcopy(data); bad['changes'][0]['after']['properties'][key] = value
            with self.assertRaises(RuntimeError): self.h['validate_preview'](bad,set(),self.plan)
        bad = copy.deepcopy(data); bad['changes'][0]['changeType'] = 'Modify'
        with self.assertRaises(RuntimeError): self.h['validate_preview'](bad,set(),self.plan)
        built = subprocess.run(['az','bicep','build','--file',str(ROOT / self.h['TEMPLATE']),'--stdout','--only-show-errors'],check=True,capture_output=True,text=True,timeout=90)
        resources = json.loads(built.stdout)['resources']; self.assertEqual(len(resources),1)
        self.assertEqual(resources[0]['type'],'Microsoft.Compute/disks')

    def test_existing_managed_disk_id_size_sku_owner_and_unique_id_are_immutable(self):
        rows = copy.deepcopy(self.plan['existingDisks']); self.h['verify_existing_disks'](rows,self.plan)
        for key,value in [('sizeGiB',8192),('sku','Premium_LRS'),('uniqueId','other'),('managedBy','/other-vm'),('id','/other-disk')]:
            bad = copy.deepcopy(rows); bad[0][key] = value
            with self.assertRaises(RuntimeError): self.h['verify_existing_disks'](bad,self.plan)

    def test_attachment_cannot_change_existing_luns_os_or_cache(self):
        vm = copy.deepcopy(self.plan['vmBefore']); self.h['verify_vm'](vm,self.plan)
        vm['data'].append({'id':self.plan['newDisk']['id'],'lun':9,'caching':'None','deleteOption':None})
        self.h['verify_vm'](vm,self.plan,attached=True)
        for key,value in [('lun',8),('caching','ReadWrite'),('deleteOption','Delete')]:
            bad = copy.deepcopy(vm); bad['data'][-1][key] = value
            with self.assertRaises(RuntimeError): self.h['verify_vm'](bad,self.plan,attached=True)
        vm['osId'] = 'other-os'
        with self.assertRaises(RuntimeError): self.h['verify_vm'](vm,self.plan,attached=True)

    def test_expansion_scripts_parse_after_public_prelude_rendering(self):
        prelude = (ROOT / 'scripts/smal-capacity-prelude.ps1').read_text()
        for path in [*self.h['SCRIPTS'].values(),'scripts/inspect-smal-capacity-interruption.ps1']:
            source = (ROOT / path).read_text().replace('__CAPACITY_PRELUDE__',prelude)
            # Parser only. Neither the prelude nor any operation is executed.
            command = '$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}'
            subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',command],input=source,text=True,check=True,capture_output=True,timeout=30)

    def test_no_pooled_resize_reset_or_cluster_recreation_exists(self):
        for path in [*self.h['SCRIPTS'].values(),'scripts/smal-capacity-prelude.ps1']:
            source = (ROOT / path).read_text()
            for forbidden in ['Resize-VHD','Resize-VirtualDisk','Resize-Partition','Reset-PhysicalDisk','Clear-Disk','New-StoragePool','New-VM ','Remove-VM','Stop-VM','Enable-ClusterS2D']:
                self.assertNotIn(forbidden,source)
        fmt = (ROOT / self.h['SCRIPTS']['format']).read_text()
        self.assertIn('Initialize-Disk -UniqueId $disk.UniqueId',fmt)
        self.assertIn("$disk.PartitionStyle.ToString() -ne 'RAW'",fmt)
        self.assertIn('[IO.FileMode]::CreateNew',fmt)
        add = (ROOT / self.h['SCRIPTS']['add-vhds']).read_text()
        self.assertIn('New-VHD -Path $spec.path -Dynamic -SizeBytes 170GB',add)
        self.assertIn('Add-VMHardDiskDrive -VM $vm',add)

    def test_interruption_inspector_cannot_create_attach_delete_or_reformat(self):
        source = (ROOT / 'scripts/inspect-smal-capacity-interruption.ps1').read_text()
        for forbidden in ['New-VHD','Add-VMHardDiskDrive','Remove-Item','Format-Volume','Initialize-Disk']:
            self.assertNotIn(forbidden,source)
        self.assertIn('$files.Count -ne 1',source)
        self.assertIn('$vhd.Attached',source)
        self.assertIn('Get-FileHash $first',source)

    def test_string_disk_identifier_is_explicitly_parsed_before_byte_conversion(self):
        value = '2346EBF2-6D1B-48B4-85DB-090E25B7E955'
        ident = uuid.UUID(value); expected = '60022480' + (ident.bytes_le[:6] + ident.bytes[-6:]).hex().upper()
        command = "$id='" + value + "';$bytes=([guid]::Parse([string]$id)).ToByteArray();'60022480'+[BitConverter]::ToString([byte[]]@($bytes[0..5]+$bytes[10..15])).Replace('-','')"
        result = subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',command],check=True,capture_output=True,text=True,timeout=30)
        self.assertEqual(result.stdout.strip(),expected)
        self.assertIn('([guid]::Parse([string]$vhd.DiskIdentifier)).ToByteArray()', (ROOT / 'scripts/add-smal-capacity-vhds.ps1').read_text())

    def test_first_file_resume_rejects_attachments_or_changed_approval(self):
        failed = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-capacity-add-vhds-20261030.json').read_text())
        admission = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-capacity-first-vhd-interruption-20261030.json').read_text())
        self.h['verify_first_file_resume'](failed,admission,self.plan)
        bad = copy.deepcopy(admission); bad['result']['firstVhd']['attached'] = True
        with self.assertRaises(RuntimeError): self.h['verify_first_file_resume'](failed,bad,self.plan)
        bad = copy.deepcopy(admission); bad['result']['planSha256'] = 'changed'
        with self.assertRaises(RuntimeError): self.h['verify_first_file_resume'](failed,bad,self.plan)
        bad = copy.deepcopy(failed); bad['result']['disks'] = [{'attached':True}]
        with self.assertRaises(RuntimeError): self.h['verify_first_file_resume'](bad,admission,self.plan)

    def growth_fixture(self):
        proof = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-final-cluster-storage-postdeploy-identity-20261030.json').read_text())
        new = [{'guestUniqueId':'synthetic-new-' + str(i),'sizeBytes':170*1024**3,'attached':True} for i in range(12)]
        baseline = {'cluster':[]}
        for row in proof['result']['nodes']:
            guest = row['guest']
            for disk in guest['virtualDisks']: disk['uniqueId'] = 'synthetic-' + disk['name']
            baseline['cluster'].append({'name':row['name'],'poolSize':guest['storagePools'][0]['size'],'virtualDisks':copy.deepcopy(guest['virtualDisks'])})
            guest['storagePools'][0]['size'] *= 2
            guest['storagePools'][0]['members'] += [{'uniqueId':r['guestUniqueId'],'size':r['sizeBytes'],'health':'Healthy'} for r in new]
        return baseline,{'disks':new},proof

    def test_growth_requires_all_24_exact_devices_and_preserves_existing_volumes(self):
        baseline,added,proof = self.growth_fixture()
        result = self.h['verify_growth'](self.plan,baseline,added,proof)
        self.assertEqual(result['totalMembers'],24)
        self.assertTrue(result['existingVirtualDiskSizesAndIdsPreserved'])
        self.assertFalse(result['platformReadinessVerified'])
        bad = copy.deepcopy(proof); bad['result']['nodes'][0]['guest']['storagePools'][0]['members'][-1]['uniqueId'] = 'foreign'
        with self.assertRaises(RuntimeError): self.h['verify_growth'](self.plan,baseline,added,bad)
        bad = copy.deepcopy(proof); bad['result']['nodes'][0]['guest']['virtualDisks'][0]['size'] *= 2
        with self.assertRaises(RuntimeError): self.h['verify_growth'](self.plan,baseline,added,bad)

    def test_completed_addition_jobs_are_not_reported_as_active_or_optimization_proof(self):
        baseline,added,proof = self.growth_fixture()
        for node in proof['result']['nodes']:
            node['guest']['storageJobs'] = [{'name':'AddPhysicalDisk','state':'Completed','percentComplete':100}]
        result = self.h['verify_growth'](self.plan,baseline,added,proof)
        self.assertEqual(result['activeStorageJobs'],[])
        self.assertEqual(result['completedJobRecordsObserved'],3)
        self.assertFalse(result['optimizationFullyCompletedProven'])

    def test_capacity_convergence_observer_cannot_replay_addition_or_formatting(self):
        source = (ROOT / 'scripts/observe-smal-capacity-growth.py').read_text()
        for forbidden in ["'vm','disk','attach'","'deployment','group','create'",'New-VHD','Format-Volume','Initialize-Disk']:
            self.assertNotIn(forbidden,source)
        self.assertIn("'azureMutationPerformed':False",source)
        self.assertIn("'newDiskOrVhdOperationRequested':False",source)

    def test_real_capacity_observation_proves_exact_doubling_and_preservation(self):
        out = ROOT / 'docs/deployment-2026-10-30'
        observed = json.loads((out / 'capacity-expansion-converged-observation-20261030.json').read_text())
        self.assertEqual(observed['status'],'complete-capacity-doubled-existing-data-preserved')
        self.assertEqual(observed['azureDataCapacityGiB'],8192)
        self.assertTrue(observed['allElevenHostDisksStandardLrs'])
        self.assertFalse(observed['azureMutationPerformed'])
        self.assertFalse(observed['platformReadinessVerified'])
        baseline = json.loads((out / 'capacity-expansion-prepare-receipt.json').read_text())['result']
        added = json.loads((out / 'capacity-expansion-add-vhds-after-id-binding-reconciliation-receipt.json').read_text())['result']
        formatted = json.loads((out / 'capacity-expansion-format-receipt.json').read_text())['result']
        proof = json.loads((ROOT / observed['observations'][-1]).read_text())
        result = self.h['verify_growth'](self.plan,baseline,added,proof)
        self.assertEqual(result['totalMembers'],24)
        self.assertEqual(result['poolSizeGiB'],4055.98)
        self.assertEqual(result['activeStorageJobs'],[])
        self.h['verify_outer_volumes'](proof,baseline,formatted,self.plan)
        self.assertEqual(added['originalFirstVhdIdRetained'],'2346EBF2-6D1B-48B4-85DB-090E25B7E955')

    def test_post_capacity_arc_bridge_and_private_controls_remain_verified(self):
        h = runpy.run_path(str(ROOT / 'scripts/assess-smal-three-node-acceptance.py'),run_name='post_capacity_cloud_test')
        cloud = json.loads((ROOT / 'docs/deployment-2026-10-29/three-node-cloud-after-capacity-20261030.json').read_text())
        result = h['verify_cloud'](cloud)
        self.assertTrue(result['resourceBridgeRunning'])
        self.assertTrue(result['customLocationSucceededAndBound'])
        self.assertTrue(result['privateAccessControlsPreserved'])


if __name__ == '__main__': unittest.main()
