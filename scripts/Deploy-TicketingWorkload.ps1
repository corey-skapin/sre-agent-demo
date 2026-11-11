#Requires -Version 7.4
<#
.SYNOPSIS
    Deploys the T12 "Friday release" workload (a ticketing web app, its alert and the agent's one write grant) before the paid SRE parent exists.

.DESCRIPTION
    Run this before Deploy-SreAgent.ps1. A new role can take many minutes to work, so this script creates the retained SRE identity,
    the web app and the grant first, while no parent is billing.

    It checks that both release packages can be downloaded, asks App Service whether the subscription has quota for the plan (nothing is
    created by that check), deploys infra/ticketing/main.bicep, and waits until the app serves the last good release.
    -WhatIf runs the read-only checks and a what-if and creates nothing, except that a missing dedicated SRE group is not created.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [string]$SkinPath = '',

    [ValidateRange(60, 1800)]
    [int]$HealthTimeoutSeconds = 600,

    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\SreRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreLifecycle.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreRelease.psm1') -Force

function Invoke-AzCli {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments $Arguments
}

function Test-AzResourceExists {
    param([Parameter(Mandatory = $true)][string]$ResourceId)
    try {
        $null = Invoke-AzCli -Arguments @('resource', 'show', '--ids', $ResourceId, '--query', 'id', '-o', 'tsv')
        return $true
    } catch {
        if ($_.Exception.Message -match 'ResourceNotFound|ResourceGroupNotFound|could not be found|was not found') { return $false }
        throw
    }
}

$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if (-not (Test-SreReleaseScenario -Skin $skin)) {
    throw 'This skin does not require T12. Add T12 to sre.requiredScenarios and fill in the release section (docs/t12-friday-release.md).'
}
Assert-SreContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null
$release = Get-SreReleaseSettings -Skin $skin -SubscriptionId $SubscriptionId
$prefix = $skin.azure.namePrefix
$agentName = [string]$skin.labels.agentName
$sreGroup = "rg-$prefix-sre"
$demoTags = Get-SreReleaseDemoTags -Skin $skin

Write-Host "T12 workload: group '$($release.resourceGroup)' in $($release.location), web app '$($release.appName)', first release $($release.goodVersion)."

# 0. Never take over a group this scenario did not create: Remove-TicketingWorkload.ps1 deletes the group on its sreScenario=T12 tag.
if ([bool](Invoke-AzCli -Arguments @('group', 'exists', '--name', $release.resourceGroup, '-o', 'json') | ConvertFrom-Json)) {
    $existingGroup = Invoke-AzCli -Arguments @('group', 'show', '--name', $release.resourceGroup, '-o', 'json') | ConvertFrom-Json
    $existingTags = if ($existingGroup.PSObject.Properties['tags']) { $existingGroup.tags } else { $null }
    Assert-SreReleaseGroupOwnership -GroupName $release.resourceGroup -Exists $true -Tags $existingTags
}

# 1. The app runs from a GitHub release asset, so both versions have to exist before anything is deployed.
$missing = @(foreach ($version in @($release.goodVersion, $release.badVersion)) {
    $check = Test-SreReleasePackage -Url (Get-SreReleasePackageUrl -Settings $release -Version $version)
    if ($check.ok) { Write-Host "Release package $version is downloadable." } else { "$version (HTTP $($check.status))" }
})
if ($missing.Count) {
    $message = "Release package(s) not downloadable: $($missing -join ', '). Publish them first: the app repository's release workflow uploads ticketing-app-<tag>.zip when you push a tag."
    if ($WhatIf) { Write-Warning "$message A real deploy stops here." } else { throw $message }
}

# 2. Quota check. It needs an existing group to ask from; the dedicated SRE group is the one this layer owns anyway.
$sreGroupExists = [bool](Invoke-AzCli -Arguments @('group', 'exists', '--name', $sreGroup, '-o', 'json') | ConvertFrom-Json)
if (-not $sreGroupExists -and -not $WhatIf) {
    Write-Host "Creating the dedicated SRE group '$sreGroup' (free; infra/ticketing/main.bicep declares the same group)."
    $tagArguments = @($demoTags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    Invoke-AzCli -Arguments (@('group', 'create', '--name', $sreGroup, '--location', [string]$skin.azure.location, '--tags') + $tagArguments + @('-o', 'none')) | Out-Null
    $sreGroupExists = $true
}
$planExists = $false
if ((Invoke-AzCli -Arguments @('group', 'exists', '--name', $release.resourceGroup, '-o', 'json') | ConvertFrom-Json)) {
    $planId = "$($release.groupId)/providers/Microsoft.Web/serverfarms/$($release.planName)"
    $planExists = Test-AzResourceExists -ResourceId $planId
}
if ($planExists) {
    Write-Host 'The App Service plan already exists, so no new quota is needed.'
} elseif ($sreGroupExists) {
    Write-Host "Checking App Service quota for $($release.sku) in $($release.location) (nothing is created; about 1 to 2 minutes)..."
    Assert-SreReleaseQuota -SubscriptionId $SubscriptionId -CarrierGroup $sreGroup -Location $release.location -Sku $release.sku `
        -ProbeTemplate (Join-Path $repoRoot 'infra\ticketing\quota-probe.bicep')
    Write-Host 'App Service quota is available.'
} else {
    Write-Warning "The SRE group '$sreGroup' does not exist yet, so the quota check cannot run in this preview. It runs before anything is created when you deploy."
}

# 3. Adopt an existing grant on the web app instead of creating a second one (a second one fails with RoleAssignmentExists).
$principalId = $null
$adoptName = ''
if ($sreGroupExists) {
    $identityId = "/subscriptions/$SubscriptionId/resourceGroups/$sreGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$agentName-uami"
    if (Test-AzResourceExists -ResourceId $identityId) {
        $principalId = Invoke-AzCli -Arguments @('identity', 'show', '--ids', $identityId, '--query', 'principalId', '-o', 'tsv')
        Write-Host "Reusing the retained SRE identity (principal $principalId)."
        if (Test-AzResourceExists -ResourceId $release.appId) {
            $siteWriter = @(Get-SreArmRoleAssignments -SubscriptionId $SubscriptionId -ScopeId $release.appId -PrincipalId $principalId |
                Where-Object { $_.scope -ieq $release.appId -and ($_.roleDefinitionId -split '/')[-1] -ieq 'de139f84-1756-47ae-9be6-808fbbe84772' })
            if ($siteWriter.Count -gt 1) { throw 'The identity has duplicate Website Contributor grants on the web app. Reconcile them before deploying.' }
            if ($siteWriter.Count -eq 1) { $adoptName = $siteWriter[0].name; Write-Host 'The web app already has the identity''s write grant; keeping it.' }
        }
    }
}

# 4. Deploy (or preview).
$paramFile = Join-Path $env:TEMP "ticketing-params-$(Get-Random).json"
$parameterBody = Get-SreReleaseDeploymentParameters -Skin $skin -Settings $release -Version $release.goodVersion -SiteWriterAssignmentName $adoptName -Tags $demoTags
[IO.File]::WriteAllText($paramFile, ($parameterBody | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
$templateFile = Join-Path $repoRoot 'infra\ticketing\main.bicep'
$verb = if ($WhatIf) { 'what-if' } else { 'create' }
$deploymentName = "ticketing-workload-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
try {
    Write-Host "Running az deployment sub $verb..."
    $granted = Get-Date
    $resultText = Invoke-AzCli -Arguments @('deployment', 'sub', $verb, '--name', $deploymentName, '--location', [string]$skin.azure.location,
        '--template-file', $templateFile, '--parameters', "@$paramFile")
} finally {
    Remove-Item -LiteralPath $paramFile -Force -ErrorAction SilentlyContinue
}
if ($WhatIf) {
    Write-Host $resultText
    Write-Host 'What-if complete. Nothing was deployed.'
    return
}
$outputs = ($resultText | ConvertFrom-Json).properties.outputs
if ($principalId -and $outputs.managedIdentityPrincipalId.value -ne $principalId) {
    throw 'The deployment did not keep the retained identity. Stop and inspect identity and role assignments before going on.'
}
$principalId = $outputs.managedIdentityPrincipalId.value

# 5. Wait for the app to serve the first release.
$hostName = Get-SreReleaseAppHost -SubscriptionId $SubscriptionId -Settings $release
Write-Host "Waiting for https://$hostName/healthz to report $($release.goodVersion) (up to $HealthTimeoutSeconds s)..."
$summary = Wait-SreReleaseHealthy -HostName $hostName -Version $release.goodVersion -TimeoutSeconds $HealthTimeoutSeconds
Write-Host ''
Write-Host "T12 workload is serving $($release.goodVersion) (release $($summary.release))."
Write-Host "  Web app:    $($release.appName) in $($release.resourceGroup)"
Write-Host "  Identity:   $agentName-uami, principal $principalId (save it before you ever park the agent)"
Write-Host "  Grant time: $($granted.ToString('HH:mm')) local. A new role can take many minutes to work; Phase 0 saw up to about 27. Deploy the parent after that."
Write-Host 'Next: Deploy-SreAgent.ps1 with -ApproveParentCreation, then Initialize-SreConfiguration.ps1 -Apply (Deploy chains it); see docs/t12-friday-release.md.'
