// =============================================================================
// LocalBox — governed vended-spoke wrapper (subscription-scoped)
//
// Deploys Jumpstart LocalBox into an enterprise landing-zone vended spoke:
//   * Creates TWO resource groups we own:
//       - nodesResourceGroupName   (SAN)  : LAW, staging storage, client VM + NIC
//       - azureLocalResourceGroup  (WE)   : Arc-connected machines + Azure Local
//                                           instance (registered by in-VM automation)
//   * Places the client VM NIC into an EXISTING LZ spoke subnet (BYO network) —
//     creates NO VNet/subnet/NSG/UDR/NAT/Bastion/public-IP. `azd down` therefore
//     leaves all LZ-owned network objects intact.
//   * Governed mode: VM has NO public IP; management is via the central Bastion.
//   * Assigns Owner on both RGs to the deployment service principal.
//
// NOTE: staging storage is deployed into the nodes RG (SAN) so the VM's staging
// artifacts are co-located; the Azure Local *instance* still registers in
// azureLocalInstanceLocation (WE) via the in-VM automation targeting
// azureLocalResourceGroup.
// =============================================================================

targetScope = 'subscription'

// ---------- Identity / SP ----------
@description('Azure AD tenant id for your service principal')
param tenantId string

@description('Object id of the Microsoft.AzureStackHCI resource provider service principal')
param spnProviderId string

// ---------- Windows client VM ----------
@description('Username for the Windows client VM account')
param windowsAdminUsername string = 'arcdemo'

@description('Password for the Windows client VM account (12-123 chars, complexity required)')
@minLength(12)
@maxLength(123)
@secure()
param windowsAdminPassword string

@description('Size of the LocalBox client VM')
@allowed([
  'Standard_E32s_v5'
  'Standard_E32s_v6'
  'Standard_E64s_v6'
])
param vmSize string = 'Standard_E64s_v6'

// ---------- Resource groups ----------
@description('Name of the resource group (nodes/compute) we create in the client VM region')
param nodesResourceGroupName string = 'rg-localbox-nodes-san-1'

@description('Name of the resource group (Azure Local registration) we create in the Azure Local instance region')
param azureLocalResourceGroupName string = 'rg-localbox-azlocal-we-1'

// ---------- Regions ----------
@description('Region for the client VM and nodes resource group')
param location string = 'southafricanorth'

@description('Region to register the Azure Local instance in (must be a supported Azure Local region)')
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
param azureLocalInstanceLocation string = 'westeurope'

// ---------- Existing LZ spoke network (BYO) ----------
@description('Name of the EXISTING landing-zone spoke virtual network')
param spokeVirtualNetworkName string = 'vnet-az-test-wkl-san-1'

@description('Name of the EXISTING subnet to place the client VM NIC into')
param spokeSubnetName string = 'snet-default'

@description('Resource group of the EXISTING spoke VNet (LZ-owned). Defaults to nodes RG if co-located; set to the LZ-owned RG otherwise.')
param spokeVirtualNetworkResourceGroup string = 'rg-az-test-wkl-san-1'

@description('Subscription id of the EXISTING spoke VNet (LZ-owned). Defaults to the current subscription.')
param spokeVirtualNetworkSubscriptionId string = subscription().subscriptionId

// ---------- LocalBox behaviour ----------
@description('Name for the Log Analytics workspace')
param logAnalyticsWorkspaceName string = 'LocalBox-Workspace'

@description('Public DNS to use for the domain')
param natDNS string = '8.8.8.8'

@description('GitHub account hosting the (patched) LocalBox artifacts — templateBaseUrl source. MUST be your fork when in-VM PowerShell is patched.')
param githubAccount string = 'microsoft'

@description('GitHub branch hosting the (patched) LocalBox artifacts')
param githubBranch string = 'main'

@description('RDP port for the client VM (management via central Bastion)')
param rdpPort string = '3389'

@description('Automatically validate + create the Azure Local cluster resource after client VM deployment')
param autoDeployClusterResource bool = true

@description('Automatically upgrade cluster nodes when updates are available (only if autoDeployClusterResource)')
param autoUpgradeClusterResource bool = false

@description('Enable automatic logon into the LocalBox client VM')
param vmAutologon bool = true

@description('Enable spot pricing for the LocalBox client VM')
param enableAzureSpotPricing bool = false

@description('Add Microsoft-internal lab CostControl/SecurityControl tags')
param governResourceTags bool = true

@description('Base tags applied to all resources')
param tags object = {
  Project: 'jumpstart_LocalBox'
}

// -----------------------------------------------------------------------------

var resourceTags = governResourceTags ? union(tags, {
  CostControl: 'Ignore'
  SecurityControl: 'Ignore'
}) : tags

var templateBaseUrl = 'https://raw.githubusercontent.com/${githubAccount}/azure_arc/${githubBranch}/azure_jumpstart_localbox/'
var customerUsageAttributionDeploymentName = 'feada075-1961-4b99-829f-fa3828068933'

