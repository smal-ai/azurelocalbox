// Approved owned platform resources only. No nodes, cluster, roles, secrets or shared networking.
targetScope = 'resourceGroup'

var tags = {
  owner: 'quintindekok'
  project: 'smal-ai'
  environment: 'lab'
  purpose: 'localbox-platform'
}

resource diagnostic 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stlboxdiagweu4766ea'
  location: 'westeurope'
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'AzureServices' }
  }
}

resource witness 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stlboxwitweu4766ea'
  location: 'westeurope'
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    // Cloud witness uses the platform-required account-key credential, held in the deployment vault later.
    allowSharedKeyAccess: true
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'AzureServices' }
  }
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-lbox-weu-4766ea'
  location: 'westeurope'
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    enabledForTemplateDeployment: true
    // Explicit owner-approved temporary deployment boundary, not the existing SMAL application vault.
    publicNetworkAccess: 'Enabled'
    accessPolicies: []
  }
}

resource audit 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'localbox-vault-audit'
  scope: vault
  properties: {
    storageAccountId: diagnostic.id
    logs: [{ category: 'AuditEvent', enabled: true }]
  }
}

// Current diagnostic APIs do not enforce storage retention. Apply a scoped blob lifecycle policy instead.
resource retention 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: diagnostic
  name: 'default'
  properties: {
    policy: {
      rules: [{
        name: 'localbox-vault-audit-90-days'
        enabled: true
        type: 'Lifecycle'
        definition: {
          filters: { blobTypes: ['appendBlob', 'blockBlob'], prefixMatch: ['insights-logs-auditevent/'] }
          actions: { baseBlob: { delete: { daysAfterModificationGreaterThan: 90 } } }
        }
      }]
    }
  }
}

resource diagnosticLock 'Microsoft.Authorization/locks@2020-05-01' = {
  name: 'localbox-diagnostics-retain'
  scope: diagnostic
  properties: { level: 'CanNotDelete', notes: 'Preserve approved LocalBox deployment audit storage. Removal requires owner instruction.' }
}

output keyVaultId string = vault.id
output diagnosticStorageId string = diagnostic.id
output witnessStorageId string = witness.id
