#Requires -Version 7.4
<#
.SYNOPSIS
Removes only the optional SRE layer after explicit operator approval.
.DESCRIPTION
Deletion loses custom agents, plans, threads, memory and connector configuration.
Export required evidence first. The Arc estate remains running. WhatIf performs
read-only discovery and does not select an account, revoke roles or delete resources.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$NamePrefix = 'arc-demo',
    [string]$SreResourceGroupName,
    [string]$AgentName,
    [string]$ArcResourceGroupName,
    [string]$InfraResourceGroupName,
    [string]$SkinPath = '',
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$PreviousIdentityPrincipalId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreRuntime.psm1') -Force
$skin = Get-DemoSkin -Path $SkinPath
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = $skin.azure.namePrefix }
if (-not $AgentName) { $AgentName = $skin.labels.agentName }
if (-not $SreResourceGroupName) { $SreResourceGroupName = "rg-$NamePrefix-sre" }
if (-not $ArcResourceGroupName) { $ArcResourceGroupName = "rg-$NamePrefix" }
if (-not $InfraResourceGroupName) { $InfraResourceGroupName = "rg-$NamePrefix-infra" }
foreach ($name in @($SreResourceGroupName, $ArcResourceGroupName, $InfraResourceGroupName)) {
    Assert-SreName -Value $name -Description 'resource group'
}
Assert-SreName -Value $AgentName -Description 'agent name' -Pattern '^[A-Za-z][-A-Za-z0-9]{0,30}[A-Za-z0-9]$'
if ($SreResourceGroupName -in @($ArcResourceGroupName, $InfraResourceGroupName)) { throw 'SRE and Arc groups must be separate.' }
Assert-SreContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null
function Read-AzJson([string[]]$Arguments) {
    Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments ($Arguments + @('-o', 'json')) | ConvertFrom-Json -Depth 100
}
$exists = Read-AzJson @('group', 'exists', '-n', $SreResourceGroupName)
$principalId = $PreviousIdentityPrincipalId
if ($exists) {
    $resources = @(Read-AzJson @('resource', 'list', '-g', $SreResourceGroupName))
    $allowedResources = @(
        "Microsoft.App/agents/$AgentName",
        "Microsoft.ManagedIdentity/userAssignedIdentities/$AgentName-uami",
        "Microsoft.Insights/components/$AgentName-appi",
        'Microsoft.Insights/actionGroups/Application Insights Smart Detection'
    )
    $unexpected = @($resources | Where-Object { "$($_.type)/$($_.name)" -notin $allowedResources })
    if ($unexpected.Count) { throw "Unexpected resources in SRE group. Refusing group deletion: $($unexpected.name -join ', ')" }
    $identities = @(Read-AzJson @('identity', 'list', '-g', $SreResourceGroupName))
    $identity = $identities | Where-Object name -EQ "$AgentName-uami" | Select-Object -First 1
    if ($identity) {
        if ($principalId -and $principalId -ne $identity.principalId) { throw 'Previous principal differs from live identity; clean it up separately.' }
        $principalId = $identity.principalId
    }
}
$roles = @('73c42c96-874c-492b-b04d-ab87d138a893', '92aaf0da-9dab-42b6-94a3-d43ce8d16293', 'acdd72a7-3385-48ef-bd42-f606fba81ae7', 'b24988ac-6180-42a0-ab88-20f7382dd24c', '749f88d5-cbae-40b8-bcfc-e573ddc772fa')
$assignments = @()
$scopes = @("/subscriptions/$SubscriptionId")
foreach ($rg in @($ArcResourceGroupName, $InfraResourceGroupName)) {
    if (Read-AzJson @('group', 'exists', '-n', $rg)) { $scopes += "/subscriptions/$SubscriptionId/resourceGroups/$rg" }
}
foreach ($scope in $scopes) {
    $atScope = @(Read-AzJson @('role', 'assignment', 'list', '--scope', $scope, '--include-inherited'))
    if ($principalId) {
        $owned = @($atScope | Where-Object { $_.principalId -eq $principalId })
        if (@($owned | Where-Object { $_.scope -notin $scopes }).Count) {
            throw 'Identity-owned grant outside the known subscription/RG scopes requires separate explicit cleanup.'
        }
        $unknown = @($owned | Where-Object { ($_.roleDefinitionId -split '/')[-1] -notin $roles })
        if ($unknown.Count) { throw "Unexpected grants for the SRE identity at $scope; approve a separate scoped cleanup before deletion." }
        $assignments += $owned
    }
    $assignments = @($assignments | Sort-Object -Property id -Unique)
}
if (-not $principalId) {
    Write-Warning 'Identity absent. No grants were deleted. Legacy orphan RBAC cannot be verified without -PreviousIdentityPrincipalId.'
}
if (-not $exists -and -not $assignments.Count) {
    Write-Host 'SRE resource group already absent. No cloud mutation performed.'
    return
}
$assignmentIds = @($assignments | ForEach-Object { $_.id })
$cleanupTarget = "$SreResourceGroupName and identity-owned grants: $($assignmentIds -join ', ')"
if ($PSCmdlet.ShouldProcess($cleanupTarget, 'delete optional SRE group and known identity-owned grants including inherited grants; lose agent history/configuration')) {
    foreach ($assignment in $assignments) {
        Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('role', 'assignment', 'delete', '--ids', $assignment.id) | Out-Null
    }
    if ($exists) {
        Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('group', 'delete', '-n', $SreResourceGroupName, '--yes', '--no-wait') | Out-Null
    }
    Write-Host 'Hibernation submitted, not verified. Run Test-SreReadiness.ps1 -DesiredState Hibernated with the saved principal ID after deletion completes.'
}
