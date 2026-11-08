"""Read-only exact identity/cost plan for the human-approved additive expansion."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import runpy
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
D = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='capacity_plan_reads')
OUT = ROOT / 'docs/deployment-2026-10-30'


def main():
    D['preflight']()
    host = '/subscriptions/' + D['SUB'] + '/resourceGroups/rg-localbox-nodes-san-1/providers/Microsoft.Compute/virtualMachines/LocalBox-Client'
    vm = D['az'](['vm','show','--subscription',D['SUB'],'-g','rg-localbox-nodes-san-1','-n','LocalBox-Client',
        '--query','{id:id,size:hardwareProfile.vmSize,osId:storageProfile.osDisk.managedDisk.id,data:storageProfile.dataDisks[].{id:managedDisk.id,lun:lun,caching:caching,deleteOption:deleteOption}}'])
    disks = D['az'](['disk','list','--subscription',D['SUB'],'-g','rg-localbox-nodes-san-1',
        '--query','[].{id:id,name:name,sizeGiB:diskSizeGB,sku:sku.name,uniqueId:uniqueId,managedBy:managedBy,state:diskState}'])
    if vm['id'].lower() != host.lower() or vm['size'] != 'Standard_E32s_v6' or sorted(row['lun'] for row in vm['data']) != list(range(9)):
        raise RuntimeError('Exact unchanged running-host profile/LUN set differs')
    expected_ids = {vm['osId'].lower(),*(row['id'].lower() for row in vm['data'])}
    if len(disks) != 10 or {row['id'].lower() for row in disks} != expected_ids or any(row['sku'] != 'Standard_LRS' or row['managedBy'].lower() != host.lower() or row['state'] != 'Attached' for row in disks):
        raise RuntimeError('Exact ten existing Standard_LRS disk identities differ')
    if sorted(row['sizeGiB'] for row in disks) != [256]*8 + [1024,2048]: raise RuntimeError('Existing disk sizes differ')
    bindings = json.loads((D['OUT'] / 'three-node-local-identity-bindings.json').read_text())
    nodes = {name:{'vmId':row['vmId'],'originalDisks':row['disks'],
                   'newDisks':[{'lun':lun,'sizeBytes':170*1024**3,'path':'X:\\AzureLocalBox\\CapacityExpansion-20261030-01\\' + name + '\\S2D-' + str(lun) + '.vhdx'} for lun in range(5,9)]}
             for name,row in bindings['nodes'].items()}
    query = "serviceName eq 'Storage' and armRegionName eq 'southafricanorth' and priceType eq 'Consumption' and contains(productName, 'Standard HDD Managed Disks')"
    url = 'https://prices.azure.com/api/retail/prices?currencyCode=USD&$filter=' + urllib.parse.quote(query)
    with urllib.request.urlopen(url,timeout=60) as response: prices = json.load(response)
    selected = [r for r in prices['Items'] if r['skuName'] == 'S50 LRS' and r['meterName'] == 'S50 LRS Disk' and r['unitOfMeasure'] == '1/Month']
    if prices.get('NextPageLink') or len(selected) != 1 or selected[0]['retailPrice'] != 192.1: raise RuntimeError('Inspected capacity-only retail reference changed; review before applying')
    plan = {'schemaVersion':1,'observedAtUtc':datetime.now(timezone.utc).isoformat(),'hostId':host,'vmBefore':vm,'existingDisks':disks,'nodes':nodes,
            'newDisk':{'id':host.rsplit('/providers/',1)[0] + '/providers/Microsoft.Compute/disks/LocalBox-Client-Capacity-20261030',
                       'name':'LocalBox-Client-Capacity-20261030','sizeGiB':4096,'sku':'Standard_LRS','location':'southafricanorth','lun':9,'driveLetter':'X',
                       'caching':'None','deleteOption':'Detach','joinOuterPool':False},
            'expectedS2dPoolId':'{923c0194-3ed4-449a-ae14-0f62861e0ec8}','oldDataDeviceCount':12,'targetDataDeviceCount':24,
            'originalOuterPoolId':'{b8174816-65a9-46f7-87c1-b189be0b90e5}','originalOuterVirtualDiskId':'D0CDB2F96D0E244E8B532E096F97FBBF',
            'existingOsDisksOrDiskSizesChanged':False,'csvSizesChanged':False,'policyOrAutomationChanged':False,'workiqRequested':False,
            'retailReference':{'sourceUrl':url,'sku':'S50 LRS','capacityUsdPerMonth':192.1,'notContractPrice':True,'transactionsTaxOtherChargesExcluded':True},
            'references':['https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/storage-spaces-direct-in-vm',
                          'https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/add-nodes#adding-drives']}
    raw = (json.dumps(plan,indent=2) + '\n').encode()
    with (OUT / 'capacity-expansion-plan.json').open('xb') as stream: stream.write(raw)
    approval = {'approved':True,'humanAnswer':'Approve supported addition','activeStorageTier':'Standard_LRS',
                'dataScopeAnswer':'Data capacity, exclude OS (Recommended)','downtimeAnswer':'Allow coordinated downtime',
                'planSha256':hashlib.sha256(raw).hexdigest(),'one4TiBDiskAndTwelve170GiBVhdxApproved':True,
                'onlyNewBlankDiskFormattingApproved':True,'oldDisksOrOsResizeApproved':False,'policyExemptionOrAutomationChangeApproved':False}
    with (OUT / 'capacity-expansion-approval.json').open('x') as stream: stream.write(json.dumps(approval,indent=2) + '\n')
    print(json.dumps({'status':'exact-plan-and-human-approval-retained-no-Azure-mutation','planSha256':approval['planSha256'],'azureNewDataGiB':4096,'newNestedDataDisks':12},indent=2))


if __name__ == '__main__': main()
