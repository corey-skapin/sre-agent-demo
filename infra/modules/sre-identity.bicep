targetScope = 'resourceGroup'

param agentName string
param location string
param tags object

@description('Retained across normal hibernation. Never replace this resource to park the agent.')
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${agentName}-uami'
  location: location
  tags: union(tags, {
    sreLifecycle: 'RetainedIdentity'
    sreAgent: agentName
  })
}

output identityName string = managedIdentity.name
output identityId string = managedIdentity.id
output principalId string = managedIdentity.properties.principalId
