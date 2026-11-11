targetScope = 'resourceGroup'

@description('Region to test. App Service quota is per subscription, region and SKU.')
param location string

@allowed([
  'B1'
  'B2'
  'B3'
])
param skuName string = 'B1'

// Deploy-TicketingWorkload.ps1 only validates this file (az deployment group validate), so nothing is created.
// A validate against an existing group asks App Service for quota; a subscription-scope validate does not.
resource probe 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'plan-quota-probe'
  location: location
  kind: 'linux'
  sku: {
    name: skuName
  }
  properties: {
    reserved: true
  }
}
