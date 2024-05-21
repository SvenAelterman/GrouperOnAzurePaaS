using './bootstrap.bicep'

param namingConvention = '{workloadName}-{purpose}-{rtype}-{location}-{sequence}'
param sequence = 2
param location = 'eastus'
param workloadName = 'grouper'
param purpose = 'test'
param tags = {
  'date-created': '2024-03-21'
  'customer-reference': 'umb'
}
param enableTelemetry = false
