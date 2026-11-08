@description('The name of your Virtual Machine')
param vmName string = 'LocalBox-Client'

@description('The size of the Virtual Machine')
@allowed([
  'Standard_E32s_v5'
  'Standard_E32s_v6'
  'Standard_E64s_v6'
])
param vmSize string = 'Standard_E64s_v6'

@description('Username for the Virtual Machine')
param windowsAdminUsername string = 'arcdemo'

@description('Password for Windows account. Password must have 3 of the following: 1 lower case character, 1 upper case character, 1 number, and 1 special character. The value must be between 12 and 123 characters long')
@minLength(12)
@maxLength(123)
@secure()
param windowsAdminPassword string

@description('The Windows version for the VM. This will pick a fully patched image of this given Windows version')
param windowsOSVersion string = '2025-datacenter-g2'

@description('Location for all resources')
param location string = resourceGroup().location

@description('Region to register Azure Local instance in. This is the region where the Azure Local instance resources will be created. The region must be one of the supported Azure Local regions.')
@allowed([
  'australiaeast'
  'southcentralus'
  'eastus'
  'westeurope'
  'southeastasia'
  'canadacentral'
  'japaneast'
  'centralindia'
])
param azureLocalInstanceLocation string = 'australiaeast'

@description('Resource Id of the subnet in the virtual network')
param subnetId string

@description('Resource group where the Arc-connected machines and Azure Local instance are registered (must be in a supported Azure Local region). In the governed vended-spoke model this differs from the client VM RG: the client VM lives in the SAN nodes RG, while Arc/Azure Local register here (e.g. westeurope). The in-VM automation uses this RG for all Arc/cluster operations. Defaults to the current resource group (stock single-RG behaviour).')
param azureLocalResourceGroup string = resourceGroup().name

param resourceTags object

@description('Tenant id of the service principal')
param tenantId string

@description('Azure AD object id for your Microsoft.AzureStackHCI resource provider')
param spnProviderId string

@description('Name for the staging storage account using to hold kubeconfig. This value is passed into the template as an output from mgmtStagingStorage.json')
param stagingStorageAccountName string

@description('Name for the environment Azure Log Analytics workspace')
param workspaceName string

@description('The base URL used for accessing artifacts and automation artifacts.')
param templateBaseUrl string

@description('Option to disable automatic cluster registration. Setting this to false will also disable deploying AKS and Resource bridge')
param registerCluster bool = true

@description('Choice to deploy Bastion to connect to the client VM')
param deployBastion bool = false

@description('Option to deploy AKS Arc with LocalBox')
param deployAKSArc bool = true

@description('Option to deploy Resource Bridge with LocalBox')
param deployResourceBridge bool = true

@description('Public DNS to use for the domain')
param natDNS string = '8.8.8.8'

@description('Override default RDP port using this parameter. Default is 3389. No changes will be made to the client VM.')
param rdpPort string = '3389'

@description('Choice to enable automatic deployment of Azure Arc enabled HCI cluster resource after the client VM deployment is complete. Default is false.')
param autoDeployClusterResource bool = false

@description('Choice to enable automatic upgrade of Azure Arc enabled HCI cluster resource after the client VM deployment is complete. Only applicable when autoDeployClusterResource is true. Default is false.')
param autoUpgradeClusterResource bool = false

@description('Enable automatic logon into LocalBox Virtual Machine')
param vmAutologon bool = false

@description('Option to enable spot pricing for the LocalBox Client VM')
param enableAzureSpotPricing bool = false

@description('Governed mode: do NOT attach a public IP to the client VM NIC and do NOT deploy an in-spoke Bastion. Management is via a central/landing-zone Bastion. When true, the VM has no public IP regardless of deployBastion.')
param noPublicIp bool = false

var encodedPassword = base64(windowsAdminPassword)
var bastionName = 'LocalBox-Bastion'
var publicIpAddressName = deployBastion == false ? '${vmName}-PIP' : '${bastionName}-PIP'
var networkInterfaceName = '${vmName}-NIC'
var osDiskType = 'Premium_LRS'
// Attach a public IP only when NOT in governed mode AND not using an in-spoke Bastion.
var attachPublicIp = !noPublicIp && deployBastion == false
var PublicIPNoBastion = {
  id: publicIpAddress.id
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2021-03-01' = {
  name: networkInterfaceName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: attachPublicIp ? PublicIPNoBastion : null
        }
      }
    ]
  }
  tags: resourceTags
}

resource publicIpAddress 'Microsoft.Network/publicIpAddresses@2021-03-01' = if (attachPublicIp) {
  name: publicIpAddressName
  location: location
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
  sku: {
    name: 'Standard'
  }
  tags: resourceTags
}

