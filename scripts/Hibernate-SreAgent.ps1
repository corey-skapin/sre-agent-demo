#Requires -Version 7.4
<#
.SYNOPSIS
    Puts the optional SRE Agent layer into an off state.

.DESCRIPTION
    Azure SRE Agent currently has no "deallocated" or "stopped" state. Because
    the agent has an always-on hourly charge, the off-state for this optional
    repo removes only the SRE Agent resource group and cleans up RBAC granted to
    the agent identity on the existing arc-demo resource groups. It does not
    delete or modify the arc-demo estate; recreate the SRE layer with
    Deploy-SreAgent.ps1 when needed.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [string]$NamePrefix = 'arc-demo',

    [string]$SreResourceGroupName,

    [string]$AgentName,

    [string]$ArcResourceGroupName,

    [string]$InfraResourceGroupName,

    [string]$SkinPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzCli {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    if ($exitCode -ne 0) {
        throw "az $($Arguments -join ' ') failed with exit code $exitCode`n$text"
    }
    return $text
}

function Get-SafeAgentName {
    param([Parameter(Mandatory = $true)][string]$RawName)
    $safe = ($RawName -replace '[^A-Za-z0-9-]', '-') -replace '-+', '-'
    $safe = $safe.Trim('-')
    if ($safe -notmatch '^[A-Za-z]') { $safe = "sre-$safe" }
    if ($safe.Length -gt 32) { $safe = $safe.Substring(0, 32).TrimEnd('-') }
    if ($safe -notmatch '[A-Za-z0-9]$') { $safe = "${safe}0" }
    return $safe
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$skinModule = Join-Path $PSScriptRoot 'lib\DemoSkin.psm1'
Import-Module $skinModule -Force
$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue -Skin $skin -Path 'azure.namePrefix' -Default $NamePrefix }
if (-not $PSBoundParameters.ContainsKey('AgentName')) { $AgentName = Get-DemoSkinValue -Skin $skin -Path 'labels.agentName' -Default $AgentName }

if (-not $SreResourceGroupName) { $SreResourceGroupName = "rg-$NamePrefix-sre" }
if (-not $AgentName) { $AgentName = Get-SafeAgentName -RawName "sre-$NamePrefix" }
if (-not $ArcResourceGroupName) { $ArcResourceGroupName = "rg-$NamePrefix" }
if (-not $InfraResourceGroupName) { $InfraResourceGroupName = "rg-$NamePrefix-infra" }

Write-Host "Selecting subscription $SubscriptionId in tenant $TenantId..."
Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId, '--only-show-errors') | Out-Null
$accountTenant = Invoke-AzCli -Arguments @('account', 'show', '--query', 'tenantId', '--output', 'tsv', '--only-show-errors')
if ($accountTenant -ne $TenantId) {
    throw "Azure CLI is signed in to tenant $accountTenant, but -TenantId is $TenantId. Run az login --tenant $TenantId."
}

Write-Host "Hibernating SRE Agent layer '$AgentName' in '$SreResourceGroupName'..."
$identityPrincipalId = Invoke-AzCli -Arguments @(
    'identity', 'show',
    '--resource-group', $SreResourceGroupName,
    '--name', "$AgentName-uami",
    '--query', 'principalId',
    '--output', 'tsv',
    '--only-show-errors'
) 2>$null

if ($identityPrincipalId) {
    foreach ($rg in @($ArcResourceGroupName, $InfraResourceGroupName)) {
        $scope = Invoke-AzCli -Arguments @('group', 'show', '--name', $rg, '--query', 'id', '--output', 'tsv', '--only-show-errors')
        $assignments = Invoke-AzCli -Arguments @(
            'role', 'assignment', 'list',
            '--assignee-object-id', $identityPrincipalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--scope', $scope,
            '--query', '[].id',
            '--output', 'tsv',
            '--only-show-errors'
        ) 2>$null
        foreach ($assignmentId in (($assignments -split "`n") | Where-Object { $_ })) {
            if ($PSCmdlet.ShouldProcess($assignmentId, 'delete SRE Agent RBAC assignment')) {
                az role assignment delete --ids $assignmentId --only-show-errors
                Write-Host "Deleted role assignment $assignmentId"
            }
        }
    }
} else {
    Write-Warning "Managed identity '$AgentName-uami' not found; RBAC cleanup skipped."
}

if (az group exists --name $SreResourceGroupName) {
    if ($PSCmdlet.ShouldProcess($SreResourceGroupName, 'delete SRE Agent resource group')) {
        az group delete --name $SreResourceGroupName --yes --no-wait --only-show-errors
        Write-Host "Delete submitted for $SreResourceGroupName"
    }
} else {
    Write-Host "$SreResourceGroupName already absent"
}

Write-Host 'SRE Agent layer off-state submitted. Recreate with scripts\Deploy-SreAgent.ps1.'
