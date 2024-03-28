param crName string
param principalId string
// Default: AcrPull
param roleDefinitionId string = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d'
)

resource cr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: crName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cr.id, principalId, roleDefinitionId)
  scope: cr
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
  }
}