// ---------- Resource groups (we own both) ----------
resource nodesRg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: nodesResourceGroupName
  location: location
  tags: resourceTags
}

resource azureLocalRg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: azureLocalResourceGroupName
  location: azureLocalInstanceLocation
  tags: resourceTags
}

// ---------- Management artifacts (LAW) — nodes RG ----------
module mgmtArtifactsAndPolicyDeployment 'mgmt/mgmtArtifacts.bicep' = {
  name: 'mgmtArtifactsAndPolicyDeployment'
  scope: nodesRg
  params: {
    workspaceName: logAnalyticsWorkspaceName
    location: location
    resourceTags: resourceTags
  }
}

// ---------- BYO network — resolves EXISTING spoke subnet, creates nothing ----------
module networkDeployment 'network/network.byo.bicep' = {
  name: 'networkByoDeployment'
  scope: nodesRg
  params: {
    virtualNetworkName: spokeVirtualNetworkName
    subnetName: spokeSubnetName
    virtualNetworkResourceGroup: spokeVirtualNetworkResourceGroup
    virtualNetworkSubscriptionId: spokeVirtualNetworkSubscriptionId
  }
}

// ---------- Staging storage — nodes RG (region = instance location for parity) ----------
module storageAccountDeployment 'mgmt/storageAccount.bicep' = {
  name: 'stagingStorageAccountDeployment'
  scope: nodesRg
  params: {
    location: azureLocalInstanceLocation
    resourceTags: resourceTags
  }
}

// ---------- Client VM host ----------
module hostDeployment 'host/host.bicep' = {
  name: 'hostVmDeployment'
  scope: nodesRg
  params: {
    vmSize: vmSize
    windowsAdminUsername: windowsAdminUsername
    windowsAdminPassword: windowsAdminPassword
    tenantId: tenantId
    spnProviderId: spnProviderId
    workspaceName: logAnalyticsWorkspaceName
    stagingStorageAccountName: storageAccountDeployment.outputs.storageAccountName
    templateBaseUrl: templateBaseUrl
    subnetId: networkDeployment.outputs.subnetId
    deployBastion: false
    noPublicIp: true
    natDNS: natDNS
    location: location
    rdpPort: rdpPort
    autoDeployClusterResource: autoDeployClusterResource
    autoUpgradeClusterResource: autoUpgradeClusterResource
    vmAutologon: vmAutologon
    resourceTags: resourceTags
    enableAzureSpotPricing: enableAzureSpotPricing
    azureLocalInstanceLocation: azureLocalInstanceLocation
    azureLocalResourceGroup: azureLocalResourceGroupName
  }
}

// ---------- VM managed identity grants on the Azure Local registration RG ----------
// The in-VM automation (Arc onboarding + cluster ARM) runs against the westeurope
// registration RG, so the client VM's managed identity needs rights there too.
// Contributor + Key Vault Administrator (ABAC-compatible; Owner/UAA are blocked).
module vmRoleWeContributor 'modules/rgRoleAssignment.bicep' = {
  name: 'vmRoleWeContributor'
  scope: azureLocalRg
  params: {
    principalId: hostDeployment.outputs.vmPrincipalId
    roleDefinitionGuid: 'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor
    nameSalt: 'contributor'
  }
}

module vmRoleWeKeyVaultAdmin 'modules/rgRoleAssignment.bicep' = {
  name: 'vmRoleWeKeyVaultAdmin'
  scope: azureLocalRg
  params: {
    principalId: hostDeployment.outputs.vmPrincipalId
    roleDefinitionGuid: '00482a5a-887f-4fb3-b363-3b7fe8e74483' // Key Vault Administrator
    nameSalt: 'kvadmin'
  }
}

// The Azure Local cluster ARM template creates role assignments during
// validate/deploy (Arc machine role grants). The VM managed identity therefore
// needs to be able to write role assignments in the WE RG. Role Based Access
// Control Administrator provides this and is NOT blocked by the subscription's
// ABAC condition (which only forbids Owner + User Access Administrator).
module vmRoleWeRbacAdmin 'modules/rgRoleAssignment.bicep' = {
  name: 'vmRoleWeRbacAdmin'
  scope: azureLocalRg
  params: {
    principalId: hostDeployment.outputs.vmPrincipalId
    roleDefinitionGuid: 'f58310d9-a9f6-439a-9e8d-f62e7b41a168' // Role Based Access Control Administrator
    nameSalt: 'rbacadmin'
  }
}

module customerUsageAttribution 'mgmt/customerUsageAttribution.bicep' = {
  name: 'pid-${customerUsageAttributionDeploymentName}'
  scope: nodesRg
  params: {}
}

output NODES_RESOURCE_GROUP string = nodesRg.name
output AZURE_LOCAL_RESOURCE_GROUP string = azureLocalRg.name
output CLIENT_VM_PRIVATE_IP string = hostDeployment.outputs.privateIP
output RDP_PORT string = rdpPort
output AZURE_TENANT_ID string = tenant().tenantId
