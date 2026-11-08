// Exactly the approved additional disk. Attachment is a separately checked action.
targetScope = 'resourceGroup'

resource node03Disk 'Microsoft.Compute/disks@2024-03-02' = {
  name: 'LocalBox-Client-Node03-SSD-20261029'
  location: 'southafricanorth'
  sku: {
    name: 'Premium_LRS'
  }
  tags: {
    project: 'smal-ai'
    environment: 'lab'
    owner: 'quintindekok'
    purpose: 'localbox-node03'
  }
  properties: {
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: 2048
    networkAccessPolicy: 'DenyAll'
    publicNetworkAccess: 'Disabled'
  }
}

output diskId string = node03Disk.id
