targetScope = 'subscription'

param namingConvention string = '{workloadName}-{purpose}-{rtype}-{location}-{sequence}'

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

    // TODO: Assign AcrPush role to specified principal
    roleAssignments: []
  }
}

output containerRegistryName string = containerRegistryModule.outputs.name
output logAnalyticsWorkspaceName string = logModule.outputs.name
output coreResourceGroupName string = coreResourceGroup.name
