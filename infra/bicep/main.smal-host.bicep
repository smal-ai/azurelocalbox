// Approved outer-host phase only. No azd hooks, bootstrap, RBAC or shared-network writes.
// Deploy ONLY to rg-localbox-nodes-san-1 using the reviewed host-phase plan.
targetScope = 'resourceGroup'

@description('Approved Windows host username. No implicit reuse of old credentials.')
param adminUsername string

@secure()
@minLength(12)
@maxLength(123)
@description('Supply through an approved secure deployment channel, never a committed parameter value.')
param adminPassword string

@description('Explicit immutable marketplace image version. Never use latest.')
@allowed(['26100.33674.261024'])
param imageVersion string

@allowed(['Standard_E32s_v6'])
param vmSize string = 'Standard_E32s_v6'

@allowed(['southafricanorth'])
param location string = 'southafricanorth'

@description('Must be resolved before apply. Does not grant approval to use current operator privileges.')
@allowed([true])
param hostPlanApproved bool

@description('Reconciled retry only: reuse the existing private NIC without writing its properties.')
param reuseExistingNic bool = false

var vmName = 'LocalBox-Client'
var tags = {
  owner: 'quintindekok'
  project: 'smal-ai'
  environment: 'lab'
  purpose: 'localbox-host'
}

// LZ-owned reference only. The template creates no VNet/subnet/NSG/route/DNS/Bastion.
resource network 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: 'vnet-smal-san-1'
  scope: resourceGroup('8d3c4bb2-fdf8-4bca-bb92-e387bd4766ea', 'rg-smal-network-san-1')
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: network
  name: 'snet-localbox-host'
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = if (!reuseExistingNic) {
  name: '${vmName}-NIC'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: false // Routing/SNAT design is a separate approved platform step.
    ipConfigurations: [{
      name: 'ipconfig1'
      properties: {
        privateIPAllocationMethod: 'Dynamic'
        subnet: { id: subnet.id }
      }
    }]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' } // No role assignments. Bootstrap identity is not yet approved.
  properties: {
    hardwareProfile: { vmSize: vmSize }
    // Explicit proposal for nested Hyper-V. Requires governance/security acceptance.
    // Never rely on the image/provider's evolving Trusted Launch defaults.
    securityProfile: { securityType: 'Standard' }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2025-datacenter-g2'
        version: imageVersion
      }
      osDisk: {
        name: '${vmName}-OSDisk'
        createOption: 'FromImage'
        diskSizeGB: 1024
        caching: 'ReadWrite'
        deleteOption: 'Detach' // No automatic data deletion on VM removal.
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
      dataDisks: [for lun in range(0, 8): {
        name: '${vmName}-DataDisk_${lun}'
        createOption: 'Empty'
        lun: lun
        diskSizeGB: 256
        caching: 'None'
        deleteOption: 'Detach'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }]
    }
    networkProfile: {
      networkInterfaces: [{
        id: resourceId('Microsoft.Network/networkInterfaces', '${vmName}-NIC')
        properties: { deleteOption: 'Detach' }
      }]
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: false // Update policy/egress must be agreed before apply.
      }
    }
    priority: 'Regular'
  }
  dependsOn: [nic]
}

output hostPlanApprovalSupplied bool = hostPlanApproved
output vmResourceId string = vm.id
output nicResourceId string = resourceId('Microsoft.Network/networkInterfaces', '${vmName}-NIC')
output hostSubnetResourceId string = subnet.id
// Reuse mode deliberately performs no NIC read/write in this template; use live readback.
output privateIp string = reuseExistingNic ? '' : nic!.properties.ipConfigurations[0].properties.privateIPAddress
output reusedExistingNic bool = reuseExistingNic
output managedIdentityPrincipalId string = vm.identity.principalId
output bootstrapDeployed bool = false
