// The T12 "Friday release" workload: a small ticketing web app on App Service, its telemetry, a checkout
// failure alert and the one write grant the SRE agent identity needs. No database, so it costs about one B1 plan.
// Adapted from microsoft/sre-agent labs/onboardinglab/ticketingapp-source/modules/workload.bicep at commit
// e6afdfc8a5e446b488325118b0c07da7c3d8462a (MIT, Copyright (c) Microsoft Corporation). See NOTICE.md.
targetScope = 'resourceGroup'

@description('Azure region for the workload. App Service quota differs by region and subscription; Deploy-TicketingWorkload.ps1 checks it first.')
param location string

@description('Short lowercase prefix shared with the rest of the demo.')
@minLength(2)
@maxLength(20)
param namePrefix string

@description('Eight lowercase hex characters, derived from the subscription and group by the deploy script, that keep the web app name globally unique and computable.')
@minLength(8)
@maxLength(8)
param siteSuffix string

@description('URL of the release package the app runs from. The deploy script passes the last good version.')
param packageUrl string

@description('App Service plan size. B1 is the cheapest plan that keeps the app always on.')
@allowed([
  'B1'
  'B2'
  'B3'
])
param appServiceSkuName string = 'B1'

@description('Object ID of the retained SRE agent identity that receives the write grant on the web app.')
param agentPrincipalId string

@description('Adopts an existing Website Contributor assignment name for the agent identity on the web app instead of creating a second one. Empty means a deterministic name.')
param siteWriterAssignmentName string = ''

@description('Tags applied to every resource.')
param tags object = {}

var planName = 'plan-${namePrefix}-ticketing'
var workspaceName = 'law-${namePrefix}-ticketing'
var appInsightsName = 'appi-${namePrefix}-ticketing'
var actionGroupName = 'ag-${namePrefix}-ticketing'
var alertName = 'alert-${namePrefix}-ticketing-checkout-failures'
var siteName = 'app-${namePrefix}-ticketing-${siteSuffix}'
var websiteContributorRoleId = 'de139f84-1756-47ae-9be6-808fbbe84772'
var siteWriterName = empty(siteWriterAssignmentName) ? guid(resourceGroup().id, siteName, agentPrincipalId, websiteContributorRoleId) : siteWriterAssignmentName
var checkoutFailureQuery = '''
AppRequests
| where TimeGenerated > ago(5m)
| where Name == "POST /checkout"
| where Success == false or toint(ResultCode) >= 500
| summarize FailureCount = count()
'''

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// No receivers: the agent reads Azure Monitor alerts directly. The group is the seam the alert rules point at.
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'ticketing'
    enabled: true
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: appServiceSkuName
    tier: 'Basic'
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: siteName
  location: location
  kind: 'app,linux'
  tags: union(tags, {
    sreScenario: 'T12'
  })
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'NODE|22-lts'
      appCommandLine: 'cd /home/site/wwwroot && node server.js'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      healthCheckPath: '/healthz'
      appSettings: [
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: packageUrl
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'false'
        }
        {
          name: 'ENABLE_ORYX_BUILD'
          value: 'false'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'NODE_OPTIONS'
          value: '--enable-source-maps'
        }
      ]
    }
  }
}

resource disableFtp 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: site
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource disableScmBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: site
  name: 'scm'
  properties: {
    allow: false
  }
}

resource checkoutFailureAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: alertName
  location: location
  tags: tags
  properties: {
    displayName: alertName
    description: 'Checkout requests returned HTTP 5xx responses.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [logAnalytics.id]
    criteria: {
      allOf: [
        {
          query: checkoutFailureQuery
          timeAggregation: 'Total'
          metricMeasureColumn: 'FailureCount'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
    autoMitigate: true
  }
}

// A spare copy of the alert, off by default. Its name contains the first rule's name, so the same response plan
// matches it: enable it and disable the first one if the plan ever merges a new failure into an old thread.
resource checkoutFailureAlertSpare 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${alertName}-b'
  location: location
  tags: tags
  properties: {
    displayName: '${alertName}-b'
    description: 'Spare copy of the checkout failure alert; off unless a rehearsal needs a fresh rule.'
    severity: 2
    enabled: false
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [logAnalytics.id]
    criteria: {
      allOf: [
        {
          query: checkoutFailureQuery
          timeAggregation: 'Total'
          metricMeasureColumn: 'FailureCount'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
    autoMitigate: true
  }
}

// The agent already reads the whole subscription through the Monitoring Contributor grant that alert access needs
// (its */read), so this is the only extra grant T12 adds: it lets an approved fix change this one web app's settings
// to redeploy a release. The agent's other grants are unchanged.
resource agentSiteWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: siteWriterName
  scope: site
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', websiteContributorRoleId)
    principalId: agentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output siteName string = site.name
output siteId string = site.id
output siteUrl string = 'https://${site.properties.defaultHostName}'
output workspaceId string = logAnalytics.id
output appInsightsAppId string = applicationInsights.properties.AppId
output alertName string = checkoutFailureAlert.name
output spareAlertName string = checkoutFailureAlertSpare.name
output actionGroupId string = actionGroup.id
