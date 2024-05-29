targetScope = 'subscription'

param namingConvention string = '{workloadName}-{purpose}-{rtype}-{location}-{sequence}'

param sequence int = 1
param location string = 'eastus'
param workloadName string = 'grouper'
param purpose string = 'test'
param tags object = {}

param deploymentTime string = utcNow()
param enableTelemetry bool = true

/* DATABASE SECRETS */
@secure()
param databaseLogin string = ''
@secure()
param databasePassword string = ''
/* GROUPER SECRETS */
@secure()
param grouperMorphStringEncryptKey string = ''
@secure()
param grouperSystemPassword string = ''

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

resource coreResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: replace(namingStructure, '{rtype}', 'core-rg')
  location: location
  tags: tags
}

module logModule 'br/public:avm/res/operational-insights/workspace:0.3.4' = {
  scope: coreResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'log'), 64)
  params: {
    name: replace(namingStructure, '{rtype}', 'log')
  }
}

var diagnosticSetting = {
  workspaceResourceId: logModule.outputs.resourceId
  logCategoriesAndGroups: [
    { categoryGroup: 'allLogs' }
  ]
  name: 'defaultSetting'
}

module containerRegistryModule 'br/public:avm/res/container-registry/registry:0.1.1' = {
  scope: coreResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'acr'), 64)
  params: {
    name: toLower(replace(replace(namingStructure, '{rtype}', 'acr'), '-', ''))

    tags: tags
    enableTelemetry: enableTelemetry
    diagnosticSettings: [diagnosticSetting]
  }
}

module keyVaultNameModule 'modules/createValidAzResourceName.bicep' = {
  scope: coreResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'kv-name'), 64)
  params: {
    purpose: purpose
    location: location
    namingConvention: namingConvention
    resourceType: 'kv'
    sequence: sequence
    workloadName: workloadName
  }
}

var databasePasswordSecretName = 'databasePassword'
var databaseLoginSecretName = 'databaseLogin'
var grouperMorphStringEncryptKeySecretName = 'grouperMorphStringEncryptKey'
var grouperSystemPasswordSecretName = 'grouperSystemPassword'

var databasePasswordSecret = !empty(databasePassword)
  ? [
      {
        name: databasePasswordSecretName
        value: databasePassword
        contentType: 'The password for the PostgreSQL database admin user.'
      }
    ]
  : []

var databaseLoginSecret = !empty(databaseLogin)
  ? [
      {
        name: databaseLoginSecretName
        value: databaseLogin
        contentType: 'The login (username) for the PostgreSQL database admin user.'
      }
    ]
  : []

var grouperMorphStringEncryptKeySecret = !empty(grouperMorphStringEncryptKey)
  ? [
      {
        name: grouperMorphStringEncryptKeySecretName
        value: grouperMorphStringEncryptKey
        contentType: 'The key used to encrypt and decrypt the morph string in Grouper.'
      }
    ]
  : []

var grouperSystemPasswordSecret = !empty(grouperSystemPassword)
  ? [
      {
        name: grouperSystemPasswordSecretName
        value: grouperSystemPassword
        contentType: 'The default system password.'
      }
    ]
  : []

// Create an array of all the secrets to pass to the Key Vault module
var secureList = concat(
  databasePasswordSecret,
  databaseLoginSecret,
  grouperMorphStringEncryptKeySecret,
  grouperSystemPasswordSecret
)

// Create a Key Vault to hold the database password
module keyVaultModule 'br/public:avm/res/key-vault/vault:0.4.0' = {
  scope: coreResourceGroup
  name: take(replace(deploymentNameStructure, '{rtype}', 'kv'), 64)
  params: {
    name: keyVaultNameModule.outputs.validName

    secrets: {
      secureList: secureList
    }

    enableRbacAuthorization: true
    enableVaultForDeployment: false
    enableVaultForDiskEncryption: false
    enableVaultForTemplateDeployment: true

    enableTelemetry: enableTelemetry
    diagnosticSettings: [diagnosticSetting]
    tags: tags
  }
}

output containerRegistryName string = containerRegistryModule.outputs.name
output logAnalyticsWorkspaceName string = logModule.outputs.name
output coreResourceGroupName string = coreResourceGroup.name
output keyVaultName string = keyVaultModule.outputs.name
output keyVaultSubscriptionId string = subscription().subscriptionId
output keyVaultResourceGroupName string = coreResourceGroup.name

// This is just the name of the Key Vault secret, not the secret itself
#disable-next-line outputs-should-not-contain-secrets
output databasePasswordSecretName string = databasePasswordSecretName
output databaseLoginSecretName string = databaseLoginSecretName
output grouperMorphStringEncryptKeySecretName string = grouperMorphStringEncryptKeySecretName
#disable-next-line outputs-should-not-contain-secrets
output grouperSystemPasswordSecretName string = grouperSystemPasswordSecretName
