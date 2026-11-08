// Explicitly approved conditional data-plane grant. No vault/network change.
targetScope = 'resourceGroup'

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: 'kv-lbox-weu-4766ea'
}

var deployer = '82f494a8-b9f5-46fc-b0f7-c70be0572a63'
var definition = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')

resource secretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, deployer, definition)
  scope: vault
  properties: {
    principalId: deployer
    principalType: 'User'
    roleDefinitionId: definition
    description: 'Owner-approved LocalBox platform secret operations, this dedicated vault only.'
  }
}

output assignmentId string = secretsOfficer.id
