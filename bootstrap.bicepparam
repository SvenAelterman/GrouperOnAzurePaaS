using './bootstrap.bicep'

param namingConvention = '{workloadName}-{purpose}-{rtype}-{location}-{sequence}'
param sequence = 1
param location = 'eastus'
param workloadName = 'grouper'
param purpose = 'test'
param tags = {
  'date-created': '2024-03-21'
  'customer-reference': 'umb'
}
param enableTelemetry = false

/* DO NOT SPECIFY A VALUE HERE */
param databasePassword = ''
param databaseLogin = ''
