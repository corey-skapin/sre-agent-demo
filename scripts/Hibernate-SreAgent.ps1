#Requires -Version 7.4
<#
.SYNOPSIS
Parks the optional SRE layer while retaining its dedicated user-assigned identity.
.DESCRIPTION
Deletes the parent and known diagnostics, not the SRE group/UAMI or Arc resources.
Removes known identity-owned external grants and the parent administrator grant.
Export configuration/evidence first: parent deletion loses live history and memory.
WhatIf performs read-only discovery only. Full identity/group removal is separate cleanup.
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
    [string]$PreviousIdentityPrincipalId,
    [ValidateRange(1, 1800)][int]$TimeoutSeconds = 300
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreLifecycle.psm1') -Force
$skin = Get-DemoSkin -Path $SkinPath
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = $skin.azure.namePrefix }
if (-not $AgentName) { $AgentName = $skin.labels.agentName }
if (-not $SreResourceGroupName) { $SreResourceGroupName = "rg-$NamePrefix-sre" }
if (-not $ArcResourceGroupName) { $ArcResourceGroupName = "rg-$NamePrefix" }
if (-not $InfraResourceGroupName) { $InfraResourceGroupName = "rg-$NamePrefix-infra" }
foreach ($name in @($SreResourceGroupName, $ArcResourceGroupName, $InfraResourceGroupName)) { Assert-SreName -Value $name -Description 'resource group' }
Assert-SreName -Value $AgentName -Description 'agent name' -Pattern '^[A-Za-z][-A-Za-z0-9]{0,30}[A-Za-z0-9]$'
if ($SreResourceGroupName -in @($ArcResourceGroupName, $InfraResourceGroupName)) { throw 'SRE and Arc groups must be separate.' }
Assert-SreContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null
$inventoryParameters = @{
    SubscriptionId = $SubscriptionId; SreResourceGroupName = $SreResourceGroupName; AgentName = $AgentName
    ArcResourceGroupName = $ArcResourceGroupName; InfraResourceGroupName = $InfraResourceGroupName
    PreviousIdentityPrincipalId = $PreviousIdentityPrincipalId
}
$before = Get-SreLifecycleInventory @inventoryParameters
$resourceIds = @($before.removableResources)
$assignmentIds = @(@($before.externalAssignments) + @($before.parentAssignments) | ForEach-Object { $_.id } | Sort-Object -Unique)
if (-not $resourceIds.Count -and -not $assignmentIds.Count) {
    if ($before.identity) { Write-Host 'SRE is already parked: retained UAMI, no parent/diagnostics or owned grants. No mutation performed.' }
    else { Write-Warning 'SRE identity is absent (legacy deletion or never deployed). Nothing to park; normal identity-retained Hibernated readiness will not pass.' }
    return
}
if (-not $before.principalId) { throw 'Cannot verify grant cleanup without a live or saved identity principal. No resources deleted.' }
$inventoryParameters.PreviousIdentityPrincipalId = $before.principalId
$target = "delete resources [$($resourceIds -join ', ')]; revoke assignments [$($assignmentIds -join ', ')]; RETAIN $($before.identityId)"
if (-not $PSCmdlet.ShouldProcess($target, 'park SRE; lose parent configuration/history, retain stable UAMI and resource group')) { return }
$clock = [Diagnostics.Stopwatch]::StartNew()
function Assert-RemainingScope {
    $current = Get-SreLifecycleInventory @inventoryParameters
    $currentAssignments = @(@($current.externalAssignments) + @($current.parentAssignments) | ForEach-Object { $_.id } | Sort-Object -Unique)
    if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'Hibernation observation deadline reached. Inspect readiness; do not blindly repeat deletion.' }
    if ($null -ne $before.identity -and $null -eq $current.identity) { throw 'Retained UAMI disappeared; stop immediately.' }
    if (@(Compare-Object @($resourceIds | Sort-Object) @($current.removableResources | Sort-Object)).Count -or
        @(Compare-Object $assignmentIds $currentAssignments).Count) { throw 'Lifecycle scope drifted since preview. Stop and obtain a fresh preview.' }
}
foreach ($id in @($assignmentIds)) {
    Assert-RemainingScope
    Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('role', 'assignment', 'delete', '--ids', $id) | Out-Null
    $assignmentIds = @($assignmentIds | Where-Object { $_ -ne $id })
}
foreach ($id in @($resourceIds)) {
    Assert-RemainingScope
    Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('resource', 'delete', '--ids', $id) | Out-Null
    do {
        $remaining = @(Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('resource', 'list', '-g', $SreResourceGroupName, '-o', 'json') | ConvertFrom-Json)
        if ($id -notin @($remaining | ForEach-Object { $_.id })) { break }
        if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Deletion remains pending for $id. Inspect readiness, do not resubmit blindly." }
        Start-Sleep -Seconds 5
    } while ($true)
    $resourceIds = @($resourceIds | Where-Object { $_ -ne $id })
}
Assert-RemainingScope
if ($before.identity) {
    Write-Host 'SRE parent/diagnostics and owned grants are absent; UAMI retained. Run Test-SreReadiness.ps1 -DesiredState Hibernated with the saved principal to verify the public readiness contract.'
} else {
    Write-Warning 'Partial/legacy cleanup completed using the saved principal, but UAMI is absent. Normal retained-identity Hibernated readiness will fail. A separately authorized deployment is needed to rebuild; no identity was created by cleanup.'
}
