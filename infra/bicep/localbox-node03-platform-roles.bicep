targetScope = 'resourceGroup'

var node = 'bd9a2019-2109-4aba-9f4e-90a1d300325d'
var definitions = [
  subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '865ae368-6a45-4bd1-8fbf-0d5151f56fc1')
  subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'c99c945f-8bd1-4fb1-a903-01460aae6068')
]
resource rgRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for definition in definitions: {
  name: guid(resourceGroup().id, node, definition)
  properties: {
    principalId: node
    principalType: 'ServicePrincipal'
    roleDefinitionId: definition
    description: 'Owner-approved inspected NODE3 Azure Local platform prerequisite, dedicated RG only.'
  }
}]
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: 'kv-lbox-weu-4766ea'
}
var secrets = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
resource vaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, node, secrets)
  scope: vault
  properties: {
    principalId: node
    principalType: 'ServicePrincipal'
    roleDefinitionId: secrets
    description: 'Owner-approved inspected NODE3 secret read, dedicated vault only.'
  }
}