resource vm 'Microsoft.Compute/virtualMachines@2022-03-01' = {
  name: vmName
  location: location
  tags: resourceTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      osDisk: {
        name: '${vmName}-OSDisk'
        caching: 'ReadWrite'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: osDiskType
        }
        diskSizeGB: 1024
      }
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: windowsOSVersion
        version: 'latest'
      }
      dataDisks: [
        {
          name: '${vmName}-DataDisk_0'
          diskSizeGB: 256
          createOption: 'Empty'
          lun: 0
          caching: 'None'
          writeAcceleratorEnabled: false
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
        {
          name: '${vmName}-DataDisk_1'
          diskSizeGB: 256
          createOption: 'Empty'
          lun: 1
          caching: 'None'
          writeAcceleratorEnabled: false
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
        {
          name: '${vmName}-DataDisk_2'
          diskSizeGB: 256
          createOption: 'Empty'
          lun: 2
          caching: 'None'
          writeAcceleratorEnabled: false
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
        {
          name: '${vmName}-DataDisk_3'
          diskSizeGB: 256
          createOption: 'Empty'
          lun: 3
          caching: 'None'
          writeAcceleratorEnabled: false
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
        {
          name: '${vmName}-DataDisk_4'
          diskSizeGB: 256
          createOption: 'Empty'
          lun: 4
          caching: 'None'
          writeAcceleratorEnabled: false
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
        {
          name: '${vmName}-DataDisk_5'
          diskSizeGB: 256
          createOption: 'Empty'
          lun: 5
          caching: 'None'
          writeAcceleratorEnabled: false
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
        {
          name: '${vmName}-DataDisk_6'
          diskSizeGB: 256
          createOption: 'Empty'
          lun: 6
          caching: 'None'
          writeAcceleratorEnabled: false
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
        {
          name: '${vmName}-DataDisk_7'
          diskSizeGB: 256
          createOption: 'Empty'
          lun: 7
          caching: 'None'
          writeAcceleratorEnabled: false
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
        }
      ]
    }
    osProfile: {
      computerName: vmName
      adminUsername: windowsAdminUsername
      adminPassword: windowsAdminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: false
      }
    }
    priority: enableAzureSpotPricing ? 'Spot' : 'Regular'
    evictionPolicy: enableAzureSpotPricing ? 'Deallocate' : null
    billingProfile: enableAzureSpotPricing ? {
      maxPrice: -1
    } : null
  }
}

resource vmBootstrap 'Microsoft.Compute/virtualMachines/extensions@2022-03-01' = {
  parent: vm
  name: 'Bootstrap'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      fileUris: [
        uri(templateBaseUrl, 'artifacts/PowerShell/Bootstrap.ps1')
      ]
      commandToExecute: 'powershell.exe -ExecutionPolicy Bypass -File Bootstrap.ps1 -adminUsername ${windowsAdminUsername} -adminPassword ${encodedPassword} -tenantId ${tenantId} -subscriptionId ${subscription().subscriptionId} -spnProviderId ${spnProviderId} -resourceGroup ${azureLocalResourceGroup} -azureLocation ${azureLocalInstanceLocation} -stagingStorageAccountName ${stagingStorageAccountName} -workspaceName ${workspaceName} -templateBaseUrl ${templateBaseUrl} -registerCluster ${registerCluster} -deployAKSArc ${deployAKSArc} -deployResourceBridge ${deployResourceBridge} -natDNS ${natDNS} -rdpPort ${rdpPort} -autoDeployClusterResource ${autoDeployClusterResource} -autoUpgradeClusterResource ${autoUpgradeClusterResource} -vmAutologon ${vmAutologon}'
    }
  }
}

// Add role assignment for the VM: Contributor role
// NOTE: upstream LocalBox grants Owner here, but the target subscription has an
// ABAC condition that forbids this principal from assigning Owner/UAA. The VM
// managed identity's role-assignment code paths in the automation are commented
// out (Arc onboarding handles its own permissions), so Contributor + Key Vault
// Administrator + Storage Account Contributor are sufficient and ABAC-compatible.
resource vmRoleAssignment_Contributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, 'Microsoft.Authorization/roleAssignments', 'Contributor')
  scope: resourceGroup()
  properties: {
    principalId: vm.identity.principalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalType: 'ServicePrincipal'
  }
}

// Add role assignment for the VM: Azure Key Vault Administrator role
resource deployerRoleAssignment_KeyVaultAdministrator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, 'Microsoft.Authorization/roleAssignments', 'KeyVaultAdministrator')
  scope: resourceGroup()
  properties: {
    principalId: vm.identity.principalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', '00482a5a-887f-4fb3-b363-3b7fe8e74483')
    principalType: 'ServicePrincipal'
  }
}

// Add role assignment for the VM: Storage Account Contributor role
resource deployerRoleAssignment_StorageAccountContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, 'Microsoft.Authorization/roleAssignments', 'StorageAccountContributor')
  scope: resourceGroup()
  properties: {
    principalId: vm.identity.principalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', '17d1049b-9a84-46fb-8f53-869881c3d3ab')
    principalType: 'ServicePrincipal'
  }
}

output adminUsername string = windowsAdminUsername
output publicIP string = attachPublicIp ? publicIpAddress!.properties.ipAddress : ''
output privateIP string = networkInterface.properties.ipConfigurations[0].properties.privateIPAddress
output vmPrincipalId string = vm.identity.principalId
