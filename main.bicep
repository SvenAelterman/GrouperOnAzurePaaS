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

param databaseName string = 'grouper'
param databaseAdministratorLoginSecretName string = 'databaseLogin'
param databaseAdministratorPasswordSecretName string = 'databasePassword'
@secure()
param databaseAdministratorLogin string
@secure()
param databaseAdministratorPassword string

param grouperMorphstringEncryptKeySecretName string = 'grouperMorphstringEncryptKey'

param keyVaultName string

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

module rolesModule 'modules/roles.bicep' = {
  name: take(replace(deploymentNameStructure, '{rtype}', 'roles'), 64)
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

// Production: Might need to reference existing private link DNS zone
module databaseDnsZoneModule 'br/public:avm/res/network/private-dns-zone:0.2.4' = {
  scope: networkResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'db-dns'), 64)
  params: {
    name: 'privatelink.postgres.database.azure.com'
    virtualNetworkLinks: [
      {
        registrationEnabled: false
        virtualNetworkResourceId: networkModule.outputs.resourceId
      }
    ]
  }
}

// Deploy a private access PostgreSQL Flexible Server
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
        name: databaseName
      }
    ]

    privateDnsZoneArmResourceId: databaseDnsZoneModule.outputs.resourceId
    delegatedSubnetResourceId: networkModule.outputs.subnetResourceIds[0]

    administratorLogin: databaseAdministratorLogin
    administratorLoginPassword: databaseAdministratorPassword
    // LATER: Consider using Entra ID and managed identity auth
    passwordAuth: 'Enabled'
    activeDirectoryAuth: 'Disabled'

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

module uamiKvRbacModule 'modules/roleAssignment-kv.bicep' = {
  scope: coreResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'uami-rbac-kv'), 64)
  params: {
    kvName: keyVaultName
    principalId: uamiModule.outputs.principalId
    roleDefinitionId: rolesModule.outputs.roles.keyVaultSecretsUser
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

module appSvcKeyVaultReferencesModule 'modules/appSvcKeyVaultRefs.bicep' = {
  scope: appResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'kv-refs'), 64)
  params: {
    keyVaultName: keyVaultName
    secretNames: [
      databaseAdministratorLoginSecretName
      databaseAdministratorPasswordSecretName
      grouperMorphstringEncryptKeySecretName
    ]
  }
}

var appServiceInstances = ['ui', 'ws', 'daemon']

module appServiceModule 'modules/avm-local/web/site/main.bicep' = [
  for appServiceInstance in appServiceInstances: {
    scope: appResourceGroup
    name: take(replace(deploymentNameStructure, '{rtype}', 'app-${appServiceInstance}'), 64)
    params: {
      keyVaultAccessIdentityResourceId: uamiModule.outputs.resourceId

      location: location
      kind: 'app,linux,container'
      name: replace(namingStructure, '{rtype}', 'app-${appServiceInstance}')
      serverFarmResourceId: appServicePlanModule.outputs.resourceId

      virtualNetworkSubnetId: networkModule.outputs.subnetResourceIds[1]
      vnetRouteAllEnabled: true
      vnetImagePullEnabled: true

      basicPublishingCredentialsPolicies: [
        {
          name: 'scm'
          allow: true
        }
      ]

      siteConfig: {
        alwaysOn: true
        // For a custom Linux container, specify the image and tag here
        linuxFxVersion: 'DOCKER|${cr.properties.loginServer}/${containerImage}'
        // Each Grouper service is started via the appCommandLine: ui, ws, or daemon
        appCommandLine: appServiceInstance
        // Using the managed identity to pull images from the ACR
        acrUseManagedIdentityCreds: true
        // Specify the user-assigned managed identity to use to pull images from the ACR
        acrUserManagedIdentityId: uamiModule.outputs.clientId

        http20Enabled: true
        minTlsVersion: '1.2'

        httpLoggingEnabled: true
        logsDirectorySizeLimit: 35
        detailedErrorLoggingEnabled: true
        retentionInDays: 1
      }

      // Define the environment variables for the Grouper services
      appSettingsKeyValuePairs: {
        DOCKER_REGISTRY_SERVER_URL: 'https://${cr.properties.loginServer}'

        GROUPER_RUN_APACHE: 'true'
        GROUPER_RUN_SHIB_SP: 'false'
        GROUPER_DATABASE_URL: 'jdbc:postgresql://${databaseModule.outputs.name}.postgres.database.azure.com:5432/${databaseName}?sslmode=require'
        // Deploy the database schema up to version 4
        GROUPER_AUTO_DDL_UPTOVERSION: '4.*.*'

        // TODO: Consider enabling E2E encryption, but this is still in preview (https://techcommunity.microsoft.com/t5/apps-on-azure-blog/end-to-end-e2e-tls-encryption-preview-on-linux-multi-tenant-app/ba-p/3976646)
        GROUPER_USE_SSL: 'false'
        GROUPER_TOMCAT_HTTP_PORT: '8080'
        GROUPER_TOMCAT_HTTPS_PORT: '-1'
        WEBSITES_PORT: '80'

        GROUPER_UI_GROUPER_AUTH: 'true'

        // Obtain secrets as Key Vault references
        GROUPER_DATABASE_USERNAME: appSvcKeyVaultReferencesModule.outputs.keyVaultRefs[0]
        GROUPER_DATABASE_PASSWORD: appSvcKeyVaultReferencesModule.outputs.keyVaultRefs[1]
        GROUPER_MORPHSTRING_ENCRYPT_KEY: appSvcKeyVaultReferencesModule.outputs.keyVaultRefs[2]
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
]

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
