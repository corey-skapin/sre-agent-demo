#Requires -Version 7.4
<#
.SYNOPSIS
Parks the optional SRE layer while retaining its dedicated user-assigned identity.
.DESCRIPTION
Deletes only the paid parent. Retains the group/UAMI, workload grants and diagnostics.
Explicit Removed also deletes verified owned grants/resources and the empty SRE group.
Export configuration/evidence first: parent deletion loses live history and memory.
WhatIf performs read-only discovery only. Prefer Remove-SreAgent.ps1 for full removal.
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
    [ValidateSet('Hibernated', 'Removed')][string]$DesiredState = 'Hibernated',
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
    DesiredState = $DesiredState
}
$before = Get-SreLifecycleInventory @inventoryParameters
$removing = $DesiredState -eq 'Removed'
foreach ($message in $before.drift) { Write-Warning "$message Retained unchanged during Hibernate; inspect before Active." }
$resourceIds = @(if ($removing) { @($before.removableResources) + @($before.resources | Where-Object id -EQ $before.identityId | ForEach-Object { $_.id }) } else { @($before.removableResources | Where-Object { $_ -eq $before.agentId }) })
$assignmentIds = @(if ($removing) { @($before.externalAssignments) + @($before.parentAssignments) | ForEach-Object { $_.id } | Sort-Object -Unique })
if ($removing -and -not $before.principalId) { throw 'Removed requires a live or saved identity principal to verify external grants, even when the group is absent.' }
if (-not $resourceIds.Count -and -not $assignmentIds.Count -and -not ($removing -and $before.groupExists)) {
    if ($removing) { Write-Host 'SRE is already Removed: owned group/resources and saved-principal grants absent. No mutation performed.' }
    elseif ($before.identity) { Write-Host 'SRE is already parked: parent absent; existing identity, diagnostics and grants retained. No mutation performed.' }
    else { Write-Warning 'SRE identity is absent (legacy deletion or never deployed). Nothing to park; normal identity-retained Hibernated readiness will not pass.' }
    return
}
$inventoryParameters.PreviousIdentityPrincipalId = $before.principalId
$target = "delete resources [$($resourceIds -join ', ')]; revoke assignments [$($assignmentIds -join ', ')]; " + $(if ($removing) { "delete empty group $($before.groupId)" } else { 'RETAIN UAMI/group, diagnostics and workload grants' })
Write-Verbose $target
if (-not $PSCmdlet.ShouldProcess($target, "$DesiredState SRE; parent deletion loses native history/memory")) { return }
$clock = [Diagnostics.Stopwatch]::StartNew()
function Assert-RemainingScope {
    $current = Get-SreLifecycleInventory @inventoryParameters
    if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'Lifecycle observation deadline reached. Inspect readiness; do not blindly repeat deletion.' }
    if (-not $removing) {
        if ($null -ne $before.identity -and $null -eq $current.identity) { throw 'Retained UAMI disappeared; stop immediately.' }
        return
    }
    $currentAssignments = @(@($current.externalAssignments) + @($current.parentAssignments) | ForEach-Object { $_.id } | Sort-Object -Unique)
    $currentResources = @($current.removableResources) + @($current.resources | Where-Object id -EQ $current.identityId | ForEach-Object { $_.id })
    # Disappearance may be parent cascade or a previously accepted deletion, never an extra delete target.
    if (@($currentResources | Where-Object { $_ -notin $resourceIds }).Count -or
        @($currentAssignments | Where-Object { $_ -notin $assignmentIds }).Count) { throw 'Lifecycle scope drifted since preview. Stop and obtain a fresh preview.' }
}
foreach ($id in @($assignmentIds)) {
    Assert-RemainingScope
    $current = Get-SreLifecycleInventory @inventoryParameters
    if ($id -notin @(@($current.externalAssignments) + @($current.parentAssignments) | ForEach-Object { $_.id })) {
        $assignmentIds = @($assignmentIds | Where-Object { $_ -ne $id })
        continue
    }
    Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('role', 'assignment', 'delete', '--ids', $id) | Out-Null
    do {
        $observed = Get-SreLifecycleInventory @inventoryParameters
        if ($id -notin @(@($observed.externalAssignments) + @($observed.parentAssignments) | ForEach-Object { $_.id })) { break }
        if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Assignment deletion remains pending for $id. Inspect Removed readiness; do not resubmit blindly." }
        Start-Sleep -Seconds 5
    } while ($true)
    $assignmentIds = @($assignmentIds | Where-Object { $_ -ne $id })
}
foreach ($id in @($resourceIds)) {
    Assert-RemainingScope
    $present = @(Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('resource', 'list', '-g', $SreResourceGroupName, '-o', 'json') | ConvertFrom-Json)
    if ($id -notin @($present | ForEach-Object { $_.id })) { $resourceIds = @($resourceIds | Where-Object { $_ -ne $id }); continue }
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
if ($removing) {
    $final = Get-SreLifecycleInventory @inventoryParameters
    if ($final.resources.Count -or $final.externalAssignments.Count -or $final.parentAssignments.Count) { throw 'Removal is incomplete; group deletion refused.' }
    if ($final.groupExists) {
        Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('group', 'delete', '-n', $SreResourceGroupName, '--yes', '--no-wait') | Out-Null
        while ((Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('group', 'exists', '-n', $SreResourceGroupName, '-o', 'json') | ConvertFrom-Json)) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'Group deletion remains pending. Inspect Removed readiness; do not resubmit blindly.' }
            Start-Sleep -Seconds 5
        }
    }
    Write-Host 'SRE owned resources, grants and dedicated group removed. Verify Removed readiness with the saved principal; shared Arc resources and private exports were not deleted.'
} elseif ($before.identity) {
    Write-Host 'SRE parent absent; UAMI/group, existing diagnostics and workload grants retained. Run Test-SreReadiness.ps1 -DesiredState Hibernated with the saved principal. Review reported drift before Active.'
} else {
    Write-Warning 'Paid parent removed, but UAMI is absent. Hibernated readiness will fail. No identity or diagnostics were created by parking; authorized deployment can rebuild missing state.'
}
