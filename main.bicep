targetScope = 'subscription'

param addressPrefixes array

param namingConvention string = '{workloadName}-{purpose}-{rtype}-{location}-{sequence}'

// From bootstrap.bicep
param coreResourceGroupName string
param logAnalyticsWorkspaceName string
param logAnalyticsWorkspaceId string
param containerRegistryName string
param containerImage string

param sequence int = 1
param location string = 'eastus'
param workloadName string = 'grouper'
param purpose string = 'test'
param tags object = {}

param deploymentTime string = utcNow()
param enableTelemetry bool = true

var deploymentNameStructure = '${workloadName}-{rtype}-${deploymentTime}'
var sequenceFormatted = format('{0:00}', sequence)
var namingStructure = replace(
  replace(
    replace(replace(namingConvention, '{workloadName}', workloadName), '{location}', location),
    '{sequence}',
    sequenceFormatted
  ),
  '{purpose}',
  purpose
)

resource networkResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: replace(namingStructure, '{rtype}', 'network-rg')
  location: location
  tags: tags
}

resource dataResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: replace(namingStructure, '{rtype}', 'data-rg')
  location: location
  tags: tags
}

resource coreResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' existing = {
  name: coreResourceGroupName
}

resource appResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: replace(namingStructure, '{rtype}', 'app-rg')
  location: location
  tags: tags
}

resource log 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  scope: coreResourceGroup
  name: logAnalyticsWorkspaceName
}

resource cr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  scope: coreResourceGroup
  name: containerRegistryName
}

var diagnosticSetting = {
  workspaceResourceId: log.id
  logCategoriesAndGroups: [
    { categoryGroup: 'allLogs' }
  ]
  name: 'defaultSetting'
}

module networkModule 'br/public:avm/res/network/virtual-network:0.1.5' = {
  scope: networkResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'network'), 64)
  params: {
    addressPrefixes: addressPrefixes
    name: replace(namingStructure, '{rtype}', 'vnet')

    subnets: [
      {
        name: 'DatabaseSubnet'
        addressPrefix: cidrSubnet(addressPrefixes[0], 27, 0)
        delegations: [
          {
            name: 'postgresql'
            properties: {
              serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
            }
          }
        ]
      }
      {
        name: 'ApplicationSubnet'
        addressPrefix: cidrSubnet(addressPrefixes[0], 27, 1)
        serviceEndpoints: [
          {
            service: 'Microsoft.KeyVault'
          }
        ]
        delegations: [
          {
            name: 'appService'
            properties: {
              serviceName: 'Microsoft.Web/serverFarms'
            }
          }
        ]
      }
      {
        name: 'ApplicationGatewaySubnet'
        addressPrefix: cidrSubnet(addressPrefixes[0], 26, 1)
      }
    ]

    // TODO: Define peering with hub network
    peerings: null

    diagnosticSettings: [diagnosticSetting]
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// TODO: Might need to reference existing private link DNS zone
module databaseDnsZoneModule 'br/public:avm/res/network/private-dns-zone:0.2.4' = {
  scope: networkResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'db-dns'), 64)
  params: {
    name: 'privatelink.postgres.database.azure.com'
  }
}

// Deploy a private access PostgreSQL Flexible Server
// TODO: Define database username/password
module databaseModule 'br/public:avm/res/db-for-postgre-sql/flexible-server:0.1.3' = {
  scope: dataResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'database'), 64)
  params: {
    name: replace(namingStructure, '{rtype}', 'pg')
    skuName: 'Standard_D2s_v3'
    tier: 'GeneralPurpose'
    databases: [
      {
        charset: 'UTF8'
        collation: 'en_US.utf8'
        name: 'grouper'
      }
    ]

    privateDnsZoneArmResourceId: databaseDnsZoneModule.outputs.resourceId
    delegatedSubnetResourceId: networkModule.outputs.subnetResourceIds[0]

    diagnosticSettings: [diagnosticSetting]
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

module uamiModule 'br/public:avm/res/managed-identity/user-assigned-identity:0.2.0' = {
  scope: coreResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'uami'), 64)
  params: {
    name: replace(namingStructure, '{rtype}', 'uami')

    enableTelemetry: enableTelemetry
    tags: tags
  }
}

// Assign the AcrPull role on the container registry to the managed identity
module uamiAcrPullRbacModule 'modules/roleAssignment-cr.bicep' = {
  scope: coreResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'uami-rbac-acr'), 64)
  params: {
    crName: containerRegistryName
    principalId: uamiModule.outputs.principalId
  }
}

// Deploy an App Service Plan
module appServicePlanModule 'br/public:avm/res/web/serverfarm:0.1.1' = {
  scope: appResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'asp'), 64)
  params: {
    name: replace(namingStructure, '{rtype}', 'asp')
    sku: {
      capacity: 1
      family: 'S'
      name: 'S1'
      size: 'S1'
      tier: 'Standard'
    }

    kind: 'Linux'
    reserved: true

    tags: tags
    //diagnosticSettings: [diagnosticSetting]
    enableTelemetry: enableTelemetry
  }
}

module appServiceModule 'modules/avm-local/web/site/main.bicep' = {
  scope: appResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'app-ui'), 64)
  params: {
    location: location
    kind: 'app,linux,container'
    name: replace(namingStructure, '{rtype}', 'app')
    serverFarmResourceId: appServicePlanModule.outputs.resourceId

    vnetRouteAllEnabled: true
    virtualNetworkSubnetId: networkModule.outputs.subnetResourceIds[1]

    basicPublishingCredentialsPolicies: [
      {
        name: 'scm'
        allow: true
      }
    ]

    siteConfig: {
      alwaysOn: true
      linuxFxVersion: 'DOCKER|${cr.properties.loginServer}/${containerImage}'
      // TODO: Create three: 'ui' 'ws' 'daemon'
      appCommandLine: 'ui-ws'
      acrUseManagedIdentityCreds: true
    }

    appSettingsKeyValuePairs: {
      DOCKER_REGISTRY_SERVER_URL: 'https://${cr.properties.loginServer}'
    }

    appInsightResourceId: applicationInsightsModule.outputs.resourceId

    httpsOnly: true

    managedIdentities: {
      userAssignedResourceIds: [
        uamiModule.outputs.resourceId
      ]
    }

    tags: tags
    diagnosticSettings: [diagnosticSetting]
    enableTelemetry: enableTelemetry
  }
}

module applicationInsightsModule 'br/public:avm/res/insights/component:0.3.0' = {
  scope: appResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'appi'), 64)
  params: {
    name: replace(namingStructure, '{rtype}', 'appi')
    workspaceResourceId: logAnalyticsWorkspaceId

    diagnosticSettings: [diagnosticSetting]
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// module keyVaultModule 'br/public:avm/res/key-vault/vault:0.4.0' = {
//   scope: coreResourceGroup
//   name: take(replace(deploymentNameStructure, '{rtype}', 'kv'),64)
//   params: {
//     name: 
//   }
// }
