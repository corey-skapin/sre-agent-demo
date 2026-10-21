targetScope = 'subscription'

@description('Azure region for the SRE Agent layer.')
param location string = 'australiaeast'

@description('Dedicated SRE group. Normal hibernation retains this group and its SRE-only user-assigned identity.')
param sreResourceGroupName string = 'rg-arc-demo-sre'

@description('Name of the SRE Agent. Must start with a letter and be 32 characters or fewer.')
param agentName string = 'sre-arc-demo'

@description('Resource group from the existing arc-demo deployment that contains Arc records, Log Analytics, DCRs, alerts, and the Action Group.')
param arcDemoResourceGroupName string = 'rg-arc-demo'

@description('Resource group from the existing arc-demo deployment that contains backing lab resources and optional Azure-native workloads.')
param arcDemoInfraResourceGroupName string = 'rg-arc-demo-infra'

@description('Existing arc-demo Log Analytics workspace resource ID. Used for SRE Agent diagnostics and knowledge graph context.')
param arcDemoWorkspaceId string

@description('Existing arc-demo Azure Monitor Action Group resource ID. Included in the knowledge graph as the Azure Monitor incident seam.')
param arcDemoActionGroupId string

@description('Additional existing resource IDs to add to the SRE Agent knowledge graph, such as a Container App, AKS cluster, or Arc machine.')
param additionalManagedResourceIds array = []

@description('The access level for the SRE Agent managed identity. High adds Contributor for governed Review-mode remediation; Low is read-only plus Log Analytics Reader.')
@allowed([
  'High'
  'Low'
])
param accessLevel string = 'High'

@allowed([
  'User'
  'ServicePrincipal'
])
param deployerPrincipalType string

param arcRoleAssignmentNames object = {}
param infraRoleAssignmentNames object = {}

@description('Tags to apply to resources created by this layer.')
param tags object = {
  owner: 'demo'
  purpose: 'sre-agent'
  env: 'demo'
  layersOn: 'arc-demo'
}

var lowAccessRoleDefinitionIds = [
  '73c42c96-874c-492b-b04d-ab87d138a893' // Log Analytics Reader
  'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
]
var highAccessRoleDefinitionIds = [
  '92aaf0da-9dab-42b6-94a3-d43ce8d16293' // Log Analytics Contributor (existing demo compatibility)
  'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
  'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor
]
var selectedRoleDefinitionIds = accessLevel == 'High' ? highAccessRoleDefinitionIds : lowAccessRoleDefinitionIds
var managedResourceIds = union([
  arcDemoRg.id
  arcDemoInfraRg.id
  arcDemoWorkspaceId
  arcDemoActionGroupId
], additionalManagedResourceIds)

resource sreRg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: sreResourceGroupName
  location: location
  tags: tags
}

resource arcDemoRg 'Microsoft.Resources/resourceGroups@2024-11-01' existing = {
  name: arcDemoResourceGroupName
}

resource arcDemoInfraRg 'Microsoft.Resources/resourceGroups@2024-11-01' existing = {
  name: arcDemoInfraResourceGroupName
}

module sreIdentity 'modules/sre-identity.bicep' = {
  name: 'sre-agent-identity'
  scope: sreRg
  params: {
    agentName: agentName
    location: location
    tags: tags
  }
}

module sreAgent 'modules/sre-agent.bicep' = {
  name: 'sre-agent-layer'
  scope: sreRg
  params: {
    agentName: agentName
    location: location
    tags: tags
    accessLevel: accessLevel
    appInsightsWorkspaceId: arcDemoWorkspaceId
    managedResourceIds: managedResourceIds
    deployerPrincipalType: deployerPrincipalType
    managedIdentityName: sreIdentity.outputs.identityName
  }
}

module arcDemoRoleAssignments 'modules/role-assignments.bicep' = {
  name: 'sre-agent-rbac-arc'
  scope: arcDemoRg
  params: {
    principalId: sreIdentity.outputs.principalId
    roleDefinitionIds: selectedRoleDefinitionIds
    roleAssignmentSeed: '${sreResourceGroupName}-${agentName}'
    existingRoleAssignmentNames: arcRoleAssignmentNames
  }
}

module arcDemoInfraRoleAssignments 'modules/role-assignments.bicep' = {
  name: 'sre-agent-rbac-infra'
  scope: arcDemoInfraRg
  params: {
    principalId: sreIdentity.outputs.principalId
    roleDefinitionIds: selectedRoleDefinitionIds
    roleAssignmentSeed: '${sreResourceGroupName}-${agentName}'
    existingRoleAssignmentNames: infraRoleAssignmentNames
  }
}

output agentName string = sreAgent.outputs.agentName
output agentId string = sreAgent.outputs.agentId
output agentPortalUrl string = sreAgent.outputs.agentPortalUrl
output managedIdentityId string = sreIdentity.outputs.identityId
output managedIdentityPrincipalId string = sreIdentity.outputs.principalId
output appInsightsId string = sreAgent.outputs.appInsightsId
output managedResourceIds array = managedResourceIds
output accessLevel string = accessLevel
