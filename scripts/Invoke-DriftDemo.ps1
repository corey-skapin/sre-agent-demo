#Requires -Version 7.4
# The two tag names and the Benign, Risky and Critical pattern follow microsoft/sre-agent labs/terraform-drift-detection (scripts/induce-drift.ps1) at commit e6afdfc8a5e446b488325118b0c07da7c3d8462a. MIT, Copyright (c) Microsoft Corporation. See NOTICE.md.
<#
.SYNOPSIS
    Puts three small, harmless drifts on the ticketing web app, one Benign, one Risky and one Critical, so the Bicep drift scan has something to find, and puts them back.

.DESCRIPTION
    Status    Reads the web app and shows, for the three settings below, what the Bicep declares and what the app has.
    Start     Applies the three drifts with your own credentials: two extra tags (Benign), FTP state FtpsOnly instead of Disabled (Risky),
              and HTTPS only switched off (Critical). Nothing restarts and the app keeps serving.
    Reset     Puts the Bicep's values back: removes exactly those two tags, FTP state Disabled, HTTPS only on.

    These are demo-time actions on the web app that Deploy-TicketingWorkload.ps1 created (it must carry the sreScenario=T12 tag). They never touch the
    Arc estate, and the SRE agent never changes anything here: its drift scan only reports and proposes the revert.

    Use -WhatIf on Start or Reset to see what would happen without changing anything.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Status', 'Start', 'Reset')]
    [string]$Action,

    [string]$SkinPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\SreRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\DemoSkin.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SreRelease.psm1') -Force

$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if (-not (Test-SreReleaseScenario -Skin $skin)) { throw 'This skin does not require T12, so there is no ticketing web app to drift. See docs/proactive-checks.md.' }
Assert-SreContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null
$release = Get-SreReleaseSettings -Skin $skin -SubscriptionId $SubscriptionId
$app = $release.appName
$group = $release.resourceGroup
$extraTags = [ordered]@{ manual_update = 'true'; changed_by = 'portal_user' }

function Read-App {
    $site = Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('resource', 'show', '--ids', $release.appId, '-o', 'json') | ConvertFrom-Json -Depth 50
    $config = Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('webapp', 'config', 'show', '-g', $group, '-n', $app, '-o', 'json') | ConvertFrom-Json -Depth 50
    $tags = [ordered]@{}
    if ($site.PSObject.Properties['tags'] -and $site.tags) { foreach ($property in $site.tags.PSObject.Properties) { $tags[$property.Name] = [string]$property.Value } }
    [pscustomobject]@{ tags = $tags; httpsOnly = [bool]$site.properties.httpsOnly; ftpsState = [string]$config.ftpsState; owned = ($tags['sreScenario'] -ceq 'T12') }
}

function Show-App {
    param($State)
    $declared = Get-SreReleaseDemoTags -Skin $skin
    $extra = @($State.tags.Keys | Where-Object { $_ -notin $declared.Keys -and $_ -ne 'sreScenario' })
    $missing = @($declared.Keys | Where-Object { -not $State.tags.Contains($_) })
    $rows = @(
        @{ check = 'Tags (Benign)'; declared = 'the deploy tags and sreScenario=T12 only'; observed = $(if ($extra.Count -or $missing.Count) { "extra: $($extra -join ', ')$(if ($missing.Count) { "; missing: $($missing -join ', ')" })" } else { 'as declared' }); same = (-not $extra.Count -and -not $missing.Count) }
        @{ check = 'FTP state (Risky)'; declared = 'Disabled'; observed = $State.ftpsState; same = ($State.ftpsState -ceq 'Disabled') }
        @{ check = 'HTTPS only (Critical)'; declared = 'true'; observed = [string]$State.httpsOnly; same = $State.httpsOnly }
    )
    foreach ($row in $rows) { Write-Host ("{0,-24} declared {1,-40} observed {2,-30} {3}" -f $row.check, $row.declared, $row.observed, $(if ($row.same) { 'as declared' } else { 'DRIFT' })) }
    return $rows
}

$state = Read-App
if ($Action -ne 'Status' -and -not $state.owned) {
    throw "The web app '$app' does not carry the tag sreScenario=T12, so it is not the workload Deploy-TicketingWorkload.ps1 created. Nothing was changed."
}

switch ($Action) {
    'Status' { $null = Show-App -State $state }
    'Start' {
        if (-not $PSCmdlet.ShouldProcess($app, 'add the tags manual_update and changed_by (Benign), set the FTP state to FtpsOnly (Risky) and switch HTTPS only off (Critical)')) { return }
        Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments (@('tag', 'update', '--resource-id', $release.appId, '--operation', 'Merge', '--tags') + @($extraTags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) + @('-o', 'none')) | Out-Null
        Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('webapp', 'config', 'set', '-g', $group, '-n', $app, '--ftps-state', 'FtpsOnly', '-o', 'none') | Out-Null
        Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('webapp', 'update', '-g', $group, '-n', $app, '--https-only', 'false', '-o', 'none') | Out-Null
        $null = Show-App -State (Read-App)
        Write-Host 'Run the drift scan now: Invoke-ScheduledTask.ps1 -Action Run -Name bicep-drift-scan -Wait. It should report one Benign, one Risky and one Critical difference. Reset when you are done.'
    }
    'Reset' {
        if (-not $PSCmdlet.ShouldProcess($app, 'remove the tags manual_update and changed_by, set the FTP state back to Disabled and HTTPS only back on')) { return }
        $present = @($extraTags.Keys | Where-Object { $state.tags.Contains($_) })
        if ($present.Count) {
            Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments (@('tag', 'update', '--resource-id', $release.appId, '--operation', 'Delete', '--tags') + @($present | ForEach-Object { "$_=$($state.tags[$_])" }) + @('-o', 'none')) | Out-Null
        }
        if ($state.ftpsState -cne 'Disabled') { Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('webapp', 'config', 'set', '-g', $group, '-n', $app, '--ftps-state', 'Disabled', '-o', 'none') | Out-Null }
        if (-not $state.httpsOnly) { Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('webapp', 'update', '-g', $group, '-n', $app, '--https-only', 'true', '-o', 'none') | Out-Null }
        $rows = Show-App -State (Read-App)
        if (@($rows | Where-Object { -not $_.same }).Count) { throw 'The web app still differs from the Bicep after Reset. Run -Action Status and check it.' }
        Write-Host 'The web app matches the Bicep again.'
    }
}
