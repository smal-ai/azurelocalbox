// Approved subscription-level effect: exactly one new LocalBox-owned RG.
targetScope = 'subscription'

resource platform 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-localbox-platform-weu-1'
  location: 'westeurope'
  tags: {
    owner: 'quintindekok'
    project: 'smal-ai'
    environment: 'lab'
    purpose: 'localbox-platform'
  }
}

output platformResourceGroupId string = platform.id
