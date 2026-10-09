#Requires -Version 7.4
<#
.SYNOPSIS
    Deploys the optional Azure SRE Agent layer onto an existing arc-demo deployment.

.DESCRIPTION
    This script discovers or accepts the resource IDs exported by arc-demo, then deploys
    infra/main.bicep at subscription scope. It does not modify or redeploy arc-demo.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [string]$Location = 'australiaeast',

    [string]$NamePrefix = 'arc-demo',

    [string]$SreResourceGroupName,

    [string]$AgentName,

    [string]$ArcResourceGroupName,

    [string]$InfraResourceGroupName,

    [string]$LogAnalyticsWorkspaceId,

    [string]$ActionGroupId,

    [string[]]$AdditionalManagedResourceIds = @(),

    [ValidateSet('High', 'Low')]
    [string]$AccessLevel = 'High',

    [string]$SkinPath = '',

    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    if ($exitCode -ne 0) {
        throw "az $($Arguments -join ' ') failed with exit code $exitCode`n$text"
    }

    return $text
}

function Get-AzTsv {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $value = Invoke-AzCli -Arguments ($Arguments + @('--only-show-errors', '-o', 'tsv'))
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Unable to resolve $Description. Pass it explicitly or check NamePrefix/resource group names."
    }

    return $value.Trim()
}

function Get-SafeAgentName {
    param([Parameter(Mandatory = $true)][string]$RawName)

    $safe = ($RawName -replace '[^A-Za-z0-9-]', '-') -replace '-+', '-'
    $safe = $safe.Trim('-')
    if ($safe -notmatch '^[A-Za-z]') {
        $safe = "sre-$safe"
    }
    if ($safe.Length -gt 32) {
        $safe = $safe.Substring(0, 32).TrimEnd('-')
    }
    if ($safe -notmatch '[A-Za-z0-9]$') {
        $safe = "${safe}0"
    }
    if ($safe -notmatch '^[A-Za-z]([-A-Za-z0-9]{0,30}[A-Za-z0-9])$') {
        throw "Unable to derive a valid SRE Agent name from '$RawName'. Pass -AgentName explicitly."
    }

    return $safe
}

function Assert-ArmId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if ($ResourceId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/') {
        throw "$Description is not a valid Azure resource ID: $ResourceId"
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required. Install it and run az login before this script.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$skinModule = Join-Path $PSScriptRoot 'lib\DemoSkin.psm1'
if (Test-Path -LiteralPath $skinModule) {
    Import-Module $skinModule -Force
}
$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if (-not $PSBoundParameters.ContainsKey('Location')) { $Location = Get-DemoSkinValue -Skin $skin -Path 'azure.location' -Default $Location }
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue -Skin $skin -Path 'azure.namePrefix' -Default $NamePrefix }
if (-not $PSBoundParameters.ContainsKey('AgentName')) { $AgentName = Get-DemoSkinValue -Skin $skin -Path 'labels.agentName' -Default $AgentName }
if (-not $PSBoundParameters.ContainsKey('AccessLevel')) { $AccessLevel = Get-DemoSkinValue -Skin $skin -Path 'sre.accessLevel' -Default $AccessLevel }
$demoTags = Merge-DemoHashtable -Defaults ([ordered]@{
    owner = 'demo'
    purpose = 'sre-agent'
    env = 'demo'
    layersOn = 'arc-demo'
}) -Overrides (Get-DemoSkinValue -Skin $skin -Path 'tags' -Default @{})

$templateFile = Join-Path $repoRoot 'infra\main.bicep'
if (-not (Test-Path -LiteralPath $templateFile)) {
    throw "Template not found: $templateFile"
}

if (-not $SreResourceGroupName) { $SreResourceGroupName = "rg-$NamePrefix-sre" }
if (-not $AgentName) { $AgentName = Get-SafeAgentName -RawName "sre-$NamePrefix" }
if (-not $ArcResourceGroupName) { $ArcResourceGroupName = "rg-$NamePrefix" }
if (-not $InfraResourceGroupName) { $InfraResourceGroupName = "rg-$NamePrefix-infra" }

