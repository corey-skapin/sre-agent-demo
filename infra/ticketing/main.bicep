targetScope = 'subscription'

@description('Region of the SRE layer. Must equal the region used for the SRE group and its retained identity.')
param sreLocation string

@description('Region of the ticketing workload. Pick one where App Service quota is available on this subscription.')
param workloadLocation string

@description('Short lowercase prefix shared with the rest of the demo.')
@minLength(2)
@maxLength(20)
param namePrefix string

@description('Dedicated SRE group that holds the retained identity (the same group the SRE layer uses).')
param sreResourceGroupName string = 'rg-${namePrefix}-sre'

@description('Name of the SRE agent; its retained identity is named <agentName>-uami.')
param agentName string

@description('Group that holds only the ticketing workload. Deleting it removes the whole workload.')
param workloadResourceGroupName string = 'rg-${namePrefix}-ticketing'

@description('Eight lowercase hex characters that make the web app name unique; the scripts derive it from the subscription and group.')
@minLength(8)
@maxLength(8)
param siteSuffix string

@description('URL of the release package the app first runs from (the last good version).')
param packageUrl string

@allowed([
  'B1'
  'B2'
  'B3'
])
param appServiceSkuName string = 'B1'

@description('Adopted Website Contributor assignment name when the agent identity already has one on the web app.')
param siteWriterAssignmentName string = ''

@description('Tags to apply to the groups and resources.')
param tags object = {
  owner: 'demo'
  purpose: 'sre-agent'
  env: 'demo'
  layersOn: 'arc-demo'
}

resource sreRg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: sreResourceGroupName
  location: sreLocation
  tags: tags
}

// The same module and deployment name as infra/main.bicep, so the SRE layer later finds this identity and keeps it.
// Creating it first lets the grants below take effect before the paid parent exists.
module sreIdentity '../modules/sre-identity.bicep' = {
  name: 'sre-agent-identity'
  scope: sreRg
  params: {
    agentName: agentName
    location: sreLocation
    tags: tags
  }
}

resource workloadRg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: workloadResourceGroupName
  location: workloadLocation
  tags: union(tags, {
    sreScenario: 'T12'
  })
}

module workload 'workload.bicep' = {
  name: 'ticketing-workload'
  scope: workloadRg
  params: {
    location: workloadLocation
    namePrefix: namePrefix
    siteSuffix: siteSuffix
    packageUrl: packageUrl
    appServiceSkuName: appServiceSkuName
    agentPrincipalId: sreIdentity.outputs.principalId
    siteWriterAssignmentName: siteWriterAssignmentName
    tags: tags
  }
}

output workloadResourceGroupName string = workloadRg.name
output siteName string = workload.outputs.siteName
output siteId string = workload.outputs.siteId
output siteUrl string = workload.outputs.siteUrl
output workspaceId string = workload.outputs.workspaceId
output managedIdentityPrincipalId string = sreIdentity.outputs.principalId
