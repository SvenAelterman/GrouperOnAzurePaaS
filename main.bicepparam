using './main.bicep'

param addressPrefixes = ['10.100.0.0/16']
param namingConvention = '{workloadName}-{purpose}-{rtype}-{location}-{sequence}'
param sequence = 1
param location = 'eastus'
param workloadName = 'grouper'
param purpose = 'test'
param tags = {
  'date-created': '2024-03-20'
  'customer-reference': 'UMB'
}
param enableTelemetry = false

param containerImage = 'umb/grouper:latest'
param containerRegistryName = 'groupertestacreastus01'
param coreResourceGroupName = 'grouper-test-core-rg-eastus-01'
param logAnalyticsWorkspaceId = '/subscriptions/68ec4f79-589c-4b65-9916-5fe7f5d385c2/resourceGroups/grouper-test-core-rg-eastus-01/providers/Microsoft.OperationalInsights/workspaces/grouper-test-log-eastus-01'
param logAnalyticsWorkspaceName = 'grouper-test-log-eastus-01'
