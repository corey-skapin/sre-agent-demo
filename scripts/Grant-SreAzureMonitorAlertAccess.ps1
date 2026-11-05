#Requires -Version 7.4
<#
.SYNOPSIS
Ensures the one subscription Monitoring Contributor grant needed for alert intake.
.DESCRIPTION
Verifies the exact live UAMI principal before inspecting or granting access.
WhatIf is read-only. Creating a missing assignment needs -GrantAzureMonitorAlertAccess to confirm you want the grant.
Existing exact assignments are adopted without changing their name.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$PrincipalId,
    [string]$SkinPath = '',
    [string]$SreResourceGroupName,
    [string]$AgentName,
    [switch]$GrantAzureMonitorAlertAccess,
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 180
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreLifecycle.psm1') -Force
$skin = Get-DemoSkin -Path $SkinPath
if (-not $SreResourceGroupName) { $SreResourceGroupName = "rg-$($skin.azure.namePrefix)-sre" }
if (-not $AgentName) { $AgentName = $skin.labels.agentName }
Assert-SreName -Value $SreResourceGroupName -Description 'SRE resource group'
Assert-SreName -Value $AgentName -Description 'agent name' -Pattern '^[A-Za-z][-A-Za-z0-9]{0,30}[A-Za-z0-9]$'
Assert-SreContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null
$scope = "/subscriptions/$SubscriptionId"
$identityId = "$scope/resourceGroups/$SreResourceGroupName/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$AgentName-uami"
$roleId = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
function Assert-LiveIdentity {
    $identity = Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('identity', 'show', '--ids', $identityId, '-o', 'json') |
        ConvertFrom-Json
    if ($identity.id -ine $identityId -or $identity.principalId -ine $PrincipalId) {
        throw 'Live UAMI does not match the principal and target you passed; no grant attempted.'
    }
}
function Read-PlatformGrant {
    $assignments = @(Get-SreArmRoleAssignments -SubscriptionId $SubscriptionId -ScopeId $scope -PrincipalId $PrincipalId)
    if (@($assignments | Where-Object principalId -NE $PrincipalId).Count) { throw 'Principal-filter inspection returned another identity; no grant attempted.' }
    $grants = @($assignments | Where-Object { Test-SreAzMonitorPlatformGrant $_ $SubscriptionId $PrincipalId })
    if ($grants.Count -gt 1) { throw 'Duplicate Azure Monitor platform grants; reconcile explicitly, no grant attempted.' }
    return $grants
}
Assert-LiveIdentity
$existing = @(Read-PlatformGrant)
$seed = "$scope|$PrincipalId|$roleId".ToLowerInvariant()
$hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($seed))
$name = [guid]::new([byte[]]$hash[0..15]).ToString()
$result = [ordered]@{
    principalId = $PrincipalId; identityId = $identityId; scope = $scope
    roleDefinitionId = "$scope/providers/Microsoft.Authorization/roleDefinitions/$roleId"
    assignmentId = "$scope/providers/Microsoft.Authorization/roleAssignments/$name"; status = 'preview'
}
if ($existing.Count) {
    $result.assignmentId = $existing[0].id
    $result.status = 'existing'
    return [pscustomobject]$result
}
if (-not $WhatIfPreference -and -not $GrantAzureMonitorAlertAccess) {
    throw 'Missing subscription Monitoring Contributor. Preview with -WhatIf, then pass -GrantAzureMonitorAlertAccess to confirm you want to grant it to this exact UAMI principal.'
}
if (-not $PSCmdlet.ShouldProcess(($result | ConvertTo-Json -Compress), 'Create exactly one Monitoring Contributor assignment')) {
    return [pscustomobject]$result
}
Assert-LiveIdentity
if (@(Read-PlatformGrant).Count) { throw 'Platform grant changed after preview; inspect again before proceeding.' }
Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @(
    'role', 'assignment', 'create', '--name', $name, '--assignee-object-id', $PrincipalId,
    '--assignee-principal-type', 'ServicePrincipal', '--role', $result.roleDefinitionId, '--scope', $scope, '-o', 'json'
) | Out-Null
$clock = [Diagnostics.Stopwatch]::StartNew()
do {
    Assert-LiveIdentity
    $observed = @(Read-PlatformGrant)
    if ($observed.Count -eq 1) {
        if ($observed[0].id -ine $result.assignmentId) { throw 'A different platform assignment appeared after creation; inspect concurrent IAM changes.' }
        $result.status = 'created'
        return [pscustomobject]$result
    }
    if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        throw 'Platform grant read-back remains pending. Inspect this exact principal before another invocation; never blindly repeat a failed or ambiguous create.'
    }
    Start-Sleep -Seconds 5
} while ($true)
