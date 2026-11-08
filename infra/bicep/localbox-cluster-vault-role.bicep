// Only after independently inspecting the newly created cluster identity.
targetScope = 'resourceGroup'

@minLength(36)
@maxLength(36)
param clusterPrincipalId string

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: 'kv-lbox-weu-4766ea'
}
var role = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
resource clusterSecrets 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, clusterPrincipalId, role)
  scope: vault
  properties: {
    principalId: clusterPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: role
    description: 'Owner-approved inspected Azure Local cluster identity, dedicated vault read only.'
  }
}
