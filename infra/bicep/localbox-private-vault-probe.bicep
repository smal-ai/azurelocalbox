// Non-credential probe for the exact ARM secret-write resource type used by HCI.
targetScope = 'resourceGroup'

@secure()
param probeValue string

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: 'kv-lbox-weu-4766ea'
}

resource probe 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'localbox-private-path-probe-20261028'
  properties: {
    value: probeValue
    contentType: 'Non-credential LocalBox ARM/private-data-plane connectivity probe'
    attributes: { enabled: true }
  }
}

output probeId string = probe.id
