#Requires -Version 7.4
param([Parameter(Mandatory)][string]$TemplatePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$template = Get-Content -LiteralPath $TemplatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "Template assertion failed: $Message" }
    $script:count++
}
$identityModule = @($template.resources | Where-Object name -EQ 'sre-agent-identity')[0]
$parentModule = @($template.resources | Where-Object name -EQ 'sre-agent-layer')[0]
$identity = @($identityModule.properties.template.resources | Where-Object type -EQ 'Microsoft.ManagedIdentity/userAssignedIdentities')
Check ($identity.Count -eq 1 -and $identityModule.properties.mode -eq 'Incremental') 'One retained identity is declared in an incremental module'
Check ($identity[0].name -eq "[format('{0}-uami', parameters('agentName'))]") 'Initial creation and future reuse have the same deterministic identity name'
Check ($identityModule.resourceGroup -eq $parentModule.resourceGroup) 'Identity and ephemeral parent share only the dedicated SRE group'
Check (@($parentModule.properties.template.resources | Where-Object type -EQ 'Microsoft.ManagedIdentity/userAssignedIdentities').Count -eq 0) 'Ephemeral parent module never creates a replacement identity'
$parent = @($parentModule.properties.template.resources | Where-Object type -EQ 'Microsoft.App/agents')[0]
Check ($parent.identity.type -eq 'SystemAssigned,UserAssigned' -and $parent.properties.actionConfiguration.mode -eq 'Review') 'Validated identity shape and governed Review preserved'
Check ($parent.properties.incidentManagementConfiguration.type -ceq 'AzMonitor') 'Fresh parent and wake explicitly select Azure Monitor through supported ARM configuration'
Check (($template | ConvertTo-Json -Depth 100) -notmatch '749f88d5-cbae-40b8-bcfc-e573ddc772fa') 'Repo IaC never creates the subscription Azure Monitor platform role'
Check ($parent.properties.actionConfiguration.identity -eq $parent.properties.knowledgeGraphConfiguration.identity) 'Actions and knowledge graph bind the same retained UAMI'
Check ($parentModule.properties.parameters.managedIdentityName.value -like '*sre-agent-identity*identityName*') 'Parent references retained identity module output'
$expectedRoles = @('92aaf0da-9dab-42b6-94a3-d43ce8d16293', 'acdd72a7-3385-48ef-bd42-f606fba81ae7', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
Check (@(Compare-Object $expectedRoles $template.variables.highAccessRoleDefinitionIds).Count -eq 0) 'High profile remains exactly three approved RG-scoped roles'
foreach ($name in @('sre-agent-rbac-arc', 'sre-agent-rbac-infra')) {
    $module = @($template.resources | Where-Object name -EQ $name)[0]
    Check ($module.properties.parameters.principalId.value -like '*sre-agent-identity*principalId*') "$name grants only retained UAMI, never recreated system identity"
    $role = @($module.properties.template.resources | Where-Object type -EQ 'Microsoft.Authorization/roleAssignments')[0]
    Check ($role.name.Contains("guid(resourceGroup().id, parameters('roleAssignmentSeed'), parameters('principalId'),")) "$name restores same deterministic names for stable scope/seed/principal/role"
}
Write-Host "$count compiled-template assertions passed; no Azure sign-in or deployment."
