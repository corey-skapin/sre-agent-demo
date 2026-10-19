targetScope = 'resourceGroup'

@description('Service principal object ID that receives roles at this resource-group scope.')
param principalId string

@description('Built-in role definition IDs to assign at this resource-group scope.')
param roleDefinitionIds array

@description('Stable seed for deterministic role assignment names.')
param roleAssignmentSeed string

@description('Existing assignment names keyed by role ID, discovered at this scope for this principal. Adopts legacy names without duplicate grants.')
param existingRoleAssignmentNames object = {}

resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleDefinitionId in roleDefinitionIds: {
  name: contains(existingRoleAssignmentNames, roleDefinitionId) ? existingRoleAssignmentNames[roleDefinitionId] : guid(resourceGroup().id, roleAssignmentSeed, principalId, roleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}]
