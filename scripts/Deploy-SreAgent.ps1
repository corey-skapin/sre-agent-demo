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

    [ValidateSet('User', 'ServicePrincipal')]
    [string]$DeployerPrincipalType,

    [switch]$ParentOnly,

    [string]$ConfigurationBackupPath,

    [switch]$AllowLegacyMigration,

    [ValidateRange(1, 600)]
    [int]$ConfigurationTimeoutSeconds = 180,

    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments $Arguments
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

    Assert-SreArmId -ResourceId $ResourceId -SubscriptionId $SubscriptionId -Description $Description
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required. Install it and run az login before this script.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\SreRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreLifecycle.psm1') -Force
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

Assert-SreName -Value $NamePrefix -Description 'name prefix' -Pattern '^[a-z][a-z0-9-]{1,19}$'
Assert-SreName -Value $AgentName -Description 'agent name' -Pattern '^[A-Za-z][-A-Za-z0-9]{0,30}[A-Za-z0-9]$'
foreach ($name in @($SreResourceGroupName, $ArcResourceGroupName, $InfraResourceGroupName)) {
    Assert-SreName -Value $name -Description 'resource group'
}
if ($SreResourceGroupName -in @($ArcResourceGroupName, $InfraResourceGroupName)) {
    throw 'The optional SRE resource group must be separate from both Arc resource groups.'
}
if ($AccessLevel -notin @('High', 'Low')) { throw 'Skin accessLevel must be High or Low.' }
Assert-SreName -Value $Location -Description 'location' -Pattern '^[a-z][a-z0-9]+$'
if (-not $WhatIf -and -not $ParentOnly -and -not $ConfigurationBackupPath) {
    throw 'Complete deployment requires -ConfigurationBackupPath outside git, or explicit -ParentOnly. Current-schema configuration uses the pinned official template protocol; migration additionally requires -AllowLegacyMigration and scoped approval. Parent deployment alone is not demo Ready.'
}
if (-not $ParentOnly -and $ConfigurationBackupPath) {
    if ($NamePrefix -ne $skin.azure.namePrefix -or $AgentName -ne $skin.labels.agentName -or
        $SreResourceGroupName -ne "rg-$NamePrefix-sre" -or $ArcResourceGroupName -ne "rg-$NamePrefix" -or $InfraResourceGroupName -ne "rg-$NamePrefix-infra") {
        throw 'Complete configuration must match the skin resource names. Reskin explicitly, or use -ParentOnly for custom parent overrides.'
    }
    $backup = [IO.Path]::GetFullPath($ConfigurationBackupPath)
    if ($backup.StartsWith(([IO.Path]::GetFullPath($repoRoot) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase) -or
        (Test-Path -LiteralPath $backup) -or -not (Test-Path -LiteralPath (Split-Path $backup -Parent) -PathType Container)) {
        throw 'ConfigurationBackupPath must be a new file in an existing directory outside the repository.'
    }
}
$account = Assert-SreContext -SubscriptionId $SubscriptionId -TenantId $TenantId
if (-not $DeployerPrincipalType) {
    $DeployerPrincipalType = switch ($account.user.type) {
        'user' { 'User' }
        'servicePrincipal' { 'ServicePrincipal' }
        default { throw 'Unable to infer deploying principal type. Pass -DeployerPrincipalType User or ServicePrincipal (including managed identity).' }
    }
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
if ($LogAnalyticsWorkspaceId -notmatch '/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') { throw 'Expected a Log Analytics workspace resource ID.' }
if ($ActionGroupId -notmatch '/providers/Microsoft\.Insights/actionGroups/[^/]+$') { throw 'Expected an Azure Monitor Action Group resource ID.' }
foreach ($id in $AdditionalManagedResourceIds) {
    Assert-ArmId -ResourceId $id -Description 'Additional managed resource ID'
}

$requiredScenarios = @(Get-DemoSkinValue -Skin $skin -Path 'sre.requiredScenarios' -Default @('T09', 'T11'))
if ('T09' -in $requiredScenarios) {
    $containerId = Get-AzTsv -Arguments @('containerapp', 'show', '-g', $InfraResourceGroupName, '-n', "ca-$NamePrefix-fault", '--query', 'id') -Description 'required T09 Container App'
    $AdditionalManagedResourceIds += $containerId
}
if ('T10' -in $requiredScenarios -or 'T11' -in $requiredScenarios) {
    $machineName = Get-DemoSkinValue -Skin $skin -Path 'sre.targetArcMachine'
    $machineId = Get-AzTsv -Arguments @('connectedmachine', 'show', '-g', $ArcResourceGroupName, '-n', $machineName, '--query', 'id') -Description 'required Arc machine'
    $AdditionalManagedResourceIds += $machineId
}
$AdditionalManagedResourceIds = @($AdditionalManagedResourceIds | Sort-Object -Unique)

# Adopt existing role names for this principal; never attempt to overwrite an old principal's assignment.
$existingNames = @{}
$sreExists = Invoke-AzCli -Arguments @('group', 'exists', '-n', $SreResourceGroupName, '-o', 'json') | ConvertFrom-Json
$principalId = $null
if ($sreExists) {
    $identities = Invoke-AzCli -Arguments @('identity', 'list', '-g', $SreResourceGroupName, '-o', 'json') | ConvertFrom-Json
    $principalId = @($identities | Where-Object name -EQ "$AgentName-uami" | Select-Object -ExpandProperty principalId) | Select-Object -First 1
    if ($principalId -and $principalId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { throw 'Retained UAMI has an invalid principal ID; stop before deployment.' }
    $resources = Invoke-AzCli -Arguments @('resource', 'list', '-g', $SreResourceGroupName, '-o', 'json') | ConvertFrom-Json
    $allowed = @("Microsoft.App/agents/$AgentName", "Microsoft.ManagedIdentity/userAssignedIdentities/$AgentName-uami", "Microsoft.Insights/components/$AgentName-appi", 'Microsoft.Insights/actionGroups/Application Insights Smart Detection')
    if (@($resources | Where-Object { "$($_.type)/$($_.name)" -notin $allowed }).Count) { throw 'Unexpected resources in the dedicated SRE group; inspect ownership before deployment.' }
    $existingDiagnostics = @($resources | Where-Object { $_.type -eq 'Microsoft.Insights/components' -and $_.name -eq "$AgentName-appi" })
    if ($existingDiagnostics.Count) {
        $component = Invoke-AzCli -Arguments @('resource', 'show', '--ids', $existingDiagnostics[0].id, '-o', 'json') | ConvertFrom-Json -Depth 100
        if ($component.properties.WorkspaceResourceId -ine $LogAnalyticsWorkspaceId -or $component.location -ine $Location) {
            throw 'Retained Application Insights workspace/location differs from requested inputs. Stop before deployment; do not silently relocate retained diagnostics.'
        }
    }
    $existingParent = $resources | Where-Object { $_.type -eq 'Microsoft.App/agents' -and $_.name -eq $AgentName } | Select-Object -First 1
    if ($existingParent) {
        if (-not $principalId) { throw 'Existing parent has no expected UAMI. Refusing implicit identity replacement; inspect and reconcile separately.' }
        $currentParent = Invoke-AzCli -Arguments @('resource', 'show', '--ids', $existingParent.id, '-o', 'json') | ConvertFrom-Json -Depth 100
        $AdditionalManagedResourceIds = @(@($AdditionalManagedResourceIds) + @($currentParent.properties.knowledgeGraphConfiguration.managedResources) | Sort-Object -Unique)
    }
    if ($principalId) {
        Write-Host "Reusing retained SRE UAMI principal: $principalId. Incremental IaC preserves its deterministic resource ID."
    } else {
        Write-Host 'First deployment: IaC will create the dedicated retained SRE UAMI; future normal hibernation keeps it.'
    }
}
$retainedAssignments = @()
if ($principalId) {
    $retainedAssignments = @(Get-SreArmRoleAssignments -SubscriptionId $SubscriptionId -ScopeId "/subscriptions/$SubscriptionId" -PrincipalId $principalId)
    $allowedRoles = if ($AccessLevel -eq 'Low') { @('73c42c96-874c-492b-b04d-ab87d138a893', 'acdd72a7-3385-48ef-bd42-f606fba81ae7') } else { @('92aaf0da-9dab-42b6-94a3-d43ce8d16293', 'acdd72a7-3385-48ef-bd42-f606fba81ae7', 'b24988ac-6180-42a0-ab88-20f7382dd24c') }
    if (@($retainedAssignments | Where-Object {
        $_.principalId -ne $principalId -or $_.scope -notin @($arcResourceGroupId, $infraResourceGroupId) -or ($_.roleDefinitionId -split '/')[-1] -notin $allowedRoles
    }).Count) { throw "$AccessLevel profile has incompatible grant scope/role. Reconcile explicitly before Active; no grants changed." }
}
foreach ($scope in @($arcResourceGroupId, $infraResourceGroupId)) {
    $names = @{}
    if ($principalId) {
        $assignments = Invoke-AzCli -Arguments @('role', 'assignment', 'list', '--scope', $scope, '--include-inherited', '--fill-principal-name', 'false', '-o', 'json') | ConvertFrom-Json
        foreach ($assignment in @($assignments | Where-Object { $_.principalId -eq $principalId })) {
            $roleId = ($assignment.roleDefinitionId -split '/')[-1]
            if ($roleId -notin $allowedRoles -or $assignment.scope -ine $scope) {
                throw "$AccessLevel profile requested but existing incompatible or inherited grant $roleId remains at $($assignment.scope). Obtain scoped approval to reconcile it before Active; incremental deployment does not revoke grants."
            }
            if ($names.ContainsKey($roleId)) { throw "Duplicate role grants for $principalId at $scope; reconcile explicitly before deployment." }
            $names[$roleId] = $assignment.name
        }
    }
    $existingNames[$scope] = $names
}

Write-Host 'Building Bicep template...'
Invoke-AzCli -Arguments @('bicep', 'build', '--file', $templateFile, '--stdout') | Out-Null

$deploymentName = "sre-agent-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
$verb = if ($WhatIf) { 'what-if' } else { 'create' }
$paramFile = Join-Path $env:TEMP "sre-agent-params-$(Get-Random).json"
$templateParameters = @{
    location                     = @{ value = $Location }
    sreResourceGroupName         = @{ value = $SreResourceGroupName }
    agentName                    = @{ value = $AgentName }
    arcDemoResourceGroupName     = @{ value = $ArcResourceGroupName }
    arcDemoInfraResourceGroupName = @{ value = $InfraResourceGroupName }
    arcDemoWorkspaceId           = @{ value = $LogAnalyticsWorkspaceId }
    arcDemoActionGroupId         = @{ value = $ActionGroupId }
    additionalManagedResourceIds = @{ value = @($AdditionalManagedResourceIds) }
    accessLevel                  = @{ value = $AccessLevel }
    deployerPrincipalType        = @{ value = $DeployerPrincipalType }
    arcRoleAssignmentNames       = @{ value = $existingNames[$arcResourceGroupId] }
    infraRoleAssignmentNames     = @{ value = $existingNames[$infraResourceGroupId] }
    tags                         = @{ value = $demoTags }
}
@{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = $templateParameters
} | ConvertTo-Json -Depth 20 | ForEach-Object {
    [System.IO.File]::WriteAllText($paramFile, $_, [System.Text.UTF8Encoding]::new($false))
}
$deploymentArgs = @(
    'deployment', 'sub', $verb,
    '--name', $deploymentName,
    '--location', $Location,
    '--template-file', $templateFile,
    '--parameters', "@$paramFile",
    '--only-show-errors'
)

$targetSummary = "SRE Agent '$AgentName' in '$SreResourceGroupName' layered on '$ArcResourceGroupName' and '$InfraResourceGroupName'"
Write-Host "Running az deployment sub $verb for $targetSummary"
try {
    $resultText = Invoke-AzCli -Arguments $deploymentArgs
    if ($WhatIf) {
        Write-Host $resultText
        Write-Host 'What-if complete. No resources were deployed.'
        return
    }
} finally {
    Remove-Item $paramFile -Force -ErrorAction SilentlyContinue
}

$result = $resultText | ConvertFrom-Json
$outputs = $result.properties.outputs
if ($principalId -and $outputs.managedIdentityPrincipalId.value -ne $principalId) {
    throw 'Deployment did not retain the preflight UAMI principal. Stop before data-plane configuration and inspect identity/RBAC drift.'
}
Write-Host ''
Write-Host 'SRE parent deployment complete; data-plane configuration and routing readiness are NOT confirmed.'
Write-Host "  Agent:       $($outputs.agentName.value)"
Write-Host "  Portal:      $($outputs.agentPortalUrl.value)"
Write-Host "  Identity:    $($outputs.managedIdentityId.value)"
Write-Host "  AccessLevel: $($outputs.accessLevel.value)"
Write-Host '  Managed resource IDs:'
foreach ($id in @($outputs.managedResourceIds.value)) {
    Write-Host "    - $id"
}
if ($ParentOnly) {
    Write-Host 'Next: Initialize-SreConfiguration.ps1 -Inspect, then approved -Apply with -BackupPath; run Test-SreReadiness.ps1. Do not induce faults before routing is verified.'
} else {
    & (Join-Path $PSScriptRoot 'Initialize-SreConfiguration.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId -SkinPath $SkinPath `
        -Apply -BackupPath $ConfigurationBackupPath -AllowLegacyMigration:$AllowLegacyMigration -TimeoutSeconds $ConfigurationTimeoutSeconds
    Write-Host 'Current-schema handler/plans verified. Run Test-SreReadiness.ps1; fresh incident/recovery evidence is a separate authorized rehearsal gate.'
}
