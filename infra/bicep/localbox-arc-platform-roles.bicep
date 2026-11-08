// Approved role effects only. Exact independently inspected node/RP identities.
targetScope = 'resourceGroup'

var rp = '4606be37-a04a-4716-a214-186a08bb7745'
var nodes = [
  '9a1205c8-6ac3-4d02-ad6d-6166827c8d9d'
  'b282b136-716d-4fa9-8e03-a4c754249a5e'
]
var manager = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'f5819b54-e033-4d82-ac66-4fec3cbf3f4c')
var device = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '865ae368-6a45-4bd1-8fbf-0d5151f56fc1')
var infra = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'c99c945f-8bd1-4fb1-a903-01460aae6068')
var secrets = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var rgBindings = [
  {
    principal: rp
    role: manager
  }
  {
    principal: nodes[0]
    role: device
  }
  {
    principal: nodes[1]
    role: device
  }
  {
    principal: nodes[0]
    role: infra
  }
  {
    principal: nodes[1]
    role: infra
  }
]

resource rgRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for binding in rgBindings: {
  name: guid(resourceGroup().id, binding.principal, binding.role)
  properties: {
    principalId: binding.principal
    principalType: 'ServicePrincipal'
    roleDefinitionId: binding.role
    description: 'Owner-approved Azure Local platform prerequisite, dedicated RG only.'
  }
}]

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: 'kv-lbox-weu-4766ea'
}

resource vaultRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for node in nodes: {
  name: guid(vault.id, node, secrets)
  scope: vault
  properties: {
    principalId: node
    principalType: 'ServicePrincipal'
    roleDefinitionId: secrets
    description: 'Owner-approved Azure Local node secret read, dedicated vault only.'
  }
}]
