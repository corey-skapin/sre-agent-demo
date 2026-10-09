targetScope = 'resourceGroup'

@description('Service principal object ID that receives roles at this resource-group scope.')
param principalId string

@description('Built-in role definition IDs to assign at this resource-group scope.')
param roleDefinitionIds array

@description('Stable seed for deterministic role assignment names.')
param roleAssignmentSeed string

resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleDefinitionId in roleDefinitionIds: {
  name: guid(resourceGroup().id, roleAssignmentSeed, roleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}]