Write-Host "Selecting subscription $SubscriptionId in tenant $TenantId..."
Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId, '--only-show-errors') | Out-Null
$accountTenant = Get-AzTsv -Arguments @('account', 'show', '--query', 'tenantId') -Description 'current Azure CLI tenant'
if ($accountTenant -ne $TenantId) {
    throw "Azure CLI is signed in to tenant $accountTenant, but -TenantId is $TenantId. Run az login --tenant $TenantId."
}

Write-Host 'Resolving existing arc-demo resources...'
$arcResourceGroupId = Get-AzTsv -Arguments @('group', 'show', '--name', $ArcResourceGroupName, '--query', 'id') -Description "Arc resource group '$ArcResourceGroupName'"
$infraResourceGroupId = Get-AzTsv -Arguments @('group', 'show', '--name', $InfraResourceGroupName, '--query', 'id') -Description "infra resource group '$InfraResourceGroupName'"

if (-not $LogAnalyticsWorkspaceId) {
    $workspaceName = "law-$NamePrefix"
    $LogAnalyticsWorkspaceId = Get-AzTsv -Arguments @('monitor', 'log-analytics', 'workspace', 'show', '--resource-group', $ArcResourceGroupName, '--workspace-name', $workspaceName, '--query', 'id') -Description "Log Analytics workspace '$workspaceName'"
}
if (-not $ActionGroupId) {
    $actionGroupName = "ag-$NamePrefix"
    $ActionGroupId = Get-AzTsv -Arguments @('monitor', 'action-group', 'show', '--resource-group', $ArcResourceGroupName, '--name', $actionGroupName, '--query', 'id') -Description "Action Group '$actionGroupName'"
}

Assert-ArmId -ResourceId $arcResourceGroupId -Description 'Arc resource group ID'
Assert-ArmId -ResourceId $infraResourceGroupId -Description 'infra resource group ID'
Assert-ArmId -ResourceId $LogAnalyticsWorkspaceId -Description 'Log Analytics workspace ID'
Assert-ArmId -ResourceId $ActionGroupId -Description 'Action Group ID'
foreach ($id in $AdditionalManagedResourceIds) {
    Assert-ArmId -ResourceId $id -Description 'Additional managed resource ID'
}

Write-Host 'Building Bicep template...'
Invoke-AzCli -Arguments @('bicep', 'build', '--file', $templateFile, '--only-show-errors') | Out-Null

$additionalManagedResourceIdsJson = ConvertTo-Json @($AdditionalManagedResourceIds) -Compress
$tagsJson = ConvertTo-Json $demoTags -Compress
$deploymentName = "sre-agent-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
$verb = if ($WhatIf) { 'what-if' } else { 'create' }
$parameters = @(
    "location=$Location",
    "sreResourceGroupName=$SreResourceGroupName",
    "agentName=$AgentName",
    "arcDemoResourceGroupName=$ArcResourceGroupName",
    "arcDemoInfraResourceGroupName=$InfraResourceGroupName",
    "arcDemoWorkspaceId=$LogAnalyticsWorkspaceId",
    "arcDemoActionGroupId=$ActionGroupId",
    "additionalManagedResourceIds=$additionalManagedResourceIdsJson",
    "accessLevel=$AccessLevel",
    "tags=$tagsJson"
)
$deploymentArgs = @(
    'deployment', 'sub', $verb,
    '--name', $deploymentName,
    '--location', $Location,
    '--template-file', $templateFile,
    '--parameters'
) + $parameters + @('--only-show-errors')

$targetSummary = "SRE Agent '$AgentName' in '$SreResourceGroupName' layered on '$ArcResourceGroupName' and '$InfraResourceGroupName'"
Write-Host "Running az deployment sub $verb for $targetSummary"
$resultText = Invoke-AzCli -Arguments $deploymentArgs
if ($WhatIf) {
    Write-Host $resultText
    Write-Host 'What-if complete. No resources were deployed.'
    return
}

$result = $resultText | ConvertFrom-Json
$outputs = $result.properties.outputs
Write-Host ''
Write-Host 'SRE Agent deploy complete.'
Write-Host "  Agent:       $($outputs.agentName.value)"
Write-Host "  Portal:      $($outputs.agentPortalUrl.value)"
Write-Host "  Identity:    $($outputs.managedIdentityId.value)"
Write-Host "  AccessLevel: $($outputs.accessLevel.value)"
Write-Host '  Managed resource IDs:'
foreach ($id in @($outputs.managedResourceIds.value)) {
    Write-Host "    - $id"
}
