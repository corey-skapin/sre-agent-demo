targetScope = 'resourceGroup'

@description('Name of the SRE Agent.')
param agentName string

@description('Azure region for the SRE Agent and diagnostics resources.')
param location string

@description('Tags to apply to resources.')
param tags object

@description('The access level for the SRE Agent action identity.')
@allowed([
  'High'
  'Low'
])
param accessLevel string = 'High'

@description('Existing Log Analytics workspace resource ID used by the workspace-based Application Insights component.')
param appInsightsWorkspaceId string

@description('Existing resource IDs the SRE Agent should know about.')
param managedResourceIds array = []

@description('Assign the deploying principal the SRE Agent Administrator role on the agent resource.')
param assignDeployerAdminRole bool = true

@description('Type of the deploying principal. Managed identities use ServicePrincipal.')
@allowed([
  'User'
  'ServicePrincipal'
])
param deployerPrincipalType string

@description('Existing SRE-only identity created by the retained identity module in this resource group.')
param managedIdentityName string

@description('All five parent settings from the versioned demo settings asset.')
param parentSettings object

var appInsightsName = take('${agentName}-appi', 255)
var sreAgentAdministratorRoleDefinitionId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: managedIdentityName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: appInsightsWorkspaceId
  }
}

// The pinned official agent-core template uses this preview for AAU/feature/sandbox properties.
#disable-next-line BCP081
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  tags: tags
  identity: {
    // Keep the validated service identity shape; only the UAMI survives parent deletion.
    type: 'SystemAssigned,UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    defaultModel: parentSettings.defaultModel
    monthlyAgentUnitLimit: parentSettings.monthlyAgentUnitLimit
    upgradeChannel: parentSettings.upgradeChannel
    experimentalSettings: parentSettings.experimentalSettings
    sandboxConfiguration: parentSettings.sandboxConfiguration
    knowledgeGraphConfiguration: {
      identity: managedIdentity.id
      managedResources: managedResourceIds
    }
    actionConfiguration: {
      accessLevel: accessLevel
      identity: managedIdentity.id
      mode: 'Review'
    }
    incidentManagementConfiguration: {
      type: 'AzMonitor'
    }
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsights.properties.AppId
        connectionString: appInsights.properties.ConnectionString
      }
    }
  }
}

resource sreAgentAdminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignDeployerAdminRole) {
  name: guid(sreAgent.id, deployer().objectId, sreAgentAdministratorRoleDefinitionId)
  scope: sreAgent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdministratorRoleDefinitionId)
    principalId: deployer().objectId
    principalType: deployerPrincipalType
  }
}

output agentName string = sreAgent.name
output agentId string = sreAgent.id
output agentPortalUrl string = 'https://portal.azure.com/#view/Microsoft_Azure_PaasServerless/AgentFrameBlade.ReactView/id/${replace(sreAgent.id, '/', '%2F')}'
output managedIdentityId string = managedIdentity.id
output managedIdentityPrincipalId string = managedIdentity.properties.principalId
output appInsightsId string = appInsights.id
output appInsightsAppId string = appInsights.properties.AppId
