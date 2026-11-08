targetScope = 'resourceGroup'

resource capacityDisk 'Microsoft.Compute/disks@2024-03-02' = {
  name: 'LocalBox-Client-Capacity-20261030'
  location: 'southafricanorth'
  sku: { name: 'Standard_LRS' }
  tags: { purpose: 'Approved AzureLocalBox additive data capacity' }
  properties: {
    diskSizeGB: 4096
    creationData: { createOption: 'Empty' }
    networkAccessPolicy: 'DenyAll'
    publicNetworkAccess: 'Disabled'
  }
}
