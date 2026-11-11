#Requires -Version 7.4
<#
.SYNOPSIS
    Removes the T12 ticketing workload: deletes its dedicated resource group and everything in it.

.DESCRIPTION
    Deletes only the group this layer owns (the one named by the skin, tagged sreScenario=T12). The agent's write grant is scoped to the
    web app, so it goes with the app. The SRE group, the retained identity, the Arc estate and every other grant are not touched.
    Park or remove the SRE agent first (Hibernate-SreAgent.ps1): while it runs, its managed resources point at this group.
    Preview with -WhatIf, then run with -Confirm:$false.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [string]$SkinPath = '',

    [ValidateRange(60, 3600)]
    [int]$TimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\SreRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreRelease.psm1') -Force

function Invoke-AzCli {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments $Arguments
}

$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if (-not (Test-SreReleaseScenario -Skin $skin)) { throw 'This skin does not require T12; there is no ticketing workload to remove.' }
Assert-SreContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null
$release = Get-SreReleaseSettings -Skin $skin -SubscriptionId $SubscriptionId
$prefix = $skin.azure.namePrefix
$protected = @("rg-$prefix", "rg-$prefix-infra", "rg-$prefix-sre")
if ($release.resourceGroup -in $protected) { throw "Refusing to delete '$($release.resourceGroup)': it is a shared group, not a dedicated ticketing group." }

$exists = [bool](Invoke-AzCli -Arguments @('group', 'exists', '--name', $release.resourceGroup, '-o', 'json') | ConvertFrom-Json)
if (-not $exists) { Write-Host "Group '$($release.resourceGroup)' does not exist. Nothing to remove."; return }
$group = Invoke-AzCli -Arguments @('group', 'show', '--name', $release.resourceGroup, '-o', 'json') | ConvertFrom-Json
$tags = $group.PSObject.Properties['tags']
if (-not ($tags -and $tags.Value -and $tags.Value.PSObject.Properties['sreScenario'] -and $tags.Value.sreScenario -eq 'T12')) {
    throw "Group '$($release.resourceGroup)' is not tagged sreScenario=T12, so this layer does not own it. Nothing deleted."
}
$sreGroup = "rg-$prefix-sre"
$agentCount = 0
if ([bool](Invoke-AzCli -Arguments @('group', 'exists', '--name', $sreGroup, '-o', 'json') | ConvertFrom-Json)) {
    $agentCount = @(Invoke-AzCli -Arguments @('resource', 'list', '--resource-group', $sreGroup, '--resource-type', 'Microsoft.App/agents', '-o', 'json') | ConvertFrom-Json).Count
}
if ($agentCount) { throw 'The SRE agent still exists. Park it first with Hibernate-SreAgent.ps1; its managed resources point at this group.' }
$resources = @(Invoke-AzCli -Arguments @('resource', 'list', '--resource-group', $release.resourceGroup, '-o', 'json') | ConvertFrom-Json)
Write-Host "Ticketing group '$($release.resourceGroup)' holds $($resources.Count) resources:"
foreach ($resource in $resources) { Write-Host "  - $($resource.type)/$($resource.name)" }

if (-not $PSCmdlet.ShouldProcess($group.id, "Delete the ticketing resource group and its $($resources.Count) resources (the agent's web-app grant goes with the app)")) { return }
$clock = [Diagnostics.Stopwatch]::StartNew()
Invoke-AzCli -Arguments @('group', 'delete', '--name', $release.resourceGroup, '--yes', '--no-wait') | Out-Null
do {
    Start-Sleep -Seconds 10
    $stillThere = [bool](Invoke-AzCli -Arguments @('group', 'exists', '--name', $release.resourceGroup, '-o', 'json') | ConvertFrom-Json)
} while ($stillThere -and $clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
if ($stillThere) { throw "Group '$($release.resourceGroup)' is still deleting after $TimeoutSeconds s. Check it in Azure; do not repeat the delete blindly." }
Write-Host "Removed '$($release.resourceGroup)' in $([int]$clock.Elapsed.TotalSeconds) s. The SRE group, the retained identity and the Arc estate were not touched."
